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

is( scalar @migration_files, 8, 'Eight migrations discovered', );

like( $migration_files[0], qr{001_initial[.]sql\z},
      'initial migration discovered first', );
like( $migration_files[1], qr{002_torrents[.]sql\z},
      'torrents migration discovered second', );
like( $migration_files[2],
      qr{003_API_torrents_info[.]sql\z},
      'API torrents_info migration discovered third', );
like( $migration_files[3],
      qr{004_API_torrents_info_index[.]sql\z},
      'API torrents_info migration discovered third', );
like( $migration_files[4],
      qr{005_API_torrents_files[.]sql\z},
      'API torrents_files migration discovered fifth', );
like( $migration_files[5],
      qr{006_API_torrents_files_index[.]sql\z},
      'API torrents_files index migration discovered sixth', );
like( $migration_files[6], qr{007_API_torrents_properties[.]sql\z},
      'API torrents_properties migration discovered seventh', );
like( $migration_files[7], qr{008_API_torrents_properties_index[.]sql\z},
      'API torrents_properties index migration discovered eighth', );

is( $db->migrate( $dbh ), 8, 'Eight migrations executed', );

my $table_name = $dbh->selectrow_array(
  q{
    SELECT name
      FROM sqlite_master
     WHERE type = 'table'
       AND name = 'schema_migrations'
  }
);

is( $table_name, 'schema_migrations', 'schema migrations table created', );

my $migration_count = $dbh->selectrow_array(
  q{
  SELECT COUNT(*)
  FROM schema_migrations
  }
);

is( $migration_count, 8, 'migrations recorded exactly once', );

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

for my $name (
               qw(
               API_torrents_info
               API_torrents_info_index
               API_torrents_files
               API_torrents_files_index
               ) )
{
  my ( $table_count ) = $dbh->selectrow_array(
    q{
      SELECT COUNT(*)
      FROM sqlite_master
      WHERE type = 'table'
  AND name = ?
    },
    undef,
    $name, );

  is( $table_count, 1, "$name table created", );
}

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
    [ 1, 2, 3, 4, 5, 6, 7, 8 ],
    'applied migration versions recorded in order', );

$dbh->disconnect;

done_testing;
