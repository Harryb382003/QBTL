package QBTL::DB;

use v5.40;
use common::sense;
use feature qw( signatures );

use DBI;
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
1;
