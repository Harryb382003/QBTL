use v5.40;
use common::sense;
use feature qw( signatures );

use Test::More;

use QBTL::Render::CLI;

my $out = '';
open my $fh, '>', \$out or die "open scalar fh: $!";

my $render = QBTL::Render::CLI->new( out => $fh );

is( $render->version( '0.001' ), 0, 'version render exits cleanly' );
like( $out, qr/\AQBTL 0\.001\n\z/, 'version output' );

$out = '';
is( $render->help, 0, 'help render exits cleanly' );
like( $out, qr/Usage: qbtl <command>/, 'help output includes usage' );
like( $out,
      qr/version\s+Show QBTL version/,
      'help output includes version command' );
like( $out,
      qr/setup\s+Create QBTL runtime directories/,
      'help output includes setup command' );

$out = '';
my $result = {
              ok       => 1,
              home     => '/tmp/QBTL',
              created  => ['/tmp/QBTL'],
              existing => ['/tmp/QBTL/logs'],};

$out = '';
is(
    $render->status(
                     {
                      ok       => 1,
                      db_path  => '/tmp/QBTL/qbtl.db',
                      problems => [],}
    ),
    0,
    'status render exits cleanly when ready' );
like( $out, qr/QBTL status/,          'status output includes title' );
like( $out, qr/Database path: ready/, 'status output says ready' );

$out = '';
is(
    $render->status(
                     {
                      ok       => 0,
                      db_path  => '/tmp/QBTL/qbtl.db',
                      problems => ['DB directory does not exist: /tmp/QBTL'],}
    ),
    1,
    'status render returns failure when not ready' );
like( $out, qr/Database path: not ready/, 'status output says not ready' );
like( $out, qr/qbtl setup/,               'status output suggests setup' );

$out = '';
is(
    $render->qbt_request(
                          {
                           ok      => 1,
                           action  => 'qbt_version',
                           request => {
                              method => 'GET',
                              url => 'http://localhost:8080/api/v2/app/version',
                           },}
    ),
    0,
    'qbt request render exits cleanly' );
like( $out, qr/qBT request/,         'qbt request output includes title' );
like( $out, qr/Action: qbt_version/, 'qbt request output includes action' );
like( $out, qr/Method: GET/,         'qbt request output includes method' );
like(
  $out, qr{URL: http://localhost:8080/api/v2/app/version}, 'qbt request output
includes URL' );

is( $render->setup( $result ), 0, 'setup render exits cleanly' );
like( $out, qr/QBTL setup complete\./, 'setup output includes completion' );
like( $out, qr/Home: \/tmp\/QBTL/,     'setup output includes home' );
like( $out, qr/Created:/,         'setup output includes created section' );
like( $out, qr/Already existed:/, 'setup output includes existing section' );

$out = '';
is(
    $render->qbt_refresh(
                          {
                           ok       => 1,
                           action   => 'qbt_refresh',
                           seen     => 2,
                           stored   => 2,
                           problems => [],}
    ),
    0,
    'qbt refresh render exits cleanly' );

like( $out,
      qr/qBT refresh complete\./,
      'qbt refresh output includes completion' );
like( $out, qr/seen:\s+2/,     'qbt refresh output includes seen count' );
like( $out, qr/stored:\s+2/,   'qbt refresh output includes stored count' );
like( $out, qr/problems:\s+0/, 'qbt refresh output includes problem count' );

done_testing;
