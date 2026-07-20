use v5.40;
use common::sense;

use File::Spec;
use FindBin;
use Test2::V0;

use lib File::Spec->catdir( $FindBin::Bin, '..', '..', 'lib' );

use QBTL::Process::QBT;

{

  package Local::TrackerAPI;

  use v5.40;
  use feature qw( signatures );
  no warnings qw( experimental::signatures );

  sub new ( $class ) {
    return bless {calls => 0}, $class;
  }

  sub torrents_trackers ( $self, $hash ) {
    $self->{calls}++;
    return {endpoint => 'torrents_trackers', hash => $hash};
  }

  sub execute_request ( $self, $request ) {
    return {
      ok   => 1,
      code => 200,
      body => '[{"url":"https://tracker.example.invalid/announce","status":2}]',
    };
  }

  sub calls ( $self ) {
    return $self->{calls};
  }
}

my $api     = Local::TrackerAPI->new;
my $process = QBTL::Process::QBT->new( api => $api );
my $hash    = '0123456789abcdef0123456789abcdef01234567';

is(
    $process->trackers( $hash, 1 ),
    {
     ok         => 1,
     action     => 'qbt_torrents_trackers',
     hash       => $hash,
     is_private => 1,
     skipped    => 1,
     reason     => 'private torrent uses torrents_info tracker',
     rows       => [],
     count      => 0,
    },
    'private torrent skips trackers API call', );

is( $api->calls, 0, 'private torrent made no trackers API request', );

is(
   $process->trackers( $hash, 0 ),
   {
    ok         => 1,
    action     => 'qbt_torrents_trackers',
    hash       => $hash,
    is_private => 0,
    request    => {
                endpoint => 'torrents_trackers',
                hash     => $hash,
    },
    result => {
      ok   => 1,
      code => 200,
      body => '[{"url":"https://tracker.example.invalid/announce","status":2}]',
    },
    rows => [
              {
               url    => 'https://tracker.example.invalid/announce',
               status => 2,
              },
    ],
    count => 1,
   },
   'public torrent fetches full tracker list', );

is( $api->calls, 1, 'public torrent made one trackers API request', );

like(
      dies { $process->trackers( $hash, undef ) },
      qr/is_private is required/,
      'caller must provide privacy classification', );

is( $api->calls, 1, 'missing privacy classification makes no API request', );

done_testing;
