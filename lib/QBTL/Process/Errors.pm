package QBTL::Process::Errors;

use v5.40;
use common::sense;
use feature qw( signatures );

use Exporter qw( import );
use Fcntl    qw( :flock );
use File::Spec;
use Cwd qw( abs_path );

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
              ERR_TORRENT_INFO_MISSING   => 1002,};

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
               }, );

my @UNHANDLED_ERRORS = (

  # New generated entries are inserted immediately before the marker below.
  # When promoting an entry into @ERRORS, remove the complete generated
  # comment/hash block but leave this marker unchanged.
  # QBTL-UNHANDLED-ERRORS
);

my %SEEN_THIS_RUN;

my $ERRORS_SOURCE_FILE = abs_path( __FILE__ ) // __FILE__;

sub _append_error_log ( %arg ) {
  my $message = $arg{message};

  return if !defined $message || $message eq '';

  my $file = _error_log_file();
  return if !defined $file || $file eq '';

  open my $fh, '>>', $file or do {
    warn "could not append error log $file: $!\n";
    return;
  };

  flock( $fh, LOCK_EX ) or do {
    warn "could not lock error log $file: $!\n";
    close $fh;
    return;
  };

  my $path = $arg{path} // '<no path>';

  print {$fh} "\n" . localtime() . "\n";
  print {$fh} $message;
  print {$fh} "\n" if $message !~ /\R\z/;
  print {$fh} "path: $path\n";

  close $fh;

  return;
}

sub begin_error_run () {
  %SEEN_THIS_RUN = ();

  return;
}

sub _classify ( $message ) {
  for my $error ( @ERRORS ) {
    return $error if $message =~ $error->{match};
  }

  return;
}

sub _ensure_unhandled_entry ( %arg ) {
  my $file      = $arg{_file} // $ERRORS_SOURCE_FILE;
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

  my $quoted_signature = _perl_single_quote( $signature );

  if ( index( $source, "signature => $quoted_signature" ) >= 0 ) {
    close $fh;
    return;
  }

  my $marker_re = qr/^[ \t]*\# QBTL-UNHANDLED-ERRORS[ \t]*$/m;

  if ( $source !~ $marker_re ) {
    warn "could not find unhandled error marker in $file\n";
    close $fh;
    return;
  }

  my $offset = $-[0];

  my $line =
      defined $arg{line} && $arg{line} =~ /\A\d+\z/
      ? $arg{line}
      : 0;

  my $entry = join '',
      "  # $signature\n",
      "  {\n",
      '    signature => ', _perl_single_quote( $signature ), ",\n",
      '    message   => ',
      _perl_single_quote( _one_line( $arg{message} ) ), ",\n",
      '    source    => ',
      _perl_single_quote( _one_line( $arg{source} ) ), ",\n",
      "    line      => $line,\n",
      '    path      => ',
      _perl_single_quote( _one_line( $arg{path} ) ), ",\n",
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

  print {$fh} $source
      or warn "could not write unhandled error TODO to $file: $!\n";
  close $fh;

  return;
}

sub _error_log_file () {
  my $log_dir = $ENV{QBTL_LOG_DIR};

  if ( !defined $log_dir || $log_dir eq '' ) {
    my $home = $ENV{HOME} // '';
    return if $home eq '';

    $log_dir = "$home/QBTL/logs";
  }

  return "$log_dir/errors.log";
}

sub error_run_summary () {
  my @summary;

  for my $signature ( sort keys %SEEN_THIS_RUN ) {
    my $seen = $SEEN_THIS_RUN{$signature};

    next if $seen->{count} < 2;

    push @summary,
        {
         signature => $signature,
         message   => $seen->{message},
         count     => $seen->{count},
         source    => $seen->{source},
         line      => $seen->{line},
         path      => $seen->{path},};
  }

  return \@summary;
}

sub _exception_origin ( $message, $fallback_source, $fallback_line ) {
  if ( $message =~ /\sat\s+(.+?)\s+line\s+(\d+)\.?\z/ ) {
    return ( $1, 0 + $2 );
  }

  return ( $fallback_source, $fallback_line );
}

sub _handler_problem_torrent ( %arg ) {
  return {
          action        => 'problem_torrent',
          quarantinable => 1,
          squelchable   => 1,};
}

sub has_error ( %arg ) {
  _append_error_log( %arg );

  my $message = _one_line( $arg{message} );
  my ( $source, $line ) =
      _exception_origin( $message, $arg{source}, $arg{line}, );

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
            %{$handled // {}},};
  }

  my ( $signature, $unhandled_message ) =
      _unhandled_identity( $message, $arg{path}, $source, $line, );
  my $seen = $SEEN_THIS_RUN{$signature} //= {
                                             count   => 0,
                                             message => $unhandled_message,
                                             source  => $source,
                                             line    => $line,
                                             path    => $arg{path},};

  $seen->{count}++;

  if ( $seen->{count} == 1 ) {
    my $subject =
        defined $arg{path} && $arg{path} ne ''
        ? $arg{path}
        : ( $arg{source} // 'QBTL' );

    warn "$subject failed: $message\n";

  }

  # Run-level warning suppression and source-file generation are separate.
  # A concise signature such as "open failed" may be seen more than once,
  # while the source file still has no matching generated entry.
  _ensure_unhandled_entry(
                           signature => $signature,
                           message   => $unhandled_message,
                           source    => $source,
                           line      => $line,
                           path      => $arg{path}, );

  return {
          has_error => 1,
          known     => 0,
          handled   => 0,
          code      => undef,
          message   => $message,
          signature => $signature,
          first     => $seen->{count} == 1 ? 1 : 0,
          count     => $seen->{count},};
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

sub _signature ( $message ) {
  return _one_line( $message );
}

sub _unhandled_identity ( $message, $path, $source, $line ) {
  my $detail = $message;

  if ( defined $source && $source ne '' && defined $line ) {
    $detail =~ s/\s+at\s+\Q$source\E\s+line\s+\Q$line\E\.?\z//;
  }

  if (    defined $path
       && $path ne ''
       && $detail =~ /\A(.+?)\s+for\s+\Q$path\E:\s*(.+)\z/ )
  {
    return ( _one_line( $1 ), _one_line( $2 ) );
  }

  return ( _signature( $detail ), _one_line( $detail ) );
}

1;
