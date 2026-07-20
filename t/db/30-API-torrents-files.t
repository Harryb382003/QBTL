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
   index        => 0,
   name         => 'Disc 1/movie.mkv',
   size         => 1000,
   progress     => 1,
   priority     => 1,
   is_seed      => 1,
   piece_range  => [ 0, 9 ],
   availability => 2.5,
   future_key   => 'retained only in complete payload',
  },
  {
   index        => 1,
   name         => 'Disc 2/extra.mkv',
   size         => 500,
   progress     => 0.5,
   priority     => 6,
   is_seed      => 0,
   piece_range  => [ 10, 14 ],
   availability => 1.25,
  },
];

is(
    $db->store_API_torrents_files( $dbh, $hash, $rows, $fetched_on ),
    {
     ok         => 1,
     infohash   => $hash,
     seen       => 2,
     stored     => 2,
     fetched_on => $fetched_on,
    },
    'complete torrents_files response stored',
);

my $payload = decode_json(
    $dbh->selectrow_array(
      q{SELECT payload_json FROM API_torrents_files WHERE infohash = ?},
      undef,
      $hash,
    )
);

is( scalar @{$payload}, 2, 'complete file-list payload retained together' );
is(
    $payload->[0]{future_key},
    'retained only in complete payload',
    'unindexed file key retained in complete payload',
);

is(
    $dbh->selectrow_hashref(
      q{
        SELECT file_index, fetched_on, name, size, progress, priority,
               is_seed, piece_start, piece_end, availability
        FROM API_torrents_files_index
        WHERE infohash = ? AND file_index = 0
      },
      undef,
      $hash,
    ),
    {
     file_index   => 0,
     fetched_on   => $fetched_on,
     name         => 'Disc 1/movie.mkv',
     size         => 1000,
     progress     => 1,
     priority     => 1,
     is_seed      => 1,
     piece_start  => 0,
     piece_end    => 9,
     availability => 2.5,
    },
    'selected torrents_files fields indexed',
);

$db->store_API_torrents_files(
    $dbh,
    $hash,
    [
      {
       index        => 0,
       name         => 'movie-renamed.mkv',
       size         => 1000,
       progress     => 1,
       priority     => 1,
       is_seed      => 1,
       piece_range  => [ 0, 9 ],
       availability => 3,
      },
    ],
    $fetched_on + 60,
);

is(
    $dbh->selectrow_array(
      q{SELECT COUNT(*) FROM API_torrents_files_index WHERE infohash = ?},
      undef,
      $hash,
    ),
    1,
    'later response removes stale indexed file rows',
);

my $before = $dbh->selectrow_array(
  q{SELECT payload_json FROM API_torrents_files WHERE infohash = ?},
  undef,
  $hash,
);

like(
    dies {
      $db->store_API_torrents_files(
        $dbh,
        $hash,
        [ { index => 0, name => 'valid' }, { name => 'missing index' } ],
        $fetched_on + 120,
      );
    },
    qr/requires index/,
    'invalid response rejected',
);

is(
    $dbh->selectrow_array(
      q{SELECT payload_json FROM API_torrents_files WHERE infohash = ?},
      undef,
      $hash,
    ),
    $before,
    'invalid response leaves previous complete payload intact',
);

$dbh->disconnect;

done_testing;
