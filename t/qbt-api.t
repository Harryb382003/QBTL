use v5.40;
use common::sense;
use feature qw( signatures );

use Test::More;

use QBTL::QBT::API;

my $api = QBTL::QBT::API->new( base_url => 'http://127.0.0.1:8080/', );

my $request     = $api->request( 'app_version' );
my $default_api = QBTL::QBT::API->new;
my $custom_api  = QBTL::QBT::API->new( base_url => 'http://127.0.0.1:8080/' );
my $recheck_request = $default_api->torrents_recheck( 'abc123' );
my $version_request = $default_api->app_version;
my $info_request =
    $default_api->torrents_info( filter => 'all',
                                 sort   => 'name', );
my $files_request = $default_api->torrents_files( 'abc123' );

isa_ok( $api, 'QBTL::QBT::API' );
is( $api->base_url, 'http://127.0.0.1:8080', 'default base URL' );

is( $api->api_url( 'app/version' ),
    'http://127.0.0.1:8080/api/v2/app/version',
    'api_url builds expected URL' );

is( $api->api_url( '/app/version' ),
    'http://127.0.0.1:8080/api/v2/app/version',
    'api_url handles leading slash' );

is( $api->base_url, 'http://127.0.0.1:8080',
    'trailing slash removed from base URL' );

is( $api->endpoint( 'app_version' ),
    'http://127.0.0.1:8080/api/v2/app/version',
    'app_version endpoint' );

is( $api->endpoint( 'torrents_info' ),
    'http://127.0.0.1:8080/api/v2/torrents/info',
    'torrents_info endpoint' );

eval { $api->endpoint( 'bogus' ) };

like( $@, qr/Unknown qBT endpoint: bogus/, 'unknown endpoint dies clearly' );

is( $request->{endpoint}, 'app_version', 'request endpoint stored' );
is( $request->{method},   'GET',         'app_version uses GET' );
is( $request->{url},
    'http://127.0.0.1:8080/api/v2/app/version',
    'request URL stored' );
is_deeply( $request->{params}, {}, 'default request params empty' );

$request = $api->request( 'torrents_files', params => {hash => 'abc123',}, );

is( $request->{method}, 'GET', 'torrents_files uses GET' );
is_deeply( $request->{params}, {hash => 'abc123'}, 'request params stored' );

$request =
    $api->request( 'torrents_recheck', params => {hashes => 'abc123',}, );

is( $request->{method},         'POST',          'torrents_recheck uses POST' );
is( $info_request->{endpoint},  'torrents_info', 'torrents_info endpoint' );
is( $files_request->{endpoint}, 'torrents_files', 'torrents_files endpoint' );
is( $recheck_request->{endpoint},
    'torrents_recheck', 'torrents_recheck endpoint' );
is( $recheck_request->{method}, 'POST', 'torrents_recheck method' );

done_testing;
