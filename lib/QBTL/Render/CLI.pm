package QBTL::Render::CLI;

use v5.40;
use common::sense;
use feature qw( signatures );

use QBTL::Util qw( epoch_time human_bytes );

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

sub help ( $self ) {
  my $out = $self->{out};

  say {$out} "Usage: qbtl <command>";
  say {$out} "";
  say {$out} "Commands:";
  say {$out} "  help        Show this help";
  say {$out} "  info        Fetch qBittorrent torrents/info";
  say {$out} "  setup       Create QBTL runtime directories";
  say {$out} "  status      Show QBTL runtime status";
  say {$out} "  version     Show QBTL version";
  say "";
  say {$out} "  qbt help      Show qBittorrent command help";
  say {$out} "  qbt info      Fetch qBittorrent torrents/info";
  say {$out} "  qbt refresh   Store qBittorrent torrents/info rows";
  say {$out} "  qbt version   Show qBittorrent version request";

  return 0;
}

sub qbt_help ( $self ) {
  my $out = $self->{out};

  say {$out} "Usage: qbtl qbt <command>";
  say {$out} "";
  say {$out} "Commands:";
  say {$out} "  help          Show this help";
  say {$out} "  info          Fetch qBittorrent torrents/info";
  say {$out} "  refresh    Store qBittorrent torrents/info rows";
  say {$out} "  version       Show qBittorrent version request";

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

sub search_result ( $self, $result ) {
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

  return 0;
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
