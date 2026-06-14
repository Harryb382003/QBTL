use v5.40;
use common::sense;
use feature qw( signatures );

use Test::More;

use QBTL::App;
use QBTL::Render::CLI;

my $out = '';
open my $fh, '>', \$out or die "open scalar fh: $!";

my $renderer = QBTL::Render::CLI->new( out => $fh );
my $app      = QBTL::App->new( renderer => $renderer );

isa_ok( $app, 'QBTL::App' );

is( $app->run_cli('version'), 0, 'version command exits cleanly' );
like( $out, qr/\AQBTL 0\.001\n\z/, 'version command renders version' );

$out = '';
is( $app->run_cli('help'), 0, 'help command exits cleanly' );
like( $out, qr/Usage: qbtl <command>/, 'help command renders usage' );

$out = '';
is( $app->run_cli(), 0, 'default command exits cleanly' );
like( $out, qr/Usage: qbtl <command>/, 'default command renders help' );

done_testing;
