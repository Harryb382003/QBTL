package QBTL::App;

use v5.40;
use common::sense;
use feature qw( signatures );

use QBTL;
use QBTL::QBT::API;
use QBTL::Config;
use QBTL::DB;
use QBTL::Help;
use QBTL::Process::Local;
use QBTL::Process::Metadata;
use QBTL::Process::Browse;
use QBTL::Process::QBT;
use QBTL::Process::Search;
use QBTL::Process::Setup;
use QBTL::Render::CLI;

sub new ( $class, %arg ) {
  $arg{config} //= QBTL::Config->new;
  $arg{renderer} //=
      QBTL::Render::CLI->new( time_format => $arg{config}->time_format, );

  return bless \%arg, $class;
}

sub _qbtl_home ( $self ) {
  my $db_path = $self->{config}->db_path;

  $db_path =~ s{/[^/]+\z}{};

  return $db_path;
}

sub local ( $self ) {
  $self->{local} //=
      QBTL::Process::Local->new( db_path => $self->{config}->db_path, );

  return $self->{local};
}

sub metadata ( $self ) {
  $self->{metadata} //=
      QBTL::Process::Metadata->new( db_path => $self->{config}->db_path, );

  return $self->{metadata};
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

    return $self->{renderer}->help;
  }

  if ( $cmd eq 'meta' ) {
    my $subcmd = shift @argv // 'help';

    if ( $subcmd eq 'help' ) {
      return $self->{renderer}->help( QBTL::Help->topic( 'meta' ) );
    }

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
    my $db = QBTL::DB->new( db_path => $self->{config}->db_path );

    my $setup =
        QBTL::Process::Setup->new( home => $self->_qbtl_home,
                                   db   => $db, );

    my $result = $setup->run;

    return $self->{renderer}->setup( $result );
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

  return $self->{renderer}->help;
}

sub browse ( $self ) {
  $self->{browse} //=
      QBTL::Process::Browse->new( db_path => $self->{config}->db_path, );

  return $self->{browse};
}

sub search ( $self ) {
  $self->{search} //=
      QBTL::Process::Search->new( db_path => $self->{config}->db_path, );

  return $self->{search};
}

1;
