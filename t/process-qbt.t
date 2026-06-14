use v5.40;
use common::sense;
use feature qw( signatures );

use File::Temp qw( tempdir );
use File::Spec;
use Test::More;

use QBTL::DB;
use QBTL::QBT::API;
use QBTL::Process::QBT;

my $api = QBTL::QBT::API->new( base_url => 'http://127.0.0.1:9090', );

my $process = QBTL::Process::QBT->new( api => $api );

isa_ok( $process, 'QBTL::Process::QBT' );

isa_ok( $process->api, 'QBTL::QBT::API' );

my $info_result = $process->torrents_info_request;

ok( $info_result->{ok}, 'torrents info request result ok' );
is( $info_result->{action},
    'qbt_torrents_info', 'torrents info request action' );
is(
  $info_result->{request}{endpoint}, 'torrents_info', 'torrents info request
endpoint' );
is( $info_result->{request}{method}, 'GET', 'torrents info request method' );
is( $info_result->{request}{url},
    'http://127.0.0.1:9090/api/v2/torrents/info',
    'torrents info request URL' );

my $dir     = tempdir( CLEANUP => 1 );
my $db_path = File::Spec->catfile( $dir, 'test.sqlite' );

my $db = QBTL::DB->new(
                   db_path       => $db_path,
                   migration_dir => File::Spec->catdir( 'share', 'migrations' ),
);

my $connect = $db->connect;

ok( $connect->{ok}, 'test DB connect ok' );

my $migration = $db->migrate( $connect->{dbh} );

ok( $migration->{ok}, 'test DB migration ok' );

my $store_result =
    $process->store_info_rows(
                      dbh  => $connect->{dbh},
                      db   => $db,
                      rows => [
                        {
                         hash          => 'abc123',
                         name          => 'Example One',
                         state         => 'pausedUP',
                         progress      => 1,
                         save_path     => '/Downloads',
                         content_path  => '/Downloads/Example One',
                         category      => 'test',
                         tags          => 'one',
                         amount_left   => 0,
                         total_size    => 1000,
                         added_on      => 1700000000,
                         completion_on => 1700000100,
                         last_activity => 1700000200,
                         tracker => 'https://tracker.example.invalid/announce',
                         ratio   => 1.0,
                        },
                        {
                         hash          => 'def456',
                         name          => 'Example Two',
                         state         => 'downloading',
                         progress      => 0.5,
                         save_path     => '/Downloads',
                         content_path  => '/Downloads/Example Two',
                         category      => 'test',
                         tags          => 'two',
                         amount_left   => 500,
                         total_size    => 2000,
                         added_on      => 1700000300,
                         completion_on => 0,
                         last_activity => 1700000400,
                         tracker => 'https://tracker.example.invalid/announce',
                         ratio   => 0.25,
                        },
                      ], );

ok( $store_result->{ok}, 'store info rows result ok' );
is( $store_result->{seen},   2, 'two qbt info rows seen' );
is( $store_result->{stored}, 2, 'two qbt info rows stored' );
is_deeply( $store_result->{problems}, [], 'no qbt info storage problems' );

my ( $count ) =
    $connect->{dbh}->selectrow_array( 'SELECT COUNT(*) FROM qbt_info' );

is( $count, 2, 'qbt_info table has two rows' );

my $bad_store =
    $process->store_info_rows(
                               dbh  => $connect->{dbh},
                               db   => $db,
                               rows => [ {name => 'Missing Hash',}, ], );

ok( !$bad_store->{ok}, 'bad qbt info row result not ok' );
is( $bad_store->{seen},   1, 'bad qbt info row seen' );
is( $bad_store->{stored}, 0, 'bad qbt info row not stored' );
is( scalar @{$bad_store->{problems}},
    1, 'bad qbt info row reports one problem' );
like(
      $bad_store->{problems}[0]{error},
      qr/qbt info row requires hash/,
      'bad qbt info row reports missing hash' );

my $refresh_result =
    $process->refresh_info_rows(
                   dbh  => $connect->{dbh},
                   db   => $db,
                   rows => [
                         {
                          hash          => 'ghi789',
                          name          => 'Refresh Example',
                          state         => 'pausedUP',
                          progress      => 1,
                          save_path     => '/Downloads',
                          content_path  => '/Downloads/Refresh Example',
                          category      => 'test',
                          tags          => 'refresh',
                          amount_left   => 0,
                          total_size    => 3000,
                          added_on      => 1700000500,
                          completion_on => 1700000600,
                          last_activity => 1700000700,
                          tracker => 'https://tracker.example.invalid/announce',
                          ratio   => 2.0,
                         },
                   ], );

ok( $refresh_result->{ok}, 'refresh info rows result ok' );
is( $refresh_result->{action}, 'qbt_refresh', 'refresh info rows action' );
is( $refresh_result->{seen},   1,             'refresh info rows seen count' );
is( $refresh_result->{stored}, 1, 'refresh info rows stored count' );
is_deeply( $refresh_result->{problems}, [], 'refresh info rows no problems' );

my ( $refresh_name ) =
    $connect->{dbh}
    ->selectrow_array( 'SELECT name FROM qbt_info WHERE hash = ?',
                       undef, 'ghi789', );

is( $refresh_name, 'Refresh Example', 'refresh info row stored in DB' );

my $fake_rows = $process->fake_info_rows;

is( ref $fake_rows,        'ARRAY',  'fake info rows returns arrayref' );
is( scalar @{$fake_rows},  2,        'fake info rows has two rows' );
is( $fake_rows->[0]{hash}, 'abc123', 'first fake info row has expected hash' );
is( $fake_rows->[1]{hash}, 'def456', 'second fake info row has expected hash' );

$connect->{dbh}->disconnect;

done_testing;
