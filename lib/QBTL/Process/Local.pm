package QBTL::Process::Local;

use v5.40;
use common::sense;
use feature qw( signatures );

use Time::HiRes qw( time );

use QBTL::DB;
use QBTL::Local::Parser;
use QBTL::Local::Scanner;
use QBTL::Process::WithDB;

sub new ( $class, %arg ) {
  $arg{db_process} //= QBTL::Process::WithDB->new( db_path => $arg{db_path}, );
  $arg{parser}     //= QBTL::Local::Parser->new;
  $arg{scanner} //=
      QBTL::Local::Scanner->new( search_tool => $arg{search_tool}, );

  return bless \%arg, $class;
}

sub db_process ( $self ) {
  return $self->{db_process};
}

sub _elapsed ( $started ) {
  return sprintf( '%.2f', time - $started );
}

sub reset ( $self, %arg ) {
  my $db      = QBTL::DB->new( db_path => $self->{db_path} );
  my $connect = $db->connect;

  return {
          ok       => 0,
          status   => 'db_connect_failed',
          problems => $connect->{problems} // [],}
      if !$connect->{ok};

  my $reset = $db->local_flush_evidence( $connect->{dbh} );

  $connect->{dbh}->disconnect;

  return {
          ok    => 0,
          reset => $reset,
          scan  => undef,}
      if !$reset->{ok};

  my $scan = $self->scan( threshold => $arg{threshold}, );

  return {
          ok    => $scan->{ok} ? 1 : 0,
          reset => $reset,
          scan  => $scan,};
}

sub parser ( $self ) {
  return $self->{parser};
}

sub scanner ( $self ) {
  return $self->{scanner};
}

sub refresh ( $self, %arg ) {
  return $self->_scan_common( %arg, refresh_only => 1, );
}

sub scan ( $self, %arg ) {
  return $self->_scan_common( %arg, refresh_only => 0, );
}

sub _scan_common ( $self, %arg ) {
  my $started      = time;
  my $threshold    = $arg{threshold} // 20;
  my $refresh_only = $arg{refresh_only} ? 1 : 0;
  my $scan         = $self->scanner->scan_torrents( path => $arg{path}, );

  if ( !$scan->{ok} ) {
    return {
            ok             => 0,
            action         => $refresh_only ? 'local_refresh' : 'local_scan',
            backend        => $scan->{backend},
            target         => $scan->{path},
            search_tool    => $scan->{search_tool},
            seen           => $scan->{count} // 0,
            stored         => 0,
            parsed         => 0,
            parse_problems => 0,
            skipped_known  => 0,
            skipped_excluded => 0,
            total          => 0,
            elapsed        => _elapsed( $started ),
            problems       => $scan->{problems} // [],};
  }

  return $self->db_process->with_db(
    sub ( $db, $dbh ) {
      my $stored                   = 0;
      my $parsed                   = 0;
      my $parse_problem            = 0;
      my $skipped_known            = 0;
      my $skipped_excluded         = 0;
      my $fastresume_stored        = 0;
      my $fastresume_parsed        = 0;
      my $fastresume_parse_problem = 0;
      my $fastresume_skipped_known = 0;
      my @problem;

      my $broad_scan = defined $arg{path} && $arg{path} ne '' ? 0 : 1;

      for my $type ( qw(torrent fastresume) ) {
        for my $path ( @{$scan->{types}{$type}{paths} // []} ) {

          if ( $broad_scan && _is_broad_excluded_path( $path ) ) {
            $skipped_excluded++;
            next;
          }

          if ( $refresh_only ) {
            my $known =
                $type eq 'fastresume'
                ? $db->local_fastresume_file_exists( $dbh, $path )
                : $db->local_torrent_file_exists( $dbh, $path );

            if ($known) {
              if ( $type eq 'fastresume' ) {
                $fastresume_skipped_known++;
              } else {
                $skipped_known++;
              }
              next;
            }
          }

          if ( $type eq 'fastresume' ) {
            my $stored_one = $self->_store_fastresume_path(
              db       => $db,
              dbh      => $dbh,
              path     => $path,
              backend  => $scan->{backend},
              problems => \@problem,
            );

            $fastresume_stored++        if $stored_one->{stored};
            $fastresume_parsed++        if $stored_one->{parsed};
            $fastresume_parse_problem++ if $stored_one->{parse_problem};

            next;
          }

          my $stored_one = $self->_store_torrent_path(
            db       => $db,
            dbh      => $dbh,
            path     => $path,
            backend  => $scan->{backend},
            problems => \@problem,
          );

          $stored++        if $stored_one->{stored};
          $parsed++        if $stored_one->{parsed};
          $parse_problem++ if $stored_one->{parse_problem};
        }
      }

      my $metadata_candidates =
          $db->promotion_candidates( $dbh, threshold => $threshold, );

      my $bt_backup_dir =
          ( $ENV{HOME} // '' )
          . '/Library/Application Support/qBittorrent/BT_backup';

      my $bt_backup_exists = -d $bt_backup_dir ? 1 : 0;

      my $bt_backup_fs_torrents   = 0;
      my $bt_backup_fs_fastresume = 0;
      my $bt_backup_db_torrents   = 0;
      my $bt_backup_db_fastresume = 0;

      if ($bt_backup_exists) {
        if ( opendir my $bt_dh, $bt_backup_dir ) {
          while ( defined( my $entry = readdir $bt_dh ) ) {
            next if $entry eq '.' || $entry eq '..';

            if ( $entry =~ /[.]torrent\z/ ) {
              $bt_backup_fs_torrents++;
              next;
            }

            if ( $entry =~ /[.]fastresume\z/ ) {
              $bt_backup_fs_fastresume++;
              next;
            }
          }

          closedir $bt_dh;
        }

        my $bt_backup_prefix = $bt_backup_dir . '/';
        my $prefix_length    = length $bt_backup_prefix;

        ( $bt_backup_db_torrents ) = $dbh->selectrow_array(
          q{
            SELECT COUNT(*)
            FROM local_torrent_files
            WHERE substr(path, 1, ?) = ?
          },
          undef,
          $prefix_length,
          $bt_backup_prefix,
        );

        ( $bt_backup_db_fastresume ) = $dbh->selectrow_array(
          q{
            SELECT COUNT(*)
            FROM local_fastresume_files
            WHERE substr(path, 1, ?) = ?
          },
          undef,
          $prefix_length,
          $bt_backup_prefix,
        );
      }

      my $bt_backup_db_valid =
             $bt_backup_exists
          && $bt_backup_db_torrents == $bt_backup_fs_torrents
          && $bt_backup_db_fastresume == $bt_backup_fs_fastresume ? 1 : 0;

      my $bt_backup_torrents =
          $bt_backup_db_valid ? $bt_backup_db_torrents : $bt_backup_fs_torrents;

      my $bt_backup_fastresume =
          $bt_backup_db_valid ? $bt_backup_db_fastresume : $bt_backup_fs_fastresume;

      return {
        ok              => @problem ? 0 : 1,
        action          => $refresh_only ? 'local_refresh' : 'local_scan',
        backend         => $scan->{backend},
        scanner_backend => $scan->{backend},
        target          => $scan->{path},
        search_tool     => $scan->{search_tool},
        seen            => $scan->{count},

        torrent_seen     => $scan->{types}{torrent}{count} // 0,
        stored           => $stored,
        parsed           => $parsed,
        parse_problems   => $parse_problem,
        skipped_known    => $skipped_known,
        skipped_excluded => $skipped_excluded,
        fastresume_seen  => $scan->{types}{fastresume}{count} // 0,
        total            => $db->local_torrent_file_count( $dbh ),

        fastresume_stored         => $fastresume_stored,
        fastresume_parsed         => $fastresume_parsed,
        fastresume_parse_problems => $fastresume_parse_problem,
        fastresume_skipped_known  => $fastresume_skipped_known,
        fastresume_total          => $db->local_fastresume_file_count( $dbh ),

        bt_backup_exists       => $bt_backup_exists,
        bt_backup_count_source => $bt_backup_db_valid ? 'db' : 'filesystem',
        bt_backup_db_valid     => $bt_backup_db_valid,
        bt_backup_torrents     => $bt_backup_torrents,
        bt_backup_fastresume   => $bt_backup_fastresume,
        bt_backup_mismatch     => $bt_backup_fastresume - $bt_backup_torrents,
        bt_backup_db_torrents  => $bt_backup_db_torrents,
        bt_backup_db_fastresume => $bt_backup_db_fastresume,
        bt_backup_fs_torrents   => $bt_backup_fs_torrents,
        bt_backup_fs_fastresume => $bt_backup_fs_fastresume,

        elapsed             => _elapsed( $started ),
        problems            => \@problem,
        metadata_candidates => $metadata_candidates,};
    } );
}

sub _store_fastresume_path ( $self, %arg ) {
  my $db      = $arg{db};
  my $dbh     = $arg{dbh};
  my $path    = $arg{path};
  my $backend = $arg{backend};
  my $problem = $arg{problems};

  my @stat = stat( $path );

  if ( !@stat ) {
    push @$problem, "stat failed for $path: $!";
    return { stored => 0, parsed => 0, parse_problem => 0, };
  }

  my $store = eval {
    $db->upsert_local_fastresume_file(
      $dbh,
      {
       path    => $path,
       size    => $stat[7],
       mtime   => $stat[9],
       backend => $backend,
      } );
  };

  if ( $@ ) {
    push @$problem, "fastresume store failed for $path: $@";
    return { stored => 0, parsed => 0, parse_problem => 0, };
  }

  if ( !$store->{ok} ) {
    push @$problem, "fastresume store failed for $path";
    return { stored => 0, parsed => 0, parse_problem => 0, };
  }

  my $parse = $self->parser->parse_file( $path );

  my $parse_store = eval {
    $db->update_local_fastresume_parse(
      $dbh,
      {
       path          => $path,
       infohash      => $parse->{infohash},
       parse_ok      => $parse->{ok} ? 1     : 0,
       parse_problem => $parse->{ok} ? undef : $parse->{problem},
      } );
  };

  if ( $@ ) {
    push @$problem, "fastresume parse store failed for $path: $@";
    return { stored => 1, parsed => 0, parse_problem => 0, };
  }

  if ( !$parse_store->{ok} ) {
    push @$problem, "fastresume parse store failed for $path";
    return { stored => 1, parsed => 0, parse_problem => 0, };
  }

  $self->_store_observed_keys(
    db       => $db,
    dbh      => $dbh,
    path     => $path,
    parse    => $parse,
    label    => 'fastresume metadata',
    problems => $problem,
  );

  return {
          stored        => 1,
          parsed        => $parse->{ok} ? 1 : 0,
          parse_problem => $parse->{ok} ? 0 : 1,};
}

sub _store_torrent_path ( $self, %arg ) {
  my $db      = $arg{db};
  my $dbh     = $arg{dbh};
  my $path    = $arg{path};
  my $backend = $arg{backend};
  my $problem = $arg{problems};

  my @stat = stat( $path );

  if ( !@stat ) {
    push @$problem, "stat failed for $path: $!";
    return { stored => 0, parsed => 0, parse_problem => 0, };
  }

  my $result = eval {
    $db->upsert_local_torrent_file(
      $dbh,
      {
       path    => $path,
       size    => $stat[7],
       mtime   => $stat[9],
       backend => $backend,
      } );
  };

  if ( $@ ) {
    push @$problem, "store failed for $path: $@";
    return { stored => 0, parsed => 0, parse_problem => 0, };
  }

  if ( !$result->{ok} ) {
    push @$problem, "store failed for $path";
    return { stored => 0, parsed => 0, parse_problem => 0, };
  }

  my $parse = $self->parser->parse_file( $path );

  my $parse_result = eval {
    $db->update_local_torrent_parse(
      $dbh,
      {
       path               => $path,
       infohash           => $parse->{infohash},
       torrent_name       => $parse->{torrent_name},
       comment            => $parse->{comment},
       announce           => $parse->{announce},
       created_by         => $parse->{created_by},
       creation_date      => $parse->{creation_date},
       payload_kind       => $parse->{payload_kind},
       payload_root_name  => $parse->{payload_root_name},
       payload_file_count => $parse->{payload_file_count},
       payload_total_size => $parse->{payload_total_size},
       payload_probe_path => $parse->{payload_probe_path},
       payload_probe_name => $parse->{payload_probe_name},
       parse_ok           => $parse->{ok} ? 1     : 0,
       parse_problem      => $parse->{ok} ? undef : $parse->{problem},
      } );
  };

  if ( $@ ) {
    push @$problem, "parse store failed for $path: $@";
    return { stored => 1, parsed => 0, parse_problem => 0, };
  }

  if ( !$parse_result->{ok} ) {
    push @$problem, "parse store failed for $path";
    return { stored => 1, parsed => 0, parse_problem => 0, };
  }

  $self->_store_observed_keys(
    db       => $db,
    dbh      => $dbh,
    path     => $path,
    parse    => $parse,
    label    => 'metadata',
    problems => $problem,
  );

  return {
          stored        => 1,
          parsed        => $parse->{ok} ? 1 : 0,
          parse_problem => $parse->{ok} ? 0 : 1,};
}

sub _store_observed_keys ( $self, %arg ) {
  my $db      = $arg{db};
  my $dbh     = $arg{dbh};
  my $path    = $arg{path};
  my $parse   = $arg{parse};
  my $label   = $arg{label};
  my $problem = $arg{problems};

  return if !$parse->{ok} || !$parse->{infohash};

  for my $key ( @{$parse->{observed_keys} // []} ) {
    my $stored_key = eval {
      $db->upsert_hash_value(
        $dbh,
        hash       => $parse->{infohash},
        key        => $key->{key},
        value      => $key->{value},
        value_type => $key->{value_type} // 'text',
      );
    };

    if ( $@ ) {
      push @$problem, "$label key store failed for $path: $@";
      next;
    }

    if ( !$stored_key->{ok} ) {
      push @$problem,
          "$label key store failed for $path: "
          . ( $stored_key->{error} // $key->{key} );
      next;
    }
  }

  return;
}

sub _is_broad_excluded_path ($path) {
  return 0 if !defined $path || $path eq '';

  return 1 if $path =~ m{(?:\A|/)BT_backup(?:/|\z)};
  return 1 if $path =~ m{(?:\A|/)queued_for_deletion(?:/|\z)};

  return 0;
}

sub summary ( $self ) {
  return $self->db_process->with_db(
    sub ( $db, $dbh ) {
      my $root = $self->{install_root};

      my $deletion =
          defined $root && length $root
          ? $db->deletion_queue_totals( $dbh, root => $root )
          : undef;

      my $restoration =
          defined $root && length $root
          ? $db->restoration_queue_totals( $dbh, root => $root )
          : undef;

      return {
              ok           => 1,
              action       => 'local_summary',
              summary      => $db->local_torrent_summary( $dbh ),
              qbt_mismatch => $db->qbt_mismatch_count( $dbh ),
              deletion     => $deletion,
              restoration  => $restoration,};
    } );
}

1;
