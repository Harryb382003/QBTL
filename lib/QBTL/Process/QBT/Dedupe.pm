package QBTL::Process::QBT::Dedupe;

use v5.40;
use common::sense;
use feature qw( signatures );

use File::Basename qw( basename dirname );
use File::Copy     qw( copy move );
use File::Path     qw( make_path );
use File::Spec;
use Encode qw( decode encode FB_CROAK );
use Encode qw( decode FB_DEFAULT );

use QBTL::Local::Parser;
use QBTL::Process::Metadata;
use QBTL::Process::WithDB;

sub new ( $class, %arg ) {
  $arg{db_process} //= QBTL::Process::WithDB->new( db_path => $arg{db_path}, );
  $arg{parser}     //= QBTL::Local::Parser->new;
  $arg{metadata_process} //= QBTL::Process::Metadata->new( db_path => $arg{db_path} );

  return bless \%arg, $class;
}

sub _apply_tracker_prefix_collision_plan ( $self, %arg ) {
  my $planned = $arg{planned} // [];
  my $result  = $arg{result};

  my %by_desired_base;

  for my $plan ( @{$planned} ) {
    my $keeper = $plan->{keeper};
    my $base   = $keeper->{desired_base} // '';

    next if !length $base;

    push @{ $by_desired_base{$base} }, $plan;
  }

  for my $base ( sort keys %by_desired_base ) {
    my @collision = @{ $by_desired_base{$base} };

    next if @collision < 2;

    my %hash_seen = map { $_->{hash} => 1 } @collision;
    next if keys(%hash_seen) < 2;

    my %prefixed_base_by_hash;
    my %prefixed_seen;
    my $unresolved = 0;

    for my $plan (@collision) {
      my $keeper       = $plan->{keeper};
#       warn join(
#         ' | ',
#         'hash=' . ( $plan->{hash} // '(none)' ),
#         'path=' . ( $keeper->{path} // '(none)' ),
#         'announce=' . ( $keeper->{announce} // '(none)' ),
#       ) . "\n";

my $prefixed_base = $self->_collision_avert_tracker(
  $keeper->{announce},
  $base,
);

      if ( !length $prefixed_base || $prefixed_seen{$prefixed_base}++ ) {
        $unresolved = 1;
        last;
      }

      $prefixed_base_by_hash{ $plan->{hash} } = $prefixed_base;
    }

    if ($unresolved) {
      $result->{rename_tracker_prefix_unresolved}++;
      next;
    }

    $result->{rename_tracker_prefix_groups}++;

    for my $plan (@collision) {
      my $keeper        = $plan->{keeper};
      my $prefixed_base = $prefixed_base_by_hash{ $plan->{hash} };

      $keeper->{desired_base}        = $prefixed_base;
      $keeper->{desired_name_source} = 'tracker_prefix_collision';
      $keeper->{should_rename} =
          ( ( $keeper->{_base} // '' ) eq $prefixed_base ) ? 0 : 1;

      $result->{rename_tracker_prefixed}++;
    }
  }

  return;
}

sub _assign_delete_queue_targets ( $self, %arg ) {
  my $queue_dir = $arg{queue_dir}
      // die 'delete queue target assignment requires queue_dir';
  my $queue = $arg{queue} // [];

  my %seen;
  my %target_seen;

  for my $entry ( @{$queue} ) {
    my $base = $entry->{basename} // basename( $entry->{source_path} // '' );
    $base = $self->_normalize_torrent_name($base);
    $base =~ s/\.torrent\z//i;
    $base .= '.torrent';

    my $n = ++$seen{$base};
    my $target_base = $self->_suffix_torrent_basename( $base, $n );

    $entry->{target_path} = File::Spec->catfile( $queue_dir, $target_base );

    warn "duplicate delete queue target assigned: $entry->{target_path}\n"
        if $target_seen{ $entry->{target_path} }++;
  }

  return $queue;
}

sub _audit_current_qbt_downloaded ( $self, %arg ) {
  my $db                = $arg{db};
  my $dbh               = $arg{dbh};
  my $downloaded_bucket = $arg{downloaded_bucket};
  my $completed_bucket  = $arg{completed_bucket};
  my $qbt_name_by_hash  = $arg{qbt_name_by_hash} // {};
  my @missing;
  my @restored;
  my @problem;

  for my $hash ( @{ $db->current_qbt_hashes( $dbh ) } ) {
    next if exists $downloaded_bucket->{keeper_by_hash}{$hash};

    my $name = $qbt_name_by_hash->{$hash};
    my $restore = $self->_restore_current_qbt_from_bt_backup(
      db => $db,
      dbh               => $dbh,
      downloaded_bucket => $downloaded_bucket,
      hash              => $hash,
      name              => $name, );

    if ( $restore->{ok} && $restore->{restored} ) {
      push @restored, $restore->{row};
      next;
    }

    if ( !$restore->{ok} && $restore->{problem} ) {
      push @problem, $restore->{problem};
      push @missing, {
        which => 'export_dir',
        path  => undef,
        hash  => $hash,
        name  => $name,
        error => 'current qBT torrent missing from Downloaded_torrents.'
          . '# TODO no repair code written',
      };
      next;
    }

    push @missing,
        {
         which => 'export_dir',
         path  => undef,
         hash  => $hash,
         name  => $name,
         error => 'current qBT torrent missing from Downloaded_torrents. # TODO no
repair code written',};
  }

  return {
          ok       => @missing || @problem ? 0 : 1,
          missing  => \@missing,
          restored => \@restored,
          problems => \@problem,
          count    => scalar @missing,};
}

sub _audit_current_qbt_completed ( $self, %arg ) {
  my $db                = $arg{db};
  my $dbh               = $arg{dbh};
  my $downloaded_bucket = $arg{downloaded_bucket};
  my $completed_bucket  = $arg{completed_bucket};
  my $qbt_name_by_hash  = $arg{qbt_name_by_hash} // {};
  my $current_completed = $db->current_qbt_completed_hash_map($dbh);
  my @missing;
  my $downloaded_available = 0;
  my $downloaded_missing   = 0;

  for my $hash ( sort keys %{$current_completed} ) {
    next if exists $completed_bucket->{keeper_by_hash}{$hash};

    my $has_downloaded =
        exists $downloaded_bucket->{keeper_by_hash}{$hash} ? 1 : 0;

    if ($has_downloaded) {
      $downloaded_available++;
    } else {
      $downloaded_missing++;
    }

    push @missing,
        {
         which                => 'export_dir_fin',
         path                 => undef,
         hash                 => $hash,
         name                 => $qbt_name_by_hash->{$hash},
         downloaded_available => $has_downloaded,
         error                => 'completed current qBT torrent missing from
Completed_torrents. # TODO no repair code written',};
  }

  return {
          ok                   => @missing ? 0 : 1,
          missing              => \@missing,
          count                => scalar @missing,
          downloaded_available => $downloaded_available,
          downloaded_missing   => $downloaded_missing,};
}

sub _bt_backup_dir ( $self ) {
  my $home = $ENV{HOME} // '';
  return '' if $home eq '';

  return File::Spec->catdir(
                             $home,
                             'Library',
                             'Application Support',
                             'qBittorrent',
                             'BT_backup', );
}

sub _choose_keeper ( $self, %arg ) {
  my $meta_basenames = $arg{meta_basenames};
  my $items          = $arg{items};

  my $qbt_name = $items->[0]->{qbt_name};
  my $qbt_base = $self->_safe_basename( $qbt_name // '' );

  my @ranked =
      sort { $b->{_score} <=> $a->{_score} || $a->{path} cmp $b->{path} } map {
    my $base  = $self->_torrent_basename( $_->{path} );
    my $score = 0;

    # When qBT currently has this hash loaded, qBT's API name wins.
    $score += 300 if length $qbt_base && $base eq $qbt_base;

    $score += 100 if $meta_basenames->{$base};

    my $torrent_base = $self->_safe_basename( $_->{torrent_name} // '' );
    $score += 20 if length $torrent_base && $base eq $torrent_base;

    +{
      %{$_},
      _base  => $base,
      _score => $score,};
      } @{$items};

  my $keeper = $ranked[0];

  if ( length $qbt_base ) {
    $keeper->{desired_base}       = $qbt_base;
    $keeper->{desired_name_source} = 'qbt_info.name';
    $keeper->{should_rename}      = $keeper->{_base} eq $qbt_base ? 0 : 1;
    return $keeper;
  }

  if ( $keeper->{_score} >= 100 ) {
    $keeper->{desired_base}       = $keeper->{_base};
    $keeper->{desired_name_source} = 'meta';
    $keeper->{should_rename}      = 0;
    return $keeper;
  }

  my $torrent_base = $self->_safe_basename( $keeper->{torrent_name} // '' );

  $keeper->{desired_base} =
      length $torrent_base ? $torrent_base : $keeper->{_base};
  $keeper->{desired_name_source} =
      length $torrent_base ? 'torrent_name' : 'existing_filename';
  $keeper->{should_rename} =
      $keeper->{_base} eq $keeper->{desired_base} ? 0 : 1;

  return $keeper;
}

sub _collision_avert_tracker ( $self, $announce, $base ) {
  $announce //= '';

  my ($host) = $announce =~ m{\A[a-z][a-z0-9+.-]*://([^/:?#]+)}i;
  $host //= '';
  $host =~ s/\Awww\.//i;

  my @part = grep { length } split /\./, $host;

  return '' if @part < 2;

  my @candidate = reverse @part[ 0 .. $#part - 1 ];

  for my $tag (@candidate) {
    next if $tag =~ /\A(?:tracker|announce|udp|http|https|bt)\z/i;

    $tag =~ s/[^A-Za-z0-9_-]+/_/g;
    $tag =~ s/\A_+//;
    $tag =~ s/_+\z//;

    return '[' . $tag . '] ' . $base if length $tag;
  }

  return '';
}

sub _commit_delete_queue ( $self, %arg ) {
  my $db        = $arg{db};
  my $dbh       = $arg{dbh};
  my $queue_dir = $arg{queue_dir};
  my $queue     = $arg{queue} // [];

  my @problem;
  my @moved;
  my @moved_pending_db;
  my %moved_by_which;
  my $moved_stale_completed = 0;

  $self->_assign_delete_queue_targets(
    queue_dir => $queue_dir,
    queue     => $queue,
  );

  for my $entry ( @{$queue} ) {
    my $old_path = $entry->{source_path};
    my $target   = $entry->{target_path};

    if ( !defined $old_path || !length $old_path || !-f $old_path ) {
      push @problem,
          {
           which  => $entry->{which},
           path   => $old_path,
           hash   => $entry->{hash},
           target => $target,
           error  => 'queued duplicate source path is not readable',
          };
      next;
    }

    if ( defined $target && -e $target ) {
      push @problem,
        {
          which  => $entry->{which},
          path   => $old_path,
          hash   => $entry->{hash},
          target => $target,
          error  => "queued duplicate target path already exists:"
                  . "\n\ttarget=$target source=$old_path",
        };
      next;
    }

    if ( !move( $old_path, $target ) ) {
      push @problem,
          {
           which  => $entry->{which},
           path   => $old_path,
           hash   => $entry->{hash},
           target => $target,
           error  => "move to queued_for_deletion failed: $!",
          };
      next;
    }

    push @moved_pending_db,
        {
         kind     => $entry->{kind},
         which    => $entry->{which},
         hash     => $entry->{hash},
         old_path => $old_path,
         new_path => $target,
        };
  }

  my $started_txn = 0;

  my $ok = eval {
    if ( $dbh->{AutoCommit} ) {
      $dbh->begin_work;
      $started_txn = 1;
    }

    for my $entry (@moved_pending_db) {
      my $updated = $db->cull_moved_duplicate_torrent_file(
        $dbh,
        old_path => $entry->{old_path},
        new_path => $entry->{new_path},
        hash     => $entry->{hash} // '',
      );

      if ( !$updated->{ok} ) {
        push @problem,
            {
             which  => $entry->{which},
             path   => $entry->{old_path},
             hash   => $entry->{hash},
             target => $entry->{new_path},
             error  => $updated->{problem}
               // 'queued duplicate DB cleanup failed',
            };
        next;
      }

      push @moved,
          {
           kind     => $entry->{kind},
           which    => $entry->{which},
           hash     => $entry->{hash},
           old_path => $entry->{old_path},
           new_path => $entry->{new_path},
          };

      if ( ( $entry->{kind} // '' ) eq 'stale_completed' ) {
        $moved_stale_completed++;
      }
      else {
        $moved_by_which{ $entry->{which} // '' }++;
      }
    }

    $dbh->commit if $started_txn;
    1;
  };

  if ( !$ok ) {
    my $error = $@ || 'unknown delete queue DB transaction error';
    eval { $dbh->rollback if $started_txn };
    die $error;
  }

  return {
          ok                    => @problem ? 0 : 1,
          moved                 => scalar @moved,
          moved_stale_completed => $moved_stale_completed,
          moved_by_which        => \%moved_by_which,
          rows                  => \@moved,
          problems              => \@problem,};
}

sub _copy_add_candidate_keeper_to_torrent_pool ( $self, %arg ) {
  my $db           = $arg{db};
  my $dbh          = $arg{dbh};
  my $keeper       = $arg{keeper};
  my $torrent_pool = $arg{torrent_pool};
  my $which        = $arg{which};

  return { ok => 1, copied => 0, existing => 0 }
      if !defined $torrent_pool || $torrent_pool eq '';

  # The torrent pool is an add/re-add source. Properly loaded current qBT
  # keepers do not need a pool copy here, but hash-as-name repair candidates
  # are allowed into the pool.
  return { ok => 1, copied => 0, existing => 0 }
      if $keeper->{current_qbt};

  my $source = $keeper->{path};

  return {
          ok      => 0,
          problem => {
                      which => 'torrent_pool',
                      path  => $source,
                      hash  => $keeper->{hash},
                      error => 'add-candidate keeper has no readable source path',
          },
  } if !defined $source || !-f $source;

  my $target = $self->_torrent_pool_copy_target(
    db           => $db,
    dbh          => $dbh,
    torrent_pool => $torrent_pool,
    keeper       => $keeper,
  );

  if ( !$target->{ok} ) {
    return {
            ok      => 0,
            problem => {
                        which => 'torrent_pool',
                        path  => $source,
                        hash  => $keeper->{hash},
                        target => $target->{target},
                        error => $target->{problem}
                          // 'could not choose torrent pool target',
            },
    };
  }

  return { ok => 1, copied => 0, existing => 1, target => $target->{target} }
      if $target->{existing};

  my $written = $self->_write_torrent_pool_copy(
    source => $source,
    target => $target->{target},
    keeper => $keeper,
    which  => $which,
  );

  if ( !$written->{ok} ) {
    return {
            ok      => 0,
            problem => {
                        which  => 'torrent_pool',
                        path   => $source,
                        hash   => $keeper->{hash},
                        target => $target->{target},
                        error  => $written->{problem}
                          // 'write torrent pool copy failed',
            },
    };
  }

  my $stored = $self->_store_torrent_file( $db, $dbh, $target->{target},
'torrent_pool' );

  if ( !$stored->{ok} || !$stored->{parse_ok} ) {
    return {
            ok      => 0,
            problem => {
                        which  => 'torrent_pool',
                        path   => $target->{target},
                        hash   => $keeper->{hash},
                        error  => $stored->{problem}
                          // 'torrent pool copy did not parse after write',
            },
    };
  }

  if ( ( $stored->{hash} // '' ) ne ( $keeper->{hash} // '' ) ) {
    return {
            ok      => 0,
            problem => {
                        which         => 'torrent_pool',
                        path          => $target->{target},
                        hash          => $keeper->{hash},
                        existing_hash => $stored->{hash},
                        error         => 'torrent pool copy hash mismatch after
write',
            },
    };
  }

  return {
          ok       => 1,
          copied   => 1,
          existing => 0,
          target   => $target->{target},
  };
}

sub _hydrate_copy_keeper ( $self, %arg ) {
  my $db     = $arg{db};
  my $dbh    = $arg{dbh};
  my $hash   = $arg{hash} // '';
  my $keeper = $arg{keeper};
  my $name   = $arg{name};

  return {ok => 0, problem => 'copy keeper hydration requires keeper'}
      if ref $keeper ne 'HASH';

  $hash = $keeper->{hash} // '' if !length $hash;

  return {ok => 0, problem => 'copy keeper hydration requires hash'}
      if !length $hash;

  my @candidate = ( $keeper, @{ $db->torrent_copy_candidates_for_hash(
    $dbh,
    $hash,
  ) // [] } );

  my %path_seen;
  my @validated;

  for my $candidate (@candidate) {
    next if ref $candidate ne 'HASH';

    my $path = $candidate->{path};
    next if !defined $path || $path eq '' || $path_seen{$path}++ || !-f $path;

    my $verified = $self->_store_torrent_file(
      $db,
      $dbh,
      $path,
      $arg{backend} // 'copy_keeper',
      force_parse => 1,
    );

    next if !$verified->{parse_ok};
    next if ( $verified->{hash} // '' ) ne $hash;
    next if !defined $verified->{announce} || !length $verified->{announce};

    $verified->{torrent_name} //= $name;
    $verified->{copy_source_last_resort} =
        $path =~ m{(?:\A|/)BT_backup(?:/|\z)} ? 1 : 0;

    push @validated, $verified;
  }

  return {
          ok      => 0,
          problem => 'no validated physical copy keeper contains tracker metadata',
          keeper  => $keeper,
         }
      if !@validated;

  @validated = sort {
         ( $a->{copy_source_last_resort} // 0 )
      <=> ( $b->{copy_source_last_resort} // 0 )
      || ( $a->{path} // '' ) cmp ( $b->{path} // '' )
  } @validated;

  return {ok => 1, keeper => $validated[0]};
}

sub _hydrate_bucket_keepers ( $self, %arg ) {
  my $db     = $arg{db};
  my $dbh    = $arg{dbh};
  my $bucket = $arg{bucket};
  my $name   = $arg{qbt_name_by_hash} // {};

  my @problem;

  for my $hash ( sort keys %{ $bucket->{keeper_by_hash} // {} } ) {
    my $hydrated = $self->_hydrate_copy_keeper(
      db      => $db,
      dbh     => $dbh,
      hash    => $hash,
      keeper  => $bucket->{keeper_by_hash}{$hash},
      name    => $name->{$hash},
      backend => $bucket->{which} // 'copy_keeper',
    );

    if ( !$hydrated->{ok} ) {
      push @problem,
          {
           which => $bucket->{which},
           path  => $bucket->{keeper_by_hash}{$hash}{path},
           hash  => $hash,
           error => $hydrated->{problem},
          };
      next;
    }

    $bucket->{keeper_by_hash}{$hash} = $hydrated->{keeper};
  }

  return {ok => @problem ? 0 : 1, problems => \@problem};
}

sub _copy_target_for_torrent ( $self, %arg ) {
  my $db      = $arg{db};
  my $dbh     = $arg{dbh};
  my $dir     = $arg{dir};
  my $torrent = $arg{torrent};
  my $base    = $arg{base};

  my $hash = $torrent->{hash};
  my $target = File::Spec->catfile( $dir, $base . '.torrent' );

  if ( !-e $target ) {
    return {ok => 1, target => $target, already_present => 0};
  }

  my $existing = $self->_store_torrent_file( $db, $dbh, $target, 'export_dir' );

  if ( $existing->{parse_ok} && ( $existing->{hash} // '' ) eq $hash ) {
    return {
            ok              => 1,
            target          => $target,
            already_present => 1,
            existing        => $existing,};
  }

my $averted_base = $self->_collision_avert_tracker(
  $torrent->{announce},
  $base,
);



  if ( !length $averted_base ) {
    return {
            ok      => 0,
            problem => {
                        which         => 'export_dir',
                        path          => $target,
                        hash          => $hash,
                        name          => $torrent->{torrent_name},
                        existing_hash => $existing->{hash},
                        collision_kind => 'tracker_prepend_no_data',
                        error         =>
                        'Unable to avoid collision via tracker prepend. '
                        . 'Tracker parser returned no data.'
                      },
          };
  }

  my $averted_target = File::Spec->catfile( $dir, $averted_base . '.torrent' );

  if ( !-e $averted_target ) {
    return {ok => 1, target => $averted_target, already_present => 0};
  }

  my $averted_existing =
      $self->_store_torrent_file( $db, $dbh, $averted_target, 'export_dir' );

  if ( $averted_existing->{parse_ok} && ( $averted_existing->{hash} // '' ) eq
$hash ) {
    return {
            ok              => 1,
            target          => $averted_target,
            already_present => 1,
            existing        => $averted_existing,};
  }

  return {
          ok      => 0,
          problem => {
                      which         => 'export_dir',
                      path          => $averted_target,
                      hash          => $hash,
                      name          => $torrent->{torrent_name},
                      existing_hash => $averted_existing->{hash},
                      error         => ( $torrent->{torrent_name} // $hash )
          . ' uncoded collision type occurred. # TODO (averted_existing)',
          },
        };
}

sub _copy_completed_to_downloaded ( $self, %arg ) {
  my $db                = $arg{db};
  my $dbh               = $arg{dbh};
  my $downloaded_bucket = $arg{downloaded_bucket};
  my $completed_bucket  = $arg{completed_bucket};
  my $qbt_name_by_hash  = $arg{qbt_name_by_hash} // {};

  my @problem;
  my @copied;
  my @copied_pending_db;

  my $downloaded_dir = $downloaded_bucket->{directory};

  return {
          ok       => 1,
          copied   => 0,
          rows     => \@copied,
          problems => \@problem,
         }
      if !defined $downloaded_dir || $downloaded_dir eq '' || !-d $downloaded_dir;

  for my $expected_hash ( sort keys %{ $completed_bucket->{keeper_by_hash} // {} } )
{
    next if exists $downloaded_bucket->{keeper_by_hash}{$expected_hash};

    my $keeper = $completed_bucket->{keeper_by_hash}{$expected_hash};
    my $source = $keeper->{path};

    if ( !defined $source || !-f $source ) {
      push @problem,
          {
           which => 'export_dir',
           path  => $source,
           hash  => $expected_hash,
           error => 'completed keeper missing; cannot copy to downloaded',
          };
      next;
    }

    my $hydrated = $self->_hydrate_copy_keeper(
      db      => $db,
      dbh     => $dbh,
      hash    => $expected_hash,
      keeper  => $keeper,
      name    => $qbt_name_by_hash->{$expected_hash},
      backend => 'export_dir_fin',
    );

    if ( !$hydrated->{ok} ) {
      push @problem,
          {
           which => 'export_dir_fin',
           path  => $source,
           hash  => $expected_hash,
           error => $hydrated->{problem},
          };
      next;
    }

    my $verified = $hydrated->{keeper};

    my $actual_hash =
        defined $verified->{hash} && length $verified->{hash}
        ? $verified->{hash}
        : '(none)';

    if ( !$verified->{parse_ok} || $actual_hash ne $expected_hash ) {
      push @problem,
          {
           which         => 'export_dir_fin',
           path          => $source,
           hash          => $expected_hash,
           expected_hash => $expected_hash,
           actual_hash   => $actual_hash,
           parse_ok      => $verified->{parse_ok} ? 1 : 0,
           parse_problem => $verified->{problem} // '(none)',
           action        => 'copy to Downloaded_torrents skipped',
           error         => 'Completed_torrents source hash mismatch',
          };
      next;
    }

    my $hash = $verified->{hash};

    my $base = $self->_safe_basename(
      $qbt_name_by_hash->{$hash}
          // $verified->{torrent_name}
          // $self->_torrent_basename($source)
          // $hash
    );
    $base = $hash if !length $base;

    my $target_result = $self->_copy_target_for_torrent(
      db      => $db,
      dbh     => $dbh,
      dir     => $downloaded_dir,
      torrent => $verified,
      base    => $base,
    );

    if ( !$target_result->{ok} ) {
      push @problem, $target_result->{problem};
      next;
    }

    if ( $target_result->{already_present} ) {
      $downloaded_bucket->{keeper_by_hash}{$hash} =
          $target_result->{existing} // $verified;
      next;
    }

    my $target = $target_result->{target};

    if ( !copy( $source, $target ) ) {
      push @problem,
          {
           which => 'export_dir',
           path  => $source,
           hash  => $hash,
           error => "copy completed to downloaded failed: $!",
          };
      next;
    }

    push @copied_pending_db,
        {
         hash     => $hash,
         old_path => $source,
         new_path => $target,
        };
  }

  my $started_txn = 0;

  my $ok = eval {
    if ( $dbh->{AutoCommit} ) {
      $dbh->begin_work;
      $started_txn = 1;
    }

    for my $copy (@copied_pending_db) {
      my $hash   = $copy->{hash};
      my $source = $copy->{old_path};
      my $target = $copy->{new_path};

      my $stored = $self->_store_torrent_file( $db, $dbh, $target, 'export_dir' );

      if ( !$stored->{parse_ok} || !$stored->{hash} || $stored->{hash} ne $hash ) {
        my $actual_target_hash =
            defined $stored->{hash} && length $stored->{hash}
            ? $stored->{hash}
            : '(none)';

        my $parse_ok      = $stored->{parse_ok} ? 1 : 0;
        my $parse_problem = $stored->{problem} // '(none)';

        push @problem,
            {
             which         => 'export_dir',
             path          => $target,
             source_path   => $source,
             hash          => $hash,
             expected_hash => $hash,
             actual_hash   => $actual_target_hash,
             parse_ok      => $parse_ok,
             parse_problem => $parse_problem,
             action        => 'copied Completed_torrents keeper to
Downloaded_torrents;'
                            . ' copied file left in place for inspection',
             error         => 'copied completed torrent verification failed',
            };
        next;
      }

      $db->update_qbt_export_dir_file_state(
          $dbh,
          which  => 'export_dir',
          hash   => $hash,
          name   => $stored->{torrent_name},
          exists => 1,
        );

      $downloaded_bucket->{keeper_by_hash}{$hash} = $stored;

      push @copied,
          {
           hash     => $hash,
           old_path => $source,
           new_path => $target,
          };
    }

    $dbh->commit if $started_txn;
    1;
  };

  if ( !$ok ) {
    my $error = $@ || 'unknown completed-to-downloaded DB transaction error';
    eval { $dbh->rollback if $started_txn };
    die $error;
  }

  return {
          ok       => @problem ? 0 : 1,
          copied   => scalar @copied,
          rows     => \@copied,
          problems => \@problem,
         };
}

sub db_process ( $self ) {
  return $self->{db_process};
}

sub _dedupe_bucket ( $self, %arg ) {
  my $db        = $arg{db};
  my $dbh       = $arg{dbh};
  my $which     = $arg{which};
  my $dir       = $arg{dir};
  my $queue_dir         = $arg{queue_dir};
  my $torrent_pool     = $arg{torrent_pool};
  my $qbt_name_by_hash = $arg{qbt_name_by_hash} // {};

  my @problem;

  my $result = {
                ok               => 1,
                which            => $which,
                directory        => $dir,
                scanned          => 0,
                stored           => 0,
                from_db          => 0,
                parsed           => 0,
                parse_problems   => 0,
                hashes           => 0,
                duplicate_groups => 0,
                kept             => 0,
                moved                 => 0,
                renamed               => 0,
                rename_not_needed     => 0,
                rename_candidates     => 0,
                rename_target_exists  => 0,
                rename_target_same_hash => 0,
                rename_target_other_hash => 0,
                rename_target_already_averted => 0,
                rename_target_unknown => 0,
                rename_tracker_prefix_groups => 0,
                rename_tracker_prefixed => 0,
                rename_tracker_prefix_unresolved => 0,
                rename_already_named  => 0,
                rename_target_collision_samples => [],
                torrent_pool_copied_add_candidates => 0,
                torrent_pool_existing_add_candidates => 0,
                keeper_by_hash        => {},
                delete_queue          => [],
                problems              => \@problem,};

  if ( !defined $dir || $dir eq '' ) {
    push @problem,
        {
       which => $which,
       path  => undef,
       error => "qBT preference $which is not stored; run qbtl qbt preferences",
        };

    $result->{ok} = 0;
    return $result;
  }

  if ( !-d $dir ) {
    push @problem,
        {
         which => $which,
         path  => $dir,
         error => 'export directory does not exist',};

    $result->{ok} = 0;
    return $result;
  }

my ( $torrent_files, $meta_basenames ) = $self->_directory_inventory( $dir );

$result->{scanned} = scalar @{$torrent_files};

my %group;

my $ok = eval {
  $dbh->begin_work if $dbh->{AutoCommit};

  $db->reset_qbt_export_dir_file_state( $dbh, which => $which );

  for my $path ( @{$torrent_files} ) {
    my $stored = $self->_store_torrent_file( $db, $dbh, $path, $which );

    $result->{stored}++  if $stored->{stored};
    $result->{from_db}++ if $stored->{from_db};

    if ( !$stored->{parse_ok} || !$stored->{hash} ) {
      $result->{parse_problems}++;
      push @problem,
          {
           which => $which,
           path  => $path,
           error => $stored->{problem} // 'torrent parse failed',};
      next;
    }

    $result->{parsed}++ if $stored->{parsed};

    if ( exists $qbt_name_by_hash->{ $stored->{hash} } ) {
      $stored->{current_qbt} = 1;
      $stored->{qbt_name}    = $qbt_name_by_hash->{ $stored->{hash} };
    }
    else {
      $stored->{current_qbt} = 0;
      $stored->{qbt_name}    = undef;
    }

    push @{$group{$stored->{hash}}}, $stored;
  }

  # After begin_work, DBI sets AutoCommit false until commit/rollback,
  # so that condition is intentional.
  $dbh->commit if !$dbh->{AutoCommit};
  1;
};

if ( !$ok ) {
  my $error = $@ || 'unknown export bucket store transaction error';
  eval { $dbh->rollback if !$dbh->{AutoCommit} };
  die $error;
}

  $result->{hashes} = scalar keys %group;

  my @planned;
  my @keeper_state_pending_db;

  for my $hash ( sort keys %group ) {
    my @items = sort { $a->{path} cmp $b->{path} } @{ $group{$hash} };

    my $keeper = $self->_choose_keeper(
      dir            => $dir,
      meta_basenames => $meta_basenames,
      items          => \@items,
    );

    $result->{duplicate_groups}++ if @items > 1;

    push @planned,
        {
          hash   => $hash,
          items  => \@items,
          keeper => $keeper,
        };
  }

  $self->_apply_tracker_prefix_collision_plan(
    planned => \@planned,
    result  => $result,
  );

  HASH:
for my $plan (@planned) {
  my $hash   = $plan->{hash};
  my @items  = @{ $plan->{items} };
  my $keeper = $plan->{keeper};

  my $keeper_original_path = $keeper->{path};

  my $rename = $self->_rename_keeper(
    db            => $db,
    dbh           => $dbh,
    dir           => $dir,
    keeper        => $keeper,
    which         => $which,
    should_rename => $keeper->{should_rename} // 0,
  );

  if ( $rename->{not_needed} ) {
    $result->{rename_not_needed}++;
  }

  if ( $rename->{candidate} ) {
    $result->{rename_candidates}++;
  }

  if ( ( $rename->{reason} // '' ) eq 'already named' ) {
    $result->{rename_already_named}++;
  }

  if ( ( $rename->{reason} // '' ) eq 'rename target exists' ) {
    $result->{rename_target_exists}++;

    if ( ( $rename->{target_classification} // '' ) eq 'same_hash' ) {
      $result->{rename_target_same_hash}++;
    }
    elsif ( ( $rename->{target_classification} // '' ) eq 'other_hash' ) {
      if ( $rename->{collision_already_averted} ) {
        $result->{rename_target_already_averted}++;
      }
      else {
        $result->{rename_target_other_hash}++;

        if ( @{ $result->{rename_target_collision_samples} } < 25 ) {
          push @{ $result->{rename_target_collision_samples} },
              {
               which               => $which,
               hash                => $keeper->{hash},
               path                => $keeper->{path},
               target              => $rename->{target},
               target_hash         => $rename->{target_hash},
               desired_base        => $keeper->{desired_base},
               desired_name_source => $keeper->{desired_name_source},
               action              => 'TODO different-hash filename collision',
              };
        }
      }
    }
    else {
      $result->{rename_target_unknown}++;
    }
  }

  if ( !$rename->{ok} ) {
    push @problem, $rename->{problem};
    next HASH;
  }

  if ( $rename->{renamed} ) {
    $result->{renamed}++;
    $keeper->{path} = $rename->{new_path};
  }

  for my $item ( @items ) {
    next if $item->{path} eq $keeper_original_path;
    next if $item->{path} eq $keeper->{path};

    my $queued = $self->_queue_duplicate_for_deletion(
      db    => $db,
      dbh   => $dbh,
      item  => $item,
      which => $which,
      kind  => 'duplicate_torrent_file',
    );

    if ( !$queued->{ok} ) {
      push @problem, $queued->{problem};
      next;
    }

    push @{ $result->{delete_queue} }, $queued->{entry};
  }

  push @keeper_state_pending_db,
    {
      which => $which,
      hash  => $hash,
      name  => $keeper->{torrent_name},
    };

$result->{keeper_by_hash}{$hash} = $keeper;
$result->{kept}++;

  $result->{keeper_by_hash}{$hash} = $keeper;
  $result->{kept}++;

  my $pool_copy = $self->_copy_add_candidate_keeper_to_torrent_pool(
    db           => $db,
    dbh          => $dbh,
    keeper       => $keeper,
    torrent_pool => $torrent_pool,
    which        => $which,
  );

  if ( !$pool_copy->{ok} ) {
    push @problem, $pool_copy->{problem};
  }
  elsif ( $pool_copy->{copied} ) {
    $result->{torrent_pool_copied_add_candidates}++;
  }
  elsif ( $pool_copy->{existing} ) {
    $result->{torrent_pool_existing_add_candidates}++;
  }

}

  my $started_txn = 0;

  my $ok = eval {
    if ( $dbh->{AutoCommit} ) {
      $dbh->begin_work;
      $started_txn = 1;
    }

    for my $row (@keeper_state_pending_db) {
      $db->update_qbt_export_dir_file_state(
        $dbh,
        which  => $row->{which},
        hash   => $row->{hash},
        name   => $row->{name},
        exists => 1,
      );
    }

    $dbh->commit if $started_txn;
    1;
  };

  if ( !$ok ) {
    my $error = $@ || 'unknown keeper state transaction error';
    eval { $dbh->rollback if $started_txn };
    die $error;
  }

  $result->{ok} = @problem ? 0 : 1;

  return $result;
}

sub _directory_inventory ( $self, $dir ) {
  opendir my $dh, $dir or die "opendir $dir: $!";

  my @torrent;
  my %meta;

  while ( defined( my $entry = readdir $dh ) ) {
    next if $entry eq '.' || $entry eq '..';

    my $name =
        utf8::is_utf8( $entry )
        ? $entry
        : decode( 'UTF-8', $entry, FB_DEFAULT );

    if ( $name =~ /\.torrent\z/ ) {
      push @torrent, File::Spec->catfile( $dir, $name );
      next;
    }

    if ( my ( $base ) = $name =~ /\A(.+)\.meta\z/ ) {
      $meta{$base} = 1;
      next;
    }
  }

  closedir $dh;

  return ( [ sort @torrent ], \%meta );
}

sub _ensure_torrent_pool_dir ( $self, $dir ) {
  my @problem;

  if ( !defined $dir || $dir eq '' ) {
    return {
            ok       => 0,
            path     => $dir,
            created  => 0,
            existing => 0,
            problems => [
                          {
                           which => 'torrent_pool',
                           path  => $dir,
                           error => 'torrent pool path is not configured',
                          },
            ],};
  }

  if ( -d $dir ) {
    return {
            ok       => 1,
            path     => $dir,
            created  => 0,
            existing => 1,
            problems => \@problem,};
  }

  if ( -e $dir ) {
    return {
            ok       => 0,
            path     => $dir,
            created  => 0,
            existing => 0,
            problems => [
                          {
                           which => 'torrent_pool',
                           path  => $dir,
                           error => 'torrent pool path exists but is not a
directory',
                          },
            ],};
  }

  eval { make_path($dir); 1 } or do {
    my $error = $@ || $! || 'unknown error';
    chomp $error;

    return {
            ok       => 0,
            path     => $dir,
            created  => 0,
            existing => 0,
            problems => [
                          {
                           which => 'torrent_pool',
                           path  => $dir,
                           error => "create torrent pool failed: $error",
                          },
            ],};
  };

  return {
          ok       => 1,
          path     => $dir,
          created  => 1,
          existing => 0,
          problems => \@problem,};
}

sub _finalize_bucket_counts ( $self, $bucket ) {
  return if ref $bucket ne 'HASH';

  my $keeper_by_hash = $bucket->{keeper_by_hash} // {};
  my $final_count    = scalar keys %{$keeper_by_hash};

  $bucket->{scanned} = $final_count;
  $bucket->{hashes}  = $final_count;
  $bucket->{kept}    = $final_count;

  return;
}

sub _move_stale_completed ( $self, %arg ) {
  my $db                 = $arg{db};
  my $dbh                = $arg{dbh};
  my $completed_bucket   = $arg{completed_bucket};
  my $current_completed  = $arg{current_completed} // {};

  my @problem;
  my @delete_queue;

  for my $hash ( sort keys %{ $completed_bucket->{keeper_by_hash} // {} } ) {
    next if $current_completed->{$hash};

    my $keeper = $completed_bucket->{keeper_by_hash}{$hash};

    my $queued = $self->_queue_duplicate_for_deletion(
      db    => $db,
      dbh   => $dbh,
      item  => $keeper,
      which => 'export_dir_fin',
      kind  => 'stale_completed',
    );

    if ( !$queued->{ok} ) {
      push @problem, $queued->{problem};
      next;
    }

    $db->update_qbt_export_dir_file_state(
                                            $dbh,
                                            which  => 'export_dir_fin',
                                            hash   => $hash,
                                            name   => $keeper->{torrent_name},
                                            exists => 1,
                                          );

    push @delete_queue, $queued->{entry};

    # This keeper no longer belongs to export_dir_fin. It has been queued for
    # deletion, so later phases such as metadata infill must not try to process
    # the old Completed_torrents path as a live keeper.
    delete $completed_bucket->{keeper_by_hash}{$hash};
  }

  return {
          ok           => @problem ? 0 : 1,
          delete_queue => \@delete_queue,
          queued       => scalar @delete_queue,
          problems     => \@problem,};
}

sub _normalize_torrent_name ( $self, $name ) {
  $name //= '';
  $name = $self->_repair_mojibake_utf8($name);
  $name = basename($name);

  $name =~ s/\.torrent\z//i;
  $name =~ s/\A\s+//;
  $name =~ s/\s+\z//;
  $name =~ s/[\x00-\x1f]+/ /g;
  $name =~ s{[/:]+}{ - }g;
  $name =~ s/\s+/ /g;
  $name =~ s/\A[.\s]+//;
  $name =~ s/[.\s]+\z//;

  return length $name ? $name : 'unnamed';
}

sub _numeric_suffix_path ( $self, %arg ) {
  my $dir  = $arg{dir}  // die 'numeric suffix path requires dir';
  my $base = $arg{base} // die 'numeric suffix path requires base';

  $base = $self->_repair_mojibake_utf8($base);

  my ( $stem, $suffix ) =
      $base =~ /\A(.+?)(\.torrent)\z/i ? ( $1, $2 ) : ( $base, '' );

  for my $n ( 1 .. 10_000 ) {
    my $candidate_base = $n == 1 ? $base : $stem . '-' . $n . $suffix;
    my $candidate      = File::Spec->catfile( $dir, $candidate_base );

    next if -e $candidate;
    return $candidate;
  }

  die "could not choose unique torrent write target for $base";
}

sub parser ( $self ) {
  return $self->{parser};
}

sub _queue_dir ( $self, $installation_root, $db ) {
  if ( defined $installation_root && length $installation_root ) {
    return File::Spec->catdir( $installation_root, 'queued_for_deletion' );
  }

  my $db_path = $db->{db_path} // '';
  my $root    = dirname( $db_path );

  return File::Spec->catdir( $root, 'queued_for_deletion' );
}

sub _queue_duplicate_for_deletion ( $self, %arg ) {
  my $db    = $arg{db};
  my $dbh   = $arg{dbh};
  my $item  = $arg{item};
  my $which = $arg{which};
  my $kind  = $arg{kind} // 'duplicate_torrent_file';

  my $old_path = $item->{path};

  my $stored = $self->_store_torrent_file(
    $db,
    $dbh,
    $old_path,
    $which,
    force_parse => 0,
  );

  if ( !$stored->{ok} || !$stored->{parse_ok} ) {
    return {
      ok      => 0,
      problem => {
        which => $which,
        path  => $old_path,
        hash  => $item->{hash},
        error => 'duplicate metadata was not promoted;'
                .'refused to queue/cull duplicate',
      },
    };
  }

  if (    defined $item->{hash}
       && length $item->{hash}
       && defined $stored->{hash}
       && length $stored->{hash}
       && $stored->{hash} ne $item->{hash} )
  {
    return {
      ok      => 0,
      problem => {
        which         => $which,
        path          => $old_path,
        hash          => $item->{hash},
        existing_hash => $stored->{hash},
        error         => 'duplicate metadata hash mismatch;'
                        .'refused to queue/cull duplicate',
      },
    };
  }

  return {
          ok    => 1,
          entry => {
            kind        => $kind,
            which       => $which,
            source_path => $old_path,
            hash        => $stored->{hash} // $item->{hash} // '',
            basename    => $self->_torrent_metadata_base(
              {
                %{$item},
                hash          => $stored->{hash} // $item->{hash},
                torrent_name  => $stored->{torrent_name} // $item->{torrent_name},
                path          => $old_path,
              }
            ),
          },
        };
}

sub _rename_keeper ( $self, %arg ) {
  my $db            = $arg{db};
  my $dbh           = $arg{dbh};
  my $dir           = $arg{dir};
  my $keeper        = $arg{keeper};
  my $which         = $arg{which};
  my $should_rename = $arg{should_rename};

  return {
          ok         => 1,
          renamed    => 0,
          candidate  => 0,
          not_needed => 1,
          reason     => 'not needed',
  } if !$should_rename;

  my $desired_base = $keeper->{desired_base}
      // $self->_torrent_basename( $keeper->{path} );
  my $desired_name = $desired_base . '.torrent';
  my $new_path     = File::Spec->catfile( $dir, $desired_name );
  my $old_path     = $keeper->{path};

  return {
        ok        => 1,
        renamed   => 0,
        candidate => 1,
        old_path  => $old_path,
        new_path  => $old_path,
        reason    => 'already named',}
    if $old_path eq $new_path;

if ( -e $new_path ) {
  my $target = $self->_store_torrent_file( $db, $dbh, $new_path, $which );
  my $target_hash = $target->{hash};

  my $classification =
        !$target->{parse_ok} || !defined $target_hash || $target_hash eq ''
      ? 'unknown'
      : $target_hash eq ( $keeper->{hash} // '' )
      ? 'same_hash'
      : 'other_hash';

  my $collision_averted_base = $self->_collision_avert_tracker(
    $keeper->{announce},
    $desired_base,
  );

  my $old_base = $self->_torrent_basename($old_path);
  my $collision_already_averted =
         $classification eq 'other_hash'
      && length $collision_averted_base
      && $old_base eq $collision_averted_base
      ? 1
      : 0;

  return {
          ok                    => 1,
          renamed               => 0,
          candidate             => 1,
          old_path              => $old_path,
          new_path              => $old_path,
          target                => $new_path,
          target_hash           => $target_hash,
          target_parse_ok       => $target->{parse_ok} ? 1 : 0,
          target_classification => $classification,
          collision_already_averted => $collision_already_averted,
          reason                => 'rename target exists',};
}

  if ( !move( $old_path, $new_path ) ) {
    return {
            ok      => 0,
            problem => {
                        which => $which,
                        path  => $old_path,
                        error => "keeper rename failed: $!",
            },
    };
  }

  my $updated = $db->update_local_torrent_file_path(
    $dbh,
    old_path => $old_path,
    new_path => $new_path,
  );

  return {
        ok        => $updated->{ok},
        renamed   => 1,
        candidate => 1,
        old_path  => $old_path,
        new_path  => $new_path,
        };
}

sub _repair_mojibake_utf8 ( $self, $value ) {
  return $value if !defined $value;

  # Some torrent metadata/path values arrive as UTF-8 bytes that were decoded
  # as Latin-1-ish characters.  On macOS that can later become an illegal byte
  # sequence when we use the value as a filesystem path.
  #
  # Try to round-trip those characters back through Latin-1 bytes and decode
  # them as real UTF-8.  If it is not that kind of string, leave it alone.
  return $value
      if $value !~ /[\x80-\xff]/;

  my $fixed = eval {
    decode( 'UTF-8', encode( 'ISO-8859-1', $value, FB_CROAK ), FB_CROAK );
  };

  return defined $fixed ? $fixed : $value;
}

sub _restore_current_qbt_from_bt_backup ( $self, %arg ) {
  my $db                = $arg{db};
  my $dbh               = $arg{dbh};
  my $downloaded_bucket = $arg{downloaded_bucket};
  my $hash              = $arg{hash};
  my $name              = $arg{name};

  my $downloaded_dir = $downloaded_bucket->{directory};
  return {ok => 0, restored => 0}
      if !defined $downloaded_dir || $downloaded_dir eq '' || !-d $downloaded_dir;

  my $bt_backup_dir = $self->_bt_backup_dir;
  return {ok => 0, restored => 0}
      if $bt_backup_dir eq '' || !-d $bt_backup_dir;

  my $source = File::Spec->catfile( $bt_backup_dir, $hash . '.torrent' );
  return {ok => 0, restored => 0}
      if !-f $source;

  my $base = $self->_safe_basename( $name // $hash );
  $base = $hash if !length $base;

  my $stored = $self->_store_torrent_file(
    $db,
    $dbh,
    $source,
    'bt_backup_copy_source',
  );

  my $hydrated = $self->_hydrate_copy_keeper(
    db      => $db,
    dbh     => $dbh,
    hash    => $hash,
    keeper  => $stored,
    name    => $name,
    backend => 'bt_backup_copy_source',
  );

  return {
          ok       => 0,
          restored => 0,
          problem  => {
                       which => 'export_dir',
                       path  => $source,
                       hash  => $hash,
                       name  => $name,
                       error => $hydrated->{problem},
                      },
         }
      if !$hydrated->{ok};

  my $torrent = $hydrated->{keeper};
  $source = $torrent->{path};

  my $target_result = $self->_copy_target_for_torrent(
                                                       db      => $db,
                                                       dbh     => $dbh,
                                                       dir     => $downloaded_dir,
                                                       torrent => $torrent,
                                                       base    => $base, );

  return {
          ok       => 0,
          restored => 0,
          problem  => $target_result->{problem},}
      if !$target_result->{ok};

  if ( $target_result->{already_present} ) {
    $downloaded_bucket->{keeper_by_hash}{$hash} =
        $target_result->{existing} // {
                                      path         => $target_result->{target},
                                      hash         => $hash,
                                      torrent_name => $name,
                                      parse_ok     => 1,
                                     };

    return {
            ok              => 1,
            restored        => 0,
            already_present => 1,};
  }

  my $target = $target_result->{target};

  if ( !copy( $source, $target ) ) {
    return {
            ok       => 0,
            restored => 0,
            problem  => {
                         which => 'export_dir',
                         path  => $source,
                         hash  => $hash,
                         name  => $name,
                         error => "restore from BT_backup failed: $!",
            },};
  }

  my @stat = stat $target;

  my $recorded = $db->record_known_local_torrent_file(
                                                       $dbh,
                                                       path         => $target,
                                                       infohash     => $hash,
                                                       torrent_name => $name,
                                                       backend      =>
'qbt_bt_backup_restore',
                                                       size         => $stat[7],
                                                       mtime        => $stat[9], );

  if ( !$recorded->{ok} ) {
    return {
            ok       => 0,
            restored => 0,
            problem  => {
                         which => 'export_dir',
                         path  => $target,
                         hash  => $hash,
                         name  => $name,
                         error => 'restore from BT_backup copied file but failed to
record DB identity',
            },};
  }

  my $row = {
             path         => $target,
             hash         => $hash,
             torrent_name => $name,
             parse_ok     => 1,
             from_db      => 1,
             backend      => 'qbt_bt_backup_restore',};

  $downloaded_bucket->{keeper_by_hash}{$hash} = $row;

  $db->update_qbt_export_dir_file_state(
                                          $dbh,
                                          which  => 'export_dir',
                                          hash   => $hash,
                                          name   => $name,
                                          exists => $row->{exists},
                                        );

  return {
          ok       => 1,
          restored => 1,
          row      => {
                       which => 'export_dir',
                       hash  => $hash,
                       name  => $name,
                       error => $torrent->{copy_source_last_resort}
                           ? 'LAST RESORT: restored from BT_backup copy source'
                           : 'restored from validated non-BT_backup copy source',
                       source_path => $source,
                       path  => $target,
          },};
}

sub run ( $self, %arg ) {
  my $installation_root = $arg{installation_root};
  my $started = time;

  return $self->db_process->with_db(
    sub ( $db, $dbh ) {
      my $queue_dir = $self->_queue_dir( $installation_root, $db );
      make_path( $queue_dir ) if !-d $queue_dir;

      my $torrent_pool =
          $self->_torrent_pool_dir( $installation_root, $arg{torrent_pool}, $db );
      my $torrent_pool_result =
          $self->_ensure_torrent_pool_dir($torrent_pool);

      my $qbt_name_by_hash = $db->current_qbt_name_map( $dbh );

      my @bucket;
      my @problem = @{ $torrent_pool_result->{problems} // [] };

      for my $which ( qw( export_dir export_dir_fin ) ) {
        my $dir = $db->qbt_preference_value( $dbh, $which );

        my $result =
            $self->_dedupe_bucket(
                                   db        => $db,
                                   dbh       => $dbh,
                                   which            => $which,
                                   dir              => $dir,
                                   queue_dir        => $queue_dir,
                                   torrent_pool     => $torrent_pool,
                                   qbt_name_by_hash => $qbt_name_by_hash, );

        push @bucket,  $result;
        push @problem, @{$result->{problems} // []};
      }

      my %bucket_by_which = map { $_->{which} => $_ } @bucket;

      my $infill = $self->{metadata_process}->infill_known_exports(
        db      => $db,
        dbh     => $dbh,
        buckets => \@bucket,
      );

      push @problem, @{ $infill->{problems} // [] };

      for my $bucket (@bucket) {
        my $hydrated = $self->_hydrate_bucket_keepers(
          db               => $db,
          dbh              => $dbh,
          bucket           => $bucket,
          qbt_name_by_hash => $qbt_name_by_hash,
        );

        push @problem, @{ $hydrated->{problems} // [] };
      }

      my $completed_to_downloaded = $self->_copy_completed_to_downloaded(
        db                => $db,
        dbh               => $dbh,
        downloaded_bucket => $bucket_by_which{export_dir},
        completed_bucket  => $bucket_by_which{export_dir_fin},
        qbt_name_by_hash  => $qbt_name_by_hash,
      );
      push @problem, @{ $completed_to_downloaded->{problems} // [] };

      my $current_completed = $db->current_qbt_completed_hash_map( $dbh );
      my $stale_completed = $self->_move_stale_completed(
        db                => $db,
        dbh               => $dbh,
        completed_bucket  => $bucket_by_which{export_dir_fin},
        current_completed => $current_completed,
        queue_dir         => $queue_dir,
      );
      push @problem, @{ $stale_completed->{problems} // [] };

      my @delete_queue;
      for my $bucket (@bucket) {
        push @delete_queue, @{ $bucket->{delete_queue} // [] };
      }
      push @delete_queue, @{ $stale_completed->{delete_queue} // [] };

      my $delete_commit = $self->_commit_delete_queue(
        db        => $db,
        dbh       => $dbh,
        queue_dir => $queue_dir,
        queue     => \@delete_queue,
      );
      push @problem, @{ $delete_commit->{problems} // [] };

      my $moved_by_which = $delete_commit->{moved_by_which} // {};
      for my $bucket (@bucket) {
        my $which = $bucket->{which} // '';
        $bucket->{moved} += $moved_by_which->{$which} // 0;
      }

      my $current_missing = $self->_audit_current_qbt_downloaded(
        db                => $db,
        dbh               => $dbh,
        downloaded_bucket => $bucket_by_which{export_dir},
        completed_bucket  => $bucket_by_which{export_dir_fin},
        qbt_name_by_hash  => $qbt_name_by_hash,
      );
      push @problem, @{ $current_missing->{problems} // [] };

      my $completed_missing = $self->_audit_current_qbt_completed(
        db                => $db,
        dbh               => $dbh,
        downloaded_bucket => $bucket_by_which{export_dir},
        completed_bucket  => $bucket_by_which{export_dir_fin},
        qbt_name_by_hash  => $qbt_name_by_hash,
      );

      my $completed_copied = $completed_to_downloaded->{copied} // 0;
      my $bt_restored      = scalar @{ $current_missing->{restored} // [] };

      if ( $bucket_by_which{export_dir} ) {
        $bucket_by_which{export_dir}{stored} += $completed_copied + $bt_restored;
        $bucket_by_which{export_dir}{parsed} += $completed_copied;
        $self->_finalize_bucket_counts( $bucket_by_which{export_dir} );
      }

      if ( $bucket_by_which{export_dir_fin} ) {
        $self->_finalize_bucket_counts( $bucket_by_which{export_dir_fin} );
      }

      my $moved                 = $delete_commit->{moved_stale_completed} // 0;
      my $renamed               = 0;
      my $rename_not_needed     = 0;
      my $rename_candidates     = 0;
      my $rename_target_exists  = 0;
      my $rename_target_same_hash = 0;
      my $rename_target_other_hash = 0;
      my $rename_target_already_averted = 0;
      my $rename_target_unknown = 0;
      my $rename_tracker_prefix_groups = 0;
      my $rename_tracker_prefixed = 0;
      my $rename_tracker_prefix_unresolved = 0;
      my $rename_already_named  = 0;
      my $torrent_pool_copied_add_candidates = 0;
      my $torrent_pool_existing_add_candidates = 0;
      my @rename_target_collision_sample;
      my $kept                  = 0;

      for my $bucket ( @bucket ) {
        $moved                += $bucket->{moved}                // 0;
        $renamed              += $bucket->{renamed}              // 0;
        $rename_not_needed    += $bucket->{rename_not_needed}    // 0;
        $rename_candidates    += $bucket->{rename_candidates}    // 0;
        $rename_target_exists += $bucket->{rename_target_exists} // 0;
        $rename_target_same_hash += $bucket->{rename_target_same_hash} // 0;
        $rename_target_other_hash += $bucket->{rename_target_other_hash} // 0;
        $rename_target_already_averted +=
            $bucket->{rename_target_already_averted} // 0;
        $rename_target_unknown += $bucket->{rename_target_unknown} // 0;
        $rename_tracker_prefix_groups += $bucket->{rename_tracker_prefix_groups} //
0;
        $rename_tracker_prefixed += $bucket->{rename_tracker_prefixed} // 0;
        $rename_tracker_prefix_unresolved +=
          $bucket->{rename_tracker_prefix_unresolved} // 0;
        $rename_already_named += $bucket->{rename_already_named} // 0;
        $torrent_pool_copied_add_candidates +=
            $bucket->{torrent_pool_copied_add_candidates} // 0;
        $torrent_pool_existing_add_candidates +=
            $bucket->{torrent_pool_existing_add_candidates} // 0;

        for my $sample ( @{ $bucket->{rename_target_collision_samples} // [] } ) {
          last if @rename_target_collision_sample >= 25;
          push @rename_target_collision_sample, $sample;
        }

        $kept += $bucket->{kept} // 0;
      }

      return {
        ok => @problem
        || ( $current_missing->{count} // 0 )
        || ( $completed_missing->{count} // 0 )
        ? 0
        : 1,
        action                         => 'qbt_export_dedupe',
        queue_dir                      => $queue_dir,
        torrent_pool                   => $torrent_pool,
        torrent_pool_created => $torrent_pool_result->{created} // 0,
        torrent_pool_existing => $torrent_pool_result->{existing} // 0,
        torrent_pool_copied_add_candidates => $torrent_pool_copied_add_candidates,
        torrent_pool_existing_add_candidates =>
                $torrent_pool_existing_add_candidates,
        buckets                        => \@bucket,
        kept                           => $kept,
        moved                          => $moved,
        renamed                        => $renamed,
        rename_not_needed              => $rename_not_needed,
        rename_candidates              => $rename_candidates,
        rename_target_exists           => $rename_target_exists,
        rename_target_same_hash         => $rename_target_same_hash,
        rename_target_other_hash        => $rename_target_other_hash,
        rename_target_already_averted   => $rename_target_already_averted,
        rename_target_unknown           => $rename_target_unknown,
        rename_tracker_prefix_groups   => $rename_tracker_prefix_groups,
        rename_tracker_prefixed        => $rename_tracker_prefixed,
        rename_tracker_prefix_unresolved => $rename_tracker_prefix_unresolved,
        rename_already_named           => $rename_already_named,
        rename_target_collision_samples => \@rename_target_collision_sample,
        copied_completed_to_downloaded => $completed_copied,
        moved_stale_completed => $delete_commit->{moved_stale_completed} // 0,
        current_qbt_missing_downloaded => $current_missing->{count} // 0,
        current_qbt_missing_completed  => $completed_missing->{count} // 0,
        current_qbt_completed_missing_downloaded_available =>
            $completed_missing->{downloaded_available} // 0,
        current_qbt_completed_missing_downloaded_missing =>
            $completed_missing->{downloaded_missing} // 0,
        current_qbt_missing            => $current_missing->{missing} // [],
        current_qbt_completed_missing  => $completed_missing->{missing} // [],
        missing_export_todo_count      => $current_missing->{count} // 0,
        missing_completed_todo_count   => $completed_missing->{count} // 0,
        missing_completed_downloaded_available_todo_count =>
            $completed_missing->{downloaded_available} // 0,
        missing_completed_downloaded_missing_todo_count =>
            $completed_missing->{downloaded_missing} // 0,
        bt_backup_restored             => $bt_restored,
        infill                         => $infill,
        infilled_torrents              => $infill->{torrents} // 0,
        infilled_evidence_sources      => $infill->{evidence_sources} // 0,
        infilled_trackers              => $infill->{trackers} // 0,
        infilled_payload_files         => $infill->{payload_files} // 0,
        infilled_info_fields           => $infill->{info_fields} // 0,
        infilled_bt_backup_evidence    => $infill->{bt_backup_evidence} // 0,
        problems                       => \@problem,};
    } );
}

sub _safe_basename ( $self, $name ) {
  return '' if !defined $name;

  $name =~ s{/+}{_}g;
  $name =~ s{:}{_}g;
  $name =~ s{\A\s+}{};
  $name =~ s{\s+\z}{};
  $name =~ s{\s+}{ }g;

  return $name;
}

sub _store_torrent_file ( $self, $db, $dbh, $path, $backend, %arg ) {

  if ( !-f $path ) {
    return {
            ok           => 0,
            stored       => 0,
            parsed       => 0,
            from_db      => 0,
            path         => $path,
            hash         => undef,
            torrent_name => undef,
            announce     => undef,
            parse_ok     => 0,
            problem      => 'path does not exist',};
  }

  my @stat = stat $path;
  my $size = $stat[7] // 0;
  my $mtime = $stat[9] // 0;

  my $existing = $db->local_torrent_file_by_path( $dbh, $path );
  if (    !$arg{force_parse}
       && $existing
       && ( $existing->{parse_ok} // 0 )
       && defined $existing->{infohash}
       && length $existing->{infohash}
       && defined $existing->{size}
       && defined $existing->{mtime}
       && $existing->{size} == $size
       && $existing->{mtime} == $mtime )
  {
    return {
            ok           => 1,
            stored       => 0,
            parsed       => 0,
            from_db      => 1,
            path         => $path,
            hash         => $existing->{infohash},
            torrent_name => $existing->{torrent_name},
            announce     => $existing->{announce},
            parse_ok     => 1,
            problem      => undef,};
  }

  my $stored =
      $db->upsert_local_torrent_file(
                                      $dbh,
                                      {
                                       path    => $path,
                                       size    => $size,
                                       mtime   => $mtime,
                                       backend => 'qbt_' . $backend,
                                      }, );

  my $parse = $self->parser->parse_file( $path );

  my $effective_announce = $parse->{announce};
  if ( ( !defined $effective_announce || !length $effective_announce )
       && ref $parse->{trackers} eq 'ARRAY'
       && ref $parse->{trackers}[0] eq 'HASH' )
  {
    $effective_announce = $parse->{trackers}[0]{tracker_url};
  }

  my $parse_result =
      $db->update_local_torrent_parse(
                            $dbh,
                            {
                             path               => $path,
                             infohash           => $parse->{infohash},
                             torrent_name       => $parse->{torrent_name},
                             comment            => $parse->{comment},
                             announce           => $effective_announce,
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
                            }, );

  if ( $parse->{ok} && $parse->{infohash} ) {
    for my $key ( @{$parse->{observed_keys} // []} ) {
      $db->upsert_hash_value(
                              $dbh,
                              hash       => $parse->{infohash},
                              key        => $key->{key},
                              value      => $key->{value},
                              value_type => $key->{value_type} // 'text', );
    }
  }

  return {
          ok           => $stored->{ok} && $parse_result->{ok} ? 1 : 0,
          stored       => $stored->{ok}                        ? 1 : 0,
          parsed       => $parse->{ok}                         ? 1 : 0,
          from_db      => 0,
          path         => $path,
          hash         => $parse->{infohash} ? $parse->{infohash} : undef,
          torrent_name => $parse->{torrent_name},
          announce     => $effective_announce,
          parse_ok     => $parse->{ok} ? 1 : 0,
          problem      => $parse->{problem},};
}

sub _torrent_basename ( $self, $path ) {
  my $base = basename( $path );
  $base =~ s/\.torrent\z//;

  return $base;
}

sub _suffix_torrent_basename ( $self, $base, $n ) {
  return $base if $n <= 1;

  my ( $stem, $suffix ) =
      $base =~ /\A(.+?)(\.torrent)\z/i ? ( $1, $2 ) : ( $base, '' );

  return $stem . '-' . $n . $suffix;
}

sub _torrent_metadata_base ( $self, $torrent ) {
  my $name =
         $torrent->{torrent_name}
      // $torrent->{metadata_name}
      // $torrent->{name}
      // $torrent->{desired_base};

  if ( defined $name && length $name ) {
    $name = $self->_repair_mojibake_utf8($name);
  }
  else {
    $name = basename( $torrent->{path} // '' );
  }

  $name =~ s/\.torrent\z//i;

  return $self->_normalize_torrent_name($name) . '.torrent';
}

sub _torrent_pool_copy_target ( $self, %arg ) {
  my $torrent_pool = $arg{torrent_pool};
  my $keeper       = $arg{keeper};

  my $hash = $keeper->{hash} // '';
  my $base = basename( $keeper->{path} // '' );

  return {
          ok      => 0,
          problem => 'torrent pool copy requires keeper hash',
  } if $hash eq '';

  return {
          ok      => 0,
          problem => 'torrent pool copy requires keeper path',
  } if $base eq '';

  my $target = $self->_torrent_write_target(
    db      => $arg{db},
    dbh     => $arg{dbh},
    dir     => $torrent_pool,
    torrent => $keeper,
  );

  if ( -e $target ) {
    my $parse = $self->parser->parse_file($target);

    if ( $parse->{ok} && ( $parse->{infohash} // '' ) eq $hash ) {
      return {
              ok       => 1,
              target   => $target,
              existing => 1,
      };
    }

  }

  return {
          ok       => 1,
          target   => $target,
          existing => 0,
  };
}

sub _torrent_pool_dir ( $self, $installation_root, $configured_pool, $db ) {
  return $configured_pool
      if defined $configured_pool && length $configured_pool;

  if ( defined $installation_root && length $installation_root ) {
    return File::Spec->catdir( $installation_root, 'torrents' );
  }

  my $db_path = $db->{db_path} // '';
  my $root    = dirname( $db_path );

  return File::Spec->catdir( $root, 'torrents' );
}

sub _torrent_write_target ( $self, %arg ) {
  my $db      = $arg{db};
  my $dbh     = $arg{dbh};
  my $dir     = $arg{dir}     // die 'torrent write target requires dir';
  my $torrent = $arg{torrent} // die 'torrent write target requires torrent';

  my $base = $self->_torrent_metadata_base($torrent);

  return $self->_numeric_suffix_path(
    db   => $db,
    dbh  => $dbh,
    dir  => $dir,
    base => $base,
  );
}

# sub _tracker_tag ( $self, $torrent ) {
#   my $announce = $torrent->{announce} // '';
#
#   my ( $host ) = $announce =~ m{\A[a-z][a-z0-9+.-]*://([^/:?#]+)}i;
#   $host //= '';
#   $host =~ s/\Awww\.//i;
#
#   my @part = grep { length } split /\./, $host;
#   return '' if @part < 2;
#
#   my @candidate = reverse @part[ 0 .. $#part - 1 ];
#
#   for my $tag (@candidate) {
#     next if $tag =~ /\A(?:tracker|announce|udp|http|https|bt)\z/i;
#
#     $tag =~ s/[^A-Za-z0-9_-]+/_/g;
#     $tag =~ s/\A_+//;
#     $tag =~ s/_+\z//;
#
#     return $tag if length $tag;
#   }
#
#   return '';
# }

sub _unique_path ( $self, $dir, $filename ) {
  my $path = File::Spec->catfile( $dir, $filename );

  return $path if !-e $path;

  my ( $base, $suffix ) =
      $filename =~ /\A(.+?)(\.torrent)\z/
      ? ( $1, $2 )
      : ( $filename, '' );

  my $n = 2;

  while ( 1 ) {
    my $candidate = File::Spec->catfile( $dir, $base . '-' . $n . $suffix );

    return $candidate if !-e $candidate;

    $n++;
  }
}

sub _write_torrent_pool_copy ( $self, %arg ) {
  my $source = $arg{source};
  my $target = $arg{target};

  # Centralized writer hook:
  # when QBTL starts storing intentional dictionary overrides, such as a
  # rewritten comment, this is where the bencoded torrent should be written
  # with those overrides. Until an override exists, preserve source bytes.
  if ( !copy( $source, $target ) ) {
    return {
            ok      => 0,
            problem => "copy add-candidate keeper to torrent pool failed: $!",
    };
  }

  return {
          ok     => 1,
          target => $target,
  };
}

1;
