package QBTL::DB;

use v5.40;
use common::sense;
use feature qw( signatures );

use DBI;
use JSON::PP ();
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
# Retained producer output helpers
#--------------------------------------------------------------------------

sub _canonical_json ( $self, $value ) {
  return JSON::PP->new->canonical->encode( $value );
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
    $self->_canonical_json( $arg{payload} ),
  );

  return 1;
}

#--------------------------------------------------------------------------
# Torrent identity
#--------------------------------------------------------------------------

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

#--------------------------------------------------------------------------
# API::torrents_info retained output
#--------------------------------------------------------------------------

sub store_API_torrents_info ( $self, $dbh, $rows, $fetched_on = time ) {
  die 'rows must be an array reference'
      if ref( $rows ) ne 'ARRAY';

  die 'fetched_on is required'
      if !defined $fetched_on || $fetched_on eq '';

  my @prepared;

  for my $row ( @{$rows} ) {
    die 'API::torrents_info row must be a hash reference'
        if ref( $row ) ne 'HASH';

    my $infohash = $row->{hash};

    die 'API::torrents_info row requires hash'
        if !defined $infohash || $infohash eq '';

    push @prepared, { infohash => $infohash, row => $row };
  }

  my %existing;
  if ( @prepared ) {
    my $placeholders = join q{,}, ('?') x @prepared;
    my $known = $dbh->selectcol_arrayref(
      "SELECT infohash FROM API_torrents_info WHERE infohash IN ($placeholders)",
      undef,
      map { $_->{infohash} } @prepared,
    );
    %existing = map { $_ => 1 } @{$known};
  }

  $self->_in_transaction(
    $dbh,
    sub {
      for my $item ( @prepared ) {
        my $row      = $item->{row};
        my $infohash = $item->{infohash};

        $self->ensure_torrent(
          $dbh,
          $infohash,
          $fetched_on,
          'API_torrents_info',
        );

        $self->_replace_retained_payload(
          $dbh,
          table      => 'API_torrents_info',
          infohash   => $infohash,
          fetched_on => $fetched_on,
          payload    => $row,
        );

        $dbh->do(
          q{
            INSERT INTO API_torrents_info_index (
              infohash, fetched_on, name, state, progress, save_path,
              content_path, category, tags, tracker, amount_left, size,
              total_size, added_on, completion_on, last_activity, ratio,
              is_private
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(infohash) DO UPDATE SET
              fetched_on    = excluded.fetched_on,
              name          = excluded.name,
              state         = excluded.state,
              progress      = excluded.progress,
              save_path     = excluded.save_path,
              content_path  = excluded.content_path,
              category      = excluded.category,
              tags          = excluded.tags,
              tracker       = excluded.tracker,
              amount_left   = excluded.amount_left,
              size          = excluded.size,
              total_size    = excluded.total_size,
              added_on      = excluded.added_on,
              completion_on = excluded.completion_on,
              last_activity = excluded.last_activity,
              ratio         = excluded.ratio,
              is_private    = excluded.is_private
          },
          undef,
          $infohash,
          $fetched_on,
          @{$row}{qw(
              name state progress save_path content_path category tags tracker
              amount_left size total_size added_on completion_on last_activity
              ratio is_private
          )},
        );
      }

      return 1;
    },
  );

  my $stored = scalar @prepared;
  my $existing_count = scalar grep { $existing{ $_->{infohash} } } @prepared;

  return {
          ok         => 1,
          seen       => scalar @{$rows},
          stored     => $stored,
          new        => $stored - $existing_count,
          existing   => $existing_count,
          fetched_on => 0 + $fetched_on,
         };
}

#--------------------------------------------------------------------------
# API::torrents_files retained output
#--------------------------------------------------------------------------

sub store_API_torrents_files ( $self, $dbh, $infohash, $rows, $fetched_on = time ) {
  die 'infohash is required'
      if !defined $infohash || $infohash eq '';

  die 'rows must be an array reference'
      if ref( $rows ) ne 'ARRAY';

  die 'fetched_on is required'
      if !defined $fetched_on || $fetched_on eq '';

  my @prepared;
  my %seen_index;

  for my $row ( @{$rows} ) {
    die 'API::torrents_files row must be a hash reference'
        if ref( $row ) ne 'HASH';

    die 'API::torrents_files row requires index'
        if !defined $row->{index};

    die "duplicate API::torrents_files index: $row->{index}"
        if $seen_index{ $row->{index} }++;

    my ( $piece_start, $piece_end );
    if ( ref( $row->{piece_range} ) eq 'ARRAY' ) {
      ( $piece_start, $piece_end ) = @{ $row->{piece_range} };
    }

    push @prepared,
        {
         row         => $row,
         file_index  => 0 + $row->{index},
         piece_start => $piece_start,
         piece_end   => $piece_end,
        };
  }

  $self->_in_transaction(
    $dbh,
    sub {
      $self->ensure_torrent(
        $dbh,
        $infohash,
        $fetched_on,
        'API_torrents_files',
      );

      $self->_replace_retained_payload(
        $dbh,
        table      => 'API_torrents_files',
        infohash   => $infohash,
        fetched_on => $fetched_on,
        payload    => $rows,
      );

      $dbh->do(
        q{DELETE FROM API_torrents_files_index WHERE infohash = ?},
        undef,
        $infohash,
      );

      for my $item ( @prepared ) {
        my $row = $item->{row};

        $dbh->do(
          q{
            INSERT INTO API_torrents_files_index (
              infohash, file_index, fetched_on, name, size, progress,
              priority, is_seed, piece_start, piece_end, availability
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          },
          undef,
          $infohash,
          $item->{file_index},
          $fetched_on,
          @{$row}{qw( name size progress priority is_seed )},
          $item->{piece_start},
          $item->{piece_end},
          $row->{availability},
        );
      }

      return 1;
    },
  );

  return {
          ok         => 1,
          infohash   => $infohash,
          seen       => scalar @{$rows},
          stored     => scalar @prepared,
          fetched_on => 0 + $fetched_on,
         };
}

1;
