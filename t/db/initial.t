use v5.40;
use common::sense;

use File::Spec;
use File::Temp qw( tempdir );
use FindBin;
use Test2::V0;

use lib File::Spec->catdir( $FindBin::Bin, '..', '..', 'lib' );

use QBTL::DB;

my $temp_dir = tempdir( CLEANUP => 1 );

my $db_path = File::Spec->catfile( $temp_dir, 'qbtl.db', );

my $migration_dir =
    File::Spec->catdir( $FindBin::Bin, '..', '..', 'share', 'migrations', );

my $db = QBTL::DB->new( db_path       => $db_path,
                        migration_dir => $migration_dir, );

isa_ok( $db, ['QBTL::DB'], 'constructed database object', );

is( $db->db_path, $db_path, 'database path retained', );

ok( $db->verify_path, 'database path is usable', );

my $dbh = $db->connect;
isa_ok( $dbh, ['DBI::db'], 'connected to SQLite database', );

ok( -f $db_path, 'SQLite database file created', );

is( $dbh->selectrow_array( 'PRAGMA foreign_keys' ),
    1, 'foreign-key enforcement enabled', );

my @migration_files = $db->migration_files;

is( scalar @migration_files, 2, 'Two migrations discovered', );

like( $migration_files[0], qr{001_initial[.]sql\z},
      'initial migration discovered first', );
like( $migration_files[1], qr{002_torrents[.]sql\z},
      'torrents migration discovered second', );

is( $db->migrate( $dbh ), 2, 'Two migrations executed', );

my $table_name = $dbh->selectrow_array(
  q{
    SELECT name
      FROM sqlite_master
     WHERE type = 'table'
       AND name = 'schema_migrations'
  }
);

is( $table_name, 'schema_migrations', 'schema migrations table created', );

is( $db->migrate( $dbh ), 0, 'already-applied migration skipped', );

my $migration_count = $dbh->selectrow_array(
  q{
  SELECT COUNT(*)
  FROM schema_migrations
  }
);

is( $migration_count, 2, 'migration recorded exactly once', );

is( $db->migrate( $dbh ), 0, 'all migrations skipped after application', );

my $torrent_table = $dbh->selectrow_array(
  q{
  SELECT name
  FROM sqlite_master
  WHERE type = 'table'
AND name = 'torrents'
}
);

is( $torrent_table, 'torrents', 'canonical torrents table created', );

my $torrent_columns = $dbh->selectall_arrayref(
  q{
  PRAGMA table_info(torrents)
  },
  {Slice => {}}, );

is(
  [ map { $_->{name} } @$torrent_columns ],
  [
    qw(
        infohash
        discovered_on
        discovered_by
    )
  ],
  'torrents table has expected columns', );

my $recorded_versions = $dbh->selectcol_arrayref(
  q{
  SELECT version
  FROM schema_migrations
  ORDER BY version
  }
);

is( $recorded_versions,
    [ 1, 2 ],
    'applied migration versions recorded in order', );

$dbh->disconnect;

done_testing;
