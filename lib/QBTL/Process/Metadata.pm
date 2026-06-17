package QBTL::Process::Metadata;

use v5.40;
use common::sense;
use feature qw( signatures );

use QBTL::Process::WithDB;

sub new ( $class, %arg ) {
  my $self =
      {with_db => QBTL::Process::WithDB->new( db_path => $arg{db_path}, ),};

  return bless $self, $class;
}

sub key ( $self, %arg ) {
  return $self->{with_db}->with_db(
    sub ( $db, $dbh ) {
      return
          $db->hash_key_detail(
                                $dbh,
                                key   => $arg{key},
                                limit => $arg{limit} // 25, );
    } );
}

sub keys ( $self ) {
  return $self->{with_db}->with_db(
    sub ( $db, $dbh ) {
      return $db->hash_keys( $dbh );
    } );
}

sub set_manual ( $self, %arg ) {
  return $self->{with_db}->with_db(
    sub ( $db, $dbh ) {
      return
          $db->set_manual_value(
                                 $dbh,
                                 hash  => $arg{hash},
                                 key   => $arg{key},
                                 value => $arg{value},
                                 note  => $arg{note}, );
    } );
}

sub get_manual ( $self, %arg ) {
  return $self->{with_db}->with_db(
    sub ( $db, $dbh ) {
      return $db->manual_values_for_hash( $dbh, $arg{hash} );
    } );
}

sub unset_manual ( $self, %arg ) {
  return $self->{with_db}->with_db(
    sub ( $db, $dbh ) {
      return
          $db->unset_manual_value(
                                   $dbh,
                                   hash => $arg{hash},
                                   key  => $arg{key}, );
    } );
}

sub promote ( $self, %arg ) {
  return $self->{with_db}->with_db(
    sub ( $db, $dbh ) {
      return $db->promote_hash_key(
        $dbh,
        key    => $arg{key},
        column => $arg{column},
      );
    }
  );
}

sub promoted ($self) {
  return $self->{with_db}->with_db(
    sub ( $db, $dbh ) {
      return $db->promoted_hash_keys($dbh);
    }
  );
}

1;
