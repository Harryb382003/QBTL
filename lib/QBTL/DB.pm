package QBTL::DB;

use v5.40;
use common::sense;
use feature qw( signatures );

use DBI;
use File::Basename qw( dirname );
use File::Spec;

sub new ( $class, %arg ) {
  die 'db_path is required' if !defined $arg{db_path};

  $arg{migration_dir} //= File::Spec->catdir( 'share', 'migrations' );

  return bless \%arg, $class;
}

sub db_path ( $self ) {
  return $self->{db_path};
}

sub migration_dir ( $self ) {
  return $self->{migration_dir};
}

sub verify_path ( $self ) {
  my $db_path = $self->db_path;
  my $dir     = dirname( $db_path );

  my @problems;

  push @problems, "DB directory does not exist: $dir"
      if !-d $dir;

  push @problems, "DB directory is not writable: $dir"
      if -d $dir && !-w $dir;

  return @problems;
}

sub connect ( $self ) {
  my @problems = $self->verify_path;

  return {
          ok       => 0,
          status   => 'db_path_invalid',
          problems => \@problems,}
      if @problems;

  my $dbh = DBI->connect(
                          'dbi:SQLite:dbname=' . $self->db_path,
                          '', '',
                          {
                           RaiseError                       => 1,
                           PrintError                       => 0,
                           AutoCommit                       => 1,
                           sqlite_unicode                   => 1,
                           sqlite_use_immediate_transaction => 1,
                          }, );

  return {
          ok  => 1,
          dbh => $dbh,};
}

sub migration_files ( $self ) {
  my $dir = $self->migration_dir;

  opendir my $dh, $dir or die "opendir migration dir $dir: $!";

  my @files = sort
      map { File::Spec->catfile( $dir, $_ ) }
      grep {/\A\d+_.+\.sql\z/} readdir $dh;

  closedir $dh;

  return @files;
}

sub migrate ( $self, $dbh ) {
  my @files = $self->migration_files;

  for my $file ( @files ) {
    my $sql = do {
      open my $fh, '<', $file or die "open migration $file: $!";
      local $/;
      <$fh>;
    };

    $dbh->do( $_ ) for grep {/\S/} split /;\s*/, $sql;
  }

  return {
          ok              => 1,
          migration_count => scalar @files,};
}

1;
