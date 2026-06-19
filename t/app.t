use v5.40;
use common::sense;
use feature qw( signatures );

use Test::More;
use File::Temp qw( tempdir );
use File::Spec;
use File::Path qw( remove_tree );

use QBTL::App;
use QBTL::Config;
use QBTL::Render::CLI;

my $out = '';

{    # package Local::FakeUA;

  package Local::FakeUA;

  use v5.40;
  use common::sense;
  use feature qw( signatures );

  sub new ( $class ) {
    return bless {urls => []}, $class;
  }

  sub get ( $self, $uri ) {
    push @{$self->{urls}}, "$uri";

    if ( "$uri" =~ m{/api/v2/app/preferences} ) {
      return
          Local::FakeResponse->new(
                   code => 200,
                   body => '{"save_path":"/Downloads","queueing_enabled":true}',
          );
    }

    return Local::FakeResponse->new(
      code => 200,
      body => '[
        {"hash":"abc123","name":"App Test One"},
        {"hash":"def456","name":"App Test Two"}]', );
  }

  sub urls ( $self ) {
    return $self->{urls};
  }
}

{    # package Local::FakeResponse;

  package Local::FakeResponse;

  use v5.40;
  use common::sense;
  use feature qw( signatures );

  sub new ( $class, %arg ) {
    return bless \%arg, $class;
  }

  sub is_success ( $self ) {
    return 1;
  }

  sub status_line ( $self ) {
    return '200 OK';
  }

  sub code ( $self ) {
    return $self->{code};
  }

  sub decoded_content ( $self ) {
    return $self->{body};
  }
}

open my $fh, '>', \$out or die "open scalar fh: $!";

my $root = tempdir( CLEANUP => 0 );

END {
  remove_tree( $root ) if defined $root && -d $root;
}

my $db_path = File::Spec->catfile( $root, 'QBTL', 'qbtl.db' );

my $config = QBTL::Config->new( db_path => $db_path,
                                qbt_url => 'http://127.0.0.1:8080', );

my $qbt_ua   = Local::FakeUA->new;
my $renderer = QBTL::Render::CLI->new( out => $fh );
my $app = QBTL::App->new(
                          config   => $config,
                          renderer => $renderer,
                          qbt_ua   => $qbt_ua, );

isa_ok( $app, 'QBTL::App' );

$out = '';
is( $app->run_cli( 'version' ), 0, 'version command exits cleanly' );
like( $out, qr/\AQBTL 0\.001\n\z/, 'version command renders version' );

$out = '';
is( $app->run_cli( 'help' ), 0, 'help command exits cleanly' );
like( $out, qr/Usage:/, 'help command renders usage heading' );
like( $out, qr/qbtl <command> \[options\]/,     'help command renders usage' );
like( $out, qr/qbt\s+qBittorrent API commands/, 'qbt command is listed' );

$out = '';
is( $app->run_cli(), 0, 'default command exits cleanly' );
like( $out, qr/Usage:/, 'default command renders help heading' );
like( $out, qr/qbtl <command> \[options\]/, 'default command renders help' );

$out = '';
is( $app->run_cli( 'setup' ), 0, 'setup command exits cleanly' );
like( $out, qr/QBTL setup complete\./, 'setup command renders completion' );
ok( -d File::Spec->catdir( $root, 'QBTL' ),
    'setup command creates configured home directory' );

$out = '';
is( $app->run_cli( 'status' ), 0, 'status command exits cleanly after setup' );
like( $out, qr/QBTL status/,          'status command renders status' );
like( $out, qr/Database path: ready/, 'status command reports ready path' );

$out = '';
is( $app->run_cli( 'qbt', 'info' ), 0, 'qbt info command exits cleanly' );
like( $out, qr/qBT request complete\./,    'qbt info command renders result' );
like( $out, qr/Action: qbt_torrents_info/, 'qbt info command renders action' );

$out = '';
is( $app->run_cli( 'qbt', 'refresh' ), 0, 'qbt refresh command exits cleanly' );
like( $out,
      qr/qBT refresh complete\./,
      'qbt refresh command renders completion' );
like( $out, qr/seen:\s+2/,     'qbt refresh command rendrs seen count' );
like( $out, qr/stored:\s+2/,   'qbt refresh command renders stored count' );
like( $out, qr/problems:\s+0/, 'qbt refresh command renders problem count' );

$out = '';
is( $app->run_cli( 'qbt', 'preferences' ),
    0, 'qbt preferences command exits cleanly' );
like( $out,
      qr/qBT preferences refresh complete\./,
      'qbt preferences command renders completion' );
like( $out, qr/seen:\s+213\b/, 'qbt preferences command renders seen count' );
like( $out, qr/stored:\s+213\b/,
      'qbt preferences command renders stored count' );
like( $out, qr/problems:\s+0/,
      'qbt preferences command renders problem count' );

$out = '';
is( $app->run_cli( 'qbt', 'preferences', 'keys' ),
    0, 'qbt preferences keys command exits cleanly' );
like( $out,
      qr/qBT preference keys:/,
      'qbt preferences keys command renders heading' );
like( $out,
      qr/web_ui_username\s+string\s+admin/,
      'qbt preferences keys command renders stored preference value' );
like( $out,
      qr/web_ui_username\s+string\s+admin/,
      'qbt preferences keys command renders stored preference value' );

$out = '';
is( $app->run_cli( 'qbt', 'help' ), 0, 'qbt help command exits cleanly' );
like( $out, qr/Usage:/,             'qbt help command renders usage heading' );
like( $out, qr/qbtl qbt <command>/, 'qbt help command renders usage' );
like( $out, qr/help\s+Show this help/, 'qbt help command is listed' );
like( $out,
      qr/info\s+Fetch qBittorrent torrents\/info/,
      'qbt info command is listed' );
like( $out,
      qr/preferences\s+.*app\/preferences/,
      'qbt preferences command is listed' );
like( $out,
      qr/refresh\s+Store qBittorrent torrents\/info rows/,
      'qbt refresh command is listed' );

$out = '';
is( $app->run_cli( 'qbt' ), 0, 'bare qbt command exits cleanly' );
like( $out, qr/Usage:/, 'bare qbt command renders qbt help heading' );
like( $out, qr/qbtl qbt <command>/, 'bare qbt command renders qbt help' );

done_testing;
