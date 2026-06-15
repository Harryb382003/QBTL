package QBTL::App;

use v5.40;
use common::sense;
use feature qw( signatures );

use QBTL;
use QBTL::QBT::API;
use QBTL::Config;
use QBTL::DB;
use QBTL::Process::QBT;
use QBTL::Process::Setup;
use QBTL::Render::CLI;

sub new ( $class, %arg ) {
  $arg{config}   //= QBTL::Config->new;
  $arg{renderer} //= QBTL::Render::CLI->new;

  return bless \%arg, $class;
}

sub _qbtl_home ( $self ) {
  my $db_path = $self->{config}->db_path;

  $db_path =~ s{/[^/]+\z}{};

  return $db_path;
}

sub run_cli ( $self, @argv ) {
  my $cmd = shift @argv // 'help';

  if ( $cmd eq 'help' ) {
    return $self->{renderer}->help;
  }

  if ( $cmd eq 'version' ) {
    return $self->{renderer}->version( $QBTL::VERSION );
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
      return $self->{renderer}->qbt_help;
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

    return $self->{renderer}->qbt_help;
  }

  return $self->{renderer}->help;
}

1;
