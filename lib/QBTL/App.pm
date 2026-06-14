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

    if ( $subcmd eq 'info' ) {
      my $api = QBTL::QBT::API->new( base_url => $self->{config}->qbt_url, );

      my $process = QBTL::Process::QBT->new( api => $api );
      my $result  = $process->torrents_info_request;

      return $self->{renderer}->qbt_request( $result );
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

      my $api = QBTL::QBT::API->new( base_url => $self->{config}->qbt_url, );
      my $process   = QBTL::Process::QBT->new( api => $api );
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
      my $result =
          $process->refresh_info_rows(
                      dbh  => $connect->{dbh},
                      db   => $db,
                      rows => [
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
                         tracker => 'https://tracker.example.invalid/announce',
                         ratio   => 1.0,
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
                         tracker => 'https://tracker.example.invalid/announce',
                         ratio   => 0.25,
                        },
                      ], );

      $connect->{dbh}->disconnect;

      return $self->{renderer}->qbt_refresh( $result );
    }

    if ( $subcmd eq 'version' ) {
      my $api = QBTL::QBT::API->new( base_url => $self->{config}->qbt_url, );

      my $process = QBTL::Process::QBT->new( api => $api );
      my $result  = $process->version_request;

      return $self->{renderer}->qbt_request( $result );
    }

    return $self->{renderer}->help;
  }

  return $self->{renderer}->help;
}

1;
