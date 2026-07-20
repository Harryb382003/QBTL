use v5.40;
use common::sense;

use File::Spec;
use File::Temp qw( tempdir );
use FindBin;
use JSON::PP qw( decode_json );
use Test2::V0;

use lib File::Spec->catdir( $FindBin::Bin, '..', '..', 'lib' );

use QBTL::DB;

my $temp_dir = tempdir( CLEANUP => 1 );
my $db = QBTL::DB->new(
     db_path       => File::Spec->catfile( $temp_dir, 'qbtl.db' ),
     migration_dir =>
         File::Spec->catdir( $FindBin::Bin, '..', '..', 'share', 'migrations' ),
);
my $dbh = $db->connect;
$db->migrate( $dbh );

my $hash       = '0123456789abcdef0123456789abcdef01234567';
my $fetched_on = 1784512046;
my $rows = [
             {
              url            => 'https://tracker.example.invalid/announce',
              status         => 2,
              tier           => 0,
              num_peers      => 4,
              num_seeds      => 8,
              num_leeches    => 1,
              num_downloaded => 12,
              msg            => 'Working',
              future_key     => 'retained only in complete payload',
             },
             {
              url    => '** [DHT] **',
              status =>  0,
              tier   => -1,
             }, ];

is(
    $db->S_API_torrents_trackers( $dbh, $hash, $rows, $fetched_on ),
    {
     ok         => 1,
     infohash   => $hash,
     seen       => 2,
     stored     => 2,
     fetched_on => $fetched_on,
    },
    'complete torrents_trackers response stored', );

my $payload = decode_json(
         $dbh->selectrow_array(
           q{SELECT payload_json FROM API_torrents_trackers WHERE infohash = ?},
           undef, $hash, ) );

is( $payload->[0]{future_key},
    'retained only in complete payload',
    'unindexed tracker key retained in complete payload', );

is(
  $dbh->selectrow_hashref(
    q{
        SELECT tracker_index, fetched_on, url, status, tier,
               num_peers, num_seeds, num_leeches, num_downloaded, msg
        FROM API_torrents_trackers_index
        WHERE infohash = ? AND tracker_index = 0
      },
    undef,
    $hash,
  ),
  {
   tracker_index  => 0,
   fetched_on     => $fetched_on,
   url            => 'https://tracker.example.invalid/announce',
   status         => 2,
   tier           => 0,
   num_peers      => 4,
   num_seeds      => 8,
   num_leeches    => 1,
   num_downloaded => 12,
   msg            => 'Working',
  },
  'selected tracker fields indexed', );

$db->S_API_torrents_trackers(
                          $dbh, $hash,
                          [
                            {
                             url => 'udp://tracker.example.invalid:80/announce',
                             status => 3}
                          ],
                          $fetched_on + 60, );

is(
    $dbh->selectrow_array(
         q{SELECT COUNT(*) FROM API_torrents_trackers_index WHERE infohash = ?},
         undef, $hash,
    ),
    1,
    'later response removes stale tracker rows', );

my $before = $dbh->selectrow_array(
           q{SELECT payload_json FROM API_torrents_trackers WHERE infohash = ?},
           undef, $hash, );

like(
  dies {
    $db->S_API_torrents_trackers( $dbh, $hash,
                                  [ {url => 'valid'}, {status => 2} ],
                                  $fetched_on + 120, );
  },
  qr/tracker row 1 requires url/,
  'invalid tracker response rejected', );

is(
    $dbh->selectrow_array(
           q{SELECT payload_json FROM API_torrents_trackers WHERE infohash = ?},
           undef, $hash,
    ),
    $before,
    'invalid response leaves prior tracker result intact', );

$dbh->disconnect;

done_testing;
