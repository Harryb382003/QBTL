use v5.40;
use common::sense;
use feature qw( signatures );

use Test::More;
use File::Temp qw( tempdir );
use File::Spec;
use File::Path qw( remove_tree );

use QBTL::Process::Setup;

my $root = tempdir( CLEANUP => 0 );
my $home = File::Spec->catdir( $root, 'QBTL' );

END {
  remove_tree( $root ) if defined $root && -d $root;
}

my $setup = QBTL::Process::Setup->new( home => $home );

isa_ok( $setup, 'QBTL::Process::Setup' );
is( $setup->home, $home, 'home stored' );

my $result = $setup->run;

ok( $result->{ok}, 'setup result ok' );
is( $result->{home}, $home, 'setup result home' );

ok( -d $home,           'home directory created' );
ok( -d "$home/logs",    'logs directory created' );
ok( -d "$home/backups", 'backups directory created' );
ok( -d "$home/tmp",     'tmp directory created' );

my $second = $setup->run;

ok( $second->{ok}, 'second setup result ok' );
is_deeply( $second->{created}, [], 'second setup creates nothing' );
ok( @{$second->{existing}} >= 4, 'second setup reports existing dirs' );

done_testing;
