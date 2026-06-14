use v5.40;
use common::sense;
use feature qw( signatures );

use Test::More;
use File::Temp qw( tempdir );
use File::Spec;

use QBTL::DB;

my $dir     = tempdir( CLEANUP => 1 );
my $db_path = File::Spec->catfile( $dir, 'test.sqlite' );

my $db = QBTL::DB->new(
                   db_path       => $db_path,
                   migration_dir => File::Spec->catdir( 'share', 'migrations' ),
);

isa_ok( $db, 'QBTL::DB' );
is( $db->db_path, $db_path, 'db path stored' );

is( $db->migration_dir,
    File::Spec->catdir( 'share', 'migrations' ),
    'migration dir stored' );

my @migration_files = $db->migration_files;

is( scalar @migration_files, 1, 'one migration file discovered' );
like( $migration_files[0], qr/001_initial\.sql\z/,
      'initial migration discovered' );

my @problems = $db->verify_path;
is_deeply( \@problems, [], 'valid temp DB directory has no path problems' );

my $result = $db->connect;

ok( $result->{ok}, 'connect result ok' );
isa_ok( $result->{dbh}, 'DBI::db' );

my $migration = $db->migrate( $result->{dbh} );

ok( $migration->{ok}, 'migration result ok' );
is( $migration->{migration_count}, 1, 'one migration ran' );

my ( $version ) = $result->{dbh}
    ->selectrow_array( 'SELECT version FROM schema_version WHERE id = 1' );

is( $version, 1, 'schema version stored' );

$result->{dbh}->do(
     'CREATE TABLE sanity_check (id INTEGER PRIMARY KEY, name TEXT NOT NULL)' );
$result->{dbh}->do( 'INSERT INTO sanity_check (name) VALUES (?)', undef, 'ok' );

my ( $name ) = $result->{dbh}
    ->selectrow_array( 'SELECT name FROM sanity_check WHERE id = 1' );

is( $name, 'ok', 'sqlite round-trip works' );

$result->{dbh}->disconnect;

ok( -e $db_path, 'sqlite file created' );

my $bad_path = File::Spec->catfile( $dir, 'missing', 'bad.sqlite' );
my $bad_db   = QBTL::DB->new( db_path => $bad_path );

my $bad = $bad_db->connect;

ok( !$bad->{ok}, 'bad DB path does not connect' );
is( $bad->{status}, 'db_path_invalid',
    'bad DB path returns db_path_invalid status' );
like( $bad->{problems}[0],
      qr/DB directory does not exist:/,
      'bad DB path reports missing directory' );

done_testing;
