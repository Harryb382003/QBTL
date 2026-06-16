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

is( scalar @migration_files, 5, 'five migration files discovered' );
like( $migration_files[0], qr/001_initial\.sql\z/,
      'initial migration discovered' );
like( $migration_files[1], qr/002_qbt_info\.sql\z/,
      'qbt_info migration discovered' );
like( $migration_files[2], qr/003_qbt_presence\.sql\z/,
      'qbt_presence migration discovered' );
like( $migration_files[3], qr/004_qbt_comment\.sql\z/,
      'qbt_comment migration discovered' );
like( $migration_files[4], qr/005_qbt_seen\.sql\z/,
      'qbt_seen migration discovered' );

my @problems = $db->verify_path;
is_deeply( \@problems, [], 'valid temp DB directory has no path problems' );

my $result = $db->connect;

ok( $result->{ok}, 'connect result ok' );
isa_ok( $result->{dbh}, 'DBI::db' );

my $migration = $db->migrate( $result->{dbh} );

ok( $migration->{ok}, 'migration result ok' );
is( $migration->{migration_count}, 5, 'five migrations ran' );

my ( $version ) = $result->{dbh}
    ->selectrow_array( 'SELECT version FROM schema_version WHERE id = 1' );

is( $version, 5, 'schema version stored' );

my ( $qbt_info_table ) = $result->{dbh}->selectrow_array(
  q{
    SELECT name
    FROM sqlite_master
    WHERE type = 'table'
    AND name = 'qbt_info'
    }
);

is( $qbt_info_table, 'qbt_info', 'qbt_info table created' );

my $columns = $result->{dbh}
    ->selectall_arrayref( q{PRAGMA table_info(qbt_info)}, {Slice => {}}, );

my %column = map { $_->{name} => 1 } @{$columns};

ok( $column{current_qbt},   'qbt_info has current_qbt column' );
ok( $column{discovered_on}, 'qbt_info has discovered_on column' );
ok( $column{discovered_by}, 'qbt_info has discovered_by column' );
ok( $column{comment},       'qbt_info has comment column' );
my $upsert = $db->upsert_qbt_info(
                         $result->{dbh},
                         {
                          hash          => 'abc123',
                          name          => 'Example Torrent',
                          state         => 'pausedUP',
                          progress      => 1,
                          save_path     => '/Downloads',
                          content_path  => '/Downloads/Example Torrent',
                          category      => 'test',
                          tags          => 'one,two',
                          amount_left   => 0,
                          total_size    => 12345,
                          added_on      => 1700000000,
                          completion_on => 1700000100,
                          last_activity => 1700000200,
                          tracker => 'https://tracker.example.invalid/announce',
                          ratio   => 1.5,
                          comment => 'https://example.test/torrent-page',
                         }, );

ok( $upsert->{ok}, 'qbt_info upsert result ok' );
is( $upsert->{hash}, 'abc123', 'qbt_info upsert returns hash' );

my $stored =
    $result->{dbh}->selectrow_hashref( 'SELECT * FROM qbt_info WHERE hash = ?',
                                       undef, 'abc123', );

is( $stored->{hash},        'abc123',          'qbt_info hash stored' );
is( $stored->{name},        'Example Torrent', 'qbt_info name stored' );
is( $stored->{state},       'pausedUP',        'qbt_info state stored' );
is( $stored->{save_path},   '/Downloads',      'qbt_info save_path stored' );
is( $stored->{amount_left}, 0,                 'qbt_info amount_left stored' );
is( $stored->{seen},        1, 'qBT upsert marks torrent as seen' );
ok( $stored->{seen_on}, 'qbt_info seen_on stored' );
is( $stored->{comment},
    'https://example.test/torrent-page',
    'qbt_info comment stored' );

my $update = $db->upsert_qbt_info(
                         $result->{dbh},
                         {
                          hash          => 'abc123',
                          name          => 'Example Torrent Renamed',
                          state         => 'downloading',
                          progress      => 0.5,
                          save_path     => '/Downloads',
                          content_path  => '/Downloads/Example Torrent Renamed',
                          category      => 'test',
                          tags          => 'one,two',
                          amount_left   => 500,
                          total_size    => 12345,
                          added_on      => 1700000000,
                          completion_on => 0,
                          last_activity => 1700000300,
                          tracker => 'https://tracker.example.invalid/announce',
                          ratio   => 0.75,
                         }, );

ok( $update->{ok}, 'qbt_info update result ok' );

my ( $count ) =
    $result->{dbh}
    ->selectrow_array( 'SELECT COUNT(*) FROM qbt_info WHERE hash = ?',
                       undef, 'abc123', );

is( $count, 1, 'qbt_info upsert keeps one row per hash' );

my ( $updated_name ) =
    $result->{dbh}->selectrow_array( 'SELECT name FROM qbt_info WHERE hash = ?',
                                     undef, 'abc123', );

is( $updated_name, 'Example Torrent Renamed', 'qbt_info row updated' );

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
