use v5.40;
use common::sense;
use feature qw( signatures );

use Test::More;

use QBTL::QBT::API;

my $api = QBTL::QBT::API->new;

isa_ok( $api, 'QBTL::QBT::API' );
is( $api->base_url, 'http://localhost:8080', 'default base URL' );

is( $api->api_url( 'app/version' ),
    'http://localhost:8080/api/v2/app/version',
    'api_url builds expected URL' );

is( $api->api_url( '/app/version' ),
    'http://localhost:8080/api/v2/app/version',
    'api_url handles leading slash' );

$api = QBTL::QBT::API->new( base_url => 'http://127.0.0.1:9090/' );

is( $api->base_url, 'http://127.0.0.1:9090',
    'trailing slash removed from base URL' );

is( $api->endpoint( 'app_version' ),
    'http://127.0.0.1:9090/api/v2/app/version',
    'app_version endpoint' );

is( $api->endpoint( 'torrents_info' ),
    'http://127.0.0.1:9090/api/v2/torrents/info',
    'torrents_info endpoint' );

eval { $api->endpoint( 'bogus' ) };

like( $@, qr/Unknown qBT endpoint: bogus/, 'unknown endpoint dies clearly' );

done_testing;
