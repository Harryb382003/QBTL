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

sub store_info_rows ( $self, %arg ) {
    my $db   = $arg{db}   // die 'db is required';
    my $dbh  = $arg{dbh}  // die 'dbh is required';
    my $rows = $arg{rows} // die 'rows is required';

    my $stored = 0;

    for my $row ( @{$rows} ) {
        my $result = $db->upsert_qbt_info( $dbh, $row );

        $stored++ if $result->{ok};
    }

    return {
        ok     => 1,
        stored => $stored,
    };
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
