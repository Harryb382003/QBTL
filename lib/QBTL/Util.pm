package QBTL::Util;

use v5.40;
use common::sense;
use feature qw( signatures );

use Exporter qw( import );

our @EXPORT_OK = qw( epoch_time human_bytes );

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
1;
