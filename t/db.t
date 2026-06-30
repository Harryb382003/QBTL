use v5.40;
use common::sense;
use feature qw( signatures );

use Test::More;
use File::Temp qw( tempdir );
use File::Spec;

use QBTL::DB;

my $dir = tempdir( CLEANUP => 1 );
my ( $tmpdir, $dbh );
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

is( scalar @migration_files, 18, 'eighteen migration files discovered' );

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

like( $migration_files[5],
      qr/006_local_torrent_files\.sql\z/,
      'local_torrent_files migration discovered' );

like( $migration_files[6],
      qr/007_local_torrent_parse\.sql\z/,
      'local_torrent_parse migration discovered' );

like( $migration_files[7], qr/008_hash_values\.sql\z/,
      'hash_values.sql migration discovered' );

like( $migration_files[8],
      qr/009_local_fastresume_files\.sql\z/,
      'local_fastresume_files migration discovered' );

like( $migration_files[9], qr/010_key_accessors\.sql\z/,
      'key_accessors migration discovered' );

like( $migration_files[10],
      qr/011_key_accessor_searchable_qbt_fields\.sql\z/,
      'key_accessor_searchable_qbt_fields migration discovered' );

like( $migration_files[11],
      qr/012_qbt_preferences\.sql\z/,
      'qbt_preferences migration discovered' );

like( $migration_files[12],
      qr/013_qbt_payload_audits\.sql\z/,
      'qbt_payload_audits migration discovered' );

like( $migration_files[13],
      qr/014_qbt_payload_files\.sql\z/,
      'qbt_payload_files migration discovered' );

like( $migration_files[14],
      qr/015_qbt_api_values\.sql\z/,
      'qbt_api_values migration discovered' );

like( $migration_files[15],
      qr/016_qbt_last\.sql\z/,
      'qbt_last migration discovered' );

like( $migration_files[16],
      qr/017_local_torrent_payload_metadata\.sql\z/,
      'local_torrent_payload_metadata migration discovered' );

like( $migration_files[17],
      qr/018_qbt_hash_as_name\.sql\z/,
      'qbt_hash_as_name migration discovered' );

my @problems = $db->verify_path;

is_deeply( \@problems, [], 'valid temp DB directory has no path problems' );

my $result = $db->connect;

ok( $result->{ok}, 'connect result ok' );
isa_ok( $result->{dbh}, 'DBI::db' );

my $dbh = $result->{dbh};

my $migration = $db->migrate( $result->{dbh} );

ok( $migration->{ok}, 'migration result ok' );
is( $migration->{migration_count}, 18, 'eighteen migrations ran' );

my ( $version ) = $result->{dbh}
    ->selectrow_array( 'SELECT version FROM schema_version WHERE id = 1' );

is( $version, 18, 'schema version stored' );

my ( $hash_as_name_table ) = $result->{dbh}->selectrow_array(
  q{
    SELECT name
    FROM sqlite_master
    WHERE type = 'table'
    AND name = 'qbt_hash_as_name'
    }
);

is( $hash_as_name_table,
    'qbt_hash_as_name', 'qbt_hash_as_name table created' );

my $hash_as_name_hash = '11a6c2942055b59ccb7d897b970da823d7e6af8a';
my $hash_as_name_replace = $db->replace_qbt_hash_as_name(
  $result->{dbh},
  [
    {
     hash => $hash_as_name_hash,
     fastresume_path => '/BT_backup/' . $hash_as_name_hash . '.fastresume',
    },
  ],
);

ok( $hash_as_name_replace->{ok}, 'hash as name inventory replace result ok' );
is( $db->qbt_hash_as_name_count( $result->{dbh} ),
    1, 'hash as name inventory count stored' );

my $hash = '7ba7c0f31cd3ae7186c8d08353cfa87291b825e4';

my $hv = $db->upsert_hash_value(
                                 $result->{dbh},
                                 hash       => $hash,
                                 key        => 'qBt-savePath',
                                 value      => '/Volumes/A/Movies',
                                 value_type => 'text', );

ok( $hv->{ok}, 'hash value upsert result ok' );

my $hv_again = $db->upsert_hash_value(
                                       $result->{dbh},
                                       hash       => $hash,
                                       key        => 'qBt-savePath',
                                       value      => '/Volumes/A/Movies',
                                       value_type => 'text', );

ok( $hv_again->{ok}, 'hash value repeat upsert result ok' );

my $promote = $db->promote_hash_key( $result->{dbh}, key => 'qBt-savePath', );

ok( $promote->{ok}, 'hash key promotion result ok' );
is( $promote->{status}, 'promoted', 'hash key promotion status stored' );
is( $promote->{target_column},
    'qbt_savepath', 'hash key promotion target column stored' );
is( $promote->{backfilled}, 1, 'hash key promotion backfilled one hash' );

my ( $promoted_value ) = $result->{dbh}->selectrow_array(
  q{
  SELECT qbt_savepath
  FROM promoted_values
  WHERE hash = ?
  },
  undef,
  $hash, );

is( $promoted_value, '/Volumes/A/Movies', 'promoted value backfilled' );

my $promote_again =
    $db->promote_hash_key( $result->{dbh}, key => 'qBt-savePath', );

ok( $promote_again->{ok}, 'repeat hash key promotion result ok' );
is( $promote_again->{status},
    'already_promoted', 'repeat hash key promotion status stored' );

my ( $seen_count ) = $result->{dbh}->selectrow_array(
  q{
    SELECT seen_count
    FROM hash_values
    WHERE hash = ?
    AND "key" = ?
    AND value = ?
    },
  undef,
  $hash,
  'qBt-savePath',
  '/Volumes/A/Movies', );

is( $seen_count, 2, 'hash value repeat upsert increments seen_count' );

my $keys = $db->hash_keys( $result->{dbh} );

ok( $keys->{ok}, 'hash keys result ok' );
is( $keys->{rows}[0]{key},    'qBt-savePath', 'hash key listed' );
is( $keys->{rows}[0]{hashes}, 1,              'hash key hash count listed' );

my $accessors = $db->key_accessors( $result->{dbh} );

ok( $accessors->{ok}, 'key accessors result ok' );

my %accessor = map { $_->{key} => $_ } @{$accessors->{rows}};

is( $accessor{comment}{kind},        'core', 'core key accessor seeded' );
is( $accessor{'qBt-savePath'}{kind}, 'core', 'promoted key becomes core-ish' );
is( $accessor{'qBt-savePath'}{source},
    'promoted_values.qbt_savepath',
    'promoted key accessor source updated' );

my $key_detail = $db->hash_key_detail(
                                       $result->{dbh},
                                       key   => 'qBt-savePath',
                                       limit => 10, );

ok( $key_detail->{ok}, 'hash key detail result ok' );
is( $key_detail->{key}, 'qBt-savePath',  'hash key detail key stored' );
is( $key_detail->{rows}[0]{hash}, $hash, 'hash key detail row hash stored' );

my $manual = $db->set_manual_value(
                                    $result->{dbh},
                                    hash  => $hash,
                                    key   => 'preferred_path',
                                    value => '/Volumes/B/Movies', );

ok( $manual->{ok}, 'manual value set result ok' );

my $manual_accessor = $db->key_accessors( $result->{dbh} );
my %manual_accessor = map { $_->{key} => $_ } @{$manual_accessor->{rows}};

is( $manual_accessor{preferred_path}{kind},
    'manual', 'manual key accessor registered' );

my $manual_rows = $db->manual_values_for_hash( $result->{dbh}, $hash );

ok( $manual_rows->{ok}, 'manual values for hash result ok' );
is( $manual_rows->{rows}[0]{key}, 'preferred_path', 'manual value key stored' );
is( $manual_rows->{rows}[0]{value},
    '/Volumes/B/Movies', 'manual value value stored' );

my $unset = $db->unset_manual_value(
                                     $result->{dbh},
                                     hash => $hash,
                                     key  => 'preferred_path', );

ok( $unset->{ok}, 'manual value unset result ok' );
is( $unset->{deleted}, 1, 'manual value deleted one row' );

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
ok( $column{qbt_last},      'qbt_info has qbt_last column' );

my $local_torrent_columns = $result->{dbh}->selectall_arrayref(
             q{PRAGMA table_info(local_torrent_files)}, {Slice => {}}, );

my %local_torrent_column = map { $_->{name} => 1 } @{$local_torrent_columns};

ok( $local_torrent_column{payload_kind},
    'local_torrent_files has payload_kind column' );
ok( $local_torrent_column{payload_root_name},
    'local_torrent_files has payload_root_name column' );
ok( $local_torrent_column{payload_file_count},
    'local_torrent_files has payload_file_count column' );
ok( $local_torrent_column{payload_total_size},
    'local_torrent_files has payload_total_size column' );
ok( $local_torrent_column{payload_probe_path},
    'local_torrent_files has payload_probe_path column' );
ok( $local_torrent_column{payload_probe_name},
    'local_torrent_files has payload_probe_name column' );
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

my $qbt_last = $db->update_qbt_last(
                                     $result->{dbh},
                                     hash   => 'abc123',
                                     caller => 'ADD', );

ok( $qbt_last->{ok}, 'qbt_last update result ok' );
is( $qbt_last->{qbt_last}, 'ADD', 'qbt_last stores caller on ok' );
is( $qbt_last->{updated}, 1, 'qbt_last updated one qbt_info row' );

my ( $stored_qbt_last ) = $result->{dbh}->selectrow_array(
                          'SELECT qbt_last FROM qbt_info WHERE hash = ?',
                          undef, 'abc123', );

is( $stored_qbt_last, 'ADD', 'qbt_last caller stored in qbt_info' );

my $qbt_last_error = $db->update_qbt_last(
                              $result->{dbh},
                              hash   => 'abc123',
                              caller => 'ADD',
                              error  => 'unexpected qBT add error', );

is( $qbt_last_error->{qbt_last},
    'ADD: unexpected qBT add error',
    'qbt_last stores caller and raw error message' );


my $api_values = $db->replace_qbt_api_values(
                                             $result->{dbh},
                                             hash     => 'abc123',
                                             endpoint => 'torrents_properties',
                                             data     => {
                                                       save_path  => '/Downloads',
                                                       total_size => 12345,
                                                       isPrivate  => \0,
                                                      }, );

ok( $api_values->{ok}, 'qbt_api_values replace result ok' );
is( $api_values->{stored}, 3, 'qbt_api_values stored three keys' );

my $api_value_rows = $db->qbt_api_values(
                                          $result->{dbh},
                                          hash     => 'abc123',
                                          endpoint => 'torrents_properties',
                                          key      => 'save_path', );

ok( $api_value_rows->{ok}, 'qbt_api_values query result ok' );
is( $api_value_rows->{count}, 1, 'qbt_api_values query returns one row' );
is( $api_value_rows->{rows}[0]{value},
    '/Downloads', 'qbt_api_values stores qBT key value' );

my $payload_audit = $db->replace_qbt_payload_audit(
                                      $result->{dbh},
                                      {
                                       hash                => 'abc123',
                                       save_path           => '/Downloads',
                                       content_path        => '/Downloads/Example',
                                       save_path_exists    => 1,
                                       content_path_exists => 1,
                                       save_path_type      => 'dir',
                                       content_path_type   => 'dir',
                                       qbt_files_ok        => 1,
                                       qbt_file_count      => 2,
                                       qbt_file_total_size => 12345,
                                       direct_probe_status => 'trusted_qbt_size',
                                       needs_deep_scan     => 0,
                                       problem             => undef,
                                      }, );

ok( $payload_audit->{ok}, 'qbt payload audit replace result ok' );

my $stored_payload_audit =
    $db->qbt_payload_audit( $result->{dbh}, 'abc123' );

is( $stored_payload_audit->{direct_probe_status},
    'trusted_qbt_size', 'qbt payload audit status stored' );

my $payload_files = $db->replace_qbt_payload_files(
                                  $result->{dbh},
                                  hash  => 'abc123',
                                  files => [
                                            {
                                             path         => 'Example/file1.mkv',
                                             size         => 100,
                                             progress     => 1,
                                             priority     => 1,
                                             availability => 1,
                                            },
                                            {
                                             path         => 'Example/file2.mkv',
                                             size         => 200,
                                             progress     => 0.5,
                                             priority     => 1,
                                             availability => 1,
                                            },
                                  ], );

ok( $payload_files->{ok}, 'qbt payload files replace result ok' );
is( $payload_files->{stored}, 2, 'qbt payload files stored two rows' );

my $stored_payload_files =
    $db->qbt_payload_files( $result->{dbh}, 'abc123' );

is( $stored_payload_files->{count}, 2, 'qbt payload files query count' );
my $fr_path = File::Spec->catfile( $tmpdir,
                          'd207bae331f40b5f9b49220e7aa4e4a60df9ca3a.fastresume',
);

my $fr_store =
    $db->upsert_local_fastresume_file(
                                       $dbh,
                                       {
                                        path    => $fr_path,
                                        size    => 1234,
                                        mtime   => 111,
                                        backend => 'test',
                                       } );

ok $fr_store->{ok}, 'stored local fastresume file';

my $fr_parse =
    $db->update_local_fastresume_parse(
                        $dbh,
                        {
                         path     => $fr_path,
                         infohash => 'd207bae331f40b5f9b49220e7aa4e4a60df9ca3a',
                         parse_ok => 1,
                         parse_problem => undef,
                        } );

ok $fr_parse->{ok}, 'updated local fastresume parse data';

is $db->local_fastresume_file_count( $dbh ), 1, 'local fastresume file count';

my $fr_summary = $db->local_fastresume_summary( $dbh );

is $fr_summary->{total},  1, 'fastresume summary total';
is $fr_summary->{parsed}, 1, 'fastresume summary parsed';
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
