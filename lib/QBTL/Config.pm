package QBTL::Config;

use v5.40;
use common::sense;
use feature qw( signatures );

use Config::Std {def_sep => '='};
use Cwd            qw(abs_path);
use File::Basename qw(dirname);
use File::Spec;

sub new ( $class, %arg ) {

  my $home         = $arg{home} // $ENV{HOME} // die 'HOME is not set';
  my $user_config  = File::Spec->catfile( $home, 'QBTL', '.qbtlrc' );
  my $lib_qbtl_dir = dirname( __FILE__ );
  my $lib_dir      = dirname( $lib_qbtl_dir );
  my $repo_root    = abs_path( dirname( $lib_dir ) );
  my $repo_config  = File::Spec->catfile( $repo_root, '.qbtlrc' );
  my $config_path  = $user_config;

  if ( !-e $config_path && -e $repo_config ) {
    $config_path = $repo_config;
  }

  my %self = (

              home             => $home,
              config_path      => $config_path,
              user_config_path => $user_config,
              repo_config_path => $repo_config,
              db_path     => File::Spec->catfile( $home, 'QBTL', 'qbtl.db' ),
              qbt_url     => 'http://localhost:8080',
              time_format => 'full',
              metadata_promoter_threshold => 20, );

  my $self = bless \%self, $class;

  $self->_load_config_file;

  for my $key ( keys %arg ) {
    next if $key eq 'home';

    $self->{$key} = $arg{$key};
  }

  return $self;
}

sub _load_config_file ( $self ) {
  my $path = $self->{config_path};

  return if !-e $path;

  my %config;
  read_config $path => %config;

  if ( exists $config{metadata}
       && defined $config{metadata}{promoter_threshold} )
  {
    $self->{metadata_promoter_threshold} =
        $config{metadata}{promoter_threshold};
  }

  if ( exists $config{time_format} ) {
    my $format = $config{time_format}{time};

    if ( $format eq 'full' || $format eq 'ymd' || $format eq 'time' ) {
      $self->{time_format} = $format;
    }
  }

  if ( exists $config{qbt}{url} ) {
    $self->{qbt_url} = $config{qbt}{url};
  }

  if ( exists $config{database}{path} ) {
    my $db_path = $config{database}{path};

    $db_path =~ s{\A~(?=/|$)}{$self->{home}};
    $db_path =~ s{\A\$HOME(?=/|$)}{$self->{home}};

    $self->{db_path} = $db_path;
  }

  return;
}

sub home        ( $self ) { return $self->{home}; }
sub config_path ( $self ) { return $self->{config_path}; }
sub db_path     ( $self ) { return $self->{db_path}; }

sub metadata_promoter_threshold ( $self ) {
  return $self->{metadata_promoter_threshold};
}

sub qbt_url ( $self ) { return $self->{qbt_url}; }

sub _repo_root ( $self ) {
  my $lib_qbtl_dir = dirname( __FILE__ );         # .../lib/QBTL
  my $lib_dir      = dirname( $lib_qbtl_dir );    # .../lib
  my $repo_root    = dirname( $lib_dir );         # repo root

  return abs_path( $repo_root );
}

sub time_format ( $self ) { return $self->{time_format}; }

1;
