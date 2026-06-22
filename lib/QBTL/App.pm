package QBTL::App;

use v5.40;
use common::sense;
use feature qw( signatures );

use File::Path qw( make_path );

use QBTL;
use QBTL::QBT::API;
use QBTL::Config;
use QBTL::DB;
use QBTL::Help;
use QBTL::Install::Setup;
use QBTL::Process::Local;
use QBTL::Process::Metadata;
use QBTL::Process::Browse;
use QBTL::Process::QBT;
use QBTL::Process::Search;
use QBTL::Render::CLI;

sub new ( $class, %arg ) {
  $arg{config} //= QBTL::Config->new;
  $arg{renderer} //=
      QBTL::Render::CLI->new( time_format => $arg{config}->time_format, );
  return bless \%arg, $class;

}

sub browse ( $self ) {
  $self->{browse} //=
      QBTL::Process::Browse->new( db_path => $self->{config}->db_path, );

  return $self->{browse};
}

sub init ( $self ) {
  my $db      = QBTL::DB->new( db_path => $self->{config}->db_path );
  my $connect = $db->connect;

  return {ok => 0, status => 'db_connect_failed', db_result => $connect}
      if !$connect->{ok};

  my $migration = $db->migrate( $connect->{dbh} );

  $connect->{dbh}->disconnect;

  my $preferences = $self->qbt->preferences;
  my $refresh     = $self->qbt->refresh;

  return {
          ok          => 1,
          migration   => $migration,
          preferences => $preferences,
          qbt_refresh => $refresh,};
}

sub install ( $self ) {
  my $installer    = $self->_installer;
  my $local_search = $installer->_detect_local_search_tool;
  my $bt_backup = $installer->_application->discover_bt_backup(
                                               local_search => $local_search, );

  if ( !$bt_backup->{ok} ) {
    return {
            ok           => 0,
            status       => $bt_backup->{status},
            bt_backup    => $bt_backup,
            local_search => $local_search,
            problems     => $bt_backup->{problems},};
  }
  my $installation =
      $installer->query_installation_paths( local_search => $local_search, );
  my $home        = $installation->{root};
  my $config_path = $installation->{config_path};

  my @dirs = ( $home, "$home/logs", "$home/backups", "$home/tmp", );

  my @created;
  my @existing;

  for my $dir ( @dirs ) {
    if ( -d $dir ) {
      push @existing, $dir;
      next;
    }

    make_path( $dir );
    push @created, $dir;
  }

  $installation->{bt_backup} = $bt_backup;

  my $config_result = $installer->write_installation_config( $installation );
  my $db_result;
  my $db = $self->{db}
      // QBTL::DB->new( db_path => File::Spec->catfile( $home, 'qbtl.db' ) );

  if ( defined $db ) {

    my $connect = $db->connect;

    if ( !$connect->{ok} ) {
      return {
              ok           => 0,
              home         => $home,
              created      => \@created,
              existing     => \@existing,
              db_result    => $connect,
              local_search => $local_search,};
    }

    my $migration = $db->migrate( $connect->{dbh} );

    $connect->{dbh}->disconnect;

    $db_result = {
                  ok            => 1,
                  migration     => $migration,
                  config_path   => $config_path,
                  config_result => $config_result,};
  }

  return {
          ok            => 1,
          config_path   => $config_path,
          config_result => $config_result,
          created       => \@created,
          db_result     => $db_result,
          existing      => \@existing,
          home          => $home,
          local_search  => $local_search,
          bt_backup     => $bt_backup,};
}

sub _installer ( $self ) {
  $self->{installer} //=
      QBTL::Install::Setup->new(
                          home         => $self->{config}->installation_root,
                          user_home    => $self->{config}->home,
                          default_root => $self->{config}->installation_root,
                          repo_root    => $self->{config}->_repo_root,
                          repo_config_path => $self->{config}->repo_config_path,
                          exists $self->{setup_interactive}
                          ? ( interactive => $self->{setup_interactive} )
                          : (), );

  return $self->{installer};
}

sub local ( $self ) {
  $self->{local} //=
      QBTL::Process::Local->new(
                              db_path     => $self->{config}->db_path,
                              search_tool => $self->{config}->local_search_tool,
      );

  return $self->{local};
}

sub metadata ( $self ) {
  $self->{metadata} //=
      QBTL::Process::Metadata->new( db_path => $self->{config}->db_path, );

  return $self->{metadata};
}

sub qbt ( $self ) {
  my $api = QBTL::QBT::API->new(
                               base_url => $self->{config}->qbt_url,
                               $self->{qbt_ua} ? ( ua => $self->{qbt_ua} ) : (),
  );

  return
      QBTL::Process::QBT->new( api     => $api,
                               db_path => $self->{config}->db_path, );
}

sub _qbtl_home ( $self ) {
  my $db_path = $self->{config}->db_path;

  $db_path =~ s{/[^/]+\z}{};

  return $db_path;
}

sub run_cli ( $self, @argv ) {
  my $cmd = shift @argv // 'help';

  if ( $cmd eq 'help' ) {
    return $self->{renderer}->help( QBTL::Help->topic( 'main' ) );
  }

  if ( $cmd eq 'db' ) {
    my $subcmd = shift @argv // 'help';

    if ( $subcmd eq 'keys' ) {
      return $self->{renderer}->metadata_keys( $self->metadata->keys );
    }

    if ( $subcmd eq 'key' ) {
      my $key = shift @argv;

      return
          $self->{renderer}->metadata_key(
                                           $self->metadata->key( key   => $key,
                                                                 limit => 25, )
          );
    }

    return $self->{renderer}->help( QBTL::Help->topic( 'meta' ) );
  }

  if ( $cmd eq 'init' ) {
    return $self->{renderer}->init( $self->init );
  }

  if ( $cmd eq 'local' ) {
    my $subcmd = shift @argv // 'help';

    if ( $subcmd eq 'summary' ) {
      return $self->{renderer}->local_summary( $self->local->summary );
    }

    if ( $subcmd eq 'scan' ) {
      my $path = shift @argv;

      return
          $self->{renderer}->local_scan(
                    $self->local->scan(
                      path      => $path,
                      threshold => $self->{config}->metadata_promoter_threshold,
                    ) );
    }

    return $self->{renderer}->help( QBTL::Help->topic( 'local' ) );
  }

  if ( $cmd eq 'meta' ) {
    my $subcmd = shift @argv // 'help';

    if ( $subcmd eq 'help' ) {
      return $self->{renderer}->help( QBTL::Help->topic( 'meta' ) );
    }

    if ( $subcmd eq 'keys' ) {
      my $scope = shift @argv;

      if ( defined $scope && $scope eq 'all' ) {
        return $self->{renderer}
            ->metadata_keys_all( $self->metadata->keys_all );
      }

      return $self->{renderer}->metadata_keys( $self->metadata->keys );
    }

    if ( $subcmd eq 'key' ) {
      my $key = shift @argv;

      return
          $self->{renderer}->metadata_key(
                                           $self->metadata->key( key   => $key,
                                                                 limit => 25, )
          );
    }

    if ( $subcmd eq 'candidates' ) {
      return
          $self->{renderer}->metadata_candidates(
                    $self->metadata->candidates(
                      threshold => $self->{config}->metadata_promoter_threshold,
                    ) );
    }

    if ( $subcmd eq 'promote' ) {
      my $key = shift @argv;

      return $self->{renderer}
          ->metadata_promote( $self->metadata->promote( key => $key, ) );
    }

    if ( $subcmd eq 'promoted' ) {
      return $self->{renderer}->metadata_promoted( $self->metadata->promoted );
    }

    if ( $subcmd eq 'set' ) {
      my $hash  = shift @argv;
      my $key   = shift @argv;
      my $value = join( ' ', @argv );

      return
          $self->{renderer}->manual_value_set(
                                               $self->metadata->set_manual(
                                                                hash  => $hash,
                                                                key   => $key,
                                                                value => $value,
                                               ) );
    }

    if ( $subcmd eq 'get' ) {
      my $hash = shift @argv;

      return $self->{renderer}->manual_values_for_hash(
                                $self->metadata->get_manual( hash => $hash, ) );
    }

    if ( $subcmd eq 'unset' ) {
      my $hash = shift @argv;
      my $key  = shift @argv;

      return
          $self->{renderer}->manual_value_unset(
                                                 $self->metadata->unset_manual(
                                                                  hash => $hash,
                                                                  key  => $key,
                                                 ) );
    }

    return $self->{renderer}->help( QBTL::Help->topic( 'meta' ) );
  }

  if ( $cmd eq 'search' ) {
    my $subcmd = shift @argv // 'help';

    if ( $subcmd eq 'help' ) {
      return $self->{renderer}->help( QBTL::Help->topic( 'search' ) );
    }

    if ( $subcmd eq 'list' ) {
      return $self->{renderer}->search_list( $self->search->search_list );
    }

    if ( @argv ) {
      return
          $self->{renderer}->search_result(
                                            $self->search->search(
                                                    field => $subcmd,
                                                    input => join( ' ', @argv ),
                                                    limit => 25, ) );
    }

    return $self->{renderer}->help( QBTL::Help->topic( 'search' ) );
  }

  if ( $cmd eq 'setup' ) {
    my $setup =
        QBTL::Install::Setup->new(
                          home         => $self->{config}->installation_root,
                          user_home    => $self->{config}->home,
                          default_root => $self->{config}->installation_root,
                          repo_config_path => $self->{config}->repo_config_path,
                          exists $self->{setup_interactive}
                          ? ( interactive => $self->{setup_interactive} )
                          : (), );

    return $self->{renderer}->setup( $self->setup );
  }

  if ( $cmd eq 'status' ) {
    my $db = QBTL::DB->new( db_path => $self->{config}->db_path );

    my $result = {
                  ok       => 1,
                  db_path  => $self->{config}->db_path,
                  problems => [ $db->verify_path ],};

    $result->{ok} = 0 if @{$result->{problems}};

    return $self->{renderer}->status( $result );
  }

  if ( $cmd eq 'qbt' ) {
    my $subcmd = shift @argv // 'help';

    if ( $subcmd eq 'help' ) {
      return $self->{renderer}->help( QBTL::Help->topic( 'qbt' ) );
    }

    if ( $subcmd eq 'info' ) {
      my $api = QBTL::QBT::API->new(
                               base_url => $self->{config}->qbt_url,
                               $self->{qbt_ua} ? ( ua => $self->{qbt_ua} ) : (),
      );

      my $process = QBTL::Process::QBT->new( api => $api );
      my $result  = $process->info;

      return $self->{renderer}->qbt_result( $result );
    }

    if ( $subcmd eq 'refresh' ) {
      my $db      = QBTL::DB->new( db_path => $self->{config}->db_path );
      my $connect = $db->connect;

      if ( !$connect->{ok} ) {
        return
            $self->{renderer}->status(
                                       {
                                        ok       => 0,
                                        db_path  => $self->{config}->db_path,
                                        problems => $connect->{problems},} );
      }

      my $migration = $db->migrate( $connect->{dbh} );

      if ( !$migration->{ok} ) {
        $connect->{dbh}->disconnect;

        return
            $self->{renderer}->qbt_refresh(
                      {
                       ok       => 0,
                       action   => 'qbt_refresh',
                       seen     => 0,
                       stored   => 0,
                       problems => [
                                     {
                                      hash  => undef,
                                      error => 'database schema update failed',
                                     },
                       ],} );
      }
      my $clear = $db->clear_current_qbt( $connect->{dbh} );

      if ( !$clear->{ok} ) {
        $connect->{dbh}->disconnect;

        return
            $self->{renderer}->qbt_refresh(
                {
                 ok       => 0,
                 action   => 'qbt_refresh',
                 seen     => 0,
                 stored   => 0,
                 new      => 0,
                 existing => 0,
                 removed  => 0,
                 problems => [
                               {
                                hash  => undef,
                                error => 'failed to clear qBT current markers',
                               },
                 ],} );
      }

      my $api = QBTL::QBT::API->new( base_url => $self->{config}->qbt_url, );
      my $process = QBTL::Process::QBT->new( api => $api );
      my $info    = $process->info;

      if ( !$info->{ok} ) {
        $connect->{dbh}->disconnect;

        return
            $self->{renderer}->qbt_refresh(
            {
             ok       => 0,
             action   => 'qbt_refresh',
             seen     => 0,
             stored   => 0,
             problems => [
                           {
                            hash  => undef,
                            error => 'qBittorrent torrents/info request failed',
                           },
             ],} );
      }

      my $result =
          $process->refresh_info_rows(
                                       dbh  => $connect->{dbh},
                                       db   => $db,
                                       rows => $info->{rows} // [], );

      $connect->{dbh}->disconnect;

      return $self->{renderer}->qbt_refresh( $result );
    }

    if ( $subcmd eq 'preferences' ) {
      my $prefcmd = shift @argv;

      my $db      = QBTL::DB->new( db_path => $self->{config}->db_path );
      my $connect = $db->connect;

      if ( !$connect->{ok} ) {
        return
            $self->{renderer}->status(
                                       {
                                        ok       => 0,
                                        db_path  => $self->{config}->db_path,
                                        problems => $connect->{problems},} );
      }

      my $migration = $db->migrate( $connect->{dbh} );

      if ( !$migration->{ok} ) {
        $connect->{dbh}->disconnect;

        return
            $self->{renderer}->qbt_preferences(
                      {
                       ok       => 0,
                       action   => 'qbt_preferences_refresh',
                       seen     => 0,
                       stored   => 0,
                       problems => [
                                     {
                                      key   => undef,
                                      error => 'database schema update failed',
                                     },
                       ],} );
      }
      if ( defined $prefcmd && $prefcmd eq 'keys' ) {
        my $result = $db->qbt_preference_keys( $connect->{dbh} );

        $connect->{dbh}->disconnect;

        return $self->{renderer}->qbt_preference_keys( $result );
      }

      if ( defined $prefcmd && $prefcmd ne 'refresh' ) {
        $connect->{dbh}->disconnect;

        return $self->{renderer}->help( QBTL::Help->topic( 'qbt' ) );
      }

      my $api = QBTL::QBT::API->new( base_url => $self->{config}->qbt_url, );
      my $process     = QBTL::Process::QBT->new( api => $api );
      my $preferences = $process->preferences;

      if ( !$preferences->{ok} ) {
        $connect->{dbh}->disconnect;

        return
            $self->{renderer}->qbt_preferences(
            {
             ok       => 0,
             action   => 'qbt_preferences_refresh',
             seen     => 0,
             stored   => 0,
             problems => [
                         {
                          key   => undef,
                          error => 'qBittorrent app/preferences request failed',
                         },
             ],} );
      }

      my $result =
          $process->refresh_preferences(
                               dbh         => $connect->{dbh},
                               db          => $db,
                               preferences => $preferences->{preferences} // {},
          );

      $connect->{dbh}->disconnect;

      return $self->{renderer}->qbt_preferences( $result );
    }

    if ( $subcmd eq 'version' ) {
      my $api = QBTL::QBT::API->new( base_url => $self->{config}->qbt_url, );

      my $process = QBTL::Process::QBT->new( api => $api );
      my $result  = $process->version;

      return $self->{renderer}->qbt_result( $result );
    }

    return $self->{renderer}->help( QBTL::Help->topic( 'qbt' ) );
  }

  if ( $cmd eq 'version' ) {
    return $self->{renderer}->version( $QBTL::VERSION );
  }

  return $self->{renderer}->help( QBTL::Help->topic( 'main' ) );
}

sub search ( $self ) {
  $self->{search} //=
      QBTL::Process::Search->new( db_path => $self->{config}->db_path, );

  return $self->{search};
}

sub setup ( $self ) {
  my $root        = $self->{config}->installation_root;
  my $config_path = $self->{config}->installation_config_path;

  if ( !-d $root || !-f $config_path ) {
    say {$self->{renderer}->{out}} 'QBTL is not installed; starting
installation.';

    my $install = $self->install;

    return $install if !$install->{ok};

    $root = $install->{home};
  }

  my $queue_dirs = $self->_installer->ensure_queue_dirs( $root );

  return {
          ok         => 1,
          home       => $root,
          created    => $queue_dirs->{created},
          existing   => $queue_dirs->{existing},
          queue_dirs => $queue_dirs,};
}

1;
