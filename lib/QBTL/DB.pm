package QBTL::DB;

use v5.40;
use common::sense;
use feature qw( signatures );

use DBI;
use File::Basename qw( dirname );

sub new ( $class, %arg ) {
  die 'db_path is required' if !defined $arg{db_path};

  return bless \%arg, $class;
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

sub db_path ( $self ) {
  return $self->{db_path};
}

sub migrate ( $self, $dbh ) {
  my $sql = do {
    open my $fh, '<', 'share/migrations/001_initial.sql'
        or die "open migration: $!";
    local $/;
    <$fh>;
  };

  $dbh->do( $_ ) for grep {/\S/} split /;\s*/, $sql;

  return {
          ok      => 1,
          version => 1,};
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

1;
