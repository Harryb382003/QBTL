package QBTL::Process::QBT;

use v5.40;
use common::sense;
use feature qw( signatures );

use QBTL::QBT::API;

sub new ( $class, %arg ) {
  $arg{api} //= QBTL::QBT::API->new;

  return bless \%arg, $class;
}

sub api ( $self ) {
  return $self->{api};
}

sub torrents_info_request ( $self, %params ) {
  my $request = $self->api->torrents_info( %params );

  return {
          ok      => 1,
          action  => 'qbt_torrents_info',
          request => $request,};
}

sub version_request ( $self ) {
  my $request = $self->api->app_version;

  return {
          ok      => 1,
          action  => 'qbt_version',
          request => $request,};
}

1;
