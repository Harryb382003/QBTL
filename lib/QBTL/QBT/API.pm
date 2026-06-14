package QBTL::QBT::API;

use v5.40;
use common::sense;
use feature qw( signatures );

sub new ($class, %arg) {
    $arg{base_url} //= 'http://localhost:8080';
    $arg{base_url} =~ s{/+\z}{};

    return bless \%arg, $class;
}

sub ua ($self) {
    return $self->{ua};
}

sub base_url ($self) {
    return $self->{base_url};
}

sub api_url ($self, $path) {
    $path =~ s{\A/+}{};

    return $self->base_url . '/api/v2/' . $path;
}

sub endpoint ($self, $name) {
    my $spec = $self->endpoint_spec($name);
    return $self->api_url( $spec->{path} );
}

sub execute_request ( $self, $request ) {
    if ( !$self->{ua} ) {
        return {
            ok      => 0,
            status  => 'no_user_agent',
            request => $request,
            error   => 'No user agent configured',
        };
    }

    return $self->{ua}->execute($request);
}

sub endpoint_spec ($self, $name) {
    my %spec = (
        login => {
            method => 'POST',
            path   => 'auth/login',
        },
        app_version => {
            method => 'GET',
            path   => 'app/version',
        },
        torrents_info => {
            method => 'GET',
            path   => 'torrents/info',
        },
        torrents_files => {
            method => 'GET',
            path   => 'torrents/files',
        },
        torrents_add => {
            method => 'POST',
            path   => 'torrents/add',
        },
        torrents_recheck => {
            method => 'POST',
            path   => 'torrents/recheck',
        },
        torrents_pause => {
            method => 'POST',
            path   => 'torrents/pause',
        },
        torrents_resume => {
            method => 'POST',
            path   => 'torrents/resume',
        },
        torrents_set_location => {
            method => 'POST',
            path   => 'torrents/setLocation',
        },
        torrents_set_download_path => {
            method => 'POST',
            path   => 'torrents/setDownloadPath',
        },
        torrents_rename_folder => {
            method => 'POST',
            path   => 'torrents/renameFolder',
        },
    );

    die "Unknown qBT endpoint: $name" if !exists $spec{$name};

    return $spec{$name};
}

sub request ($self, $name, %arg) {
    my $spec = $self->endpoint_spec($name);

    return {
        endpoint => $name,
        method   => $spec->{method},
        url      => $self->api_url( $spec->{path} ),
        params   => $arg{params} // {},
    };
}


###
### actual api calls
###

sub app_version ($self) {
    return $self->request('app_version');
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

sub torrents_files ($self, $hash) {
    return $self->request(
        'torrents_files',
        params => {
            hash => $hash,
        },
    );
}

sub torrents_info ($self, %params) {
    return $self->request(
        'torrents_info',
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

sub torrents_recheck ($self, $hashes) {
    return $self->request(
        'torrents_recheck',
        params => {
            hashes => $hashes,
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

sub torrents_resume ($self, $hashes) {
    return $self->request(
        'torrents_resume',
        params => {
            hashes => $hashes,
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

sub torrents_set_location ($self, $hashes, $location) {
    return $self->request(
        'torrents_set_location',
        params => {
            hashes   => $hashes,
            location => $location,
        },
    );
}

1;
