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

  return {
          ok  => 1,
          dbh => $dbh,};

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
# Consume
#--------------------------------------------------------------------------

sub C_local_torrent_file_count ( $self, $dbh ) {
  my ( $count ) =
      $dbh->selectrow_array( 'SELECT COUNT(*) FROM local_torrent_files' );

  return $count // 0;
}

sub C_local_fastresume_file_count ( $self, $dbh ) {
  my ( $count ) =
      $dbh->selectrow_array( 'SELECT COUNT(*) FROM local_fastresume_files' );

  return $count // 0;
}

#--------------------------------------------------------------------------
# Produce
#--------------------------------------------------------------------------

sub _canonical_json ( $self, $value ) {
  return JSON::PP->new->canonical->encode( $value );
}

sub ensure_torrent ( $self, $dbh, $hash, $discovered_on, $discovered_by, ) {
  die 'hash is required'
      if !defined $hash
      || $hash eq '';

  die 'discovered_on is required'
      if !defined $discovered_on
      || $discovered_on eq '';

  die 'discovered_by is required'
      if !defined $discovered_by
      || $discovered_by eq '';

  $dbh->do(
    q{
      INSERT INTO torrents (
        hash,
        discovered_on,
        discovered_by
      )
      VALUES (?, ?, ?)
      ON CONFLICT(hash) DO UPDATE SET
        discovered_on = excluded.discovered_on,
        discovered_by = excluded.discovered_by
      WHERE excluded.discovered_on < torrents.discovered_on
    },
    undef,
    $hash,
    $discovered_on,
    $discovered_by, );

  return $dbh->selectrow_hashref(
    q{
      SELECT
        hash,
        discovered_on,
        discovered_by
      FROM torrents
      WHERE hash = ?
    },
    undef,
    $hash, );
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
  for my $required ( qw( table hash fetched_on payload ) ) {
    die "$required is required"
        if !defined $arg{$required} || $arg{$required} eq '';
  }

  my $table = $arg{table};
  die "invalid retained payload table: $table"
      if $table !~ /\AAPI_[A-Za-z0-9_]+\z/;

  $dbh->do(
    qq{
      INSERT INTO $table (hash, fetched_on, payload_json)
      VALUES (?, ?, ?)
      ON CONFLICT(hash) DO UPDATE SET
        fetched_on = excluded.fetched_on,
        payload_json = excluded.payload_json
    },
    undef,
    $arg{hash},
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
          ratio private
      )
    ],
    validate => sub ( $rows ) {
      die 'rows must be an array reference'
          if ref( $rows ) ne 'ARRAY';

      my @prepared;

      for my $row ( $rows->@* ) {
        die 'API::torrents_info row must be a hash reference'
            if ref( $row ) ne 'HASH';

        my $hash = $row->{hash};

        die 'API::torrents_info row requires hash'
            if !defined $hash || $hash eq '';

        push @prepared, {hash => $hash, row => $row};
      }

      return \@prepared;
    },
    index_row => sub ( $row ) {
      return {
        map { $_ => $row->{$_} }
            qw(
            name state progress save_path content_path category tags tracker
            amount_left size total_size added_on completion_on last_activity
            ratio private
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
  my $hash       = $arg{hash};
  my $payload    = $arg{payload};
  my $fetched_on = $arg{fetched_on};

  die 'producer descriptor is required'
      if ref( $descriptor ) ne 'HASH';

  die 'hash is required'
      if !defined $hash || $hash eq '';

  die 'fetched_on is required'
      if !defined $fetched_on || $fetched_on eq '';

  my $prepared = $descriptor->{validate}->( $payload );
  my $rows     = $descriptor->{index_rows}->( $prepared );
  my @columns  = $descriptor->{index_columns}->@*;

  my $column_sql = join ', ', qw( hash fetched_on ), @columns;
  my $value_sql  = join ', ', ( '?' ) x ( 2 + @columns );
  my $insert_sql = sprintf 'INSERT INTO %s (%s) VALUES (%s)',
      $descriptor->{index_table}, $column_sql, $value_sql;

  $self->_in_transaction(
    $dbh,
    sub {
      $self->ensure_torrent( $dbh, $hash, $fetched_on, $descriptor->{producer},
      );

      $self->_replace_retained_payload(
                                        $dbh,
                                        table => $descriptor->{payload_table},
                                        hash  => $hash,
                                        fetched_on => $fetched_on,
                                        payload    => $prepared, );

      $dbh->do( 'DELETE FROM ' . $descriptor->{index_table} . ' WHERE hash = ?',
                undef, $hash, );

      for my $row ( $rows->@* ) {
        $dbh->do( $insert_sql, undef, $hash, $fetched_on, @{$row}{@columns}, );
      }

      return 1;
    }, );

  return {
          ok   => 1,
          hash => $hash,
          seen => scalar(
                          ref( $prepared ) eq 'ARRAY'
                          ? $prepared->@*
                          : 1
          ),
          stored     => scalar $rows->@*,
          fetched_on => 0 + $fetched_on,};
}

sub S_API_torrents_refresh ( $self, %arg ) {
  my $method = $arg{method};

  my $reject = sub ( $error, %extra ) {
    warn "$error\n";

    return {
            ok                 => 0,
            rejected           => 1,
            preserved_existing => 1,
            action             => 'qbt_API_refresh_rejected',
            method             => $method,
            %extra,
            problems => [ {error => $error,} ],};
  };

  return $reject->( 'API torrents refresh method is required' )
      if !defined $method || $method eq '';

  return $reject->( "unsupported API torrents method: $method" )
      unless $method =~ /\A(?:info|files|properties|trackers)\z/;

  my $db = $arg{db};
  return $reject->( 'db is required' ) if !defined $db;

  my $dbh = $arg{dbh};
  return $reject->( 'dbh is required' ) if !defined $dbh;

  my $payload = exists $arg{payload} ? $arg{payload} : $arg{rows};
  return $reject->( "API_torrents_${method} payload is required" )
      if !defined $payload;

  my $hash = $arg{hash};
  return $reject->( "hash is required for API_torrents_$method" )
      if $method ne 'info' && ( !defined $hash || $hash eq '' );

  my $fetched_on   = $arg{fetched_on} // time;
  my $store_method = "S_API_torrents_$method";

  my $store = eval {
    return $method eq 'info'
        ? $db->$store_method( $dbh, $payload, fetched_on => $fetched_on, )
        : $db->$store_method( $dbh, $hash, $payload, fetched_on => $fetched_on,
        );
  };

  if ( !$store || !$store->{ok} ) {
    my $error = $@ || "API_torrents_${method} store failed";
    return $reject->( $error, hash => $hash, );
  }

  my $action =
      $method eq 'info'
      ? 'qbt_refresh'
      : "qbt_torrents_${method}_refresh";

  return {
          %{$store},
          action => $action,
          $method eq 'info' ? ( removed => $store->{removed} // 0 ) : (),
          problems => [],};
}

sub S_API_torrents_info ( $self, $dbh, $rows, %arg ) {
  my $descriptor = $self->P_API_torrents_info;
  my $prepared   = $descriptor->{validate}->( $rows );
  my @columns    = $descriptor->{index_columns}->@*;
  my $fetched_on = $arg{fetched_on} // time;

  die 'fetched_on is required'
      if !defined $fetched_on || $fetched_on eq '';

  my %existing;
  if ( $prepared->@* ) {
    my $placeholders = join q{,}, ( '?' ) x $prepared->@*;
    my $known = $dbh->selectcol_arrayref(
                                         'SELECT hash FROM '
                                             . $descriptor->{payload_table}
                                             . " WHERE hash IN ($placeholders)",
                                         undef,
                                         map { $_->{hash} } $prepared->@*, );
    %existing = map { $_ => 1 } $known->@*;
  }

  my $column_sql = join ', ', qw( hash fetched_on ), @columns;
  my $value_sql  = join ', ', ( '?' ) x ( 2 + @columns );
  my $update_sql = join ', ', map {"$_ = excluded.$_"} qw( fetched_on ),
      @columns;
  my $insert_sql = sprintf(
                            'INSERT INTO %s (%s) VALUES (%s) '
                                . 'ON CONFLICT(hash) DO UPDATE SET %s',
                            $descriptor->{index_table},
                            $column_sql, $value_sql, $update_sql, );

  $self->_in_transaction(
    $dbh,
    sub {
      for my $item ( $prepared->@* ) {
        my $row       = $item->{row};
        my $hash      = $item->{hash};
        my $index_row = $descriptor->{index_row}->( $row );

        $self->ensure_torrent( $dbh, $hash, $fetched_on,
                               $descriptor->{producer}, );

        $self->_replace_retained_payload(
                                          $dbh,
                                          table => $descriptor->{payload_table},
                                          hash  => $hash,
                                          fetched_on => $fetched_on,
                                          payload    => $row, );

        $dbh->do( $insert_sql, undef, $hash, $fetched_on,
                  @{$index_row}{@columns}, );
      }

      return 1;
    }, );

  my $stored         = scalar $prepared->@*;
  my $existing_count = scalar grep { $existing{$_->{hash}} } $prepared->@*;

  return {
          ok         => 1,
          seen       => scalar $rows->@*,
          stored     => $stored,
          new        => $stored - $existing_count,
          existing   => $existing_count,
          fetched_on => 0 + $fetched_on,};
}

sub S_API_torrents_files ( $self, $dbh, $hash, $rows, %arg ) {
  my $fetched_on = $arg{fetched_on} // time;
  return
      $self->_S_producer(
                          $dbh,
                          descriptor => $self->P_API_torrents_files,
                          hash       => $hash,
                          payload    => $rows,
                          fetched_on => $fetched_on, );
}

sub S_API_torrents_properties ( $self, $dbh, $hash, $properties, %arg ) {
  my $fetched_on = $arg{fetched_on} // time;
  my $stored = $self->_S_producer(
                                 $dbh,
                                 descriptor => $self->P_API_torrents_properties,
                                 hash       => $hash,
                                 payload    => $properties,
                                 fetched_on => $fetched_on, );

  return {
          ok         => $stored->{ok},
          hash       => $stored->{hash},
          fetched_on => $stored->{fetched_on},};
}

sub S_API_torrents_trackers ( $self, $dbh, $hash, $rows, %arg ) {
  my $fetched_on = $arg{fetched_on} // time;
  return
      $self->_S_producer(
                          $dbh,
                          descriptor => $self->P_API_torrents_trackers,
                          hash       => $hash,
                          payload    => $rows,
                          fetched_on => $fetched_on, );
}

sub S_local_torrent_file_upsert ( $self, $dbh, $row ) {
  die 'dbh is required'
      if !$dbh;

  die 'local torrent path is required'
      if !defined $row->{path} || $row->{path} eq q{};

  my $sth = $dbh->prepare(
    <<'SQL'
INSERT INTO local_torrent_files (
    path,
    size,
    mtime,
    backend,
    seen_on
)
VALUES (
    ?,
    ?,
    ?,
    ?,
    CURRENT_TIMESTAMP
)
ON CONFLICT(path) DO UPDATE SET
    size    = excluded.size,
    mtime   = excluded.mtime,
    backend = excluded.backend,
    seen_on = CURRENT_TIMESTAMP
SQL
  );

  $sth->execute( $row->{path}, $row->{size}, $row->{mtime}, $row->{backend}, );

  return {
          ok   => 1,
          path => $row->{path},};
}

sub S_local_torrent_parse_update ( $self, $dbh, $row ) {
  die 'dbh is required'
      if !$dbh;

  die 'local torrent path is required'
      if !defined $row->{path} || $row->{path} eq q{};

  my $sth = $dbh->prepare(
    <<'SQL'
UPDATE local_torrent_files
SET
    hash           = ?,
    torrent_name       = ?,
    comment            = ?,
    announce           = ?,
    created_by         = ?,
    creation_date      = ?,
    parsed_on          = CURRENT_TIMESTAMP,
    parse_ok           = ?,
    parse_problem      = ?,
    payload_kind       = ?,
    payload_root_name  = ?,
    payload_file_count = ?,
    payload_total_size = ?,
    payload_probe_path = ?,
    payload_probe_name = ?
WHERE path = ?
SQL
  );

  $sth->execute(
                 $row->{hash},               $row->{torrent_name},
                 $row->{comment},            $row->{announce},
                 $row->{created_by},         $row->{creation_date},
                 $row->{parse_ok},           $row->{parse_problem},
                 $row->{payload_kind},       $row->{payload_root_name},
                 $row->{payload_file_count}, $row->{payload_total_size},
                 $row->{payload_probe_path}, $row->{payload_probe_name},
                 $row->{path}, );

  my $changed = $sth->rows;

  return {
          ok      => $changed > 0 ? 1 : 0,
          path    => $row->{path},
          changed => $changed,};
}

1;
