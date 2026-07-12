package QBTL::Install::Application;

# lib/QBTL/Install/Application.pm
use v5.40;
use common::sense;
use feature qw( signatures );

use Config::Std {def_sep => '='};
use File::Spec;

sub new ( $class, %arg ) {
  return bless \%arg, $class;
}

sub _bt_backup_probe_paths ( $self ) {
  my $home = $self->{user_home} // $ENV{HOME} // $self->home;

  if ( $^O eq 'darwin' ) {
    return (
      File::Spec->catdir(
                          $home,
                          'Library',
                          'Application Support',
                          'qBittorrent',
                          'BT_backup',
      ),
    );
  } else {

    say __LINE__ . "Currently, no support has been written for " . $^O;

  }

  return;
}

sub discover_bt_backup ( $self, %arg ) {
  my $local_search = $arg{local_search} // {};
  my $out          = $self->{out} // \*STDOUT;

  for my $path ( $self->_bt_backup_probe_paths ) {
    say {$out} "Checking for the default installation for BT_backup.";
    say {$out} "$path";

    if ( -d $path ) {
      return {
              ok     => 1,
              source => 'probe',
              path   => $path,};
    }
  }

  if ( ( $local_search->{search_tool} // '' ) eq 'mdfind' ) {
    say {$out} 'BT_backup was not found in the default directory';
    say {$out} 'Now searching for BT_backup with mdfind.';

    my @paths = $self->_discover_bt_backup_mdfind;

    if ( @paths ) {
      return {
              ok     => 1,
              source => 'mdfind',
              path   => $paths[0],};
    }
  }

    if ( ( $local_search->{search_tool} // '' ) eq 'find' ) {
    say {$out} 'BT_backup was not found in the default directory';
    say {$out} 'searching for BT_backup with find.';
  }
  else {
    say {$out} 'BT_backup was not found with configured/default discovery.';
    say {$out} 'Falling back to searching for BT_backup with find.';
  }

  my @paths = $self->_discover_bt_backup_find;

  if ( @paths ) {
    return {
            ok     => 1,
            source => 'find',
            path   => $paths[0],};
  }

  return {
          ok       => 0,
          status   => 'bt_backup_not_found',
          problems => [
            'no BT_backup directory found, check your qBittorrent installation',
          ],};
}

sub _discover_bt_backup_find ( $self ) {
  my $home = $self->{user_home} // $ENV{HOME} // $self->home;
  ( my $safe_home = $home ) =~ s/'/'\\''/g;

  open my $fh, '-|', "find '$safe_home' -name BT_backup -type d 2>/dev/null"
      or return;

  my @paths = <$fh>;
  close $fh;

  chomp @paths;

  return @paths;
}

sub _discover_bt_backup_mdfind ( $self ) {
  open my $fh, '-|', 'mdfind', 'kMDItemFSName == "BT_backup"'
      or return;

  my @paths = <$fh>;
  close $fh;

  chomp @paths;

  return grep { -d $_ && ( File::Spec->splitdir($_) )[-1] eq 'BT_backup' }
      @paths;
}

sub discover_user_configs ( $self, %arg ) {
    my $local_search = $arg{local_search} // {};
    my $repo_root    = $self->{repo_root};
    my @paths;

    @paths = $self->_discover_user_configs_find;

    @paths = grep { defined $_ && -f $_ } @paths;

    if ( defined $repo_root && length $repo_root ) {
        @paths = grep {
            $_ ne $repo_root
                && index( $_, "$repo_root/" ) != 0
        } @paths;
    }
    my $trash = File::Spec->catdir(
        $self->{user_home} // $ENV{HOME} // $self->home,'.Trash'
        );

@paths = grep {
    $_ ne $trash
        && index( $_, "$trash/" ) != 0
} @paths;

    my %seen;
    @paths = grep { !$seen{$_}++ } sort @paths;

    my @configs = map { $self->installation_config($_) } @paths;

    return {
        ok      => 1,
        paths   => \@paths,
        configs => \@configs,
        count   => scalar @paths,
    };
}

sub _discover_user_configs_find ($self) {
    my $home = $self->{user_home} // $ENV{HOME} // $self->home;

    (my $safe_home = $home) =~ s/'/'\\''/g;

    my $out = $self->{out} // \*STDOUT;
say {$out} "Searching for existing QBTL installations... this may take a while";

    open my $fh, '-|', "find '$safe_home' -name .qbtlrc -type f 2>/dev/null"
        or return;

    my @paths = <$fh>;
    close $fh;

    chomp @paths;
    return @paths;
}

sub _discover_user_configs_mdfind ($self) {
    open my $fh, '-|', 'mdfind', 'kMDItemFSName == ".qbtlrc"'
        or return;

    my @paths = <$fh>;
    close $fh;

    chomp @paths;
    return @paths;
}

sub home ( $self ) {
  return $self->{home};
}

sub installation_config ( $self, $path ) {
    my %config;
    read_config $path => %config;

    return {
        path             => $path,
        has_installation => exists $config{installation} ? 1 : 0,
        root             => $config{installation}{root},
        config           => $config{installation}{config},
    };
}


1;
