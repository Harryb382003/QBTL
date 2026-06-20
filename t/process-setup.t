use v5.40;
use common::sense;
use feature qw( signatures );

use Test::More;
use File::Temp qw( tempdir );
use File::Spec;
use File::Path qw( remove_tree );

use QBTL::DB;
use QBTL::Process::Setup;

my $root    = tempdir( CLEANUP => 0 );
my $home    = File::Spec->catdir( $root, 'QBTL' );
my $db_path = File::Spec->catfile( $home, 'qbtl.db' );

END {
  remove_tree( $root ) if defined $root && -d $root;
}

my $db = QBTL::DB->new(
                   db_path       => $db_path,
                   migration_dir => File::Spec->catdir( 'share', 'migrations' ),
);

my $setup = QBTL::Process::Setup->new(
                                       home        => $home,
                                       db          => $db,
                                       interactive => 0, );

isa_ok( $setup, 'QBTL::Process::Setup' );
is( $setup->home, $home, 'home stored' );

my $result = $setup->run;

ok( $result->{ok}, 'setup result ok' );
is( $result->{home}, $home, 'setup result home' );

ok( -d $home,           'home directory created' );
ok( -d "$home/logs",    'logs directory created' );
ok( -d "$home/backups", 'backups directory created' );
ok( -d "$home/tmp",     'tmp directory created' );

my $config_path = File::Spec->catfile( $home, '.qbtlrc' );

ok( -e $config_path, 'setup writes config file' );

{
  open my $config_fh, '<', $config_path
      or die "open $config_path: $!";
  my $config_text = do { local $/; <$config_fh> };

  like( $config_text, qr/\[installation\]/,
        'config file includes installation section' );
  like( $config_text, qr/root\s*=\s*\Q$home\E/,
        'config file stores installation root' );
  like( $config_text,
        qr/config\s*=\s*\Q$config_path\E/,
        'config file stores config path' );

  #   like( $config_text, qr/path\s*=\s*\Q$db_path\E/,
  #         'config file stores database path' );
}

my $config_path = File::Spec->catfile( $home, '.qbtlrc' );

ok( -e $config_path, 'setup writes config file' );

{
  open my $config_fh, '<', $config_path
      or die "open $config_path: $!";
  my $config_text = do { local $/; <$config_fh> };

  like( $config_text, qr/\[installation\]/,
        'config file includes installation section' );
  like( $config_text, qr/root\s*=\s*\Q$home\E/,
        'config file stores installation root' );
  like( $config_text,
        qr/config\s*=\s*\Q$config_path\E/,
        'config file stores config path' );

  #   like( $config_text, qr/path\s*=\s*\Q$db_path\E/,
  #         'config file stores database path' );
}

# ok( -e $db_path,                          'database file created' );
# ok( $result->{db_result}{ok},             'database setup result ok' );
# ok( $result->{db_result}{migration}{ok},  'database migration result ok' );
ok( $result->{local_search}{ok},          'local search detection result ok' );
ok( $result->{local_search}{search_tool}, 'local search tool selected' );

my $second = $setup->run;

ok( $second->{ok}, 'second setup result ok' );
is_deeply( $second->{created}, [], 'second setup creates nothing' );
ok( @{$second->{existing}} >= 4, 'second setup reports existing dirs' );
ok( $second->{db_result}{ok},    'second setup database result ok' );

my $prompt_in  = "/tmp/custom-QBTL\n/tmp/custom-config\n";
my $prompt_out = '';

open my $in_fh,  '<', \$prompt_in  or die "open scalar input: $!";
open my $out_fh, '>', \$prompt_out or die "open scalar output: $!";

my $prompt_setup =
    QBTL::Process::Setup->new(
                 home                => $home,
                 default_root        => $home,
                 default_config_path => File::Spec->catfile( $home, '.qbtlrc' ),
                 interactive         => 1,
                 in                  => $in_fh,
                 out                 => $out_fh, );

my $answers = $prompt_setup->query_installation_paths;

is( $answers->{root}, '/tmp/custom-QBTL', 'custom install root answer stored' );
is( $answers->{config_dir},
    '/tmp/custom-config', 'custom config directory answer stored' );
is( $answers->{config_path},
    '/tmp/custom-config/.qbtlrc', 'custom config path answer stored' );
ok( $answers->{changed}, 'custom answers mark installation as changed' );
like( $prompt_out, qr/Install QBTL where\?/,   'install prompt printed' );
like( $prompt_out, qr/Store \.qbtlrc where\?/, 'config prompt printed' );

my $custom_root   = File::Spec->catdir( $root, 'CustomQBTL' );
my $custom_config = File::Spec->catfile( $custom_root, 'custom.qbtlrc' );

my $write =
    $prompt_setup->write_installation_config(
                                              {
                                               root        => $custom_root,
                                               config_path => $custom_config,
                                               changed     => 1,} );

ok( $write->{ok},      'custom installation config write result ok' );
ok( -e $custom_config, 'custom installation config file written' );

{
  open my $custom_fh, '<', $custom_config
      or die "open $custom_config: $!";
  my $custom_text = do { local $/; <$custom_fh> };

  like( $custom_text,
        qr/root\s*=\s*\Q$custom_root\E/,
        'custom config stores custom installation root' );
  like( $custom_text,
        qr/config\s*=\s*\Q$custom_config\E/,
        'custom config stores custom config path' );
}

my $prompt_in  = "/tmp/custom-QBTL\n/tmp/custom-config\n";
my $prompt_out = '';

open my $in_fh,  '<', \$prompt_in  or die "open scalar input: $!";
open my $out_fh, '>', \$prompt_out or die "open scalar output: $!";

my $prompt_setup =
    QBTL::Process::Setup->new(
                 home                => $home,
                 default_root        => $home,
                 default_config_path => File::Spec->catfile( $home, '.qbtlrc' ),
                 interactive         => 1,
                 in                  => $in_fh,
                 out                 => $out_fh, );

my $answers = $prompt_setup->query_installation_paths;

is( $answers->{root}, '/tmp/custom-QBTL', 'custom install root answer stored' );
is( $answers->{config_dir},
    '/tmp/custom-config', 'custom config directory answer stored' );
is( $answers->{config_path},
    '/tmp/custom-config/.qbtlrc', 'custom config path answer stored' );
ok( $answers->{changed}, 'custom answers mark installation as changed' );
like( $prompt_out, qr/Install QBTL where\?/,   'install prompt printed' );
like( $prompt_out, qr/Store \.qbtlrc where\?/, 'config prompt printed' );

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
  open my $custom_fh, '<', $custom_config
      or die "open $custom_config: $!";
  my $custom_text = do { local $/; <$custom_fh> };

  like( $custom_text,
        qr/root\s*=\s*\Q$custom_root\E/,
        'custom config stores custom installation root' );
  like( $custom_text,
        qr/config\s*=\s*\Q$custom_config\E/,
        'custom config stores custom config path' );
}

done_testing;
