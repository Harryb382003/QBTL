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


###
### actual api calls
###

sub app_version ($self) {
    return $self->request('app_version');
}

sub torrents_info ($self, %params) {
    return $self->request(
        'torrents_info',
        params => \%params,
    );
}

sub torrents_files ($self, $hash) {
    return $self->request(
        'torrents_files',
        params => {
            hash => $hash,
        },
    );
}

sub torrents_recheck ($self, $hashes) {
    return $self->request(
        'torrents_recheck',
        params => {
            hashes => $hashes,
        },
    );
}

sub login ($self, $username, $password) {
    return $self->request(
        'login',
        params => {
            username => $username,
            password => $password,
        },
    );
}

sub torrents_add ($self, %params) {
    return $self->request(
        'torrents_add',
        params => \%params,
    );
}

sub torrents_pause ($self, $hashes) {
    return $self->request(
        'torrents_pause',
        params => {
            hashes => $hashes,
        },
    );
}

sub torrents_resume ($self, $hashes) {
    return $self->request(
        'torrents_resume',
        params => {
            hashes => $hashes,
        },
    );
}

sub torrents_set_location ($self, $hashes, $location) {
    return $self->request(
        'torrents_set_location',
        params => {
            hashes   => $hashes,
            location => $location,
        },
    );
}

sub torrents_set_download_path ($self, $hashes, $path) {
    return $self->request(
        'torrents_set_download_path',
        params => {
            hashes => $hashes,
            path   => $path,
        },
    );
}

sub torrents_rename_folder ($self, $hash, $old_path, $new_path) {
    return $self->request(
        'torrents_rename_folder',
        params => {
            hash     => $hash,
            oldPath  => $old_path,
            newPath  => $new_path,
        },
    );
}

1;
