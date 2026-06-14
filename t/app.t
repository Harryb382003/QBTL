use v5.40;
use common::sense;
use feature qw( signatures );

use Test::More;

use QBTL::App;

my $app = QBTL::App->new;

isa_ok( $app, 'QBTL::App' );

is( $app->run_cli('version'), 0, 'version command exits cleanly' );
is( $app->run_cli('help'),    0, 'help command exits cleanly' );
is( $app->run_cli(),          0, 'default command exits cleanly' );

done_testing;
