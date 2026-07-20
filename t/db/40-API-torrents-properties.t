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

my $properties = {
                  save_path     => '/Downloads/example',
                  creation_date => 1700000000,
                  piece_size    => 1048576,
                  comment    => 'https://tracker.example.invalid/details/123',
                  created_by => 'Example Creator',
                  total_size => 2000,
                  future_key => 'retained only in complete payload',};

is(
    $db->S_API_torrents_properties( $dbh, $hash, $properties, $fetched_on, ),
    {
     ok         => 1,
     infohash   => $hash,
     fetched_on => $fetched_on,
    },
    'complete torrents_properties response stored', );

my $payload = decode_json(
       $dbh->selectrow_array(
         q{SELECT payload_json FROM API_torrents_properties WHERE infohash = ?},
         undef, $hash, ) );

is( $payload->{future_key},
    'retained only in complete payload',
    'unindexed property retained in complete payload', );

is(
  $dbh->selectrow_hashref(
    q{
        SELECT fetched_on, comment
        FROM API_torrents_properties_index
        WHERE infohash = ?
      },
    undef,
    $hash,
  ),
  {
   fetched_on => $fetched_on,
   comment    => 'https://tracker.example.invalid/details/123',
  },
  'torrent comment indexed', );

$db->S_API_torrents_properties(
         $dbh, $hash,
         {
          %{$properties},
          comment => 'UPDATED URL: https://tracker.example.invalid/details/456',
         },
         $fetched_on + 60, );

is(
  $dbh->selectrow_hashref(
    q{
        SELECT fetched_on, comment
        FROM API_torrents_properties_index
        WHERE infohash = ?
      },
    undef,
    $hash,
  ),
  {
   fetched_on => $fetched_on + 60,
   comment    => 'UPDATED URL: https://tracker.example.invalid/details/456',
  },
  'later properties response replaces indexed comment', );

my $before = $dbh->selectrow_array(
         q{SELECT payload_json FROM API_torrents_properties WHERE infohash = ?},
         undef, $hash, );

like(
  dies {
    $db->S_API_torrents_properties( $dbh, $hash, [], $fetched_on + 120, );
  },
  qr/properties must be a hash reference/,
  'invalid properties response rejected', );

is(
    $dbh->selectrow_array(
         q{SELECT payload_json FROM API_torrents_properties WHERE infohash = ?},
         undef, $hash,
    ),
    $before,
    'invalid response leaves previous complete payload intact', );

$dbh->disconnect;

done_testing;
