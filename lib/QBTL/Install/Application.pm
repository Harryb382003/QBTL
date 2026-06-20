package QBTL::Install::Application;

use v5.40;
use common::sense;
use feature qw( signatures );

use Config::Std {def_sep => '='};
use File::Spec;

sub new ( $class, %arg ) {
  return bless \%arg, $class;
}

sub discover_user_configs ( $self, %arg ) {
    my $local_search = $arg{local_search} // {};
    my $repo_root    = $self->{repo_root};

    my @paths;

    if ( ( $local_search->{search_tool} // '' ) eq 'mdfind' ) {
        @paths = $self->_discover_user_configs_mdfind;
    } else {
        @paths = $self->_discover_user_configs_find;
    }

    @paths = grep { defined $_ && -f $_ } @paths;

    if ( defined $repo_root && length $repo_root ) {
        @paths = grep {
            $_ ne $repo_root
                && index( $_, "$repo_root/" ) != 0
        } @paths;
    }

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

sub _discover_user_configs_mdfind ($self) {
    open my $fh, '-|', 'mdfind', 'kMDItemFSName == ".qbtlrc"'
        or return;

    my @paths = <$fh>;
    close $fh;

    chomp @paths;
    return @paths;
}

sub _discover_user_configs_find ($self) {
    my $home = $self->{user_home} // $ENV{HOME} // $self->home;

    open my $fh, '-|', 'find', $home, '-name', '.qbtlrc', '-type', 'f'
        or return;

    my @paths = <$fh>;
    close $fh;

    chomp @paths;
    return @paths;
}

sub home ( $self ) {
  return $self->{home};
}


1;
