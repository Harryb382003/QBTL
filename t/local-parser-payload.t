use v5.40;
use common::sense;
use feature qw( signatures );

use Test::More;
use File::Spec;
use Digest::SHA    ();
use File::Temp qw( tempdir );
use Bencode qw( bencode );

use QBTL::Local::Parser;

my $dir = tempdir( CLEANUP => 1 );
my $single_path = File::Spec->catfile( $dir, 'single.torrent' );

open my $single_fh, '>:raw', $single_path or die "open single: $!";
print {$single_fh} bencode(
  {
    announce => 'https://tracker.example.invalid/announce',
    info     => {
      name   => 'movie.mp4',
      length => 12345,
    },
  }
);
close $single_fh;

my $parser = QBTL::Local::Parser->new;
my $single = $parser->parse_file($single_path);

ok( $single->{ok}, 'single-file torrent parses' );
is( $single->{payload_kind},       'single_file', 'single-file payload kind' );
is( $single->{payload_root_name},  'movie.mp4',   'single-file payload root name' );
is( $single->{payload_probe_name}, 'movie.mp4',   'single-file payload probe name' );
is( $single->{payload_total_size}, 12345,         'single-file payload total size' );

my %single_key = map { $_->{key} => $_->{value} } @{ $single->{observed_keys} };
is( $single_key{'info.name'},   'movie.mp4', 'single-file info.name observed' );
is( $single_key{'info.length'}, 12345,       'single-file info.length observed' );

my $multi_path = File::Spec->catfile( $dir, 'multi.torrent' );

open my $multi_fh, '>:raw', $multi_path or die "open multi: $!";
print {$multi_fh} bencode(
  {
    info => {
      name  => 'Mega Pack',
      files => [
        {
          length => 100,
          path   => [ 'Disc 1', 'clip-one.mkv' ],
        },
        {
          length => 200,
          path   => [ 'Disc 2', 'clip-two.mkv' ],
        },
      ],
    },
  }
);
close $multi_fh;

my $multi = $parser->parse_file($multi_path);

ok( $multi->{ok}, 'multi-file torrent parses' );
is( $multi->{payload_kind},       'multi_file',             'multi-file payload kind' );
is( $multi->{payload_root_name},  'Mega Pack',              'multi-file payload root name' );
is( $multi->{payload_file_count}, 2,                        'multi-file payload file count' );
is( $multi->{payload_total_size}, 300,                      'multi-file payload total size' );
is( $multi->{payload_probe_path}, 'Disc 1/clip-one.mkv',    'multi-file payload probe path' );
is( $multi->{payload_probe_name}, 'clip-one.mkv',           'multi-file payload probe name' );

my %multi_key = map { $_->{key} => $_->{value} } @{ $multi->{observed_keys} };
is( $multi_key{'info.name'},           'Mega Pack',           'multi-file info.name observed' );
is( $multi_key{'info.files.count'},    2,                     'multi-file count observed' );
is( $multi_key{'info.files.0.path'},   'Disc 1/clip-one.mkv', 'multi-file first path observed' );
is( $multi_key{'info.files.0.length'}, 100,                   'multi-file first length observed' );
is( $multi_key{'info.files.1.path'},   'Disc 2/clip-two.mkv', 'multi-file second path observed' );
is( $multi_key{'info.files.1.length'}, 200,                   'multi-file second length observed' );

my $raw_info_path = File::Spec->catfile( $dir, 'raw-info.torrent' );
my $raw_info = 'd6:lengthi1e4:name4:teste';
my $raw_torrent = 'd4:info' . $raw_info . 'e';
open my $raw_info_fh, '>:raw', $raw_info_path or die $!;
print {$raw_info_fh} $raw_torrent;
close $raw_info_fh;

my $raw_info_result = $parser->parse_file($raw_info_path);
ok( $raw_info_result->{ok}, 'raw-info torrent parsed' );
is(
  $raw_info_result->{infohash},
  Digest::SHA::sha1_hex($raw_info),
  'torrent infohash uses exact raw bencoded info bytes',
);

done_testing;
