package QBTL::Render::Base;

use v5.40;
use common::sense;
use feature qw( signatures );

use QBTL::Util qw( epoch_time human_bytes );

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

sub _qbt_export_dedupe_problem_count ( $self, $result ) {
  return scalar @{$result->{problems} // []};
}
