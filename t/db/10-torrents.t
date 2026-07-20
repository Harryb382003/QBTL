use v5.40;
use common::sense;
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test2::V0;
use lib File::Spec->catdir( $FindBin::Bin, '..', '..', 'lib' );

use QBTL::DB;

my $temp_dir = tempdir( CLEANUP => 1 );
my $db = QBTL::DB->new(
    db_path       => File::Spec->catfile( $temp_dir, 'qbtl.db' ),
    migration_dir =>
        File::Spec->catdir( $FindBin::Bin, '..', '..', 'share', 'migrations', ),
);
my $dbh = $db->connect;
$db->migrate( $dbh );

my $first = $db->ensure_torrent( $dbh,
                                 '0123456789abcdef0123456789abcdef01234567',
                                 '2026-07-19 16:00:00', 'qbt', );

is(
    $first,
    {
     infohash      => '0123456789abcdef0123456789abcdef01234567',
     discovered_on => '2026-07-19 16:00:00',
     discovered_by => 'qbt',
    },
    'torrent identity inserted', );

my $second = $db->ensure_torrent( $dbh,
                                  '0123456789abcdef0123456789abcdef01234567',
                                  '2026-07-20 12:00:00', 'local', );

is(
    $second,
    {
     infohash      => '0123456789abcdef0123456789abcdef01234567',
     discovered_on => '2026-07-19 16:00:00',
     discovered_by => 'qbt',
    },
    'later observation does not overwrite discovery evidence', );

my $earlier = $db->ensure_torrent( $dbh,
                                   '0123456789abcdef0123456789abcdef01234567',
                                   '2025-12-01 08:30:00', 'local', );

is(
    $earlier,
    {
     infohash      => '0123456789abcdef0123456789abcdef01234567',
     discovered_on => '2025-12-01 08:30:00',
     discovered_by => 'local',
    },
    'earlier evidence improves discovery record', );

is( $dbh->selectrow_array( 'SELECT COUNT(*) FROM torrents' ),
    1, 'one canonical torrent row stored', );

$dbh->disconnect;

done_testing;
