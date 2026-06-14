use v5.40;
use common::sense;
use feature qw( signatures );

use Test::More;

use QBTL::QBT::API;
use QBTL::Process::QBT;

my $api = QBTL::QBT::API->new(
    base_url => 'http://127.0.0.1:9090',
);

my $process = QBTL::Process::QBT->new( api => $api );

isa_ok( $process, 'QBTL::Process::QBT' );
isa_ok( $process->api, 'QBTL::QBT::API' );

my $result = $process->version_request;

ok( $result->{ok}, 'version request result ok' );
is( $result->{action}, 'qbt_version', 'version request action' );
is( $result->{request}{endpoint}, 'app_version', 'version request endpoint' );
is( $result->{request}{method}, 'GET', 'version request method' );
is(
    $result->{request}{url},
    'http://127.0.0.1:9090/api/v2/app/version',
    'version request URL'
);

done_testing;
