use v5.40;
use common::sense;
use feature qw( signatures );

use Test::More;

use QBTL::QBT::API;

my $default_api = QBTL::QBT::API->new;

{    # package Local::FakeLWP

  package Local::FakeLWP;

  use v5.40;
  use common::sense;
  use feature qw( signatures );

  sub new ( $class ) {
    return bless {urls => [], posts => []}, $class;
  }

  sub get ( $self, $uri ) {
    push @{$self->{urls}}, "$uri";

    return
        Local::FakeResponse->new( code => 200,
                                  body => 'v5.0.0', );
  }

  sub post ( $self, $url, $params ) {
    push @{$self->{posts}},
        {
         url    => $url,
         params => $params,};

    return
        Local::FakeResponse->new( code => 200,
                                  body => 'Ok.', );
  }

  sub posts ( $self ) {
    return $self->{posts};
  }

  sub urls ( $self ) {
    return $self->{urls};
  }
}

{    # package Local::FakeResponse;

  package Local::FakeResponse;

  use v5.40;
  use common::sense;
  use feature qw( signatures );

  sub new ( $class, %arg ) {
    return bless \%arg, $class;
  }

  sub is_success ( $self ) {
    return 1;
  }

  sub status_line ( $self ) {
    return '200 OK';
  }

  sub code ( $self ) {
    return $self->{code};
  }

  sub decoded_content ( $self ) {
    return $self->{body};
  }
}

isa_ok( $default_api, 'QBTL::QBT::API' );
is( $default_api->base_url, 'http://localhost:8080', 'default base URL' );

is(
    $default_api->api_url( 'app/version' ),
    'http://localhost:8080/api/v2/app/version',
    'api_url builds expected URL' );

is(
    $default_api->api_url( '/app/version' ),
    'http://localhost:8080/api/v2/app/version',
    'api_url handles leading slash' );

my $custom_api = QBTL::QBT::API->new( base_url => 'http://127.0.0.1:9090/', );

is( $custom_api->base_url, 'http://127.0.0.1:9090',
    'trailing slash removed from base URL' );

is( $custom_api->endpoint( 'app_version' ),
    'http://127.0.0.1:9090/api/v2/app/version',
    'app_version endpoint' );

is( $custom_api->endpoint( 'torrents_info' ),
    'http://127.0.0.1:9090/api/v2/torrents/info',
    'torrents_info endpoint' );

eval { $custom_api->endpoint( 'bogus' ) };

like( $@, qr/Unknown qBT endpoint: bogus/, 'unknown endpoint dies clearly' );

my $spec = $default_api->endpoint_spec( 'torrents_recheck' );

is_deeply(
           $spec,
           {
            method => 'POST',
            path   => 'torrents/recheck',
           },
           'endpoint_spec returns method and path' );

my $request = $default_api->request( 'app_version' );

is( $request->{endpoint}, 'app_version', 'request endpoint stored' );
is( $request->{method},   'GET',         'app_version uses GET' );
is( $request->{url},
    'http://localhost:8080/api/v2/app/version',
    'request URL stored' );
is_deeply( $request->{params}, {}, 'default request params empty' );

$request =
    $default_api->request( 'torrents_files', params => {hash => 'abc123',}, );

is( $request->{method}, 'GET', 'torrents_files uses GET' );
is_deeply( $request->{params}, {hash => 'abc123',}, 'request params stored' );

$request = $default_api->request( 'torrents_recheck',
                                  params => {hashes => 'abc123',}, );

is( $request->{method}, 'POST', 'torrents_recheck uses POST' );

my $version_request = $default_api->app_version;

is( $version_request->{endpoint}, 'app_version', 'app_version endpoint' );
is( $version_request->{method},   'GET',         'app_version method' );

my $info_request =
    $default_api->torrents_info( filter => 'all',
                                 sort   => 'name', );

is( $info_request->{endpoint}, 'torrents_info', 'torrents_info endpoint' );
is_deeply(
           $info_request->{params},
           {
            filter => 'all',
            sort   => 'name',
           },
           'torrents_info params' );

my $files_request = $default_api->torrents_files( 'abc123' );

is( $files_request->{endpoint}, 'torrents_files', 'torrents_files endpoint' );
is_deeply(
           $files_request->{params},
           {hash => 'abc123',},
           'torrents_files params' );

my $recheck_request = $default_api->torrents_recheck( 'abc123' );

is( $recheck_request->{endpoint},
    'torrents_recheck', 'torrents_recheck endpoint' );
is( $recheck_request->{method}, 'POST', 'torrents_recheck method' );
is_deeply(
           $recheck_request->{params},
           {hashes => 'abc123',},
           'torrents_recheck params' );

my $login_request = $default_api->login( 'admin', 'secret' );

is( $login_request->{endpoint}, 'login', 'login endpoint' );
is( $login_request->{method},   'POST',  'login method' );
is_deeply(
           $login_request->{params},
           {
            username => 'admin',
            password => 'secret',
           },
           'login params' );

my $add_request =
    $default_api->torrents_add( urls => 'https://example.invalid/test.torrent',
                                savepath => '/tmp/downloads', );

is( $add_request->{endpoint}, 'torrents_add', 'torrents_add endpoint' );
is( $add_request->{method},   'POST',         'torrents_add method' );
is_deeply(
           $add_request->{params},
           {
            urls     => 'https://example.invalid/test.torrent',
            savepath => '/tmp/downloads',
           },
           'torrents_add params' );

my $pause_request = $default_api->torrents_pause( 'abc123' );

is( $pause_request->{endpoint}, 'torrents_pause', 'torrents_pause endpoint' );
is( $pause_request->{method},   'POST',           'torrents_pause method' );
is_deeply(
           $pause_request->{params},
           {hashes => 'abc123',},
           'torrents_pause params' );

my $resume_request = $default_api->torrents_resume( 'abc123' );

is( $resume_request->{endpoint}, 'torrents_resume',
    'torrents_resume endpoint' );
is( $resume_request->{method}, 'POST', 'torrents_resume method' );
is_deeply(
           $resume_request->{params},
           {hashes => 'abc123',},
           'torrents_resume params' );

my $set_location_request =
    $default_api->torrents_set_location( 'abc123', '/Volumes/Downloads', );

is( $set_location_request->{endpoint},
    'torrents_set_location', 'torrents_set_location endpoint' );
is( $set_location_request->{method}, 'POST', 'torrents_set_location method' );
is_deeply(
           $set_location_request->{params},
           {
            hashes   => 'abc123',
            location => '/Volumes/Downloads',
           },
           'torrents_set_location params' );

my $set_download_path_request =
    $default_api->torrents_set_download_path( 'abc123',
                                              '/Volumes/Incomplete', );

is( $set_download_path_request->{endpoint},
    'torrents_set_download_path', 'torrents_set_download_path endpoint' );
is( $set_download_path_request->{method},
    'POST', 'torrents_set_download_path method' );
is_deeply(
           $set_download_path_request->{params},
           {
            hashes => 'abc123',
            path   => '/Volumes/Incomplete',
           },
           'torrents_set_download_path params' );

my $rename_folder_request =
    $default_api->torrents_rename_folder(
                                          'abc123',
                                          'Old Folder',
                                          'New Folder', );

is( $rename_folder_request->{endpoint},
    'torrents_rename_folder', 'torrents_rename_folder endpoint' );
is( $rename_folder_request->{method}, 'POST', 'torrents_rename_folder method' );
is_deeply(
           $rename_folder_request->{params},
           {
            hash    => 'abc123',
            oldPath => 'Old Folder',
            newPath => 'New Folder',
           },
           'torrents_rename_folder params' );

my $fake_lwp = Local::FakeLWP->new;

my $realish_api = QBTL::QBT::API->new( base_url => 'http://127.0.0.1:9090',
                                       ua       => $fake_lwp, );

my $get_result = $realish_api->execute_request( $realish_api->app_version );

is( $get_result->{ok},   1,        'execute GET succeeds with LWP-style ua' );
is( $get_result->{code}, 200,      'execute GET returns response code' );
is( $get_result->{body}, 'v5.0.0', 'execute GET returns response body' );
is( $fake_lwp->urls->[0],
    'http://127.0.0.1:9090/api/v2/app/version',
    'execute GET calls expected URL' );

$fake_lwp = Local::FakeLWP->new;

$realish_api = QBTL::QBT::API->new( base_url => 'http://127.0.0.1:9090',
                                    ua       => $fake_lwp, );

$get_result = $realish_api->execute_request(
         $realish_api->torrents_info( filter => 'all', category => 'movies' ) );

is( $get_result->{ok}, 1, 'execute GET with params succeeds' );
like( $fake_lwp->urls->[0],
      qr{\Ahttp://127\.0\.0\.1:9090/api/v2/torrents/info\?},
      'execute GET with params adds query string' );
like( $fake_lwp->urls->[0],
      qr/filter=all/, 'execute GET URL includes filter param' );
like(
  $fake_lwp->urls->[0], qr/category=movies/, 'execute GET URL includes category
param' );

my $fake_post_lwp = Local::FakeLWP->new;

my $post_api = QBTL::QBT::API->new( base_url => 'http://127.0.0.1:9090',
                                    ua       => $fake_post_lwp, );

my $post_result =
    $post_api->execute_request( $post_api->login( 'admin', 'adminadmin' ) );

is( $post_result->{ok},   1,     'execute POST succeeds with LWP-style ua' );
is( $post_result->{code}, 200,   'execute POST returns response code' );
is( $post_result->{body}, 'Ok.', 'execute POST returns response body' );

is(
    $fake_post_lwp->posts->[0]{url},
    'http://127.0.0.1:9090/api/v2/auth/login',
    'execute POST calls expected URL' );

is( $fake_post_lwp->posts->[0]{params}{username},
    'admin', 'execute POST sends username param' );

is( $fake_post_lwp->posts->[0]{params}{password},
    'adminadmin', 'execute POST sends password param' );

done_testing;
