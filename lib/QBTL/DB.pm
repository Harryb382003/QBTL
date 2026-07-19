package QBTL::DB;

use v5.40;
use common::sense;
use feature qw( signatures );

use DBI;
use File::Basename qw( dirname );
use File::Spec;

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

sub migrate ( $self, $dbh ) {
  my @files = $self->migration_files;

  for my $file ( @files ) {
    open my $fh, '<', $file
        or die "cannot read migration $file: $!";

    local $/;
    my $sql = <$fh>;
    close $fh;

    $dbh->begin_work;

    eval {
      $dbh->do( $sql );
      $dbh->commit;
      1;
    } or do {
      my $error = $@ || 'unknown migration error';

      eval { $dbh->rollback };

      die "migration failed for $file: $error";
    };
  }

  return scalar @files;
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

1;
