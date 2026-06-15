package QBTL::Util;

use v5.40;
use common::sense;
use feature qw( signatures );

use Exporter qw( import );

our @EXPORT_OK = qw( epoch_time );

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

1;
