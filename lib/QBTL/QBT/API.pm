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

1;
