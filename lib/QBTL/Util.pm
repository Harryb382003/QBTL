package QBTL::Util;

use v5.40;
use common::sense;
use feature qw( signatures );

use Exporter qw( import );

our @EXPORT_OK = qw(
    epoch_time
    human_bytes
    human_duration
    parse_bytes
    parse_byte_values
);

sub epoch_time ( $value, %arg ) {
  return '' if !defined $value;
  return '' if $value eq '';
  return '' if $value <= 0;

  my $format = $arg{format} // 'full';

  my @time = localtime( $value );

  my $ymd =
      sprintf( '%04d-%02d-%02d', $time[5] + 1900, $time[4] + 1, $time[3], );

  my $hms = sprintf( '%02d:%02d:%02d', $time[2], $time[1], $time[0], );

  if ( $format eq 'ymd' ) {
    return $ymd;
  }

  if ( $format eq 'time' ) {
    return $hms;
  }

  return "$ymd $hms";
}

sub human_bytes ( $value ) {
  return '' if !defined $value;
  return '' if $value eq '';
  return '' if $value !~ /\A\d+(?:\.\d+)?\z/;
  my @unit = qw( B KiB MiB GiB TiB PiB );
  my $size = $value + 0;
  my $unit = 0;
  while ( $size >= 1024 && $unit < $#unit ) {
    $size /= 1024;
    $unit++;
  }

  if ( $unit == 0 ) {
    return sprintf( '%d %s', $size, $unit[$unit] );
  }

  return sprintf( '%.2f %s', $size, $unit[$unit] );

}

sub human_duration ( $seconds ) {
  return '' if !defined $seconds;
  return '' if $seconds eq '';

  $seconds = int( $seconds + 0.5 );

  my $days = int( $seconds / 86400 );
  $seconds %= 86400;

  my $hours = int( $seconds / 3600 );
  $seconds %= 3600;

  my $minutes = int( $seconds / 60 );
  my $secs    = $seconds % 60;

  my @part;

  push @part, "${days}d"    if $days;
  push @part, "${hours}h"   if $hours;
  push @part, "${minutes}m" if $minutes;
  push @part, "${secs}s"    if $secs || !@part;

  return join ' ', @part;
}

sub parse_byte_values ( $text ) {
  return if !defined $text;

  $text =~ s/^\s+//;
  $text =~ s/\s+$//;

  return if $text !~ /\A(\d+(?:\.\d+)?)\s*([KMGTPE]?i?B?|[KMGTPE])\z/i;

  my $number = $1 + 0;
  my $unit   = uc $2;

  $unit = 'B' if $unit eq '';

  my %multiplier = (
    B => [1],

    K => [ 1000,    1024 ],
    M => [ 1000**2, 1024**2 ],
    G => [ 1000**3, 1024**3 ],
    T => [ 1000**4, 1024**4 ],
    P => [ 1000**5, 1024**5 ],
    E => [ 1000**6, 1024**6 ],

    KB => [1000],
    MB => [ 1000**2 ],
    GB => [ 1000**3 ],
    TB => [ 1000**4 ],
    PB => [ 1000**5 ],
    EB => [ 1000**6 ],

    KIB => [1024],
    MIB => [ 1024**2 ],
    GIB => [ 1024**3 ],
    TIB => [ 1024**4 ],
    PIB => [ 1024**5 ],
    EIB => [ 1024**6 ], );

  return if !exists $multiplier{$unit};

  my %seen;
  return grep { !$seen{$_}++ }
      map { int( $number * $_ ) } @{$multiplier{$unit}};
}

sub parse_bytes ( $text ) {
  my @value = parse_byte_values( $text );
  return $value[0];
}

sub timed_phase ( $label, $code ) {
  my $started = Time::HiRes::time();
  my $result  = $code->();
  my $elapsed = Time::HiRes::time() - $started;
  say STDERR sprintf '%-32s %8.3f sec', $label, $elapsed;

  return $result;
}

1;
