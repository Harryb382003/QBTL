package QBTL::DB;

use v5.40;
use common::sense;
use feature qw( signatures );

use DBI;
use JSON::PP       ();
use File::Basename qw( dirname );
use File::Spec;

#--------------------------------------------------------------------------
# Construction / connection
#--------------------------------------------------------------------------

sub new ( $class, %arg ) {
  die 'db_path is required'
      if !defined $arg{db_path} || $arg{db_path} eq '';

  return
      bless {
             db_path       => $arg{db_path},
             migration_dir => $arg{migration_dir},
      }, $class;
}

sub connect ( $self ) {
  $self->verify_path;

  my $dbh = DBI->connect(
                          'dbi:SQLite:dbname=' . $self->db_path,
                          q{}, q{},
                          {
                           RaiseError     => 1,
                           PrintError     => 0,
                           AutoCommit     => 1,
                           sqlite_unicode => 1,
                          }, );

  $dbh->do( 'PRAGMA foreign_keys = ON' );

  return dbh => $dbh;
}

sub db_path ( $self ) {
  return $self->{db_path};
}

#--------------------------------------------------------------------------
# Migration support
#--------------------------------------------------------------------------

sub migrate ( $self, $dbh ) {
  my @files = $self->migration_files;

  $dbh->do(
    q{
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version    INTEGER PRIMARY KEY,
      applied_at TEXT NOT NULL
    )
  }
  );

  my $applied = 0;

  for my $file ( @files ) {
    my ( $version ) = $file =~ m{/(\d+)_};

    die "cannot determine migration version from $file"
        if !defined $version;

    my ( $already_applied ) = $dbh->selectrow_array(
      q{
        SELECT 1
          FROM schema_migrations
         WHERE version = ?
      },
      undef,
      0 + $version, );

    next if $already_applied;

    open my $fh, '<', $file
        or die "cannot read migration $file: $!";

    local $/;
    my $sql = <$fh>;
    close $fh;

    $dbh->begin_work;

    eval {
      $dbh->do( $sql );

      $dbh->do(
        q{
          INSERT INTO schema_migrations (
            version,
            applied_at
          )
          VALUES (?, datetime('now'))
        },
        undef,
        0 + $version, );

      $dbh->commit;
      $applied++;

      1;
    } or do {
      my $error = $@ || 'unknown migration error';

      eval { $dbh->rollback };

      die "migration failed for $file: $error";
    };
  }

  return $applied;
}

sub migration_dir ( $self ) {
  return $self->{migration_dir} if defined $self->{migration_dir};

  return
      File::Spec->catdir( dirname( __FILE__ ),
                          '..', '..', 'share', 'migrations', );
}

sub migration_files ( $self ) {
  my $dir = $self->migration_dir;

  opendir my $dh, $dir or die "cannot open migration directory $dir: $!";

  my @files = sort grep {
    /\A\d+_[A-Za-z0-9_-]+\.sql\z/
        && -f File::Spec->catfile( $dir, $_ )
  } readdir $dh;

  closedir $dh;

  return map { File::Spec->catfile( $dir, $_ ) } @files;
}

sub verify_path ( $self ) {
  my $path   = $self->db_path;
  my $parent = dirname( $path );

  die "database parent directory does not exist: $parent" if !-d $parent;
  die "database path is a directory: $path"               if -d $path;

  return 1;
}

#--------------------------------------------------------------------------
# Produce
#--------------------------------------------------------------------------

sub _canonical_json ( $self, $value ) {
  return JSON::PP->new->canonical->encode( $value );
}

sub ensure_torrent ( $self, $dbh, $infohash, $discovered_on, $discovered_by, ) {
  die 'infohash is required'
      if !defined $infohash
      || $infohash eq '';

  die 'discovered_on is required'
      if !defined $discovered_on
      || $discovered_on eq '';

  die 'discovered_by is required'
      if !defined $discovered_by
      || $discovered_by eq '';

  $dbh->do(
    q{
      INSERT INTO torrents (
        infohash,
        discovered_on,
        discovered_by
      )
      VALUES (?, ?, ?)
      ON CONFLICT(infohash) DO UPDATE SET
        discovered_on = excluded.discovered_on,
        discovered_by = excluded.discovered_by
      WHERE excluded.discovered_on < torrents.discovered_on
    },
    undef,
    $infohash,
    $discovered_on,
    $discovered_by, );

  return $dbh->selectrow_hashref(
    q{
      SELECT
        infohash,
        discovered_on,
        discovered_by
      FROM torrents
      WHERE infohash = ?
    },
    undef,
    $infohash, );
}

sub _in_transaction ( $self, $dbh, $code ) {
  die 'transaction callback must be a code reference'
      if ref( $code ) ne 'CODE';

  my $started = $dbh->{AutoCommit} ? 1 : 0;
  $dbh->begin_work if $started;

  my $result = eval { $code->() };

  if ( $@ ) {
    my $error = $@;
    eval { $dbh->rollback } if $started;
    die $error;
  }

  $dbh->commit if $started;
  return $result;
}

sub _replace_retained_payload ( $self, $dbh, %arg ) {
  for my $required ( qw( table infohash fetched_on payload ) ) {
    die "$required is required"
        if !defined $arg{$required} || $arg{$required} eq '';
  }

  my $table = $arg{table};
  die "invalid retained payload table: $table"
      if $table !~ /\AAPI_[A-Za-z0-9_]+\z/;

  $dbh->do(
    qq{
      INSERT INTO $table (infohash, fetched_on, payload_json)
      VALUES (?, ?, ?)
      ON CONFLICT(infohash) DO UPDATE SET
        fetched_on = excluded.fetched_on,
        payload_json = excluded.payload_json
    },
    undef,
    $arg{infohash},
    $arg{fetched_on},
    $self->_canonical_json( $arg{payload} ), );

  return 1;
}

sub P_API_torrents_trackers ( $class ) {
  return {
    producer      => 'API_torrents_trackers',
    payload_table => 'API_torrents_trackers',
    index_table   => 'API_torrents_trackers_index',
    index_columns => [
      qw(
          tracker_index url status tier num_peers num_seeds
          num_leeches num_downloaded msg
      )
    ],
    validate => sub ( $rows ) {
      if ( ref( $rows ) ne 'ARRAY' ) {
        die 'trackers must be an array reference';
      }
      for my $tracker_index ( 0 .. $#{$rows} ) {
        my $row = $rows->[$tracker_index];
        if ( ref( $row ) ne 'HASH' ) {
          die "tracker row $tracker_index must be a hash reference";
        }
        if ( !defined $row->{url} || $row->{url} eq '' ) {
          die "tracker row $tracker_index requires url";
        }
      }
      return $rows;
    },
    index_rows => sub ( $rows ) {
      return [
        map {
          my $tracker_index = $_;
          my $row           = $rows->[$tracker_index];
          +{
            tracker_index  => $tracker_index,
            url            => $row->{url},
            status         => $row->{status},
            tier           => $row->{tier},
            num_peers      => $row->{num_peers},
            num_seeds      => $row->{num_seeds},
            num_leeches    => $row->{num_leeches},
            num_downloaded => $row->{num_downloaded},
            msg            => $row->{msg},};
        } 0 .. $#{$rows} ];
    },};
}

sub P_API_torrents_info ( $class ) {
  return {
    producer      => 'API_torrents_info',
    payload_table => 'API_torrents_info',
    index_table   => 'API_torrents_info_index',
    index_columns => [
      qw(
          name state progress save_path content_path category tags tracker
          amount_left size total_size added_on completion_on last_activity
          ratio is_private
      )
    ],
    validate => sub ( $rows ) {
      die 'rows must be an array reference'
          if ref( $rows ) ne 'ARRAY';

      my @prepared;

      for my $row ( $rows->@* ) {
        die 'API::torrents_info row must be a hash reference'
            if ref( $row ) ne 'HASH';

        my $infohash = $row->{hash};

        die 'API::torrents_info row requires hash'
            if !defined $infohash || $infohash eq '';

        push @prepared, {infohash => $infohash, row => $row};
      }

      return \@prepared;
    },
    index_row => sub ( $row ) {
      return {
        map { $_ => $row->{$_} }
            qw(
            name state progress save_path content_path category tags tracker
            amount_left size total_size added_on completion_on last_activity
            ratio is_private
            )};
    },};
}

sub P_API_torrents_files ( $class ) {
  return {
    producer      => 'API_torrents_files',
    payload_table => 'API_torrents_files',
    index_table   => 'API_torrents_files_index',
    index_columns => [
      qw(
          file_index name size progress priority is_seed
          piece_start piece_end availability
      )
    ],
    validate => sub ( $rows ) {
      die 'rows must be an array reference'
          if ref( $rows ) ne 'ARRAY';

      my %seen_index;

      for my $row ( $rows->@* ) {
        die 'API::torrents_files row must be a hash reference'
            if ref( $row ) ne 'HASH';

        die 'API::torrents_files row requires index'
            if !defined $row->{index};

        die "duplicate API::torrents_files index: $row->{index}"
            if $seen_index{$row->{index}}++;
      }

      return $rows;
    },
    index_rows => sub ( $rows ) {
      return [
        map {
          my $row = $_;
          my ( $piece_start, $piece_end );

          if ( ref( $row->{piece_range} ) eq 'ARRAY' ) {
            ( $piece_start, $piece_end ) = $row->{piece_range}->@*;
          }

          +{
            file_index   => 0 + $row->{index},
            name         => $row->{name},
            size         => $row->{size},
            progress     => $row->{progress},
            priority     => $row->{priority},
            is_seed      => $row->{is_seed},
            piece_start  => $piece_start,
            piece_end    => $piece_end,
            availability => $row->{availability},};
        } $rows->@* ];
    },};
}

sub P_API_torrents_properties ( $class ) {
  return {
    producer      => 'API_torrents_properties',
    payload_table => 'API_torrents_properties',
    index_table   => 'API_torrents_properties_index',
    index_columns => [qw( comment )],
    validate      => sub ( $properties ) {
      die 'properties must be a hash reference'
          if ref( $properties ) ne 'HASH';

      return $properties;
    },
    index_rows => sub ( $properties ) {
      return [ {comment => $properties->{comment}}, ];
    },};
}

#--------------------------------------------------------------------------
# Store
#--------------------------------------------------------------------------

sub _S_producer ( $self, $dbh, %arg ) {
  my $descriptor = $arg{descriptor};
  my $infohash   = $arg{infohash};
  my $payload    = $arg{payload};
  my $fetched_on = $arg{fetched_on};

  die 'producer descriptor is required'
      if ref( $descriptor ) ne 'HASH';

  die 'infohash is required'
      if !defined $infohash || $infohash eq '';

  die 'fetched_on is required'
      if !defined $fetched_on || $fetched_on eq '';

  my $prepared = $descriptor->{validate}->( $payload );
  my $rows     = $descriptor->{index_rows}->( $prepared );
  my @columns  = $descriptor->{index_columns}->@*;

  my $column_sql = join ', ', qw( infohash fetched_on ), @columns;
  my $value_sql  = join ', ', ( '?' ) x ( 2 + @columns );
  my $insert_sql = sprintf 'INSERT INTO %s (%s) VALUES (%s)',
      $descriptor->{index_table}, $column_sql, $value_sql;

  $self->_in_transaction(
    $dbh,
    sub {
      $self->ensure_torrent( $dbh, $infohash, $fetched_on,
                             $descriptor->{producer}, );

      $self->_replace_retained_payload(
                                        $dbh,
                                        table => $descriptor->{payload_table},
                                        infohash   => $infohash,
                                        fetched_on => $fetched_on,
                                        payload    => $prepared, );

      $dbh->do(
            'DELETE FROM ' . $descriptor->{index_table} . ' WHERE infohash = ?',
            undef, $infohash, );

      for my $row ( $rows->@* ) {
        $dbh->do( $insert_sql, undef, $infohash,
                  $fetched_on, @{$row}{@columns}, );
      }

      return 1;
    }, );

  return {
          ok       => 1,
          infohash => $infohash,
          seen     => scalar(
                          ref( $prepared ) eq 'ARRAY'
                          ? $prepared->@*
                          : 1
          ),
          stored     => scalar $rows->@*,
          fetched_on => 0 + $fetched_on,};
}

sub S_API_torrents_info ( $self, $dbh, $rows, $fetched_on = time ) {
  die 'fetched_on is required'
      if !defined $fetched_on || $fetched_on eq '';

  my $descriptor = $self->P_API_torrents_info;
  my $prepared   = $descriptor->{validate}->( $rows );
  my @columns    = $descriptor->{index_columns}->@*;

  my %existing;
  if ( $prepared->@* ) {
    my $placeholders = join q{,}, ( '?' ) x $prepared->@*;
    my $known = $dbh->selectcol_arrayref(
                                     'SELECT infohash FROM '
                                         . $descriptor->{payload_table}
                                         . " WHERE infohash IN ($placeholders)",
                                     undef,
                                     map { $_->{infohash} } $prepared->@*, );
    %existing = map { $_ => 1 } $known->@*;
  }

  my $column_sql = join ', ', qw( infohash fetched_on ), @columns;
  my $value_sql  = join ', ', ( '?' ) x ( 2 + @columns );
  my $update_sql = join ', ', map {"$_ = excluded.$_"} qw( fetched_on ),
      @columns;
  my $insert_sql = sprintf(
                            'INSERT INTO %s (%s) VALUES (%s) '
                                . 'ON CONFLICT(infohash) DO UPDATE SET %s',
                            $descriptor->{index_table},
                            $column_sql, $value_sql, $update_sql, );

  $self->_in_transaction(
    $dbh,
    sub {
      for my $item ( $prepared->@* ) {
        my $row       = $item->{row};
        my $infohash  = $item->{infohash};
        my $index_row = $descriptor->{index_row}->( $row );

        $self->ensure_torrent( $dbh, $infohash, $fetched_on,
                               $descriptor->{producer}, );

        $self->_replace_retained_payload(
                                          $dbh,
                                          table => $descriptor->{payload_table},
                                          infohash   => $infohash,
                                          fetched_on => $fetched_on,
                                          payload    => $row, );

        $dbh->do( $insert_sql, undef, $infohash, $fetched_on,
                  @{$index_row}{@columns}, );
      }

      return 1;
    }, );

  my $stored         = scalar $prepared->@*;
  my $existing_count = scalar grep { $existing{$_->{infohash}} } $prepared->@*;

  return {
          ok         => 1,
          seen       => scalar $rows->@*,
          stored     => $stored,
          new        => $stored - $existing_count,
          existing   => $existing_count,
          fetched_on => 0 + $fetched_on,};
}

sub S_API_torrents_files ( $self, $dbh, $infohash, $rows, $fetched_on = time ) {
  return
      $self->_S_producer(
                          $dbh,
                          descriptor => $self->P_API_torrents_files,
                          infohash   => $infohash,
                          payload    => $rows,
                          fetched_on => $fetched_on, );
}

sub S_API_torrents_properties ( $self, $dbh, $infohash, $properties,
                                $fetched_on = time )
{
  my $stored = $self->_S_producer(
                                 $dbh,
                                 descriptor => $self->P_API_torrents_properties,
                                 infohash   => $infohash,
                                 payload    => $properties,
                                 fetched_on => $fetched_on, );

  return {
          ok         => $stored->{ok},
          infohash   => $stored->{infohash},
          fetched_on => $stored->{fetched_on},};
}

sub S_API_torrents_trackers ( $self, $dbh, $infohash, $rows,
                              $fetched_on = time )
{
  return
      $self->_S_producer(
                          $dbh,
                          descriptor => $self->P_API_torrents_trackers,
                          infohash   => $infohash,
                          payload    => $rows,
                          fetched_on => $fetched_on, );
}

1;
