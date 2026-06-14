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
	remove_tree($root) if defined $root && -d $root;
}

my $db_path = File::Spec->catfile( $root, 'QBTL', 'qbtl.db' );

my $renderer = QBTL::Render::CLI->new( out => $fh );
my $config   = QBTL::Config->new( db_path => $db_path );
my $app      = QBTL::App->new( config => $config, renderer => $renderer );

isa_ok( $app, 'QBTL::App' );

is( $app->run_cli( 'version' ), 0, 'version command exits cleanly' );
like( $out, qr/\AQBTL 0\.001\n\z/, 'version command renders version' );

$out = '';
is( $app->run_cli( 'help' ), 0, 'help command exits cleanly' );
like( $out, qr/Usage: qbtl <command>/, 'help command renders usage' );

$out = '';
is( $app->run_cli(), 0, 'default command exits cleanly' );
like( $out, qr/Usage: qbtl <command>/, 'default command renders help' );

$out = '';
is( $app->run_cli( 'setup' ), 0, 'setup command exits cleanly' );
like( $out, qr/QBTL setup complete\./, 'setup command renders completion' );
ok( -d File::Spec->catdir( $root, 'QBTL' ),
    'setup command creates configured home directory' );

done_testing;
