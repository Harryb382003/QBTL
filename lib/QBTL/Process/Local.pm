package QBTL::Process::Local;

use v5.40;
use common::sense;
use feature qw( signatures );

use Time::HiRes    qw( time );
use File::Basename qw( basename );
use File::Copy     qw( move );
use File::Path     qw( make_path );
use File::Spec;
use Digest::MD5 ();

use QBTL::DB;
use QBTL::Local::Parser;
use QBTL::Local::Scanner;
use QBTL::Process::WithDB;
use QBTL::Process::Errors qw(
    ERR_TORRENT_BDECODE_FAILED
    begin_error_run
    has_error
    error_run_summary
);

sub new ( $class, %arg ) {
  $arg{db_process} //= QBTL::Process::WithDB->new( db_path => $arg{db_path}, );
  $arg{parser}     //= QBTL::Local::Parser->new;
  $arg{scanner} //=
      QBTL::Local::Scanner->new( search_tool => $arg{search_tool}, );

  return bless \%arg, $class;
}

sub db_process ( $self ) { return $self->{db_process}; }

sub _elapsed ( $started ) { return sprintf( '%.2f', time - $started ); }

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

sub parser ( $self ) { return $self->{parser}; }

sub scanner ( $self ) { return $self->{scanner}; }

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
            ok               => 0,
            action           => $refresh_only ? 'local_refresh' : 'local_scan',
            backend          => $scan->{backend},
            target           => $scan->{path},
            search_tool      => $scan->{search_tool},
            seen             => $scan->{count} // 0,
            stored           => 0,
            parsed           => 0,
            parse_problems   => 0,
            skipped_known    => 0,
            skipped_excluded => 0,
            total            => 0,
            elapsed          => _elapsed( $started ),
            problems         => $scan->{problems} // [],};
  }

  return $self->db_process->with_db(
    sub ( $db, $dbh ) {
      my $skipped_known            = 0;
      my $fastresume_stored        = 0;
      my $fastresume_parsed        = 0;
      my $fastresume_parse_problem = 0;
      my $skipped_excluded         = 0;
      my %torrent_culled           = (
        presumed_duplicate         => 0,
        previously_catalogued      => 0,
        preclassified_for_deletion => 0,
        qbt_bt_backup              => 0,
      );
      my %fastresume_decode_skipped = (
        preclassified_for_deletion => 0,
        qbt_bt_backup              => 0,
      );
      my $stored                   = 0;
      my $parsed                   = 0;
      my $parse_problem            = 0;
      my @parse_problem_detail;

      my $fastresume_skipped_excluded = 0;
      my $fastresume_skipped_known    = 0;
      my @problem;
      my @stored_torrents;

      my $broad_scan = defined $arg{path} && $arg{path} ne '' ? 0 : 1;

      for my $type ( qw(torrent fastresume) ) {
        for my $path ( @{$scan->{types}{$type}{paths} // []} ) {
          if ( $refresh_only ) {
            my $known =
                  $type eq 'fastresume'
                ? $db->local_fastresume_file_exists( $dbh, $path )
                : $db->local_torrent_file_exists( $dbh, $path );

            if ( $known ) {
              if ( $type eq 'fastresume' ) {
                $fastresume_skipped_known++;
              } else {
                $skipped_known++;
              }

              next;
            }
          }

          my $excluded_reason =
              $broad_scan ? _broad_excluded_reason( $path ) : undef;
          my $excluded = defined $excluded_reason ? 1 : 0;

          if ( $type eq 'fastresume' ) {
            my $stored_one =
                $self->_store_fastresume_path(
                                               db       => $db,
                                               dbh      => $dbh,
                                               path     => $path,
                                               backend  => $scan->{backend},
                                               problems => \@problem,
                                               parse    => $excluded ? 0 : 1, );

            $fastresume_stored++ if $stored_one->{stored};

            if ( $excluded ) {
              $fastresume_skipped_excluded++;
              $fastresume_decode_skipped{$excluded_reason}++;
            } else {
              $fastresume_parsed++ if $stored_one->{parsed};

              $fastresume_parse_problem++
                  if $stored_one->{parse_problem};
            }

            next;
          }

          if ( $excluded ) {
            $skipped_excluded++;
            $torrent_culled{$excluded_reason}++;
            next;
          }

          my $stored_one =
              $self->_store_torrent_path(
                                          db       => $db,
                                          dbh      => $dbh,
                                          path     => $path,
                                          backend  => $scan->{backend},
                                          problems => \@problem, );

          if ( $stored_one->{stored} ) {
            $stored++;

            push @stored_torrents, $stored_one;
          }

          if ( $stored_one->{parse_problem} ) {
            $parse_problem++;

            push @parse_problem_detail, $stored_one->{parse_problem_detail}
                if $stored_one->{parse_problem_detail};
          }
        }
      }

      my $pre_cull =
          $self->_pre_cull(
                            db       => $db,
                            dbh      => $dbh,
                            torrents => \@stored_torrents,
                            problems => \@problem, );

      for my $reason ( keys %{ $pre_cull->{culled} // {} } ) {
        $torrent_culled{$reason} += $pre_cull->{culled}{$reason} // 0;
      }

      my $unculled_torrents = $pre_cull->{retained} // [];

      my $torrent_disposition_total = scalar @$unculled_torrents;
      $torrent_disposition_total += $_ for values %torrent_culled;

      my $torrent_classified = $scan->{types}{torrent}{count} // 0;

      if ( $torrent_disposition_total != $torrent_classified ) {
        my $error = has_error(
          source  => __FILE__,
          line    => __LINE__,
          message => 'local torrent accounting mismatch',
          classified => $torrent_classified,
          accounted  => $torrent_disposition_total,
        );
        push @problem, $error->{message} if $error->{first};
      }

      for my $torrent ( @$unculled_torrents ) {
        my $stored_contents =
            $self->_store_torrent_contents(
                                            db       => $db,
                                            dbh      => $dbh,
                                            path     => $torrent->{path},
                                            problems => \@problem, );

        $parsed++ if $stored_contents->{parsed};

        if ( $stored_contents->{parse_problem} ) {
          $parse_problem++;

          push @parse_problem_detail, $stored_contents->{parse_problem_detail}
              if $stored_contents->{parse_problem_detail};
        }
      }

      my $torrent_content_attempted = $parsed + $parse_problem;

      if ( $torrent_content_attempted != scalar @$unculled_torrents ) {
        my $error = has_error(
          source  => __FILE__,
          line    => __LINE__,
          message => 'local torrent decode accounting mismatch',
          retained => scalar @$unculled_torrents,
          accounted => $torrent_content_attempted,
        );
        push @problem, $error->{message} if $error->{first};
      }

      #       my $metadata_candidates =
      #           $db->promotion_candidates( $dbh, threshold => $threshold, );

      my $metadata_candidates = {
                                 ok         => 1,
                                 threshold  => $threshold,
                                 candidates => [],};

      my $bt_backup_dir =
          ( $ENV{HOME} // '' )
          . '/Library/Application Support/qBittorrent/BT_backup';

      my $bt_backup_exists = -d $bt_backup_dir ? 1 : 0;

      my $bt_backup_fs_torrents   = 0;
      my $bt_backup_fs_fastresume = 0;

      if ( $bt_backup_exists ) {
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
      }

 #       warn "torrent seen: " . ( $scan->{types}{torrent}{count} // 0 ) . "\n";
 #       warn "excluded: $skipped_excluded\n";
 #       warn "fastresume seen: "
 #           . ( $scan->{types}{fastresume}{count} // 0 ) . "\n";
 #       warn "fastresume excluded: $fastresume_skipped_excluded\n";

      my $torrent_metadata_total =
          $db->C_LOC_torrent_metadata_count( $dbh );

      return {
        ok              => @problem      ? 0               : 1,
        action          => $refresh_only ? 'local_refresh' : 'local_scan',
        backend         => $scan->{backend},
        scanner_backend => $scan->{backend},
        target          => $scan->{path},
        search_tool     => $scan->{search_tool},
        seen            => $scan->{count},

        torrent_seen       => $scan->{types}{torrent}{count} // 0,
        torrent_classified => $scan->{types}{torrent}{count} // 0,
        torrent_retained          => scalar @$unculled_torrents,
        torrent_content_attempted => $torrent_content_attempted,
        torrent_metadata_extracted => $parsed,
        torrent_metadata_total     => $torrent_metadata_total,
        torrent_culled     => \%torrent_culled,

        stored           => $stored,
        parsed           => $parsed,
        parse_problems       => $parse_problem,
        parse_problem_summary => _parse_problem_summary( \@parse_problem_detail ),
        skipped_known    => $skipped_known,
        skipped_excluded => $skipped_excluded,
        fastresume_seen  => $scan->{types}{fastresume}{count} // 0,

        # DBD::SQLite::db selectrow_array failed:
        # no such table: local_torrent_files at lib/QBTL/DB.pm line 164.

        total => $db->C_LOC_torrents_count( $dbh ),

        fastresume_stored           => $fastresume_stored,
        fastresume_parsed           => $fastresume_parsed,
        fastresume_parse_problems   => $fastresume_parse_problem,
        fastresume_skipped_known    => $fastresume_skipped_known,
        fastresume_skipped_excluded => $fastresume_skipped_excluded,
        fastresume_decode_skipped   => \%fastresume_decode_skipped,

       #         fastresume_total => $db->C_local_fastresume_file_count( $dbh ),
        fastresume_total => undef,    # no LOC_fastresume inventory exists yet

        bt_backup_exists       => $bt_backup_exists,
        bt_backup_count_source => 'filesystem',
        bt_backup_db_valid     => undef,

        bt_backup_torrents   => $bt_backup_fs_torrents,
        bt_backup_fastresume => $bt_backup_fs_fastresume,
        bt_backup_mismatch => $bt_backup_fs_fastresume - $bt_backup_fs_torrents,

        bt_backup_db_torrents   => undef,
        bt_backup_db_fastresume => undef,
        bt_backup_fs_torrents   => $bt_backup_fs_torrents,
        bt_backup_fs_fastresume => $bt_backup_fs_fastresume,

        elapsed             => _elapsed( $started ),
        problems            => \@problem,
        metadata_candidates => $metadata_candidates,};
    } );
}

sub _store_fastresume_path ( $self, %arg ) {
  my $db       = $arg{db};
  my $dbh      = $arg{dbh};
  my $path     = $arg{path};
  my $backend  = $arg{backend};
  my $problem  = $arg{problems};
  my $do_parse = exists $arg{parse} ? $arg{parse} : 1;
  my @stat     = stat( $path );

  if ( !@stat ) {
    push @$problem, "stat failed for $path: $!";
    return {stored => 0, parsed => 0, parse_problem => 0,};
  }

  my $store = eval {
    $db->S_LOC_torrents_fastresume(
                                    $dbh,
                                    path    => $path,
                                    size    => $stat[7],
                                    mtime   => $stat[9],
                                    backend => $backend, );
  };

  if ( $@ ) {
    my $error = has_error(
                           source  => __FILE__,
                           line    => __LINE__,
                           message => $@,
                           path    => $path, );
    push @$problem, $error->{message} if $error->{first};
    return {stored => 0, parsed => 0, parse_problem => 0,};
  }

  if ( !$store->{ok} ) {
    __LINE__ . ": LOC_torrents_fastresume $path";
    return {
            stored        => 0,
            parsed        => 0,
            parse_problem => 0,};
  }

  if ( !$do_parse ) {
    return {
            stored        => 1,
            parsed        => 0,
            parse_problem => 0,};
  }

  my $parse = $self->parser->parse_file( $path );

  my $parse_store = eval {
    $db->update_local_fastresume_parse(
                                        $dbh,
                                        {
                                         path          => $path,
                                         hash          => $parse->{hash},
                                         parse_ok      => $parse->{ok} ? 1 : 0,
                                         parse_problem => $parse->{ok}
                                         ? undef
                                         : $parse->{problem},
                                        } );
  };

  if ( $@ ) {
    my $error = has_error(
                           source  => __FILE__,
                           line    => __LINE__,
                           message => $@,
                           path    => $path, );
    push @$problem, $error->{message} if $error->{first};
    return {stored => 1, parsed => 0, parse_problem => 0,};
  }

  if ( !$parse_store->{ok} ) {
    push @$problem, ": fastresume parse store failed for $path";
    return {stored => 1, parsed => 0, parse_problem => 0,};
  }

  $self->_store_observed_keys(
                               db       => $db,
                               dbh      => $dbh,
                               path     => $path,
                               parse    => $parse,
                               label    => 'fastresume metadata',
                               problems => $problem, );

  return {
          stored        => 1,
          inserted      => 0,
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
    warn "STAT FAILED for $path: $!\n";

    push @$problem, "stat failed for $path: $!";

    return {
            stored => 0,
            path   => $path,};
  }

  my $result = eval {
    $db->S_LOC_torrents_upsert(
                                $dbh,
                                {
                                 path    => $path,
                                 backend => $backend,
                                } );
  };

  my $upsert_error = $@;

  if ( $upsert_error ) {
    warn "UPSERT EXCEPTION for $path:\n$upsert_error\n";

    push @$problem, "store failed for $path: $upsert_error";

    return {
            stored => 0,
            path   => $path,};
  }

  if ( !$result->{ok} ) {
    require Data::Dumper;

    warn "BAD UPSERT RESULT:\n" . Data::Dumper::Dumper( $result );

    push @$problem, "store failed for $path";

    return {
            stored => 0,
            path   => $path,};
  }

  return {
          stored  => 1,
          path    => $path,
          size    => $stat[7],
          mtime   => $stat[9],
          backend => $backend,};
}

sub _whole_file_md5 ( $path ) {
  open my $fh, '<:raw', $path
      or die "open failed for $path: $!";

  my $digest = Digest::MD5->new;
  $digest->addfile( $fh );
  close $fh
      or die "close failed for $path: $!";

  return $digest->hexdigest;
}

sub _pre_cull ( $self, %arg ) {
  my $db       = $arg{db};
  my $dbh      = $arg{dbh};
  my $torrents = $arg{torrents};
  my $problem  = $arg{problems};

  my @candidates =
      grep { $_->{stored} && defined $_->{path} && length $_->{path} }
      @$torrents;

  # Only files sharing a byte size can be whole-file duplicates. Hash those
  # groups and retain one deterministic path for content inspection.
  my %by_size;
  push @{ $by_size{ $_->{size} // -1 } }, $_ for @candidates;

  my @deduplicated;
  my $presumed_duplicate = 0;

  for my $size ( sort { $a <=> $b } keys %by_size ) {
    my @group = sort { $a->{path} cmp $b->{path} } @{ $by_size{$size} };

    if ( $size < 0 || @group < 2 ) {
      push @deduplicated, @group;
      next;
    }

    my %digest_keeper;

    for my $torrent ( @group ) {
      my $digest = eval { _whole_file_md5( $torrent->{path} ) };

      if ( my $error = $@ ) {
        my $reported = has_error(
          source  => __FILE__,
          line    => __LINE__,
          message => $error,
          path    => $torrent->{path},
        );
        push @$problem, $reported->{message} if $reported->{first};
        push @deduplicated, $torrent;
        next;
      }

      if ( $digest_keeper{$digest} ) {
        $presumed_duplicate++;
        next;
      }

      $digest_keeper{$digest} = $torrent->{path};
      push @deduplicated, $torrent;
    }
  }

  my $state = eval {
    $db->C_LOC_torrent_parse_state(
      $dbh,
      [ map { $_->{path} } @deduplicated ],
    );
  };

  if ( my $error = $@ ) {
    my $reported = has_error(
      source  => __FILE__,
      line    => __LINE__,
      message => $error,
    );
    push @$problem, $reported->{message} if $reported->{first};

    return {
      retained => \@deduplicated,
      culled   => {
        presumed_duplicate    => $presumed_duplicate,
        previously_catalogued => 0,
      },
    };
  }

  my @retained;
  my $previously_catalogued = 0;

  for my $torrent ( @deduplicated ) {
    my $prior = $state->{ $torrent->{path} };

    # Successful prior extraction is sufficient to avoid reopening and
    # bdecoding an already catalogued path. Prior failures are retained so
    # permission changes or repaired files are retried on a full scan.
    if ( $prior && $prior->{parse_ok} ) {
      $previously_catalogued++;
      next;
    }

    push @retained, $torrent;
  }

  return {
    retained => \@retained,
    culled   => {
      presumed_duplicate    => $presumed_duplicate,
      previously_catalogued => $previously_catalogued,
    },
  };
}

sub _store_torrent_contents ( $self, %arg ) {
  my $db      = $arg{db};
  my $dbh     = $arg{dbh};
  my $path    = $arg{path};
  my $problem = $arg{problems};

  my $parse = $self->parser->parse_file( $path );

  my $parse_result = eval {
    $db->S_LOC_torrent_parse_update(
                            $dbh,
                            {
                             path               => $path,
                             hash               => $parse->{hash},
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
                             parse_ok           => $parse->{ok} ? 1 : 0,
                             parse_problem      => $parse->{ok}
                             ? undef
                             : $parse->{problem},
                            } );
  };

  my $parse_store_error = $@;

  if ( $parse_store_error ) {
    warn "PARSE STORE EXCEPTION for $path:\n$parse_store_error\n";

    push @$problem, "parse store failed for $path: $parse_store_error";

    return {
            parsed        => 0,
            parse_problem => 0,};
  }

  if ( !$parse_result->{ok} ) {
    require Data::Dumper;

    warn "BAD PARSE STORE RESULT:\n" . Data::Dumper::Dumper( $parse_result );

    push @$problem, "parse store failed for $path";

    return {
            parsed        => 0,
            parse_problem => 0,};
  }

  $self->_store_observed_keys(
                               db       => $db,
                               dbh      => $dbh,
                               path     => $path,
                               parse    => $parse,
                               label    => 'metadata',
                               problems => $problem, );

  if ( !$parse->{ok} ) {
    my $error = has_error(
                           source  => __FILE__,
                           line    => __LINE__,
                           message => $parse->{problem},
                           path    => $path, );

    push @$problem, $error->{message}
        if !$error->{handled} && $error->{first};
  }

  return {
    parsed        => $parse->{ok} ? 1 : 0,
    parse_problem => $parse->{ok} ? 0 : 1,

    parse_problem_detail => $parse->{ok}
    ? undef
    : {
       path    => $path,
       problem => $parse->{problem} // 'unknown parse failure',
    },};
}

sub _parse_problem_summary ( $details ) {
  my %summary;

  for my $detail ( @{$details // []} ) {
    my $code    = $detail->{error_code};
    my $problem = $detail->{problem} // 'unknown parse failure';

    if ( defined $code && $code == ERR_TORRENT_BDECODE_FAILED ) {
      $problem =~ s/\s+at\s+\d+\z//;
    }

    my $key = join "\0", defined $code ? $code : '', $problem;
    my $row = $summary{$key} //= {
                                  error_code => $code,
                                  problem    => $problem,
                                  count      => 0,};

    $row->{count}++;
  }

  return [
    sort {
      ( $a->{error_code} // 0 ) <=> ( $b->{error_code} // 0 )
          || $a->{problem} cmp $b->{problem}
    } values %summary ];
}

sub _problem_torrent_dir ( $self ) {
  my $root = $self->{install_root};

  return if !defined $root || $root eq '';

  return File::Spec->catdir( $root, 'problem_torrents' );
}

sub _move_to_problem_torrents ( %arg ) {
  my $path        = $arg{path};
  my $destination = $arg{destination};

  eval { make_path( $destination ) if !-d $destination; 1 } or return {
                                 ok      => 0,
                                 problem => "could not create $destination: $@",
  };

  my $name   = basename( $path );
  my $target = File::Spec->catfile( $destination, $name );
  my $suffix = 1;

  while ( -e $target ) {
    my ( $stem, $extension ) =
        $name =~ /\A(.*?)([.]torrent)\z/
        ? ( $1, $2 )
        : ( $name, '' );

    $target = File::Spec->catfile( $destination, "$stem.$suffix$extension", );
    $suffix++;
  }

  return {
          ok      => 0,
          problem => "$!",}
      if !move( $path, $target );

  return {
          ok   => 1,
          path => $target,};
}

sub _path_is_within ( $path, $directory ) {
  return 0 if !defined $path || !defined $directory;

  my $canonical_path = File::Spec->canonpath( File::Spec->rel2abs( $path ) );
  my $canonical_dir =
      File::Spec->canonpath( File::Spec->rel2abs( $directory ) );

  return 1 if $canonical_path eq $canonical_dir;

  my $prefix = File::Spec->catdir( $canonical_dir, '' );

  return index( $canonical_path, $prefix ) == 0 ? 1 : 0;
}

sub _store_observed_keys ( $self, %arg ) {
  my $db      = $arg{db};
  my $dbh     = $arg{dbh};
  my $path    = $arg{path};
  my $parse   = $arg{parse};
  my $label   = $arg{label};
  my $problem = $arg{problems};

  return if !$parse->{ok} || !$parse->{hash};

  my %seen;
  my @observed;

  for my $key ( @{$parse->{observed_keys} // []} ) {
    my $name       = $key->{key};
    my $value      = defined $key->{value} ? $key->{value} : '';
    my $value_type = $key->{value_type} // 'text';

    my $dedupe_key = join "\0", $name, $value, $value_type;

    next if $seen{$dedupe_key}++;

    push @observed,
        {
         key        => $name,
         value      => $value,
         value_type => $value_type,};
  }

  eval {
    $db->S_LOC_hash_values(
                            $dbh,
                            hash   => $parse->{hash},
                            values => \@observed, );
    1;
  } or do {
    push @$problem, "$label key store failed for $path: $@";
  };

  return;
}

sub _broad_excluded_reason ( $path ) {
  return if !defined $path || $path eq '';

  return 'qbt_bt_backup'
      if $path =~ m{(?:\A|/)BT_backup(?:/|\z)};

  return 'preclassified_for_deletion'
      if $path =~ m{(?:\A|/)queued_for_deletion(?:/|\z)};

  return;
}

sub _is_broad_excluded_path ( $path ) {
  return defined _broad_excluded_reason( $path ) ? 1 : 0;
}

sub summary ( $self ) {
  return $self->db_process->with_db(
    sub ( $db, $dbh ) {
      my $root                        = $self->{install_root};
      my $stored                      = 0;
      my $parsed                      = 0;
      my $parse_problem               = 0;
      my $skipped_known               = 0;
      my $skipped_excluded            = 0;
      my $fastresume_stored           = 0;
      my $fastresume_parsed           = 0;
      my $fastresume_parse_problem    = 0;
      my $fastresume_skipped_excluded = 0;
      my $fastresume_skipped_known    = 0;
      my @problem;
      my @stored_torrents;
      my @parse_problem_detail;

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
