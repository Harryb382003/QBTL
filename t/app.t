use v5.40;
use common::sense;
use feature qw( signatures );

use Test::More;
use File::Temp qw( tempdir );
use File::Spec;
use File::Path qw( remove_tree );

use QBTL::App;
use QBTL::Config;
use QBTL::Render::CLI;

my $out = '';
open my $fh, '>', \$out or die "open scalar fh: $!";

my $root = tempdir( CLEANUP => 0 );

END {
  remove_tree( $root ) if defined $root && -d $root;
}

my $db_path = File::Spec->catfile( $root, 'QBTL', 'qbtl.db' );

my $config = QBTL::Config->new( db_path => $db_path,
                                qbt_url => 'http://127.0.0.1:9090', );

my $renderer = QBTL::Render::CLI->new( out => $fh );
my $app      = QBTL::App->new( config => $config, renderer => $renderer );

isa_ok( $app, 'QBTL::App' );

$out = '';
is( $app->run_cli( 'version' ), 0, 'version command exits cleanly' );
like( $out, qr/\AQBTL 0\.001\n\z/, 'version command renders version' );

$out = '';
is( $app->run_cli( 'help' ), 0, 'help command exits cleanly' );
like( $out, qr/Usage: qbtl <command>/, 'help command renders usage' );
like( $out, qr/help\s+Show this help/, 'help command is listed' );
like( $out,
      qr/qbt help\s+Show qBittorrent command help/,
      'qbt help command is listed' );

$out = '';
is( $app->run_cli(), 0, 'default command exits cleanly' );
like( $out, qr/Usage: qbtl <command>/, 'default command renders help' );

$out = '';
is( $app->run_cli( 'setup' ), 0, 'setup command exits cleanly' );
like( $out, qr/QBTL setup complete\./, 'setup command renders completion' );
ok( -d File::Spec->catdir( $root, 'QBTL' ),
    'setup command creates configured home directory' );

$out = '';
is( $app->run_cli( 'status' ), 0, 'status command exits cleanly after setup' );
like( $out, qr/QBTL status/,          'status command renders status' );
like( $out, qr/Database path: ready/, 'status command reports ready path' );

$out = '';
is( $app->run_cli( 'qbt', 'version' ), 0, 'qbt version command exits cleanly' );
like( $out, qr/qBT request/, 'qbt version command renders request' );
like( $out,
      qr{http://127\.0\.0\.1:9090/api/v2/app/version},
      'qbt version command uses configured qBT URL' );

$out = '';
is( $app->run_cli( 'qbt', 'info' ), 0, 'qbt info command exits cleanly' );
like( $out, qr/qBT request/, 'qbt info command renders request' );
like( $out,
      qr{http://127\.0\.0\.1:9090/api/v2/torrents/info},
      'qbt info command uses configured qBT URL' );

$out = '';
is( $app->run_cli( 'qbt', 'refresh' ), 0, 'qbt refresh command exits cleanly' );
like( $out,
      qr/qBT refresh complete\./,
      'qbt refresh command renders completion' );
like( $out, qr/seen:\s+2/,     'qbt refresh command renders seen count' );
like( $out, qr/stored:\s+2/,   'qbt refresh command renders stored count' );
like( $out, qr/problems:\s+0/, 'qbt refresh command renders problem count' );

$out = '';
is( $app->run_cli( 'qbt', 'help' ), 0, 'qbt help command exits cleanly' );
like( $out, qr/Usage: qbtl qbt <command>/, 'qbt help command renders usage' );
like( $out, qr/help\s+Show this help/,     'qbt help command is listed' );
like( $out,
      qr/info\s+Show qBittorrent torrents\/info request/,
      'qbt info command is listed' );
like( $out,
      qr/refresh\s+Store fake qBittorrent torrents\/info rows/,
      'qbt refresh command is listed' );

$out = '';
is( $app->run_cli( 'qbt' ), 0, 'bare qbt command exits cleanly' );
like( $out, qr/Usage: qbtl qbt <command>/,
      'bare qbt command renders qbt help' );

done_testing;
