package QBTL::Process::QBT;

use v5.40;
use common::sense;
use feature qw( signatures );

use JSON::PP qw( decode_json encode_json );

use QBTL::QBT::API;

sub new ( $class, %arg ) {
  $arg{api} //= QBTL::QBT::API->new;
  return bless \%arg, $class;
}

sub api ( $self ) {
  return $self->{api};
}

sub _decode_preferences ( $self, $result ) {
  return {} if !$result->{ok};

  my $body = $result->{body} // '';

  return {} if !length $body;

  my $preferences = eval { decode_json( $body ) };

  if ( $@ || ref( $preferences ) ne 'HASH' ) {
    return {};
  }

  return $preferences;
}

sub _decode_object ( $self, $result ) {
  return {} if !$result->{ok};

  my $body = $result->{body} // '';

  return {} if !length $body;

  my $object = eval { decode_json( $body ) };

  if ( $@ || ref( $object ) ne 'HASH' ) {
    return {};
  }

  return $object;
}

sub fake_info_rows ( $self ) {
  return [
           {
            hash          => 'abc123',
            name          => 'Fake qBT Torrent One',
            state         => 'pausedUP',
            progress      => 1,
            save_path     => '/Downloads',
            content_path  => '/Downloads/Fake qBT Torrent One',
            category      => 'test',
            tags          => 'fake,offline',
            amount_left   => 0,
            total_size    => 1000,
            added_on      => 1700000000,
            completion_on => 1700000100,
            last_activity => 1700000200,
            tracker       => 'https://tracker.example.invalid/announce',
            ratio         => 1.0,
           },
           {
            hash          => 'def456',
            name          => 'Fake qBT Torrent Two',
            state         => 'downloading',
            progress      => 0.5,
            save_path     => '/Downloads',
            content_path  => '/Downloads/Fake qBT Torrent Two',
            category      => 'test',
            tags          => 'fake,offline',
            amount_left   => 500,
            total_size    => 2000,
            added_on      => 1700000300,
            completion_on => 0,
            last_activity => 1700000400,
            tracker       => 'https://tracker.example.invalid/announce',
            ratio         => 0.25,
           }, ];
}

sub info ( $self, %params ) {
  my $request = $self->{api}->torrents_info( %params );
  my $result  = $self->{api}->execute_request( $request );

  if ( !$result->{ok} && ( $result->{code} // 0 ) =~ /\A(?:401|403)\z/ ) {
    my $login = $self->login;

    if ( !$login->{ok} ) {
      return {
              ok      => 0,
              action  => 'qbt_torrents_info',
              request => $request,
              result  => $result,
              login   => $login,};
    }

    $result = $self->{api}->execute_request( $request );

    my $rows = $self->_decode_info_rows( $result );

    return {
            ok      => $result->{ok} ? 1 : 0,
            action  => 'qbt_torrents_info',
            request => $request,
            result  => $result,
            rows    => $rows,
            count   => scalar @{$rows},
            login   => $login,
            retried => 1,};
  }

  my $rows = $self->_decode_info_rows( $result );

  return {
          ok      => $result->{ok} ? 1 : 0,
          action  => 'qbt_torrents_info',
          request => $request,
          result  => $result,
          rows    => $rows,
          count   => scalar @{$rows},};
}

sub properties ( $self, $hash ) {
  my $request = $self->{api}->torrents_properties( $hash );
  my $result  = $self->{api}->execute_request( $request );

  if ( !$result->{ok} && ( $result->{code} // 0 ) =~ /\A(?:401|403)\z/ ) {
    my $login = $self->login;

    if ( !$login->{ok} ) {
      return {
              ok      => 0,
              action  => 'qbt_torrents_properties',
              request => $request,
              result  => $result,
              login   => $login,};
    }

    $result = $self->{api}->execute_request( $request );

    my $properties = $self->_decode_object( $result );

    return {
            ok         => $result->{ok} ? 1 : 0,
            action     => 'qbt_torrents_properties',
            request    => $request,
            result     => $result,
            properties => $properties,
            count      => scalar keys %{$properties},
            login      => $login,
            retried    => 1,};
  }

  my $properties = $self->_decode_object( $result );

  return {
          ok         => $result->{ok} ? 1 : 0,
          action     => 'qbt_torrents_properties',
          request    => $request,
          result     => $result,
          properties => $properties,
          count      => scalar keys %{$properties},};
}

sub log_main ( $self, %params ) {
  my $request = $self->{api}->log_main( %params );
  my $result  = $self->{api}->execute_request( $request );

  if ( !$result->{ok} && ( $result->{code} // 0 ) =~ /\A(?:401|403)\z/ ) {
    my $login = $self->login;

    if ( !$login->{ok} ) {
      return {
              ok      => 0,
              action  => 'qbt_log_main',
              request => $request,
              result  => $result,
              login   => $login,};
    }

    $result = $self->{api}->execute_request( $request );

    return {
            ok      => $result->{ok} ? 1 : 0,
            action  => 'qbt_log_main',
            request => $request,
            result  => $result,
            login   => $login,
            retried => 1,};
  }

  return {
          ok      => $result->{ok} ? 1 : 0,
          action  => 'qbt_log_main',
          request => $request,
          result  => $result,};
}

sub login ( $self, %arg ) {
  my $username = $arg{username} // 'admin';
  my $password = $arg{password} // 'adminadmin';

  my $request = $self->{api}->login( $username, $password );
  my $result  = $self->{api}->execute_request( $request );

  return {
          ok      => $result->{ok} ? 1 : 0,
          action  => 'qbt_login',
          request => $request,
          result  => $result,};
}

sub preferences ( $self ) {
  my $request = $self->{api}->app_preferences;
  my $result  = $self->{api}->execute_request( $request );
  my $login;
  my $retried = 0;

  if ( !$result->{ok} && ( $result->{code} // 0 ) =~ /\A(?:401|403)\z/ ) {
    $login = $self->login;

    if ( !$login->{ok} ) {
      return {
              ok      => 0,
              action  => 'qbt_preferences',
              request => $request,
              result  => $result,
              login   => $login,};
    }

    $result  = $self->{api}->execute_request( $request );
    $retried = 1;
  }

  my $preferences = $self->_decode_preferences( $result );

  my $response = {
                  ok          => $result->{ok} ? 1 : 0,
                  action      => 'qbt_preferences',
                  request     => $request,
                  result      => $result,
                  preferences => $preferences,
                  count       => scalar keys %{$preferences},};

  if ( $login ) {
    $response->{login} = $login;
  }

  if ( $retried ) {
    $response->{retried} = 1;
  }

  return $response;
}

sub refresh_preferences ( $self, %arg ) {
  my $db          = $arg{db}          // die 'db is required';
  my $dbh         = $arg{dbh}         // die 'dbh is required';
  my $preferences = $arg{preferences} // die 'preferences is required';

  my $seen     = 0;
  my $stored   = 0;
  my @problems = ();

  for my $key ( sort keys %{$preferences} ) {
    $seen++;

    my ( $value, $value_type ) =
        $self->_preference_value( $preferences->{$key}, );

    my $result = eval {
      $db->upsert_qbt_preference(
                                  $dbh,
                                  {
                                   key        => $key,
                                   value      => $value,
                                   value_type => $value_type,
                                  } );
    };

    if ( !$result || !$result->{ok} ) {
      push @problems,
          {
           key   => $key,
           error => $@ || 'qbt_preferences upsert failed',};
      next;
    }

    $stored++;
  }

  return {
          ok       => @problems ? 0 : 1,
          action   => 'qbt_preferences_refresh',
          seen     => $seen,
          stored   => $stored,
          problems => \@problems,};
}

sub refresh_info_rows ( $self, %arg ) {
  my $db               = $arg{db}   // die 'db is required';
  my $dbh              = $arg{dbh}  // die 'dbh is required';
  my $rows             = $arg{rows} // die 'rows is required';
  my $fetch_properties = $arg{fetch_properties} // 0;

  my $store = $self->store_info_rows(
                                      dbh  => $dbh,
                                      db   => $db,
                                      rows => $rows, );

  my $api_values = $self->store_api_values_for_info_rows(
                                      dbh              => $dbh,
                                      db               => $db,
                                      rows             => $rows,
                                      fetch_properties => $fetch_properties, );

  my @problems = ( @{$store->{problems} // []},
                   @{$api_values->{problems} // []}, );

  return {
          ok                       => @problems ? 0 : 1,
          action                   => 'qbt_refresh',
          seen                     => $store->{seen},
          stored                   => $store->{stored},
          new                      => $store->{new},
          existing                 => $store->{existing},
          removed                  => $store->{removed},
          qbt_api_info_keys        => $api_values->{info_keys_stored},
          qbt_properties_seen      => $api_values->{properties_seen},
          qbt_properties_keys      => $api_values->{properties_keys_stored},
          problems                 => \@problems,};
}

sub store_api_values_for_info_rows ( $self, %arg ) {
  my $db               = $arg{db}   // die 'db is required';
  my $dbh              = $arg{dbh}  // die 'dbh is required';
  my $rows             = $arg{rows} // die 'rows is required';
  my $fetch_properties = $arg{fetch_properties} // 0;

  my $info_keys_stored       = 0;
  my $properties_seen        = 0;
  my $properties_keys_stored = 0;
  my @problems               = ();

  for my $row ( @{$rows} ) {
    my $hash = $row->{hash};

    if ( !defined $hash || $hash eq '' ) {
      push @problems,
          {
           hash  => undef,
           error => 'qBT API value row requires hash',};
      next;
    }

    my $info_store = eval {
      $db->replace_qbt_api_values(
                                   $dbh,
                                   hash     => $hash,
                                   endpoint => 'torrents_info',
                                   data     => $row, );
    };

    if ( !$info_store || !$info_store->{ok} ) {
      push @problems,
          {
           hash  => $hash,
           error => $@ || 'qbt_api_values torrents_info store failed',};
      next;
    }

    $info_keys_stored += $info_store->{stored} // 0;

    next if !$fetch_properties;

    my $properties = $self->properties( $hash );

    if ( !$properties->{ok} ) {
      push @problems,
          {
           hash  => $hash,
           error => 'qBittorrent torrents/properties request failed',};
      next;
    }

    $properties_seen++;

    my $properties_store = eval {
      $db->replace_qbt_api_values(
                                 $dbh,
                                 hash     => $hash,
                                 endpoint => 'torrents_properties',
                                 data     => $properties->{properties} // {}, );
    };

    if ( !$properties_store || !$properties_store->{ok} ) {
      push @problems,
          {
           hash  => $hash,
           error => $@ || 'qbt_api_values torrents_properties store failed',};
      next;
    }

    $properties_keys_stored += $properties_store->{stored} // 0;
  }

  return {
          ok                       => @problems ? 0 : 1,
          info_keys_stored         => $info_keys_stored,
          properties_seen          => $properties_seen,
          properties_keys_stored   => $properties_keys_stored,
          problems                 => \@problems,};
}

sub status ( $self, %arg ) {
  my $db  = $arg{db}  // die 'db is required';
  my $dbh = $arg{dbh} // die 'dbh is required';

  my $status = $db->qbt_status($dbh);

  return {
          ok         => $status->{ok},
          action     => 'qbt_status',
          summary    => $status->{summary},
          states     => $status->{states},
          categories => $status->{categories},};
}

sub store_info_rows ( $self, %arg ) {
  my $db   = $arg{db}   // die 'db is required';
  my $dbh  = $arg{dbh}  // die 'dbh is required';
  my $rows = $arg{rows} // die 'rows is required';

  my $seen     = 0;
  my $stored   = 0;
  my $new      = 0;
  my $existing = 0;
  my @problems = ();

  for my $row ( @{$rows} ) {
    $seen++;

    my $result = eval { $db->upsert_qbt_info( $dbh, $row ); };
    my $exists = $db->qbt_info_exists( $dbh, $row->{hash} );

    if ( $exists ) {
      $existing++;
    } else {
      $new++;
    }

    if ( !$result || !$result->{ok} ) {
      push @problems,
          {
           hash  => $row->{hash},
           error => $@ || 'qbt_info upsert failed',};
      next;
    }

    $stored++;
  }
  my $removed = $db->removed_qbt_count( $dbh );
  return {
          ok       => @problems ? 0 : 1,
          seen     => $seen,
          stored   => $stored,
          new      => $new,
          existing => $existing,
          removed  => $removed,
          problems => \@problems,};
}

sub torrents_info_request ( $self, %params ) {
  my $request = $self->api->torrents_info( %params );

  return {
          ok      => 1,
          action  => 'qbt_torrents_info',
          request => $request,};
}

sub version ( $self ) {
  my $request = $self->{api}->app_version;
  my $result  = $self->{api}->execute_request( $request );
  my $login;
  my $retried = 0;

  if ( !$result->{ok} && ( $result->{code} // 0 ) =~ /\A(?:401|403)\z/ ) {
    $login = $self->login;

    if ( !$login->{ok} ) {
      return {
              ok      => 0,
              action  => 'qbt_version',
              request => $request,
              result  => $result,
              login   => $login,};
    }

    $result  = $self->{api}->execute_request( $request );
    $retried = 1;
  }

  my $response = {
                  ok      => $result->{ok} ? 1 : 0,
                  action  => 'qbt_version',
                  request => $request,
                  result  => $result,};

  if ( $login ) {
    $response->{login} = $login;
  }

  if ( $retried ) {
    $response->{retried} = 1;
  }

  return $response;
}

sub _preference_value ( $self, $value ) {
  if ( !defined $value ) {
    return ( undef, 'null' );
  }

  if ( JSON::PP::is_bool( $value ) ) {
    return ( $value ? 1 : 0, 'bool' );
  }

  if ( ref( $value ) ) {
    return ( encode_json( $value ), 'json' );
  }

  if ( $value =~ /\A-?[0-9]+\z/ ) {
    return ( $value, 'integer' );
  }

  if ( $value =~ /\A-?(?:[0-9]+\.[0-9]*|[0-9]*\.[0-9]+)\z/ ) {
    return ( $value, 'number' );
  }

  return ( $value, 'string' );
}

sub _decode_info_rows ( $self, $result ) {
  return [] if !$result->{ok};

  my $body = $result->{body} // '';

  return [] if !length $body;

  my $rows = eval { decode_json( $body ) };

  if ( $@ || ref( $rows ) ne 'ARRAY' ) {
    return [];
  }

  return $rows;
}

1;
