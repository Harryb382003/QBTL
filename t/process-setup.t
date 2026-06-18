use v5.40;
use common::sense;
use feature qw( signatures );

use Test::More;
use File::Temp qw( tempdir );
use File::Spec;
use File::Path qw( remove_tree );

use QBTL::DB;
use QBTL::Process::Setup;

my $root    = tempdir( CLEANUP => 0 );
my $home    = File::Spec->catdir( $root, 'QBTL' );
my $db_path = File::Spec->catfile( $home, 'qbtl.db' );

END {
  remove_tree( $root ) if defined $root && -d $root;
}

my $db = QBTL::DB->new(
                   db_path       => $db_path,
                   migration_dir => File::Spec->catdir( 'share', 'migrations' ),
);

my $setup = QBTL::Process::Setup->new( home => $home,
                                       db   => $db, );

isa_ok( $setup, 'QBTL::Process::Setup' );
is( $setup->home, $home, 'home stored' );

my $result = $setup->run;

ok( $result->{ok}, 'setup result ok' );
is( $result->{home}, $home, 'setup result home' );

ok( -d $home,           'home directory created' );
ok( -d "$home/logs",    'logs directory created' );
ok( -d "$home/backups", 'backups directory created' );
ok( -d "$home/tmp",     'tmp directory created' );

ok( -e $db_path,                         'database file created' );
ok( $result->{db_result}{ok},            'database setup result ok' );
ok( $result->{db_result}{migration}{ok}, 'database migration result ok' );
ok( $result->{local_search}{ok}, 'local search detection result ok' );
ok( $result->{local_search}{search_tool}, 'local search tool selected' );

my $second = $setup->run;

ok( $second->{ok}, 'second setup result ok' );
is_deeply( $second->{created}, [], 'second setup creates nothing' );
ok( @{$second->{existing}} >= 4, 'second setup reports existing dirs' );
ok( $second->{db_result}{ok},    'second setup database result ok' );

done_testing;
