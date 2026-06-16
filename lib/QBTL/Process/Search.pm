package QBTL::Process::Search;

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

sub search_list ($self) {
  return $self->db_process->with_db(
    sub ( $db, $dbh ) {
      return {
        ok     => 1,
        action => 'search_list',
        fields => [ $db->qbt_info_columns($dbh) ],
      };
    }
  );
}

sub search ( $self, %arg ) {
  my $field = $arg{field};
  my $input = $arg{input};
  my $limit = $arg{limit} // 25;

  return $self->db_process->with_db(
    sub ( $db, $dbh ) {
      my $result = $db->search_qbt_info(
        $dbh,
        $field,
        $input,
        limit => $limit,
      );

      $result->{action} = 'search';

      return $result;
    }
  );
}

1;
