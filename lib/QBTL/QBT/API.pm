package QBTL::QBT::API;

use v5.40;
use common::sense;
use feature qw( signatures );

sub new ($class, %arg) {
    $arg{base_url} //= 'http://localhost:8080';

    $arg{base_url} =~ s{/+\z}{};

    return bless \%arg, $class;
}

sub base_url ($self) {
    return $self->{base_url};
}

sub api_url ($self, $path) {
    $path =~ s{\A/+}{};

    return $self->base_url . '/api/v2/' . $path;
}

sub endpoint ($self, $name) {
    my %endpoint = (
        login                       => 'auth/login',
        app_version                 => 'app/version',
        torrents_info               => 'torrents/info',
        torrents_files              => 'torrents/files',
        torrents_add                => 'torrents/add',
        torrents_recheck            => 'torrents/recheck',
        torrents_pause              => 'torrents/pause',
        torrents_resume             => 'torrents/resume',
        torrents_set_location       => 'torrents/setLocation',
        torrents_set_download_path  => 'torrents/setDownloadPath',
        torrents_rename_folder      => 'torrents/renameFolder',
    );

    die "Unknown qBT endpoint: $name" if !exists $endpoint{$name};

    return $self->api_url( $endpoint{$name} );
}

sub request ($self, $name, %arg) {
    my %method = (
        login                       => 'POST',
        app_version                 => 'GET',
        torrents_info               => 'GET',
        torrents_files              => 'GET',
        torrents_add                => 'POST',
        torrents_recheck            => 'POST',
        torrents_pause              => 'POST',
        torrents_resume             => 'POST',
        torrents_set_location       => 'POST',
        torrents_set_download_path  => 'POST',
        torrents_rename_folder      => 'POST',
    );

    die "Unknown qBT endpoint: $name" if !exists $method{$name};

    return {
        endpoint => $name,
        method   => $method{$name},
        url      => $self->endpoint($name),
        params   => $arg{params} // {},
    };
}

1;
