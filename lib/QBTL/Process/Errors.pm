package QBTL::Process::Errors;

use v5.40;
use common::sense;
use feature qw( signatures );

use Exporter qw( import );
use Fcntl qw( :flock );

# 1000–1099  local torrent parsing
# 1100–1199  local fastresume parsing
# 2000–2099  filesystem operations
# 3000–3099  database/storage
# 4000–4099  qBittorrent API
# 5000–5099  metadata conflicts

our @EXPORT_OK = qw(
    ERR_TORRENT_BDECODE_FAILED
    ERR_TORRENT_INFO_MISSING

    begin_error_run
    has_error
    error_run_summary
);

use constant {
  ERR_TORRENT_BDECODE_FAILED => 1001,
  ERR_TORRENT_INFO_MISSING   => 1002,
};

my @ERRORS = (
  {
    code    => ERR_TORRENT_BDECODE_FAILED,
    match   => qr/\Abdecode failed\b/,
    handler => \&_handler_problem_torrent,
  },
  {
    code    => ERR_TORRENT_INFO_MISSING,
    match   => qr/\Amissing info dictionary\b/,
    handler => \&_handler_problem_torrent,
  },
);

my @UNHANDLED_ERRORS = (

  # QBTL-UNHANDLED-ERRORS
);

my %SEEN_THIS_RUN;

sub begin_error_run () {
  %SEEN_THIS_RUN = ();

  return;
}

sub has_error ( %arg ) {
  my $message = _one_line( $arg{message} );

  return {
    has_error => 0,
    known     => 0,
    handled   => 0,
  } if $message eq '';

  my $known = _classify( $message );

  if ( $known ) {
    my $handled = $known->{handler}->( %arg, message => $message );

    return {
      has_error => 1,
      known     => 1,
      handled   => 1,
      code      => $known->{code},
      message   => $message,
      %{$handled // {}},
    };
  }

  my $signature = _signature( $message );
  my $seen      = $SEEN_THIS_RUN{$signature} //= {
    count   => 0,
    message => $message,
    source  => $arg{source},
    line    => $arg{line},
    path    => $arg{path},
  };

  $seen->{count}++;

  if ( $seen->{count} == 1 ) {
    my $subject = defined $arg{path} && $arg{path} ne ''
        ? $arg{path}
        : ( $arg{source} // 'QBTL' );

    warn "$subject failed: $message\n";

    _ensure_unhandled_entry(
      signature => $signature,
      message   => $message,
      source    => $arg{source},
      line      => $arg{line},
      path      => $arg{path},
    );
  }

  return {
    has_error => 1,
    known     => 0,
    handled   => 0,
    code      => undef,
    message   => $message,
    signature => $signature,
    first     => $seen->{count} == 1 ? 1 : 0,
    count     => $seen->{count},
  };
}

sub error_run_summary () {
  my @summary;

  for my $signature ( sort keys %SEEN_THIS_RUN ) {
    my $seen = $SEEN_THIS_RUN{$signature};

    next if $seen->{count} < 2;

    push @summary, {
      signature => $signature,
      message   => $seen->{message},
      count     => $seen->{count},
      source    => $seen->{source},
      line      => $seen->{line},
      path      => $seen->{path},
    };
  }

  return \@summary;
}

sub _classify ( $message ) {
  for my $error ( @ERRORS ) {
    return $error if $message =~ $error->{match};
  }

  return;
}

sub _handler_problem_torrent ( %arg ) {
  return {
    action       => 'problem_torrent',
    quarantinable => 1,
    squelchable   => 1,
  };
}

sub _signature ( $message ) {
  return _one_line( $message );
}

sub _one_line ( $value ) {
  return '' if !defined $value;

  $value =~ s/\R+/ /g;
  $value =~ s/\s+\z//;
  $value =~ s/\A\s+//;

  return $value;
}

sub _perl_single_quote ( $value ) {
  $value = '' if !defined $value;
  $value =~ s/\\/\\\\/g;
  $value =~ s/'/\\'/g;

  return "'$value'";
}

sub _ensure_unhandled_entry ( %arg ) {
  my $file      = __FILE__;
  my $signature = _one_line( $arg{signature} );

  return if $signature eq '';

  open my $fh, '+<', $file or do {
    warn "could not update $file with unhandled error TODO: $!\n";
    return;
  };

  flock( $fh, LOCK_EX ) or do {
    warn "could not lock $file for unhandled error TODO: $!\n";
    close $fh;
    return;
  };

  local $/;
  my $source = <$fh> // '';

  if ( index( $source, "\n  # $signature\n" ) >= 0 ) {
    close $fh;
    return;
  }

  my $marker = "  # QBTL-UNHANDLED-ERRORS\n";
  my $offset = index( $source, $marker );

  if ( $offset < 0 ) {
    warn "could not find unhandled error marker in $file\n";
    close $fh;
    return;
  }

  my $line = defined $arg{line} && $arg{line} =~ /\A\d+\z/
      ? $arg{line}
      : 0;

  my $entry = join '',
      "  # $signature\n",
      "  {\n",
      '    signature => ', _perl_single_quote( $signature ), ",\n",
      '    message   => ', _perl_single_quote( _one_line( $arg{message} ) ), ",\n",
      '    source    => ', _perl_single_quote( _one_line( $arg{source} ) ), ",\n",
      "    line      => $line,\n",
      '    path      => ', _perl_single_quote( _one_line( $arg{path} ) ), ",\n",
      "  },\n\n";

  substr( $source, $offset, 0, $entry );

  seek( $fh, 0, 0 ) or do {
    warn "could not seek $file for unhandled error TODO: $!\n";
    close $fh;
    return;
  };

  truncate( $fh, 0 ) or do {
    warn "could not truncate $file for unhandled error TODO: $!\n";
    close $fh;
    return;
  };

  print {$fh} $source or warn "could not write unhandled error TODO to $file: $!\n";
  close $fh;

  return;
}

1;
