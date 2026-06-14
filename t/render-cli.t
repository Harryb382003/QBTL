use v5.40;
use common::sense;
use feature qw( signatures );

use Test::More;

use QBTL::Render::CLI;

my $out = '';
open my $fh, '>', \$out or die "open scalar fh: $!";

my $render = QBTL::Render::CLI->new( out => $fh );

is( $render->version('0.001'), 0, 'version render exits cleanly' );
like( $out, qr/\AQBTL 0\.001\n\z/, 'version output' );

$out = '';
is( $render->help, 0, 'help render exits cleanly' );
like( $out, qr/Usage: qbtl <command>/, 'help output includes usage' );
like( $out, qr/version\s+Show QBTL version/, 'help output includes version command' );

done_testing;
