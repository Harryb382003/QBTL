use v5.40;
use common::sense;
use feature qw( signatures );

use Test::More;
use File::Temp qw( tempdir );
use File::Spec;

use QBTL::DB;

my $dir     = tempdir( CLEANUP => 1 );
my $db_path = File::Spec->catfile( $dir, 'test.sqlite' );

my $db = QBTL::DB->new( db_path => $db_path );

isa_ok( $db, 'QBTL::DB' );
is( $db->db_path, $db_path, 'db path stored' );

my $dbh = $db->connect;

isa_ok( $dbh, 'DBI::db' );

$dbh->do('CREATE TABLE sanity_check (id INTEGER PRIMARY KEY, name TEXT NOT NULL)');
$dbh->do( 'INSERT INTO sanity_check (name) VALUES (?)', undef, 'ok' );

my ($name) = $dbh->selectrow_array('SELECT name FROM sanity_check WHERE id = 1');

is( $name, 'ok', 'sqlite round-trip works' );

$dbh->disconnect;

ok( -e $db_path, 'sqlite file created' );

done_testing;
