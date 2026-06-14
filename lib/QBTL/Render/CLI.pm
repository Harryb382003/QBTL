package QBTL::Render::CLI;

use v5.40;
use common::sense;
use feature qw( signatures );

sub new ( $class, %arg ) {
  $arg{out} //= \*STDOUT;

  return bless \%arg, $class;
}

sub version ( $self, $version ) {
  my $out = $self->{out};

  say {$out} "QBTL $version";

  return 0;
}

sub help ( $self ) {
  my $out = $self->{out};

  say {$out} "Usage: qbtl <command>";
  say {$out} "";
  say {$out} "Commands:";
  say {$out} "  help        Show this help";
  say {$out} "  setup       Create QBTL runtime directories";
  say {$out} "  status      Show QBTL runtime status";
  say {$out} "  version     Show QBTL version";
  say "";
  say {$out} "  qbt help      Show qBittorrent command help";
  say {$out} "  qbt info      Show qBittorrent torrents/info request";
  say {$out} "  qbt refresh   Store fake qBittorrent torrents/info rows";
  say {$out} "  qbt version   Show qBittorrent version request";

  return 0;
}

sub qbt_help ( $self ) {
    my $out = $self->{out};

    say {$out} "Usage: qbtl qbt <command>";
    say {$out} "";
    say {$out} "Commands:";
    say {$out} "  help      Show this help";
    say {$out} "  info      Show qBittorrent torrents/info request";
    say {$out} "  refresh   Store fake qBittorrent torrents/info rows";
    say {$out} "  version   Show qBittorrent version request";

    return 0;
}

sub qbt_refresh ( $self, $result ) {
  my $out = $self->{out};

  if ( !$result->{ok} ) {
    say {$out} "qBT refresh failed.";
  } else {
    say {$out} "qBT refresh complete.";
  }

  say {$out} "  seen:     $result->{seen}";
  say {$out} "  stored:   $result->{stored}";
  say {$out} "  problems: " . scalar @{$result->{problems}};

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

1;
