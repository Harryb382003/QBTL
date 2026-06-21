use v5.40;
use common::sense;
use feature qw( signatures );

use Test::More;
use File::Temp qw( tempdir );
use File::Spec;
use File::Path qw( remove_tree make_path );

use QBTL::Install::Setup;

my $root = tempdir( CLEANUP => 0 );
my $home = File::Spec->catdir( $root, 'QBTL' );

END {
  remove_tree( $root ) if defined $root && -d $root;
}

my $setup = QBTL::Install::Setup->new( home        => $home,
                                       interactive => 0, );

isa_ok( $setup, 'QBTL::Install::Setup' );
is( $setup->home, $home, 'home stored' );

my $result = $setup->query_installation_paths;

is( $result->{root},       $home, 'default installation root returned' );
is( $result->{config_dir}, $home, 'default config directory returned' );
is( $result->{config_path},
    File::Spec->catfile( $home, '.qbtlrc' ),
    'default config path returned' );

my $prompt_in  = "/tmp/custom-QBTL\n/tmp/custom-config\n";
my $prompt_out = '';

open my $in_fh,  '<', \$prompt_in  or die "open scalar input: $!";
open my $out_fh, '>', \$prompt_out or die "open scalar output: $!";

my $prompt_setup =
    QBTL::Install::Setup->new(
                      home               => $home,
                      default_root       => $home,
                      default_config_dir => File::Spec->catdir( $home, 'QBTL' ),
                      interactive        => 1,
                      in                 => $in_fh,
                      out                => $out_fh, );

$result = $prompt_setup->query_installation_paths;

is( $result->{root}, '/tmp/custom-QBTL', 'custom install root answer stored' );
is( $result->{config_dir}, '/tmp/custom-config',
    'custom config directory answer stored' );
is( $result->{config_path},
    '/tmp/custom-config/.qbtlrc', 'custom config path answer stored' );
ok( $result->{changed}, 'custom answers mark installation as changed' );
like( $prompt_out, qr/Install QBTL where\?/,   'install prompt printed' );
like( $prompt_out, qr/Store \.qbtlrc where\?/, 'config prompt printed' );

my $tilde_in  = "~/FOO\n\n";
my $tilde_out = '';

open my $tilde_in_fh,  '<', \$tilde_in  or die "open scalar input: $!";
open my $tilde_out_fh, '>', \$tilde_out or die "open scalar output: $!";

my $tilde_setup =
    QBTL::Install::Setup->new(
                            home         => $home,
                            user_home    => $root,
                            default_root => File::Spec->catdir( $root, 'QBTL' ),
                            interactive  => 1,
                            in           => $tilde_in_fh,
                            out          => $tilde_out_fh, );

$result = $tilde_setup->query_installation_paths;

is( $result->{root},
    File::Spec->catdir( $root, 'FOO' ),
    'tilde install root expands to user home' );
is( $result->{config_dir},
    File::Spec->catdir( $root, 'FOO', 'QBTL' ),
    'default config directory follows custom install root' );
is( $result->{config_path},
    File::Spec->catfile( $root, 'FOO', 'QBTL', '.qbtlrc' ),
    'config filename remains fixed as .qbtlrc' );

my $home_var_in  = "\$home/BAR\n\$ENV{HOME}/CONFIG\n";
my $home_var_out = '';

open my $home_var_in_fh,  '<', \$home_var_in  or die "open scalar input: $!";
open my $home_var_out_fh, '>', \$home_var_out or die "open scalar output: $!";

my $home_var_setup =
    QBTL::Install::Setup->new(
                            home         => $home,
                            user_home    => $root,
                            default_root => File::Spec->catdir( $root, 'QBTL' ),
                            interactive  => 1,
                            in           => $home_var_in_fh,
                            out          => $home_var_out_fh, );

$result = $home_var_setup->query_installation_paths;

is( $result->{root},
    File::Spec->catdir( $root, 'BAR' ),
    '$home install root expands to user home' );
is( $result->{config_path},
    File::Spec->catfile( $root, 'CONFIG', '.qbtlrc' ),
    '$ENV{HOME} config directory expands and keeps .qbtlrc filename' );

{

  package Local::Discovery;

  sub new ( $class, $config ) {
    return bless {config => $config}, $class;
  }

  sub discover_user_configs ( $self, %arg ) {
    return {
            ok      => 1,
            paths   => [ $self->{config}{path} ],
            configs => [ $self->{config} ],
            count   => 1,};
  }
}

package main;

my $discovered_root   = File::Spec->catdir( $root,            'Discovered' );
my $discovered_dir    = File::Spec->catdir( $discovered_root, 'QBTL' );
my $discovered_config = File::Spec->catfile( $discovered_dir, '.qbtlrc' );

make_path( $discovered_dir );

open my $discovered_fh, '>', $discovered_config
    or die "write $discovered_config: $!";

say {$discovered_fh} "[installation]";
say {$discovered_fh} "root = \$home/Discovered";
say {$discovered_fh} "config = \$home/Discovered/QBTL/.qbtlrc";

close $discovered_fh;

$discovered_config = Cwd::abs_path( $discovered_config );
$discovered_dir    = Cwd::abs_path( $discovered_dir );
$discovered_root   = Cwd::abs_path( $discovered_root );

my $discovery_setup =
    QBTL::Install::Setup->new(
                               home        => $home,
                               application =>
                                   Local::Discovery->new(
                                    {
                                     path             => $discovered_config,
                                     has_installation => 1,
                                     root             => '$home/Discovered',
                                     config => '$home/Discovered/QBTL/.qbtlrc',}
                                   ),
                               user_home   => $root,
                               interactive => 0, );

$result =
    $discovery_setup->query_installation_paths(
                                                local_search => {
                                                          ok          => 1,
                                                          search_tool => 'find',
                                                }, );

is( $result->{root}, $discovered_dir,
    'discovered installation root becomes default root' );
is( $result->{config_dir},
    File::Spec->catdir( $discovered_root, 'QBTL' ),
    'discovered config path becomes default config directory' );
is( $result->{config_path},
    $discovered_config, 'discovered config path remains .qbtlrc' );

my $custom_root   = File::Spec->catdir( $root, 'CustomQBTL' );
my $custom_config = File::Spec->catfile( $custom_root, '.qbtlrc' );

my $write =
    $prompt_setup->write_installation_config(
                                              {
                                               root        => $custom_root,
                                               config_path => $custom_config,
                                               changed     => 1,} );

ok( $write->{ok},      'custom installation config write result ok' );
ok( -e $custom_config, 'custom installation config file written' );

{
  open my $custom_fh, '<', $custom_config or die "open $custom_config: $!";
  my $custom_text = do { local $/; <$custom_fh> };

  like( $custom_text, qr/\[installation\]/,
        'custom config includes installation section' );
  like( $custom_text,
        qr/root\s*=\s*\Q$custom_root\E/,
        'custom config stores custom installation root' );
  like( $custom_text,
        qr/config\s*=\s*\Q$custom_config\E/,
        'custom config stores custom config path' );
}

done_testing;
