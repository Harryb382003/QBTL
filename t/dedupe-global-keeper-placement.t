use v5.40;
use common::sense;
use feature qw( signatures );

use Test::More;
use File::Copy qw( move );
use File::Path qw( make_path );
use File::Spec;
use File::Temp qw( tempdir );

use lib 'lib';
use QBTL::Process::QBT::Dedupe;

{
  package Local::FakeDB;

  sub new ( $class, $rows ) {
    return bless {rows => $rows, added => {}, deleted => {}}, $class;
  }

  sub parsed_local_torrent_files ( $self, $dbh ) {
    return [ map { +{%{$_}} } @{ $self->{rows} } ];
  }

  sub upsert_add_queue ( $self, $dbh, %arg ) {
    $self->{added}{ $arg{hash} } = $arg{path};
    return {ok => 1};
  }

  sub delete_add_queue_hash ( $self, $dbh, $hash ) {
    $self->{deleted}{$hash}++;
    delete $self->{added}{$hash};
    return {ok => 1};
  }
}

{
  package Local::Dedupe;
  use parent 'QBTL::Process::QBT::Dedupe';
  use File::Basename qw( basename );
  use File::Copy qw( move );
  use File::Spec;

  sub _bt_backup_dir ($self) { return '' }

  sub _move_keeper_to_managed_dir ( $self, %arg ) {
    my $keeper = $arg{keeper};
    my $source = $keeper->{path};

    if ( $self->_path_is_under( $source, $arg{dir} ) ) {
      return {ok => 1, moved => 0, existing => 1, keeper => $keeper};
    }

    my $target = File::Spec->catfile( $arg{dir}, basename($source) );
    move( $source, $target ) or die "test move failed: $!";

    return {
      ok     => 1,
      moved  => 1,
      keeper => {%{$keeper}, path => $target},
    };
  }

  sub _queue_duplicate_for_deletion ( $self, %arg ) {
    return {
      ok    => 1,
      entry => {
        source_path => $arg{item}{path},
        hash        => $arg{item}{hash},
        which       => $arg{which},
        kind        => $arg{kind},
      },
    };
  }
}

my $root = tempdir( CLEANUP => 1 );
my $downloaded = File::Spec->catdir( $root, 'Downloaded_torrents' );
my $completed  = File::Spec->catdir( $root, 'Completed_torrents' );
my $pool       = File::Spec->catdir( $root, 'torrents' );
my $restore    = File::Spec->catdir( $root, 'queued_for_restoration' );
my $delete     = File::Spec->catdir( $root, 'queued_for_deletion' );
my $loose      = File::Spec->catdir( $root, 'loose' );
make_path( $downloaded, $completed, $pool, $restore, $delete, $loose );

sub touch_torrent ($path) {
  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} 'torrent';
  close $fh;
  return $path;
}

my $qbt_file = touch_torrent( File::Spec->catfile( $downloaded, 'qbt.torrent' ) );
my $qbt_dup  = touch_torrent( File::Spec->catfile( $loose, 'qbt-copy.torrent' ) );
my $repair   = touch_torrent( File::Spec->catfile( $loose, 'repair.torrent' ) );
my $normal   = touch_torrent( File::Spec->catfile( $loose, 'normal.torrent' ) );

my $db = Local::FakeDB->new([
  {path => $qbt_file, infohash => 'HASH-QBT', torrent_name => 'qbt'},
  {path => $qbt_dup,  infohash => 'HASH-QBT', torrent_name => 'qbt'},
  {path => $repair,   infohash => 'HASH-REPAIR', torrent_name => 'repair'},
  {path => $normal,   infohash => 'HASH-NORMAL', torrent_name => 'normal'},
]);

my $dedupe = bless {}, 'Local::Dedupe';
my $result = $dedupe->_canonicalize_scanned_torrents(
  db                => $db,
  dbh               => undef,
  torrent_pool      => $pool,
  restoration_dir   => $restore,
  deletion_dir      => $delete,
  downloaded_dir    => $downloaded,
  completed_dir     => $completed,
  downloaded_bucket => {keeper_by_hash => {'HASH-QBT' => {path => $qbt_file}}},
  completed_bucket  => {keeper_by_hash => {}},
  qbt_name_by_hash  => {'HASH-QBT' => 'qbt', 'HASH-REPAIR' => 'repair'},
);

ok( $result->{ok}, 'global keeper classification completed' );
is( $result->{qbt_satisfied}, 1, 'qBT folder satisfies one hash' );
is( $result->{restoration_moved}, 1, 'current qBT keeper moved to restoration' );
is( $result->{pool_moved}, 1, 'non-current keeper moved to torrent pool' );
is( $result->{add_queued}, 1, 'restoration keeper entered API add queue' );

ok( -f File::Spec->catfile( $restore, 'repair.torrent' ),
    'repair candidate is staged for restoration' );
ok( -f File::Spec->catfile( $pool, 'normal.torrent' ),
    'normal keeper is moved to torrent pool' );
ok( -f $qbt_file, 'qBT keeper remains in qBT folder' );

is( $db->{added}{'HASH-REPAIR'},
    File::Spec->catfile( $restore, 'repair.torrent' ),
    'add queue stores restoration path' );

is_deeply(
  [ map { $_->{source_path} } @{ $result->{delete_queue} } ],
  [$qbt_dup],
  'only loose duplicate of qBT keeper is queued for deletion',
);

my $naming = bless {torrent_name_source_counts => {}}, 'Local::Dedupe';

is(
  $naming->_torrent_metadata_base({
    torrent_name => 'Metadata Name.mkv',
    path         => File::Spec->catfile( $loose, 'Existing Name.torrent' ),
  }),
  'Metadata Name.mkv.torrent',
  'parsed info.name remains the preferred generated basename',
);

is(
  $naming->_torrent_metadata_base({
    torrent_name => '/',
    path         => File::Spec->catfile( $loose, 'Existing Name.torrent' ),
  }),
  'Existing Name.torrent',
  'existing filename is used when metadata normalizes to punctuation only',
);

is(
  $naming->_torrent_metadata_base({
    torrent_name => '/',
    path         => '',
    hash         => '0123456789abcdef0123456789abcdef01234567',
  }),
  '0123456789abcdef0123456789abcdef01234567.torrent',
  'hash is the last stable fallback when metadata and filename are unusable',
);

is_deeply(
  $naming->{torrent_name_source_counts},
  {
    torrent_metadata => 1,
    existing_filename => 1,
    hash_fallback => 1,
  },
  'generated basename sources are counted for the export-dedupe reveal',
);

done_testing;
