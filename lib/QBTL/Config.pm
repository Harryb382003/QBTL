package QBTL::Config;

use v5.40;
use common::sense;
use feature qw( signatures );

sub new ($class, %arg) {
    $arg{db_path} //= 'var/qbtl.sqlite';
    $arg{qbt_url} //= 'http://localhost:8080';

    return bless \%arg, $class;
}

sub db_path ($self) {
    return $self->{db_path};
}

sub qbt_url ($self) {
    return $self->{qbt_url};
}

1;
