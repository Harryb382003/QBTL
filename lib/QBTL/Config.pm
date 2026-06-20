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
  my $default_root = File::Spec->catdir( $home, 'QBTL' );
  my $user_config  = File::Spec->catfile( $default_root, '.qbtlrc' );
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
              local_search_tool           => 'mdfind',
              metadata_promoter_threshold => 20, );

  my $self = bless \%self, $class;

  $self->_load_config_file;

  for my $key ( keys %arg ) {
    next if $key eq 'home';

    $self->{$key} = $arg{$key};
  }

  if ( exists $arg{db_path} && !exists $arg{installation_root} ) {
    $self->{installation_root} = dirname( $self->{db_path} );

    if ( !exists $arg{installation_config_path} ) {
      $self->{installation_config_path} =
          File::Spec->catfile( $self->{installation_root}, '.qbtlrc' );
    }
  }

  return $self;
}

sub config_path ( $self ) { return $self->{config_path}; }

sub db_path ( $self ) { return $self->{db_path}; }

sub home ( $self ) { return $self->{home}; }

sub installation_root ( $self ) {
  return $self->{installation_root} if defined $self->{installation_root};

  my $root = $self->{db_path};
  $root =~ s{/[^/]+\z}{};

  return $root;
}

sub installation_config_path ( $self ) {
  return $self->{installation_config_path}
      if defined $self->{installation_config_path};

  return File::Spec->catfile( $self->installation_root, '.qbtlrc' );
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

  if ( exists $config{installation}{root} ) {
    $self->{installation_root} =
        $self->_expand_user_path( $config{installation}{root} );
  }

  if ( exists $config{installation}{config} ) {
    $self->{installation_config_path} =
        $self->_expand_user_path( $config{installation}{config} );
  } else {
    $self->{installation_config_path} =
        File::Spec->catfile( $self->{installation_root}, '.qbtlrc' );
  }

  $self->{db_path} =
      File::Spec->catfile( $self->{installation_root}, 'qbtl.db' );

  if ( exists $config{local}{search_tool} ) {
    my $search_tool = $config{local}{search_tool};

    if ( $search_tool =~ /\A(?:mdfind|plocate|mlocate|locate|slocate|find)\z/ )
    {
      $self->{local_search_tool} = $search_tool;
    }
  }

  if ( exists $config{database}{path} ) {
    $self->{db_path} = $self->_expand_user_path( $config{database}{path} );
  }

  return;
}

sub local_search_tool ( $self ) { return $self->{local_search_tool}; }

sub metadata_promoter_threshold ( $self ) {
  return $self->{metadata_promoter_threshold};
}

sub qbt_url ( $self ) { return $self->{qbt_url}; }

sub repo_config_path ( $self ) {
  return $self->{repo_config_path};
}

sub _repo_root ( $self ) {
  my $lib_qbtl_dir = dirname( __FILE__ );         # .../lib/QBTL
  my $lib_dir      = dirname( $lib_qbtl_dir );    # .../lib
  my $repo_root    = dirname( $lib_dir );         # repo root

  return abs_path( $repo_root );
}

sub time_format ( $self ) { return $self->{time_format}; }

sub _expand_user_path ( $self, $path ) {
  return if !defined $path;

  $path =~ s{\A~(?=/|$)}{$self->{home}};
  $path =~ s{\A\$HOME(?=/|$)}{$self->{home}};
  $path =~ s{\A\$home(?=/|$)}{$self->{home}};

  return $path;
}

1;
