package QBTL::Process::QBT::ExportDedupe;

use v5.40;
use common::sense;
use feature qw( signatures );

use File::Basename qw( basename dirname );
use File::Copy     qw( copy move );
use File::Path     qw( make_path );
use File::Spec;
use Encode qw( decode FB_DEFAULT );

use QBTL::Local::Parser;
use QBTL::Process::QBT::ExportInfill;
use QBTL::Process::WithDB;

sub new ( $class, %arg ) {
  $arg{db_process} //= QBTL::Process::WithDB->new( db_path => $arg{db_path}, );
  $arg{parser}     //= QBTL::Local::Parser->new;
  $arg{infill_process} //= QBTL::Process::QBT::ExportInfill->new;

  return bless \%arg, $class;
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
                torrent_pool_copied_unused => 0,
                torrent_pool_existing_unused => 0,
                keeper_by_hash        => {},
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

  $db->reset_qbt_export_dir_file_state( $dbh, which => $which );

  my ( $torrent_files, $meta_basenames ) = $self->_directory_inventory( $dir );

  $result->{scanned} = scalar @{$torrent_files};

  my %group;

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

  $result->{hashes} = scalar keys %group;

  my @planned;

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

    my $move = $self->_move_duplicate(
      db        => $db,
      dbh       => $dbh,
      item      => $item,
      queue_dir => $queue_dir,
      which     => $which,
    );

    if ( !$move->{ok} ) {
      push @problem, $move->{problem};
      next;
    }

    $result->{moved}++;
  }

  $db->update_qbt_export_dir_file_state(
    $dbh,
    which  => $which,
    hash   => $hash,
    name   => $keeper->{torrent_name},
    exists => 1,
  );

  $result->{keeper_by_hash}{$hash} = $keeper;
  $result->{kept}++;

  my $pool_copy = $self->_copy_unused_keeper_to_torrent_pool(
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
    $result->{torrent_pool_copied_unused}++;
  }
  elsif ( $pool_copy->{existing} ) {
    $result->{torrent_pool_existing_unused}++;
  }

}

  $result->{ok} = @problem ? 0 : 1;

  return $result;
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
      my $prefixed_base = $self->_collision_averted_base( $keeper, $base );

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

  my $target = File::Spec->catfile( $torrent_pool, $base );

  if ( -e $target ) {
    my $parse = $self->parser->parse_file($target);

    if ( $parse->{ok} && ( $parse->{infohash} // '' ) eq $hash ) {
      return {
              ok       => 1,
              target   => $target,
              existing => 1,
      };
    }

    $target = File::Spec->catfile( $torrent_pool, $hash . '.torrent' );

    if ( -e $target ) {
      my $hash_parse = $self->parser->parse_file($target);

      if ( $hash_parse->{ok} && ( $hash_parse->{infohash} // '' ) eq $hash ) {
        return {
                ok       => 1,
                target   => $target,
                existing => 1,
        };
      }

      return {
              ok      => 0,
              target  => $target,
              problem => 'torrent pool fallback target exists with different or unreadable infohash',
      };
    }
  }

  return {
          ok       => 1,
          target   => $target,
          existing => 0,
  };
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
            problem => "copy unused keeper to torrent pool failed: $!",
    };
  }

  return {
          ok     => 1,
          target => $target,
  };
}


sub _copy_unused_keeper_to_torrent_pool ( $self, %arg ) {
  my $db           = $arg{db};
  my $dbh          = $arg{dbh};
  my $keeper       = $arg{keeper};
  my $torrent_pool = $arg{torrent_pool};
  my $which        = $arg{which};

  return { ok => 1, copied => 0, existing => 0 }
      if !defined $torrent_pool || $torrent_pool eq '';

  return { ok => 1, copied => 0, existing => 0 }
    if $current_qbt_hash->{$keeper->{hash}};

  my $source = $keeper->{path};

  return {
          ok      => 0,
          problem => {
                      which => 'torrent_pool',
                      path  => $source,
                      hash  => $keeper->{hash},
                      error => 'unused keeper has no readable source path',
          },
  } if !defined $source || !-f $source;

  my $target = $self->_torrent_pool_copy_target(
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

  my $stored = $self->_store_torrent_file( $db, $dbh, $target->{target}, 'torrent_pool' );

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
                        error         => 'torrent pool copy hash mismatch after write',
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


sub _move_duplicate ( $self, %arg ) {
  my $db        = $arg{db};
  my $dbh       = $arg{dbh};
  my $item      = $arg{item};
  my $queue_dir = $arg{queue_dir};
  my $which     = $arg{which};

  my $old_path = $item->{path};
  my $target   = $self->_unique_path( $queue_dir, basename( $old_path ) );

  my $stored = $self->_store_torrent_file(
    $db,
    $dbh,
    $old_path,
    $which,
    force_parse => 1,
  );

  if ( !$stored->{ok} || !$stored->{parse_ok} ) {
    return {
            ok      => 0,
            problem => {
                        which => $which,
                        path  => $old_path,
                        hash  => $item->{hash},
                        error => 'duplicate metadata was not promoted; refused to queue/cull duplicate',
            },};
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
                        error         => 'duplicate metadata hash mismatch; refused to queue/cull duplicate',
            },};
  }

  if ( !move( $old_path, $target ) ) {
    return {
            ok      => 0,
            problem => {
                        which => $which,
                        path  => $old_path,
                        error => "move to queued_for_deletion failed: $!",
            },};
  }

  my $updated = $db->cull_moved_duplicate_torrent_file(
    $dbh,
    old_path => $old_path,
    new_path => $target,
    hash     => $stored->{hash} // $item->{hash} // '',
  );

  if ( !$updated->{ok} ) {
    return {
            ok      => 0,
            problem => {
                        which => $which,
                        path  => $old_path,
                        hash  => $stored->{hash} // $item->{hash},
                        error => $updated->{problem}
                          // 'queued duplicate DB cleanup failed',
            },};
  }

  return {
          ok       => $updated->{ok},
          old_path => $old_path,
          new_path => $target,
          culled   => $updated->{deleted} // 0,
          };
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
                           error => 'torrent pool path exists but is not a directory',
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

  my $collision_averted_base = $self->_collision_averted_base(
    $keeper,
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

sub _tracker_tag ( $self, $torrent ) {
  my $announce = $torrent->{announce} // '';

  my ( $host ) = $announce =~ m{\A[a-z][a-z0-9+.-]*://([^/:?#]+)}i;
  $host //= '';
  $host =~ s/\Awww\.//i;

  my @part = grep { length } split /\./, $host;
  return '' if @part < 2;

  my $tag = $part[-2];
  $tag =~ s/[^A-Za-z0-9_-]+/_/g;
  $tag =~ s/\A_+//;
  $tag =~ s/_+\z//;

  return $tag;
}

sub _collision_averted_base ( $self, $torrent, $base ) {
  my $tag = $self->_tracker_tag( $torrent );
  return '' if !length $tag;

  return '[' . $tag . '] ' . $base;
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

  my $averted_base = $self->_collision_averted_base( $torrent, $base );

  if ( !length $averted_base ) {
    return {
            ok      => 0,
            problem => {
                        which         => 'export_dir',
                        path          => $target,
                        hash          => $hash,
                        name          => $torrent->{torrent_name},
                        existing_hash => $existing->{hash},
                        error         => ( $torrent->{torrent_name} // $hash )
                          . ' uncoded collision type occurred. # TODO',
            },};
  }

  my $averted_target = File::Spec->catfile( $dir, $averted_base . '.torrent' );

  if ( !-e $averted_target ) {
    return {ok => 1, target => $averted_target, already_present => 0};
  }

  my $averted_existing =
      $self->_store_torrent_file( $db, $dbh, $averted_target, 'export_dir' );

  if ( $averted_existing->{parse_ok} && ( $averted_existing->{hash} // '' ) eq $hash ) {
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
                        . ' uncoded collision type occurred. # TODO',
          },};
}

sub _copy_completed_to_downloaded ( $self, %arg ) {
  my $db                 = $arg{db};
  my $dbh                = $arg{dbh};
  my $downloaded_bucket  = $arg{downloaded_bucket};
  my $completed_bucket   = $arg{completed_bucket};
  my $qbt_name_by_hash   = $arg{qbt_name_by_hash} // {};

  my @problem;
  my @copied;
  my $downloaded_dir = $downloaded_bucket->{directory};

  return {
          ok       => 1,
          copied   => 0,
          rows     => \@copied,
          problems => \@problem,}
      if !defined $downloaded_dir || $downloaded_dir eq '' || !-d $downloaded_dir;

  for my $expected_hash ( sort keys %{ $completed_bucket->{keeper_by_hash} // {} } ) {
    next if exists $downloaded_bucket->{keeper_by_hash}{$expected_hash};

    my $keeper = $completed_bucket->{keeper_by_hash}{$expected_hash};
    my $source = $keeper->{path};

    if ( !defined $source || !-f $source ) {
      push @problem,
          {
           which => 'export_dir',
           path  => $source,
           hash  => $expected_hash,
           error => 'completed keeper missing; cannot copy to downloaded',};
      next;
    }

    my $verified = $self->_store_torrent_file( $db, $dbh, $source, 'export_dir_fin' );
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
           error         => 'Completed_torrents source hash mismatch',};
      next;
    }

    my $hash = $verified->{hash};

    my $base = $self->_safe_basename(
      $qbt_name_by_hash->{$hash}
          // $verified->{torrent_name}
          // $self->_torrent_basename( $source )
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
           error => "copy completed to downloaded failed: $!",};
      next;
    }

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
           action        => 'copied Completed_torrents keeper to Downloaded_torrents; copied file left in place for inspection',
           error         => 'copied completed torrent verification failed',};
      next;
    }

    $db->update_qbt_export_dir_file_state(
                                           $dbh,
                                           which  => 'export_dir',
                                           hash   => $hash,
                                           name   => $stored->{torrent_name},
                                           exists => 1, );

    $downloaded_bucket->{keeper_by_hash}{$hash} = $stored;

    push @copied,
        {
         hash     => $hash,
         old_path => $source,
         new_path => $target,};
  }

  return {
          ok       => @problem ? 0 : 1,
          copied   => scalar @copied,
          rows     => \@copied,
          problems => \@problem,};
}

sub _move_stale_completed ( $self, %arg ) {
  my $db                 = $arg{db};
  my $dbh                = $arg{dbh};
  my $completed_bucket   = $arg{completed_bucket};
  my $current_completed  = $arg{current_completed} // {};
  my $queue_dir          = $arg{queue_dir};

  my @problem;
  my @moved;

  for my $hash ( sort keys %{ $completed_bucket->{keeper_by_hash} // {} } ) {
    next if $current_completed->{$hash};

    my $keeper = $completed_bucket->{keeper_by_hash}{$hash};

    my $move = $self->_move_duplicate(
                                       db        => $db,
                                       dbh       => $dbh,
                                       item      => $keeper,
                                       queue_dir => $queue_dir,
                                       which     => 'export_dir_fin', );

    if ( !$move->{ok} ) {
      push @problem, $move->{problem};
      next;
    }

    $db->update_qbt_export_dir_file_state(
                                           $dbh,
                                           which  => 'export_dir_fin',
                                           hash   => $hash,
                                           name   => $keeper->{torrent_name},
                                           exists => 0, );

    delete $completed_bucket->{keeper_by_hash}{$hash};

    push @moved,
        {
         hash     => $hash,
         old_path => $move->{old_path},
         new_path => $move->{new_path},};

    # This keeper no longer belongs to export_dir_fin. It has been moved to
    # queued_for_deletion, so later phases such as export infill must not try
    # to process the old Completed_torrents path as a live keeper.
    delete $completed_bucket->{keeper_by_hash}{$hash};
  }

  return {
          ok       => @problem ? 0 : 1,
          moved    => scalar @moved,
          rows     => \@moved,
          problems => \@problem,};
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

  my $torrent = {
                 path         => $source,
                 hash         => $hash,
                 torrent_name => $name,
                 announce     => undef,
                 parse_ok     => 1,};

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
                                                       backend      => 'qbt_bt_backup_restore',
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
                         error => 'restore from BT_backup copied file but failed to record DB identity',
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
                                         exists => 1, );

  return {
          ok       => 1,
          restored => 1,
          row      => {
                       which => 'export_dir',
                       hash  => $hash,
                       name  => $name,
                       error => 'restored from BT_backup',
                       path  => $target,
          },};
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
         error => 'current qBT torrent missing from Downloaded_torrents. # TODO no repair code written',};
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
         error                => 'completed current qBT torrent missing from Completed_torrents. # TODO no repair code written',};
  }

  return {
          ok                   => @missing ? 0 : 1,
          missing              => \@missing,
          count                => scalar @missing,
          downloaded_available => $downloaded_available,
          downloaded_missing   => $downloaded_missing,};
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

      my $infill = $self->{infill_process}->infill_known_exports(
        db      => $db,
        dbh     => $dbh,
        buckets => \@bucket,
      );
      push @problem, @{ $infill->{problems} // [] };

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

      my $moved                 = $stale_completed->{moved} // 0;
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
      my $torrent_pool_copied_unused = 0;
      my $torrent_pool_existing_unused = 0;
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
        $rename_tracker_prefix_groups += $bucket->{rename_tracker_prefix_groups} // 0;
        $rename_tracker_prefixed += $bucket->{rename_tracker_prefixed} // 0;
        $rename_tracker_prefix_unresolved += $bucket->{rename_tracker_prefix_unresolved} // 0;
        $rename_already_named += $bucket->{rename_already_named} // 0;
        $torrent_pool_copied_unused +=
            $bucket->{torrent_pool_copied_unused} // 0;
        $torrent_pool_existing_unused +=
            $bucket->{torrent_pool_existing_unused} // 0;

        for my $sample ( @{ $bucket->{rename_target_collision_samples} // [] } ) {
          last if @rename_target_collision_sample >= 25;
          push @rename_target_collision_sample, $sample;
        }

        $kept                 += $bucket->{kept}                 // 0;
      }

      return {
              ok                             => @problem || ( $current_missing->{count} // 0 ) || ( $completed_missing->{count} // 0 ) ? 0 : 1,
              action                         => 'qbt_export_dedupe',
              queue_dir                      => $queue_dir,
              torrent_pool                   => $torrent_pool,
              torrent_pool_created           => $torrent_pool_result->{created} // 0,
              torrent_pool_existing          => $torrent_pool_result->{existing} // 0,
              torrent_pool_copied_unused     => $torrent_pool_copied_unused,
              torrent_pool_existing_unused   => $torrent_pool_existing_unused,
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
              moved_stale_completed          => $stale_completed->{moved} // 0,
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

  my $parse_result =
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
          announce     => $parse->{announce},
          parse_ok     => $parse->{ok} ? 1 : 0,
          problem      => $parse->{problem},};
}

sub _torrent_basename ( $self, $path ) {
  my $base = basename( $path );
  $base =~ s/\.torrent\z//;

  return $base;
}

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

1;
