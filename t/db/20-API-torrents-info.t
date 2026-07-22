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

my $first_hash  = '0123456789abcdef0123456789abcdef01234567';
my $second_hash = '89abcdef0123456789abcdef0123456789abcdef';
my $fetched_on  = 1784512046;

my $stored = $db->S_API_torrents_info(
                       $dbh,
                       [
                         {
                          hash          => $first_hash,
                          name          => 'First torrent',
                          state         => 'pausedUP',
                          progress      => 1,
                          save_path     => '/Volumes/One',
                          content_path  => '/Volumes/One/First torrent',
                          category      => 'test',
                          tags          => 'one,two',
                          tracker       => 'https://tracker.example/announce',
                          amount_left   => 0,
                          size          => 100,
                          total_size    => 100,
                          added_on      => 1700000000,
                          completion_on => 1700000100,
                          last_activity => 1700000200,
                          ratio         => 1.5,
                              => 1,
                          future_key => 'retained only in the complete payload',
                         },
                         {
                          hash         => $second_hash,
                          name         => 'Second torrent',
                          state        => 'downloading',
                          progress     => 0.5,
                          save_path    => '/Volumes/Two',
                          content_path => '/Volumes/Two/Second torrent',
                          amount_left  => 500,
                          size         => 1000,
                          total_size   => 1000,
                          added_on     => 1700000300,
                          ratio        => 0.25,
                             => 0,
                         },
                       ],
                       fetched_on => $fetched_on, );

is(
    $stored,
    {
     ok         => 1,
     seen       => 2,
     stored     => 2,
     new        => 2,
     existing   => 0,
     fetched_on => $fetched_on,
    },
    'complete torrents_info response stored', );

is(
  $dbh->selectall_arrayref(
    q{SELECT infohash, discovered_on, discovered_by FROM torrents ORDER BY
infohash},
    {Slice => {}},
  ),
  [
    {
     infohash      => $first_hash,
     discovered_on => $fetched_on,
     discovered_by => 'API_torrents_info',
    },
    {
     infohash      => $second_hash,
     discovered_on => $fetched_on,
     discovered_by => 'API_torrents_info',
    },
  ],
  'canonical torrent identities created from API hash values', );

my $payload = decode_json(
      $dbh->selectrow_array(
        q{SELECT payload_json FROM API_torrents_info WHERE infohash = ?}, undef,
        $first_hash, ) );

is( $payload->{hash}, $first_hash,
    'original API hash key retained in payload' );
is( $payload->{future_key},
    'retained only in the complete payload',
    'unindexed API key retained in complete payload' );

is(
  $dbh->selectrow_hashref(
    q{
        SELECT infohash, fetched_on, name, save_path, total_size,
        FROM API_torrents_info_index
        WHERE infohash = ?
      },
    undef,
    $first_hash,
  ),
  {
   infohash   => $first_hash,
   fetched_on => $fetched_on,
   name       => 'First torrent',
   save_path  => '/Volumes/One',
   total_size => 100,
    => 1,
  },
  'selected torrents_info fields indexed', );

my $updated_on = $fetched_on + 60;
my $updated = $db->S_API_torrents_info(
                                $dbh,
                                [
                                  {
                                   hash         => $first_hash,
                                   name         => 'First torrent renamed',
                                   state        => 'uploading',
                                   save_path    => '/Volumes/One',
                                   content_path => '/Volumes/One/First torrent',
                                   total_size   => 100,
                                      => 1,
                                  },
                                ],
                                fetched_on => $updated_on, );

is( $updated->{new},      0, 'repeat observation is not new' );
is( $updated->{existing}, 1, 'repeat observation counted as existing' );

is(
  $dbh->selectrow_hashref(
q{SELECT fetched_on, name, state FROM API_torrents_info_index WHERE infohash =
?},
    undef,
    $first_hash,
  ),
  {
   fetched_on => $updated_on,
   name       => 'First torrent renamed',
   state      => 'uploading',
  },
  'repeat fetch updates indexed representation', );

my $before = $dbh->selectrow_array( q{SELECT COUNT(*) FROM API_torrents_info} );
my $error  = dies {
  $db->S_API_torrents_info(
                          $dbh,
                          [
                            {
                             hash => 'fedcba9876543210fedcba9876543210fedcba98',
                             name => 'valid'
                            },
                            {name => 'missing hash'},
                          ],
                          fetched_on => $updated_on + 60, );
};

like( $error, qr/requires hash/, 'missing hash rejects the response' );
is( $dbh->selectrow_array( q{SELECT COUNT(*) FROM API_torrents_info} ),
    $before, 'invalid response leaves no partial rows' );

$dbh->disconnect;

done_testing;
