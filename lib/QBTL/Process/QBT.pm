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

sub fake_info_rows ($self) {
    return [
        {
            hash          => 'abc123',
            name          => 'Fake qBT Torrent One',
            state         => 'pausedUP',
            progress      => 1,
            save_path     => '/Downloads',
            content_path  => '/Downloads/Fake qBT Torrent One',
            category      => 'test',
            tags          => 'fake,offline',
            amount_left   => 0,
            total_size    => 1000,
            added_on      => 1700000000,
            completion_on => 1700000100,
            last_activity => 1700000200,
            tracker       => 'https://tracker.example.invalid/announce',
            ratio         => 1.0,
        },
        {
            hash          => 'def456',
            name          => 'Fake qBT Torrent Two',
            state         => 'downloading',
            progress      => 0.5,
            save_path     => '/Downloads',
            content_path  => '/Downloads/Fake qBT Torrent Two',
            category      => 'test',
            tags          => 'fake,offline',
            amount_left   => 500,
            total_size    => 2000,
            added_on      => 1700000300,
            completion_on => 0,
            last_activity => 1700000400,
            tracker       => 'https://tracker.example.invalid/announce',
            ratio         => 0.25,
        },
    ];
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
