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

sub refresh_info_rows ( $self, %arg ) {
    my $db   = $arg{db}   // die 'db is required';
    my $dbh  = $arg{dbh}  // die 'dbh is required';
    my $rows = $arg{rows} // die 'rows is required';

    my $store = $self->store_info_rows(
        dbh  => $dbh,
        db   => $db,
        rows => $rows,
    );

    return {
        ok       => $store->{ok},
        action   => 'qbt_refresh',
        seen     => $store->{seen},
        stored   => $store->{stored},
        problems => $store->{problems},
    };
}

sub store_info_rows ( $self, %arg ) {
  my $db   = $arg{db}   // die 'db is required';
  my $dbh  = $arg{dbh}  // die 'dbh is required';
  my $rows = $arg{rows} // die 'rows is required';

  my $seen   = 0;
  my $stored = 0;
  my @problems;

  for my $row ( @{$rows} ) {
    $seen++;

    my $result = eval { $db->upsert_qbt_info( $dbh, $row ); };

    if ( !$result || !$result->{ok} ) {
      push @problems,
          {
           hash  => $row->{hash},
           error => $@ || 'qbt_info upsert failed',};
      next;
    }

    $stored++;
  }

  return {
          ok       => @problems ? 0 : 1,
          seen     => $seen,
          stored   => $stored,
          problems => \@problems,};
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
