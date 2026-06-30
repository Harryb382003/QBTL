package QBTL::Render::CLI;

use v5.40;
use common::sense;
use feature qw( signatures );

use QBTL::Util qw( epoch_time human_bytes );

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

sub new ( $class, %arg ) {
  $arg{out}         //= \*STDOUT;
  $arg{time_format} //= 'full';

  return bless \%arg, $class;
}

sub db_error ( $self, $result ) {
  return $self->setup(
    {
      ok        => 0,
      home      => undef,
      created   => [],
      existing  => [],
      db_result => $result->{db_result},
    }
  );
}

sub db_random ( $self, $result ) {
  if ( !$result->{ok} ) {
    return $self->db_error($result);
  }

  return $self->db_torrent( $result->{row} );
}

sub db_summary ( $self, $result ) {
  if ( !$result->{ok} ) {
    return $self->db_error($result);
  }

  my $summary = $result->{summary} // {};
  my $out     = $self->{out};

  say {$out} 'QBTL database summary';
  say {$out} '';
  say {$out} 'qBT inventory:';
  say {$out} '  currently in qBT: ' . ( $summary->{current} // 0 );
  say {$out} '  removed from qBT: ' . ( $summary->{removed} // 0 );
  say {$out} '  total qBT-known:  ' . ( $summary->{total}   // 0 );
  say {$out} '';
  say {$out} 'local torrent files:';
  say {$out} '  not scanned yet';

  return;
}

sub db_torrent ( $self, $row ) {
  my $out = $self->{out};

  if ( !$row ) {
    say {$out} 'No qBT rows found.';
    return;
  }

  my $current = $row->{current_qbt} ? 'yes' : 'no';

  my $progress =
      defined $row->{progress}
      ? sprintf( '%.2f%%', $row->{progress} * 100 )
      : '';

my $seen = $row->{seen} ? 'yes' : 'unknown';

  say {$out} 'Torrent';
  say {$out} '';
  say {$out} 'identity:';
  say {$out} "  hash:          " . ( $row->{hash}          // '' );
  say {$out} "  discovered on: " . ( $row->{discovered_on} // '' );
  say {$out} "  discovered by: " . ( $row->{discovered_by} // '' );
  say {$out} '';
  say {$out} 'qBT presence:';
  say {$out} "  in qBT:        " . $current;
  say {$out} "  seen:          " . $seen;
  say {$out} "  seen on:       " . ( $row->{seen_on} // '' );
  say {$out} '';
  say {$out} 'qBT display:';
  say {$out} "  name:          " . ( $row->{name}     // '' );
  say {$out} "  state:         " . ( $row->{state}    // '' );
  say {$out} "  category:      " . ( $row->{category} // '' );
  say {$out} "  tags:          " . ( $row->{tags}     // '' );
  say {$out} '';
  say {$out} 'qBT comment:';
  say {$out} "  comment:       " . ( $row->{comment} // '' );
  say {$out} '';
  say {$out} 'qBT progress:';
  say {$out} "  progress:      " . $progress;
  say {$out} "  amount left:   " . human_bytes( $row->{amount_left} // '' );
  say {$out} "  total size:    " . human_bytes( $row->{total_size}  // '' );
  say {$out} "  ratio:         " . ( $row->{ratio} // '' );
  say {$out} '';
  say {$out} 'qBT paths:';
  say {$out} "  save path:     " . ( $row->{save_path}    // '' );
  say {$out} "  content path:  " . ( $row->{content_path} // '' );
  say {$out} '';
  say {$out} 'qBT timing:';
  say {$out} "  added on:      "
      . epoch_time( $row->{added_on}, format => $self->{time_format} );
  say {$out} "  completion on: "
      . epoch_time( $row->{completion_on}, format => $self->{time_format} );
  say {$out} "  last activity: "
      . epoch_time( $row->{last_activity}, format => $self->{time_format} );
  say {$out} '';
  say {$out} 'qBT tracker:';
  say {$out} "  tracker:       " . ( $row->{tracker} // '' );

  return;
}

sub elapsed ( $self, $elapsed ) {
  my $out = $self->{out};
  say {$out} '';
  say {$out} 'Run time: ' . ( $elapsed // '' );

  return;
}

sub help ( $self, $help ) {
  my $out = $self->{out};

  $help //= {};

  say {$out} $help->{title} if $help->{title};
  say {$out} '';

  if ( $help->{usage} ) {
    say {$out} 'Usage:';
    say {$out} "  $help->{usage}";
    say {$out} '';
  }

  if ( @{ $help->{commands} // [] } ) {
    say {$out} 'Commands:';

    for my $cmd ( @{ $help->{commands} } ) {
      printf {$out} "  %-10s %s\n", $cmd->[0], $cmd->[1];
    }

    say {$out} '';
  }

  if ( @{ $help->{examples} // [] } ) {
    say {$out} 'Examples:';

    for my $example ( @{ $help->{examples} } ) {
      say {$out} "  $example";
    }
  }

  return 0;
}

sub init ( $self, $result ) {
  my $out = $self->{out};

  if ( !$result->{ok} ) {
    say {$out} 'QBTL init failed.';

    for my $problem ( @{ $result->{problems} // [] } ) {
      say {$out} "  problem: $problem";
    }

    return 1;
  }

  say {$out} 'QBTL init complete.';

  if ( $result->{migration} && $result->{migration}{ok} ) {
    say {$out} '';
    say {$out} 'Database:';
    say {$out} '  schema ready';
  }

  if ( $result->{preferences} && $result->{preferences}{ok} ) {
    say {$out} '';
    say {$out} 'qBT preferences:';
    say {$out} '  refreshed';
  }

  if ( $result->{qbt_refresh} && $result->{qbt_refresh}{ok} ) {
    say {$out} '';
    say {$out} 'qBT inventory:';
    say {$out} '  refreshed';
  }

  if ( $result->{local_scan} ) {
  my $scan = $result->{local_scan};

  say {$out} '';
  say {$out} 'Local scan:';
  say {$out} '  backend:          ' . ( $scan->{backend} // '' );
  say {$out} '  seen:             ' . ( $scan->{seen} // 0 );
  say {$out} '  torrent stored:   ' . ( $scan->{stored} // 0 );
  say {$out} '  torrent parsed:   ' . ( $scan->{parsed} // 0 );
  say {$out} '  torrent problems: ' . ( $scan->{parse_problems} // 0 );
  say {$out} '  torrent total:    ' . ( $scan->{total} // 0 );
  say {$out} '  fastres stored:   ' . ( $scan->{fastresume_stored} // 0 );
  say {$out} '  fastres parsed:   ' . ( $scan->{fastresume_parsed} // 0 );
  say {$out} '  fastres problems: ' . ( $scan->{fastresume_parse_problems} // 0 );
  say {$out} '  fastres total:    ' . ( $scan->{fastresume_total} // 0 );
}

  say {$out} '';
# say {$out} 'Elapsed: ' . ( $result->{elapsed} // '' ) . 's';

  return 0;
}

sub local_reset ( $self, $result ) {
  my $out = $self->{out};

  if ( !$result->{ok} ) {
    say {$out} 'Local reset failed.';

    for my $problem ( @{ $result->{problems} // [] } ) {
      say {$out} "  problem: $problem";
    }

    return 1;
  }

  my $reset = $result->{reset} // {};

  say {$out} 'Local evidence reset.';
  say {$out} '  torrent rows deleted:    ' . ( $reset->{torrent_deleted} // 0 );
  say {$out} '  fastresume rows deleted: ' . ( $reset->{fastres_deleted} // 0 );

  if ( $result->{scan} ) {
    say {$out} '';
    return $self->local_scan( $result->{scan} );
  }

  return 0;
}


sub help_all ( $self, $topics ) {
  my $out = $self->{out};

  $topics //= [];

  for my $idx ( 0 .. $#$topics ) {
    say {$out} '' if $idx;
    $self->help( $topics->[$idx] );
  }

  return 0;
}

sub local_scan ( $self, $result ) {
  my $out = $self->{out};

  if ( !$result->{ok} ) {
    if ( defined $result->{target} && length $result->{target} ) {
      say {$out} 'Local scan of ' . $result->{target} . ' failed.';
    } else {
      say {$out} 'Local scan failed.';
    }
    say {$out} '  backend:  ' . ( $result->{backend} // '' );
    say {$out} '  seen:     ' . ( $result->{seen} // 0 );
    say {$out} '  torrents: ' . ( $result->{torrent_seen} // 0 );
    say {$out} '  stored:   ' . ( $result->{stored} // 0 );
    say {$out} '  parsed:   ' . ( $result->{parsed} // 0 );
    say {$out} '  problems: ' . ( $result->{parse_problems} // 0 );
    say {$out} '  fastres:  ' . ( $result->{fastresume_seen} // 0 );
    say {$out} '  fastres stored:   '
      . ( $result->{fastresume_stored} // 0 );
    say {$out} '  fastres parsed:   '
      . ( $result->{fastresume_parsed} // 0 );
    say {$out} '  fastres problems: '
      . ( $result->{fastresume_parse_problems} // 0 );
    say {$out} '  fastres total:    ' . ( $result->{fastresume_total} // 0 );

    for my $problem ( @{ $result->{problems} // [] } ) {
      say {$out} "  problem:  $problem";
    }
#     say {$out} '  elapsed:  ' . ( $result->{elapsed} // '' ) . 's';

    return;
  }

  my $label = ($result->{action} // '') eq 'local_refresh' ? 'Local refresh' : 'Local scan';

  if ( defined $result->{target} && length $result->{target} ) {
    say {$out} $label . ' of ' . $result->{target} . ' complete.';
  } else {
    say {$out} $label . ' complete.';
  }
  say {$out} '  scanner backend:  ' . ( $result->{scanner_backend} // $result->{backend} // 'unknown' );
  say {$out} '  seen:             ' . ( $result->{seen} // 0 );
  say {$out} '  torrent stored:   ' . ( $result->{stored} // 0 );
  say {$out} '  torrent parsed:   ' . ( $result->{parsed} // 0 );
  say {$out} '  torrent skipped:  ' . ( $result->{skipped_known} // 0 );
  say {$out} '  path excluded:    ' . ( $result->{skipped_excluded} // 0 );
  say {$out} '  torrent problems: ' . ( $result->{parse_problems} // 0 );
  say {$out} '  torrent total:    ' . ( $result->{total} // 0 );

      say {$out} '';
  say {$out} '  fastres stored:   '
    . ( $result->{fastresume_stored} // 0 );
  say {$out} '  fastres parsed:   '
    . ( $result->{fastresume_parsed} // 0 );
  say {$out} '  fastres skipped:  '
    . ( $result->{fastresume_skipped_known} // 0 );
  say {$out} '  fastres problems: '
    . ( $result->{fastresume_parse_problems} // 0 );
  say {$out} '  fastres total:    ' . ( $result->{fastresume_total} // 0 );

  if ( $result->{bt_backup_exists} ) {
    say {$out} '';
    say {$out} '  qBT BT_backup torrents:      '
      . ( $result->{bt_backup_torrents} // 0 );
    say {$out} '  qBT BT_backup fastresume:    '
      . ( $result->{bt_backup_fastresume} // 0 );
    say {$out} '  qBT hash as filename:        '
      . ( $result->{bt_backup_mismatch} // 0 );
    say {$out} '  qBT BT_backup count source:  '
      . ( $result->{bt_backup_count_source} // 'unknown' );
  }

      say {$out} '';
#   say {$out} '  elapsed:  ' . ( $result->{elapsed} // '' ) . 's';

  my $metadata_candidates = $result->{metadata_candidates};

  if ( $metadata_candidates && $metadata_candidates->{ok} ) {
    my $count = scalar @{ $metadata_candidates->{candidates} // [] };

    if ($count) {
      say {$out} '';
      say {$out} 'Metadata promotion candidates:';
      say {$out} '  threshold:  '
          . ( $metadata_candidates->{threshold} // '' );
      say {$out} "  candidates: $count";
      say {$out} '';
      say {$out} 'Run:';
      say {$out} '  qbtl meta candidates';
    }
  }

  return 0;
}

sub local_summary ( $self, $result ) {
  my $out = $self->{out};

  if ( !$result->{ok} ) {
    say {$out} 'Local summary failed.';

    for my $problem ( @{ $result->{problems} // [] } ) {
      say {$out} "  problem:  $problem";
    }

    return;
  }

  my $summary = $result->{summary} // {};
  my $qbt_mismatch = $result->{qbt_mismatch} // 0;

  say {$out} 'Local torrent files:';
  say {$out} '  scanner backend: ' . ( $summary->{scanner_backend} // 'unknown' );
  say {$out} '  latest scan:     ' . ( $summary->{latest_seen} // '' );
  say {$out} '  total paths:     ' . ( $summary->{total} // 0 );
  say {$out} '  parsed:          ' . ( $summary->{parsed} // 0 );
  say {$out} '  parse problems:  ' . ( $summary->{parse_problems} // 0 );

  my $deletion = $result->{deletion};
  if ( $deletion && $deletion->{ok} ) {
    say {$out} '';
    say {$out} 'queued_for_deletion:';
    say {$out} '  total:                ' . ( $deletion->{total} // 0 );
    say {$out} '  should restore:       ' . ( $deletion->{should_restore} // 0 );
    say {$out} '  should remain queued: ' . ( $deletion->{should_remain_queued} // 0 );
  }

  my $restoration = $result->{restoration};
  if ( $restoration && $restoration->{ok} ) {
    say {$out} '';
    say {$out} 'queued_for_restoration:';
    say {$out} '  total:                 ' . ( $restoration->{total} // 0 );
    say {$out} '  should restore:        ' . ( $restoration->{should_restore} // 0 );
    say {$out} '  should queue deletion: ' . ( $restoration->{should_queue_deletion} // 0 );
  }

  say {$out} '';
  say {$out} 'qBT mis-match:      ' . $qbt_mismatch;

  return;
}

sub qbt_mismatch ( $self, $result ) {
  my $out = $self->{out};

  if ( !$result->{ok} ) {
    say {$out} 'qBT mismatch failed.';

    for my $problem ( @{ $result->{problems} // [] } ) {
      say {$out} "  problem: $problem";
    }

    return 1;
  }

  say {$out} 'qBT mis-match:';
  say {$out} '  fastresume without matching BT_backup torrent: '
      . ( $result->{count} // 0 );

  return 0 if !@{ $result->{rows} // [] };

  say {$out} '';
  say {$out} 'Rows:';

  for my $row ( @{ $result->{rows} } ) {
    say {$out} '  ' . ( $row->{infohash} // '' );
    say {$out} '    fastresume:        ' . ( $row->{fastresume_path} // '' );
    say {$out} '    qBT name:          ' . ( $row->{qbt_name} // '' );

    if ( ( $row->{qbt_state} // '' ) ne 'queuedDL' ) {
      say {$out} '    qBT state:         ' . ( $row->{qbt_state} // '' );
    }

    say {$out} '    repair candidates: ' . ( $row->{repair_candidates} // 0 );

    for my $path ( @{ $row->{repair_candidate_paths} // [] } ) {
      say {$out} '      ' . $path;
    }
  }

  return 0;
}

sub metadata_key ( $self, $result ) {
  if ( !$result->{ok} ) {
    return $self->db_error($result);
  }

  my $out     = $self->{out};
  my $summary = $result->{summary} // {};

  say {$out} 'Observed metadata key:';
  say {$out} '  key:    ' . ( $result->{key} // '' );
  say {$out} '  hashes: ' . ( $summary->{hashes}      // 0 );
  say {$out} '  values: ' . ( $summary->{values_seen} // 0 );
  say {$out} '  seen:   ' . ( $summary->{seen}        // 0 );
  say {$out} '';

  if ( !@{ $result->{rows} // [] } ) {
    say {$out} 'Examples:';
    say {$out} '  none';
    return;
  }

  say {$out} 'Examples:';

  for my $row ( @{ $result->{rows} } ) {
    say {$out} '  '
        . ( $row->{hash}  // '' )
        . '  '
        . ( $row->{value} // '' );
  }

  return;
}

sub metadata_keys ( $self, $result ) {
  if ( !$result->{ok} ) {
    return $self->db_error($result);
  }

  my $out = $self->{out};

  say {$out} 'Observed metadata keys:';
  say {$out} '';

  if ( !@{ $result->{rows} // [] } ) {
    say {$out} '  none';
    return 0;
  }

  printf {$out} "%-32s %8s %8s %8s\n",
      'Key',
      'Hashes',
      'Values',
      'Seen';

  printf {$out} "%-32s %8s %8s %8s\n",
      '-' x 32,
      '-' x 8,
      '-' x 8,
      '-' x 8;

  for my $row ( @{ $result->{rows} } ) {
    printf {$out} "%-32s %8s %8s %8s\n",
        $row->{key},
        $row->{hashes}      // 0,
        $row->{values_seen} // 0,
        $row->{seen}        // 0;
  }

  return 0;
}

sub metadata_keys_all ( $self, $result ) {
  if ( !$result->{ok} ) {
    return $self->db_error($result);
  }

  my $out = $self->{out};

  say {$out} 'All metadata/evidence keys:';
  say {$out} '';

  if ( !@{ $result->{rows} // [] } ) {
    say {$out} '  none';
    return;
  }

  printf {$out} "%-45s %-10s %-50s %-12s %s\n",
    'Key', 'Kind', 'Data', 'Status', 'Accessor';

  printf {$out} "%-45s %-10s %-50s %-12s %s\n",
    '-' x 45, '-' x 10, '-' x 50, '-' x 12, '-' x 24;

  for my $row ( @{ $result->{rows} } ) {
    printf {$out} "%-45s %-10s %-50s %-12s %s\n",
        $row->{key}      // '',
        $row->{kind}     // '',
        $row->{data}   // '',
        $row->{status}   // '',
        $row->{accessor} // 'TODO';
  }

  return;
}

sub metadata_candidates ( $self, $result ) {
  if ( !$result->{ok} ) {
    return $self->db_error($result);
  }

  my $out = $self->{out};

  say {$out} 'Metadata promotion candidates:';
  say {$out} '  threshold: ' . ( $result->{threshold} // '' );
  say {$out} '';

  if ( !@{ $result->{candidates} // [] } ) {
    say {$out} '  none';
    return;
  }

  printf {$out} "%-36s %8s %8s %8s  %s\n",
      'Key',
      'Hashes',
      'Values',
      'Seen',
      'Action';

  printf {$out} "%-36s %8s %8s %8s  %s\n",
      '-' x 36,
      '-' x 8,
      '-' x 8,
      '-' x 8,
      '-' x 24;

  for my $row ( @{ $result->{candidates} } ) {
    printf {$out} "%-36s %8s %8s %8s  %s\n",
        $row->{key},
        $row->{hashes}      // 0,
        $row->{values_seen} // 0,
        $row->{seen}        // 0,
        $row->{action}      // '';
  }

  return;
}

sub metadata_promote ( $self, $result ) {
  if ( !$result->{ok} ) {
    return $self->db_error($result);
  }

  my $out = $self->{out};

  if ( ( $result->{status} // '' ) eq 'already_promoted' ) {
    say {$out} 'Metadata key already promoted.';
  } else {
    say {$out} 'Metadata key promoted.';
  }

  say {$out} '  key:        ' . ( $result->{key}           // '' );
  say {$out} '  column:     ' . ( $result->{target_column} // '' );
  say {$out} '  backfilled: ' . ( $result->{backfilled}    // 0 );

  return;
}

sub metadata_promoted ( $self, $result ) {
  if ( !$result->{ok} ) {
    return $self->db_error($result);
  }

  my $out = $self->{out};

  say {$out} 'Promoted metadata keys:';
  say {$out} '';

  if ( !@{ $result->{rows} // [] } ) {
    say {$out} '  none';
    return;
  }

  printf {$out} "%-32s %-32s %-10s %s\n",
      'Key',
      'Column',
      'Type',
      'Created';

  printf {$out} "%-32s %-32s %-10s %s\n",
      '-' x 32,
      '-' x 32,
      '-' x 10,
      '-' x 19;

  for my $row ( @{ $result->{rows} } ) {
    printf {$out} "%-32s %-32s %-10s %s\n",
        $row->{key},
        $row->{target_column},
        $row->{value_type} // '',
        $row->{created_on} // '';
  }

  return;
}

sub manual_value_set ( $self, $result ) {
  if ( !$result->{ok} ) {
    return $self->db_error($result);
  }

  my $out = $self->{out};

  say {$out} 'Manual metadata set.';
  say {$out} '  hash:  ' . ( $result->{hash}  // '' );
  say {$out} '  key:   ' . ( $result->{key}   // '' );
  say {$out} '  value: ' . ( $result->{value} // '' );

  return;
}

sub manual_values_for_hash ( $self, $result ) {
  if ( !$result->{ok} ) {
    return $self->db_error($result);
  }

  my $out = $self->{out};

  say {$out} 'Manual metadata:';
  say {$out} '  hash: ' . ( $result->{hash} // '' );
  say {$out} '';

  if ( !@{ $result->{rows} // [] } ) {
    say {$out} '  none';
    return;
  }

  for my $row ( @{ $result->{rows} } ) {
    say {$out} '  '
        . ( $row->{key} // '' )
        . ': '
        . ( $row->{value} // '' );
  }

  return;
}

sub manual_value_unset ( $self, $result ) {
  if ( !$result->{ok} ) {
    return $self->db_error($result);
  }

  my $out = $self->{out};

  say {$out} 'Manual metadata removed.';
  say {$out} '  hash: ' . ( $result->{hash}    // '' );
  say {$out} '  key:  ' . ( $result->{key}     // '' );
  say {$out} '  rows: ' . ( $result->{removed} // 0 );

  return;
}

sub qbt_preference_keys ( $self, $result ) {
  if ( !$result->{ok} ) {
    return $self->db_error($result);
  }

  my $out = $self->{out};

  say {$out} 'qBT preference keys:';
  say {$out} '  count: ' . ( $result->{count} // scalar @{ $result->{rows} // [] } );
  say {$out} '';

  if ( !@{ $result->{rows} // [] } ) {
    say {$out} '  none';
    return 0;
  }

  printf {$out} "%-36s %-12s %-40s %s\n",
      'Key', 'Value type', 'Value', 'Last seen';
  printf {$out} "%-36s %-12s %-40s %s\n",
      '-' x 36, '-' x 12, '-' x 40, '-' x 19;

  for my $row ( @{ $result->{rows} } ) {
    my $value = defined $row->{value} ? $row->{value} : '';
    $value =~ s/\n/\\n/g;

    if ( length $value > 40 ) {
      $value = substr( $value, 0, 37 ) . '...';
    }

    printf {$out} "%-36s %-12s %-40s %s\n",
        $row->{key} // '',
        $row->{value_type} // '',
        $value,
        $row->{last_seen_on} // '';
  }

  return 0;
}

sub qbt_preferences ( $self, $result ) {
  my $out = $self->{out};

  if ( !$result->{ok} ) {
    say {$out} "qBT preferences refresh failed.";
  } else {
    say {$out} "qBT preferences refresh complete.";
  }

  say {$out} "  seen:     " . ( $result->{seen}   // 0 );
  say {$out} "  stored:   " . ( $result->{stored} // 0 );
  say {$out} "  problems: " . scalar @{ $result->{problems} // [] };

  if ( @{ $result->{problems} // [] } ) {
    say {$out} "";
    say {$out} "Problems:";

    for my $problem ( @{ $result->{problems} } ) {
      my $key   = defined $problem->{key} ? $problem->{key} : '(unknown)';
      my $error = $problem->{error} // 'unknown error';

      say {$out} "  $key: $error";
    }

    return 1;
  }

  return 0;
}

sub qbt_add ( $self, $result ) {
  my $out = $self->{out};

  if ( ( $result->{status} // '' ) eq 'already_loaded_running' ) {
    say {$out} $result->{message} // 'Torrent already loaded and running';
    return 0;
  }

  if ( !$result->{ok} ) {
    say {$out} 'qBT add failed.';

    for my $problem ( @{ $result->{problems} // [] } ) {
      if ( ref $problem eq 'HASH' ) {
        say {$out} '  problem: ' . ( $problem->{error} // '' );
      } else {
        say {$out} "  problem: $problem";
      }
    }

    if ( $result->{add_result} && $result->{add_result}{error} ) {
      say {$out} '  problem: ' . $result->{add_result}{error};
    }

    return 1;
  }

  say {$out} 'qBT add complete.';
  say {$out} '  hash:    ' . ( $result->{hash} // '' );
  say {$out} '  torrent: ' . ( $result->{torrent_path} // '' );

  if ( defined $result->{used_savepath} && $result->{used_savepath} ne '' ) {
    say {$out} '  savepath: ' . $result->{used_savepath};
  } else {
    say {$out} '  savepath: qBT default';
  }

  if ( $result->{search} && $result->{search}{searched} ) {
    my $found = $result->{search}{found_path} // '(not found)';
    say {$out} '  payload:  ' . $found;

    if ( $result->{search}{match_kind} ) {
      say {$out} '  matched via:   ' . $result->{search}{match_kind};
    }
  }

  return 0;
}

sub qbt_refresh ( $self, $result ) {
  my $out = $self->{out};

  if ( !$result->{ok} ) {
    say {$out} "qBT refresh failed.";
  } else {
    say {$out} "qBT refresh complete.";
  }

  say {$out} "  seen:     " . ( $result->{seen}     // 0 );
  say {$out} "  stored:   " . ( $result->{stored}   // 0 );
  say {$out} "  new:      " . ( $result->{new}      // 0 );
  say {$out} "  existing: " . ( $result->{existing} // 0 );
  say {$out} "  removed:  " . ( $result->{removed}  // 0 );
  say {$out} "  problems: " . scalar @{$result->{problems} // []};

  if ( @{$result->{problems}} ) {
    say {$out} "";
    say {$out} "Problems:";

    for my $problem ( @{$result->{problems}} ) {
      my $hash  = defined $problem->{hash} ? $problem->{hash} : '(unknown)';
      my $error = $problem->{error} // 'unknown error';

      say {$out} "  $hash: $error";
    }

    return 1;
  }

  return 0;
}

sub qbt_request ( $self, $result ) {
  my $out = $self->{out};

  if ( !$result->{ok} ) {
    say {$out} "qBT request failed.";
    return 1;
  }

  say {$out} "qBT request";
  say {$out} "Action: $result->{action}";
  say {$out} "Method: $result->{request}{method}";
  say {$out} "URL: $result->{request}{url}";

  return 0;
}

sub qbt_result ( $self, $result ) {
  my $out = $self->{out};

  say {$out} $result->{ok} ? 'qBT request complete.' : 'qBT request failed.';
  say {$out} "Action: " . ( $result->{action} // '' );

  if ( ( $result->{action} // '' ) eq 'qbt_torrents_info' ) {
    say {$out} "Torrents: " . ( $result->{count} // 0 );

    return $result->{ok} ? 0 : 1;
  }

  if ( $result->{result} ) {
    say {$out} "Status: " . ( $result->{result}{status} // '' );
    say {$out} "Code: " .   ( $result->{result}{code}   // '' );

    if ( defined $result->{result}{body} && length $result->{result}{body} ) {
      say {$out} "Body:";
      say {$out} $result->{result}{body};
    }
  }

  return $result->{ok} ? 0 : 1;

}

sub qbt_status ( $self, $result ) {
  my $out = $self->{out};

  if ( !$result->{ok} ) {
    say {$out} 'qBT status failed.';

    for my $problem ( @{ $result->{problems} // [] } ) {
      if ( ref $problem eq 'HASH' ) {
        say {$out} '  problem: ' . ( $problem->{error} // '' );
      } else {
        say {$out} "  problem: $problem";
      }
    }

    return 1;
  }

  my $summary    = $result->{summary}    // {};
  my $categories = $result->{categories} // {};
  my $states     = $result->{states}     // [];

  say {$out} 'qBT status';

  if ( $summary->{latest_seen_on} ) {
    say {$out} '  timestamp: ' . $summary->{latest_seen_on};
  }

  say {$out} '';
  say {$out} 'qBT inventory:';
  say {$out} '  currently loaded:        '
    . ( $summary->{current_count} // 0);
  say {$out} '  previously seen/removed: '
    . ( $summary->{removed_count} // 0);
  say {$out} '  hash_as_name:            '
    . ( $summary->{hash_as_name_count} // 0);
  say {$out} '  total known:             '
    . ($summary->{total_count} // 0 );

  say {$out} '';
  say {$out} 'States:';

  if ( @{$states} ) {
    for my $row ( @{$states} ) {
      say {$out} '  ' . ( $row->{state} // '' ) . ': ' . ( $row->{count} // 0 );
    }
  } else {
    say {$out} '  none';
  }

  say {$out} '';
  say {$out} 'Categories:';
  say {$out} '  categorized:   ' . ( $categories->{categorized}   // 0 );
  say {$out} '  uncategorized: ' . ( $categories->{uncategorized} // 0 );

  return 0;
}


sub search_hat ( $self, $result ) {
  if ( !$result->{ok} ) {
    return $self->db_error($result);
  }

  my $out       = $self->{out};
  my $inventory = $result->{inventory} // {};
  my $rows      = $result->{rows} // [];

  if ( !$inventory->{ok} ) {
    say {$out} '';
    say {$out} 'BT_backup inventory warning: ' . ( $inventory->{status} // 'unknown' );
    say {$out} '  dir: ' . ( $inventory->{dir} // '' );
  }

  if ( !@{$rows} ) {
    say {$out} 'No local .torrent matches.';
    say {$out} '';
    say {$out} 'Search: hat';
    say {$out} 'Definition: hash as name';
    say {$out} '  qBT loaded hashes:          ' . ( $inventory->{current_qbt} // 0 );
    say {$out} '  BT_backup torrents:        ' . ( $inventory->{torrents}    // 0 );
    say {$out} '  hash as name candidates:   ' . ( $result->{hash_as_name_hashes} // 0 );
    say {$out} '  hashes with local matches: ' . ( $result->{hashes_with_matches} // 0 );
    say {$out} '  local torrent files:       ' . ( $result->{count} // 0 );
    return;
  }


  my $last_hash = '';

  for my $row ( @{$rows} ) {
    my $hash = $row->{hash} // '';

    if ( $hash ne $last_hash ) {
      say {$out} '' if $last_hash ne '';
      say {$out} $hash;
      $last_hash = $hash;
    }

    say {$out} "\t" . ( $row->{torrent_path} // '' );
  }

  say {$out} '';
  say {$out} 'Search: hat';
  say {$out} 'Definition: hash as name';
  say {$out} '  qBT loaded hashes:          ' . ( $inventory->{current_qbt} // 0 );
  say {$out} '  BT_backup torrents:        ' . ( $inventory->{torrents}    // 0 );
  say {$out} '  hash as name candidates:   ' . ( $result->{hash_as_name_hashes} // 0 );
  say {$out} '  hashes with local matches: ' . ( $result->{hashes_with_matches} // 0 );
  say {$out} '  local torrent files:       ' . ( $result->{count} // 0 );

  return;
}

sub search_list ( $self, $result ) {
  if ( !$result->{ok} ) {
    return $self->db_error($result);
  }

  my $out = $self->{out};

  say {$out} 'Searchable qBT fields:';
  say {$out} '';

  for my $field ( @{ $result->{fields} // [] } ) {
    say {$out} "  $field";
  }

  return;
}


sub search_hash ( $self, $result ) {
  my $out = $self->{out};

  if ( !$result->{ok} ) {
    say {$out} 'Search failed.';
    say {$out} 'Field: hash';
    say {$out} 'Status: ' . ( $result->{status} // '' );
    return;
  }

  my $row = $result->{row};

  if ($row) {
    $self->db_torrent($row);
    say {$out} '';
  } else {
    say {$out} 'Torrent';
    say {$out} '';
    say {$out} 'identity:';
    say {$out} '  hash:          ' . ( $result->{hash} // '' );
    say {$out} '';
  }

  my $torrent_file = 'not checked';

  if ( $result->{qbt_loaded} ) {
    $torrent_file = $row->{qbt_torrent_file} ? 'yes' : 'no';
  }

  say {$out} 'qBT torrent status:';
  say {$out} '  qBT loaded:       ' . ( $result->{qbt_loaded} ? 'yes' : 'no' );
  say {$out} '  qBT torrent file: ' . $torrent_file;
  say {$out} '  status:           ' . ( $result->{qbt_status} // '' );

  if ( $row && defined $row->{qbt_torrent_file_checked_on} ) {
    say {$out} '  checked on:       ' . ( $row->{qbt_torrent_file_checked_on} // '' );
  }

  if ( ( $result->{qbt_status} // '' ) eq 'LOADED/RUNNING' ) {
    return;
  }

  say {$out} '';
  say {$out} 'local torrent matches:';

  my $matches = $result->{local_matches} // [];

  if ( !@{$matches} ) {
    say {$out} '  none';
    return;
  }

  for my $match ( @{$matches} ) {
    say {$out} '  ' . ( $match->{path} // '' );
  }

  return;
}

sub search_result ( $self, $result ) {
  return $self->search_hash($result)
      if ( $result->{action} // '' ) eq 'search_hash';

  my $out = $self->{out};

  if ( !$result->{ok} ) {
    say {$out} 'Search failed.';
    say {$out} 'Field: ' . ( $result->{field} // '' );
    say {$out} 'Status: ' . ( $result->{status} // '' );
    return;
  }

  my $rows = $result->{rows} // [];

  if ( !@{$rows} ) {
    say {$out} 'No matches.';
    return;
  }

  if ( @{$rows} == 1 ) {
    return $self->db_torrent( $rows->[0] );
  }

  say {$out} 'Matches: ' . scalar @{$rows};
  say {$out} '';

  for my $row ( @{$rows} ) {
    say {$out} ( $row->{hash} // '' ) . ' : ' . ( $row->{name} // '' );
  }

  return;
}

sub setup ( $self, $result ) {
  my $out = $self->{out};

  if ( $result->{db_result} && $result->{db_result}{ok} ) {
    say {$out} "";
    say {$out} "Database:";
    say {$out} "  schema ready";
  }

  if ( !$result->{ok} ) {
    say {$out} "QBTL setup failed.";

    if ( $result->{db_result} && $result->{db_result}{problems} ) {
      say {$out} "";
      say {$out} "Problems:";
      say {$out} "  $_" for @{$result->{db_result}{problems}};
    }

    return 1;
  }

  say {$out} "QBTL setup complete.";
  say {$out} "Home: $result->{home}";

  if ( @{$result->{created}} ) {
    say {$out} "";
    say {$out} "Created:";
    say {$out} "  $_" for @{$result->{created}};
  }

  if ( @{$result->{existing}} ) {
    say {$out} "";
    say {$out} "Already existed:";
    say {$out} "  $_" for @{$result->{existing}};
  }

  if ( $result->{db_result} && $result->{db_result}{ok} ) {
    say {$out} "";
    say {$out} "Database:";
    say {$out} "  schema ready";
  }

  if ( $result->{local_search} && $result->{local_search}{ok} ) {
    say {$out} "";
    say {$out} "Local search:";
    say {$out} "  search_tool = " . $result->{local_search}{search_tool};
    say {$out} "  path = " . $result->{local_search}{path};

    if ( $result->{local_search}{warning} ) {
      say {$out} "";
      say {$out} $result->{local_search}{warning};
    }
  }

  return 0;
}

sub _short_value ( $value, $limit = 40 ) {
  return '' if !defined $value;

  $value =~ s/\s+/ /g;

  if ( length $value <= $limit ) {
    return $value;
  }

  return substr( $value, 0, $limit - 3 ) . '...';
}

sub status ( $self, $result ) {
  my $out = $self->{out};

  say {$out} "QBTL status";
  say {$out} "DB: $result->{db_path}";

  if ( $result->{ok} ) {
    say {$out} "Database path: ready";
    return 0;
  }

  say {$out} "Database path: not ready";
  say {$out} "";

  say {$out} "Problems:";
  say {$out} "  $_" for @{$result->{problems}};

  say {$out} "";
  say {$out} "Repair:";
  say {$out} "  qbtl setup";

  return 1;
}

sub version ( $self, $version ) {
  my $out = $self->{out};

  say {$out} "QBTL $version";

  return 0;
}

1;
