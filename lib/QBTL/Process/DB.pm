package QBTL::Process::DB;

use v5.40;
use common::sense;
use feature qw( signatures );

use QBTL::DB;

sub new ( $class, %arg ) {
  $arg{db} //= QBTL::DB->new(
    db_path => $arg{db_path},
  );

  return bless \%arg, $class;
}

sub db ($self) {
  return $self->{db};
}

sub with_db ( $self, $code ) {
  my $db = $self->db;

  my $connect = $db->connect;

  if ( !$connect->{ok} ) {
    return {
      ok        => 0,
      status    => 'db_connect_failed',
      db_result => $connect,
    };
  }

  my $dbh = $connect->{dbh};

  my $migration = $db->migrate($dbh);

  if ( !$migration->{ok} ) {
    $dbh->disconnect;

    return {
      ok        => 0,
      status    => 'db_migration_failed',
      db_result => $migration,
    };
  }

  my $result = $code->( $db, $dbh );

  $dbh->disconnect;

  return $result;
}

1;
