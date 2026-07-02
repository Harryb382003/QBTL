package QBTL::Process::QBT;

use v5.40;
use common::sense;
use feature qw( signatures );

use JSON::PP       qw( decode_json encode_json );
use File::Basename qw( dirname basename );
use File::Spec;

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
  my @rows     = ();
  my @problems = ();

  for my $key ( sort keys %{$preferences} ) {
    $seen++;

    my ( $value, $value_type ) =
        $self->_preference_value( $preferences->{$key}, );

    push @rows,
        {
         key        => $key,
         value      => $value,
         value_type => $value_type,};

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
          rows     => \@rows,
          problems => \@problems,};
}

sub refresh_info_rows ( $self, %arg ) {
  my $db               = $arg{db}               // die 'db is required';
  my $dbh              = $arg{dbh}              // die 'dbh is required';
  my $rows             = $arg{rows}             // die 'rows is required';
  my $fetch_properties = $arg{fetch_properties} // 0;

  my $store = $self->store_info_rows(
                                      dbh  => $dbh,
                                      db   => $db,
                                      rows => $rows, );

  my $api_values =
      $self->store_api_values_for_info_rows(
                                          dbh              => $dbh,
                                          db               => $db,
                                          rows             => $rows,
                                          fetch_properties => $fetch_properties,
      );

  my @problems =
      ( @{$store->{problems} // []}, @{$api_values->{problems} // []}, );

  return {
          ok                  => @problems ? 0 : 1,
          action              => 'qbt_refresh',
          seen                => $store->{seen},
          stored              => $store->{stored},
          new                 => $store->{new},
          existing            => $store->{existing},
          removed             => $store->{removed},
          qbt_api_info_keys   => $api_values->{info_keys_stored},
          qbt_properties_seen => $api_values->{properties_seen},
          qbt_properties_keys => $api_values->{properties_keys_stored},
          problems            => \@problems,};
}

sub store_api_values_for_info_rows ( $self, %arg ) {
  my $db               = $arg{db}               // die 'db is required';
  my $dbh              = $arg{dbh}              // die 'dbh is required';
  my $rows             = $arg{rows}             // die 'rows is required';
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
                                   data     => $properties->{properties} // {},
      );
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
          ok                     => @problems ? 0 : 1,
          info_keys_stored       => $info_keys_stored,
          properties_seen        => $properties_seen,
          properties_keys_stored => $properties_keys_stored,
          problems               => \@problems,};
}

sub with_qbt_log_context ( $self, %arg ) {
  my $caller = $arg{caller} // die 'caller is required';
  my $code   = $arg{code}   // die 'code is required';

  die 'code must be a coderef' if ref $code ne 'CODE';

  my $snapshot_params = $arg{snapshot_params} // {};
  my $fetch_params    = $arg{fetch_params}    // {};

  my $snapshot = $self->log_main( %{$snapshot_params} );
  my $last_id  = $self->_last_log_id( $snapshot );

  my $action_result = eval { $code->() };
  my $action_error  = $@;

  my %log_params = (
                     normal   => 1,
                     info     => 1,
                     warning  => 1,
                     critical => 1,
                     %{$fetch_params}, );

  $log_params{last_known_id} = $last_id if defined $last_id;

  my $log_response = $self->log_main( %log_params );
  my $log_entries  = $self->_decode_log_entries( $log_response->{result} );

  my $action_ok =
         !$action_error
      && ref( $action_result ) eq 'HASH'
      && ( $action_result->{ok} // 0 ) ? 1 : 0;

  return {
          ok            => $action_ok,
          action        => 'qbt_log_context',
          caller        => $caller,
          snapshot      => $snapshot,
          last_known_id => $last_id,
          action_result => $action_result,
          action_error  => $action_error || undef,
          log_response  => $log_response,
          log_entries   => $log_entries,
          log_count     => scalar @{$log_entries},};
}

sub add ( $self, %arg ) {
  my $db     = $arg{db}    // die 'db is required';
  my $dbh    = $arg{dbh}   // die 'dbh is required';
  my $input  = $arg{input} // die 'add input is required';
  my $search = $arg{search_tool} // $self->{search_tool} // 'mdfind';

  my $target =
      $self->_resolve_add_target(
                                  dbh   => $dbh,
                                  db    => $db,
                                  input => $input, );

  return $target if !$target->{ok};

  my $hash    = $target->{hash};
  my $torrent = $target->{torrent};
  my $qbt_row = $db->qbt_info_by_hash( $dbh, $hash );

  if (    $qbt_row
       && ( $qbt_row->{current_qbt} // 0 )
       && defined $qbt_row->{total_size}
       && $qbt_row->{total_size} != -1 )
  {
    return {
            ok      => 1,
            action  => 'qbt_add',
            status  => 'already_loaded_running',
            message => 'Torrent already loaded and running',
            hash    => $hash,
            target  => $target,};
  }

  my $loaded_broken =
         $qbt_row
      && ( $qbt_row->{current_qbt} // 0 )
      && defined $qbt_row->{total_size}
      && $qbt_row->{total_size} == -1 ? 1 : 0;

  my $search_result =
      $self->_search_payload_root( torrent     => $torrent,
                                   search_tool => $search, );

  my %add_param;
  my $used_path;

  if ( $loaded_broken ) {
    if ( $search_result->{suggested_savepath} ) {
      $used_path = $search_result->{suggested_savepath};
      $add_param{savepath} = $used_path;
    } elsif ( defined $qbt_row->{save_path} && $qbt_row->{save_path} ne '' ) {
      $used_path = $qbt_row->{save_path};
      $add_param{savepath} = $used_path;
    }
  } else {
    if ( $search_result->{suggested_savepath} ) {
      $used_path = $search_result->{suggested_savepath};
      $add_param{savepath} = $used_path;
    }
  }

  my $add_context = $self->with_qbt_log_context(
    caller => 'ADD',
    code   => sub {
      my $request =
          $self->{api}->torrents_add_file( $torrent->{path}, %add_param, );
      my $result = $self->{api}->execute_request( $request );
      return {
              ok      => $result->{ok} ? 1 : 0,
              action  => 'qbt_add_file',
              request => $request,
              result  => $result,};
    }, );

  my $interpret = $self->_interpret_add_context( $add_context );

  my $info = $self->info( hashes => $hash );
  my $refresh =
      $info->{ok}
      ? $self->refresh_info_rows(
                                  dbh              => $dbh,
                                  db               => $db,
                                  rows             => $info->{rows} // [],
                                  fetch_properties => 1, )
      : {
         ok       => 0,
         action   => 'qbt_refresh',
         problems => [
                  {
                   hash  => $hash,
                   error => 'qBittorrent torrents/info request failed after add'
                  }
         ],};

  if ( $interpret->{ok} ) {
    $db->update_qbt_last( $dbh, hash => $hash, caller => 'ADD' );
  } else {
    $db->update_qbt_last(
                          $dbh,
                          hash   => $hash,
                          caller => 'ADD',
                          error  => $interpret->{error} // 'qBT add failed', );
  }

  return {
          ok            => $interpret->{ok} ? 1 : 0,
          action        => 'qbt_add',
          status        => $interpret->{status},
          hash          => $hash,
          input         => $input,
          input_type    => $target->{input_type},
          torrent_path  => $torrent->{path},
          qbt_loaded    => $qbt_row ? 1 : 0,
          qbt_broken    => $loaded_broken,
          search        => $search_result,
          used_savepath => $used_path,
          add_context   => $add_context,
          add_result    => $interpret,
          refresh       => $refresh,};
}

sub _resolve_add_target ( $self, %arg ) {
  my $db    = $arg{db}    // die 'db is required';
  my $dbh   = $arg{dbh}   // die 'dbh is required';
  my $input = $arg{input} // '';

  if ( $input =~ /\A[0-9a-fA-F]{40}\z/ ) {
    my $hash = $input;
    my $row  = $db->best_local_torrent_file_for_hash( $dbh, $hash );

    return {
            ok       => 0,
            action   => 'qbt_add',
            status   => 'no_torrent_file_for_hash',
            hash     => $hash,
            problems => [
                        {
                         hash  => $hash,
                         error => 'No parsed local .torrent file found for hash'
                        }
            ],}
        if !$row;

    return {
            ok         => 1,
            action     => 'qbt_add_resolve',
            input_type => 'hash',
            hash       => $hash,
            torrent    => $row,};
  }

  my $path = File::Spec->rel2abs( $input );

  return {
          ok       => 0,
          action   => 'qbt_add',
          status   => 'torrent_file_not_readable',
          problems => [ {error => "Torrent file is not readable: $input"} ],}
      if !-f $path || !-r $path;

  my $row = $db->local_torrent_file_by_path( $dbh, $path );

  return {
    ok       => 0,
    action   => 'qbt_add',
    status   => 'torrent_file_not_scanned',
    problems => [
      {
       error =>
           'Torrent file is not in the local scan DB; run qbtl local scan first'
      }
    ],}
      if !$row;

  return {
       ok       => 0,
       action   => 'qbt_add',
       status   => 'torrent_file_not_parsed',
       problems => [
         {
          path  => $path,
          error => $row->{parse_problem} // 'Torrent file did not parse cleanly'
         }
       ],}
      if !( $row->{parse_ok} // 0 )
      || !defined $row->{infohash}
      || $row->{infohash} eq '';

  return {
          ok         => 1,
          action     => 'qbt_add_resolve',
          input_type => 'path',
          hash       => $row->{infohash},
          torrent    => $row,};
}

sub _search_payload_root ( $self, %arg ) {
  my $torrent = $arg{torrent}     // {};
  my $tool    = $arg{search_tool} // 'mdfind';
  my @target  = _payload_search_targets( $torrent );

  return {
          ok                 => 1,
          searched           => 0,
          search_tool        => $tool,
          query              => undef,
          found_path         => undef,
          suggested_savepath => undef,
          problems           => [],}
      if !@target;

  if ( $tool eq 'mdfind' ) {
    my $mdfind = _command_path( 'mdfind' );

    return {
            ok                 => 0,
            searched           => 0,
            search_tool        => $tool,
            query              => join( ', ', map { $_->{name} } @target ),
            found_path         => undef,
            suggested_savepath => undef,
            problems           => ['mdfind not available'],}
        if !$mdfind;

    my @candidate;
    my @problem;

    for my $target ( @target ) {
      my $name = $target->{name};
      next if !defined $name || $name eq '';

      my @cmd = ( $mdfind, '-name', $name );

      open my $fh, '-|', @cmd
          or do {
        push @problem, "mdfind failed for $name: $!";
        next;
          };

      while ( my $found = <$fh> ) {
        chomp $found;
        next if $found eq '';
        next if !_usable_payload_candidate( $found );

        my $absolute = File::Spec->rel2abs( $found );
        push @candidate,
            {
             path               => $absolute,
             matched_name       => $name,
             match_kind         => $target->{kind},
             suggested_savepath =>
                 _suggested_savepath_for_payload_match(
                                                   $absolute, $target, $torrent,
                 ),};
      }

      close $fh;
    }

    @candidate = sort {
      ( _payload_match_rank( $a->{match_kind} )
        <=> _payload_match_rank( $b->{match_kind} ) )
          || ( $a->{path} cmp $b->{path} )
    } @candidate;

    my $best = $candidate[0];

    return {
            ok                 => @problem ? 0 : 1,
            searched           => 1,
            search_tool        => $tool,
            query              => join( ', ', map { $_->{name} } @target ),
            found_path         => $best ? $best->{path}               : undef,
            suggested_savepath => $best ? $best->{suggested_savepath} : undef,
            match_kind         => $best ? $best->{match_kind}         : undef,
            candidates         => [ map { $_->{path} } @candidate ],
            problems           => \@problem,};
  }

  return {
          ok                 => 0,
          searched           => 0,
          search_tool        => $tool,
          query              => join( ', ', map { $_->{name} } @target ),
          found_path         => undef,
          suggested_savepath => undef,
          problems           => ["unsupported payload search tool: $tool"],};
}

sub _payload_search_targets ( $torrent ) {
  my @target;
  my %seen;

  for my $pair (
                 [ payload_root_name => $torrent->{payload_root_name} ],
                 [ probe             => $torrent->{payload_probe_name} ],
                 [ payload_root_name => $torrent->{torrent_name} ], )
  {
    my ( $kind, $name ) = @{$pair};
    next if !defined $name || $name eq '';
    next if _is_metadata_evidence_path( $name );
    next if $seen{"$kind\0$name"}++;

    push @target,
        {
         kind => $kind,
         name => $name,};
  }

  return @target;
}

sub _payload_match_rank ( $kind ) {
  return 0 if defined $kind && $kind eq 'root';
  return 1 if defined $kind && $kind eq 'probe';
  return 9;
}

sub _usable_payload_candidate ( $path ) {
  return 0 if !defined $path || $path eq '';
  return 0 if !-e $path;
  return 0 if _is_metadata_evidence_path( $path );
  return 1;
}

sub _is_metadata_evidence_path ( $path ) {
  return 0 if !defined $path;
  return $path =~ /\.(?:torrent|fastresume)\z/i ? 1 : 0;
}

sub _suggested_savepath_for_payload_match ( $found_path, $target, $torrent ) {
  return undef if !defined $found_path || $found_path eq '';

  if ( ( $target->{kind} // '' ) eq 'root' ) {
    return dirname( $found_path );
  }

  my $root =
      _infer_payload_root_from_probe( $found_path,
                                      $torrent->{payload_probe_path} );
  return dirname( $root ) if defined $root && $root ne '';

  return dirname( $found_path );
}

sub _infer_payload_root_from_probe ( $found_path, $probe_path ) {
  return undef if !defined $found_path || $found_path eq '';
  return undef if !defined $probe_path || $probe_path eq '';

  my @part =
      grep { defined $_ && $_ ne '' } File::Spec->splitdir( $probe_path );
  return undef if !@part;

  my $root = $found_path;
  for ( 1 .. scalar @part ) {
    $root = dirname( $root );
  }

  return $root;
}

sub _command_path ( $command ) {
  for my $dir ( File::Spec->path ) {
    next if !defined $dir || $dir eq '';
    my $path = File::Spec->catfile( $dir, $command );
    return $path if -x $path && !-d $path;
  }

  return;
}

sub _interpret_add_context ( $self, $context ) {
  my $action = $context->{action_result} // {};
  my $result = $action->{result}         // {};
  my $body   = $result->{body}           // '';

  for my $entry ( @{$context->{log_entries} // []} ) {
    my $message = $entry->{message} // '';

    if ( $message =~ /duplicate torrent/i ) {
      return {
              ok     => 1,
              status => 'ok',
              detail => 'duplicate torrent parsed as ok'};
    }
  }

  return {ok => 1, status => 'ok'}
      if ( $action->{ok} // 0 ) && $body !~ /fail/i;

  my @message = grep { defined $_ && $_ ne '' }
      map { $_->{message} } @{$context->{log_entries} // []};

  push @message, $body                    if $body ne '';
  push @message, $result->{status}        if defined $result->{status};
  push @message, $context->{action_error} if defined $context->{action_error};

  return {
          ok     => 0,
          status => 'error',
          error  => join( '; ', @message ) || 'qBT add failed',};
}

sub status ( $self, %arg ) {
  my $db  = $arg{db}  // die 'db is required';
  my $dbh = $arg{dbh} // die 'dbh is required';

  my $status = $db->qbt_status( $dbh );

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

sub _decode_log_entries ( $self, $result ) {
  return [] if !$result || !$result->{ok};

  my $body = $result->{body} // '';

  return [] if !length $body;

  my $rows = eval { decode_json( $body ) };

  if ( $@ || ref( $rows ) ne 'ARRAY' ) {
    return [];
  }

  return $rows;
}

sub _last_log_id ( $self, $log_response ) {
  my $entries = $self->_decode_log_entries( $log_response->{result} );
  my $last_id;

  for my $entry ( @{$entries} ) {
    next if ref( $entry ) ne 'HASH';
    next if !defined $entry->{id};

    $last_id = $entry->{id}
        if !defined $last_id || $entry->{id} > $last_id;
  }

  return $last_id;
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
