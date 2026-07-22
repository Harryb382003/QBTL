package QBTL::QBT::API;

use v5.40;
use common::sense;
use feature qw( signatures );

use URI;
use URI::Escape qw(uri_escape uri_escape_utf8);
use LWP::UserAgent;
use HTTP::Cookies;

sub new ( $class, %arg ) {
  $arg{base_url} //= 'http://localhost:8080';
  $arg{base_url} =~ s{/+\z}{};

  $arg{username} //= 'admin';
  $arg{password} //= 'adminadmin';
  $arg{timeout}  //= 3;

  $arg{ua} //= LWP::UserAgent->new( cookie_jar => HTTP::Cookies->new,
                                    timeout    => $arg{timeout}, );

  return bless \%arg, $class;
}

sub api_url ($self, $path) {
    $path =~ s{\A/+}{};

    return $self->base_url . '/api/v2/' . $path;
}

sub base_url ($self) {
    return $self->{base_url};
}

sub endpoint ($self, $name) {
    my $spec = $self->endpoint_spec($name);
    return $self->api_url( $spec->{path} );
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
        app_preferences => {
            method => 'GET',
            path   => 'app/preferences',
        },
        torrents_info => {
            method => 'GET',
            path   => 'torrents/info',
        },
        torrents_files => {
            method => 'GET',
            path   => 'torrents/files',
        },
        torrents_properties => {
            method => 'GET',
            path   => 'torrents/properties',
        },
        log_main => {
            method => 'GET',
            path   => 'log/main',
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
        torrents_rename_folder => {
            method => 'POST',
            path   => 'torrents/renameFolder',
        },
        rss_refresh_item => {
            method => 'POST',
            path   => 'rss/refreshItem',
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
        torrents_trackers => {
        method => 'GET',
        path   => 'torrents/trackers',
        },
    );

    die "Unknown qBT endpoint: $name" if !exists $spec{$name};

    return $spec{$name};
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

  return $self->_execute_lwp_request( $request );
}

sub _execute_lwp_request ( $self, $request ) {
  my $method = $request->{method} // '';
  my $url    = $request->{url}    // '';

  if ( $method eq 'GET' ) {
    my $uri = URI->new( $url );

    if ( %{ $request->{params} // {} } ) {
      $uri->query_form( %{ $request->{params} } );
    }

    my $res = $self->{ua}->get( $uri );

    return {
            ok      => $res->is_success ? 1 : 0,
            status  => $res->status_line,
            code    => $res->code,
            request => $request,
            url     => "$uri",
            body    => $res->decoded_content // '',
    };
  }

  if ( $method eq 'POST' ) {
    if ( $request->{form_data} ) {
      my $res = $self->{ua}->post(
                                   $url,
                                   Content_Type => 'form-data',
                                   Content      => $request->{form_data},
      );

      return {
              ok      => $res->is_success ? 1 : 0,
              status  => $res->status_line,
              code    => $res->code,
              request => $request,
              url     => $url,
              body    => $res->decoded_content // '',
      };
    }

    my $res = $self->{ua}->post( $url, $request->{params} // {} );

    return {
            ok      => $res->is_success ? 1 : 0,
            status  => $res->status_line,
            code    => $res->code,
            request => $request,
            url     => $url,
            body    => $res->decoded_content // '',
    };
  }

  return {
          ok      => 0,
          status  => 'unsupported_method',
          request => $request,
          error   => "Unsupported method: $method",
  };
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

sub ua ( $self ) {
  $self->{ua} //= LWP::UserAgent->new(
    cookie_jar => {},
  );

  return $self->{ua};
}


###
### actual api calls
###

sub app_preferences ($self) {
    return $self->request('app_preferences');
}

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

sub torrents_add_file ( $self, $path, %params ) {
    die 'torrent path is required' if !defined $path || $path eq '';

    my @form_data = ( torrents => [$path] );

    for my $key ( sort keys %params ) {
        next if !defined $params{$key};
        next if $params{$key} eq '';

        push @form_data, $key => $params{$key};
    }

    return {
        endpoint  => 'torrents_add',
        method    => 'POST',
        url       => $self->endpoint('torrents_add'),
        params    => \%params,
        form_data => \@form_data,
        file      => $path,
    };
}

sub torrents_files ($self, $hash) {
    return $self->request(
        'torrents_files',
        params => {
            hash => $hash,
        },
    );
}

sub torrents_properties ($self, $hash) {
    return $self->request(
        'torrents_properties',
        params => {
            hash => $hash,
        },
    );
}

sub torrents_trackers ($self, $hash) {
    return $self->request(
        'torrents_trackers',
        params => {
            hash => $hash,
        },
    );
}

sub log_main ($self, %params) {
    return $self->request(
        'log_main',
        params => \%params,
    );
}

sub torrents_info ($self, %params) {
    return $self->request( 'torrents_info', params => \%params, );
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


###
### known qBT torrent mutation calls, not yet implemented
###


sub rss_refresh_item ( $self, $item_path ) {
    return $self->request(
        'rss_refresh_item',
        params => {
            itemPath => $item_path,
        },
    );
}


sub torrents_delete (
    $self,
    $hashes,
    $delete_files,
) { ... }

sub torrents_reannounce (
    $self,
    $hashes,
) { ... }

sub torrents_add_trackers (
    $self,
    $hash,
    $urls,
) { ... }

sub torrents_edit_tracker (
    $self,
    $hash,
    $original_url,
    $new_url,
) { ... }

sub torrents_remove_trackers (
    $self,
    $hash,
    $urls,
) { ... }

sub torrents_add_peers (
    $self,
    $hashes,
    $peers,
) { ... }

sub torrents_increase_priority (
    $self,
    $hashes,
) { ... }

sub torrents_decrease_priority (
    $self,
    $hashes,
) { ... }

sub torrents_top_priority (
    $self,
    $hashes,
) { ... }

sub torrents_bottom_priority (
    $self,
    $hashes,
) { ... }

sub torrents_set_file_priority (
    $self,
    $hash,
    $file_ids,
    $priority,
) { ... }

sub torrents_set_download_limit (
    $self,
    $hashes,
    $limit,
) { ... }

sub torrents_set_upload_limit (
    $self,
    $hashes,
    $limit,
) { ... }

sub torrents_set_share_limits (
    $self,
    $hashes,
    $ratio_limit,
    $seeding_time_limit,
    $inactive_seeding_time_limit,
) { ... }

sub torrents_rename (
    $self,
    $hash,
    $name,
) { ... }

sub torrents_rename_file (
    $self,
    $hash,
    $old_path,
    $new_path,
) { ... }

sub torrents_set_category (
    $self,
    $hashes,
    $category,
) { ... }

sub torrents_create_category (
    $self,
    $category,
    $save_path,
) { ... }

sub torrents_edit_category (
    $self,
    $category,
    $save_path,
) { ... }

sub torrents_remove_categories (
    $self,
    $categories,
) { ... }

sub torrents_add_tags (
    $self,
    $hashes,
    $tags,
) { ... }

sub torrents_remove_tags (
    $self,
    $hashes,
    $tags,
) { ... }

sub torrents_create_tags (
    $self,
    $tags,
) { ... }

sub torrents_delete_tags (
    $self,
    $tags,
) { ... }

sub torrents_set_auto_management (
    $self,
    $hashes,
    $enable,
) { ... }

sub torrents_toggle_sequential_download (
    $self,
    $hashes,
) { ... }

sub torrents_toggle_first_last_piece_priority (
    $self,
    $hashes,
) { ... }

sub torrents_set_force_start (
    $self,
    $hashes,
    $value,
) { ... }

sub torrents_set_super_seeding (
    $self,
    $hashes,
    $value,
) { ... }

1;
