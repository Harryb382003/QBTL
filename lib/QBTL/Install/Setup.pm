package QBTL::Install::Setup;

use v5.40;
use common::sense;
use feature qw( signatures );

use Config::Std {def_sep => '='};
use File::Basename qw( dirname );
use File::Path     qw( make_path );
use File::Spec;

use QBTL::Install::Application;
use QBTL::Config;
use QBTL::DB;
use QBTL::Render::CLI;

sub new ( $class, %arg ) {
  $arg{config} //= QBTL::Config->new;
  $arg{renderer} //=
      QBTL::Render::CLI->new( time_format => $arg{config}->time_format, );

  return bless \%arg, $class;
}

sub _application ( $self ) {
  return $self->{application} //=
      QBTL::Install::Application->new(
                                       home      => $self->home,
                                       user_home => $self->{user_home},
                                       repo_root => $self->{repo_root}, );
}

sub _command_path ( $self, $command ) {
  return if !defined $command || $command eq '';

  for my $dir ( File::Spec->path ) {
    next if !defined $dir || $dir eq '';

    my $path = File::Spec->catfile( $dir, $command );
    return $path if -x $path && !-d $path;
  }

  return;
}

sub _contract_home_path ( $self, $path ) {
  my $home = $self->{user_home} // $ENV{HOME} // '';
  if ( length $home && $path =~ s{\A\Q$home\E(?=/|$)}{\$home} ) {
    return $path;
  }
  return $path;
}

sub _default_config_dir ( $self, $root, $default_root ) {
  return $root if $root eq $default_root;

  return File::Spec->catdir( $root, 'QBTL' );
}

sub _detect_local_search_tool ( $self ) {
  my @tools = (
                {name => 'mdfind',  indexed => 1},
                {name => 'plocate', indexed => 1},
                {name => 'mlocate', indexed => 1},
                {name => 'locate',  indexed => 1},
                {name => 'slocate', indexed => 1},
                {name => 'find',    indexed => 0}, );

  my @found;

  for my $tool ( @tools ) {
    my $path = $self->_command_path( $tool->{name} );

    push @found,
        {
         name    => $tool->{name},
         path    => $path,
         indexed => $tool->{indexed},
         found   => defined $path ? 1 : 0,};
  }

  my ( $selected ) = grep { $_->{found} && $_->{indexed} } @found;
  my $warning;

  if ( !defined $selected ) {
    ( $selected ) = grep { $_->{found} && $_->{name} eq 'find' } @found;

    if ( defined $selected ) {
      $warning =
            'No indexed local search tool found. Consider installing '
          . 'plocate, mlocate, or locate for DB-driven local file discovery. '
          . 'Using filesystem fallback: find';
    }
  }

  if ( !defined $selected ) {
    return {
            ok       => 0,
            status   => 'no_local_search_tool',
            tools    => \@found,
            problems => ['No local search tool found'],};
  }

  return {
          ok          => 1,
          tools       => \@found,
          search_tool => $selected->{name},
          path        => $selected->{path},
          indexed     => $selected->{indexed},
          warning     => $warning,};
}

sub _expand_home_path ( $self, $path ) {
  return if !defined $path;

  my $home = $self->{user_home} // $ENV{HOME} // '';
  return $path if !length $home;

  $path =~ s{\A~(?=/|$)}{$home};
  $path =~ s{\A\$home(?=/|$)}{$home}i;
  $path =~ s{\A\$\{home\}(?=/|$)}{$home}i;
  $path =~ s{\A\$ENV\{HOME\}(?=/|$)}{$home};

  return $path;
}

sub home ( $self ) {
  return $self->{home};
}

sub _interactive ( $self ) {
  return $self->{interactive} if exists $self->{interactive};
  my $in = $self->{in} // \*STDIN;
  return -t $in ? 1 : 0;
}

sub _prompt_path ( $self, $question, $default ) {
  return $default if !$self->_interactive;
  my $out = $self->{out} // \*STDOUT;
  my $in  = $self->{in}  // \*STDIN;
  print {$out} "$question [$default]: ";
  my $answer = <$in>;
  return $default if !defined $answer;
  chomp $answer;
  $answer =~ s/\A\s+//;
  $answer =~ s/\s+\z//;
  return length $answer ? $answer : $default;
}

sub query_installation_paths ( $self, %arg ) {
  my $discovery =
      $arg{local_search} && $arg{local_search}{ok}
      ? $self->_application->discover_user_configs(
                                       local_search => $arg{local_search}, )
      : {ok => 1, paths => [], configs => [], count => 0};
  my $existing = $self->_preferred_installation_config( $discovery );
  my $default_root =
      $self->_expand_home_path(
                    $existing->{root} // $self->{default_root} // $self->home );

  my $root = $self->_expand_home_path(
                  $self->_prompt_path( 'Install QBTL where?', $default_root ) );

  my $default_config_dir =
        $existing->{config_dir}
      ? $self->_expand_home_path( $existing->{config_dir} )
      : $self->{default_config_dir}
      ? $self->_expand_home_path( $self->{default_config_dir} )
      : $self->_default_config_dir( $root, $default_root );

  my $config_dir = $self->_expand_home_path(
           $self->_prompt_path( 'Store .qbtlrc where?', $default_config_dir ) );

  my $config_path = File::Spec->catfile( $config_dir, '.qbtlrc' );

  return {
     root               => $root,
     config_dir         => $config_dir,
     config_path        => $config_path,
     default_root       => $default_root,
     default_config_dir => $default_config_dir,
     discovery          => $discovery,
     changed => ( $root ne $default_root || $config_dir ne $default_config_dir )
     ? 1
     : 0,};
}

sub _preferred_installation_config ( $self, $discovery ) {
  my @configs = grep { $_->{has_installation} } @{ $discovery->{configs} // [] };

  return {} if !@configs;

  my $config = $configs[0];
  my $root   = $self->_expand_home_path( $config->{root} );
  my $path   = $self->_expand_home_path( $config->{config} // $config->{path} );

  my $dir = defined $path ? dirname( $path ) : undef;

  return {
          root       => $root,
          config_dir => $dir,
          config     => $path,};
}

sub write_installation_config ( $self, $installation ) {
  my $path    = $installation->{config_path};
  my $dir     = dirname( $path );
  my $existed = -e $path ? 1 : 0;
  make_path( $dir ) if !-d $dir;
  my %config;
  my $source = $self->{repo_config_path};
  if ( -e $path ) {
    read_config $path => %config;
    $source = $path;
  } elsif ( defined $source && -e $source ) {
    read_config $source => %config;
  }

  $config{installation}{root} =
      $self->_contract_home_path( $installation->{root} );
  $config{installation}{config} =
      $self->_contract_home_path( $installation->{config_path} );

#   $config{database}{path} =
#       $self->_contract_home_path(
#                       File::Spec->catfile( $installation->{root}, 'qbtl.db' ) );

  write_config %config => $path;

  return {
          ok      => 1,
          path    => $path,
          source  => $source,
          changed => $installation->{changed} || !$existed ? 1 : 0,};

}

1;
