package QBTL::Process::Browse;

use v5.40;
use common::sense;
use feature qw( signatures );

use QBTL::Process::DB;

sub new ( $class, %arg ) {
  $arg{db_process} //= QBTL::Process::DB->new(
    db_path => $arg{db_path},
  );

  return bless \%arg, $class;
}

sub db_process ($self) {
  return $self->{db_process};
}

sub summary ($self) {
  return $self->db_process->with_db(
    sub ( $db, $dbh ) {
      return {
        ok      => 1,
        action  => 'browse_summary',
        summary => $db->qbt_summary($dbh),
      };
    }
  );
}

sub random ($self) {
  return $self->db_process->with_db(
    sub ( $db, $dbh ) {
      return {
        ok     => 1,
        action => 'browse_random',
        row    => $db->random_qbt_info($dbh),
      };
    }
  );
}

1;
