use v5.40;
use common::sense;
use feature qw( signatures );

use File::Temp qw( tempfile );
use Test::More;

use lib 'lib';
use QBTL::Process::Errors ();

my $full = 'open failed for /tmp/example.torrent: Permission denied at lib/QBTL/Process/Local.pm line 527.';

my ( $source, $line ) = QBTL::Process::Errors::_exception_origin(
  $full,
  'lib/QBTL/Process/Local.pm',
  572,
);

is( $source, 'lib/QBTL/Process/Local.pm', 'exception source overrides reporting source' );
is( $line, 527, 'exception line overrides reporting line' );

my ( $signature, $message ) = QBTL::Process::Errors::_unhandled_identity(
  $full,
  '/tmp/example.torrent',
  $source,
  $line,
);

is( $signature, 'open failed', 'signature retains the failed operation' );
is( $message, 'Permission denied', 'message retains the failure reason' );

my ( $fh, $file ) = tempfile();
print {$fh} <<'ERRORS';
my @UNHANDLED_ERRORS = (

  # QBTL-UNHANDLED-ERRORS
);
ERRORS
close $fh;

QBTL::Process::Errors::_ensure_unhandled_entry(
  _file     => $file,
  signature => $signature,
  message   => $message,
  source    => $source,
  line      => $line,
  path      => '/tmp/example.torrent',
);

open my $check, '<', $file or die "open $file: $!";
local $/;
my $written = <$check>;
close $check;

like( $written, qr/signature => 'open failed'/, 'generator writes the concise signature' );
like( $written, qr/message   => 'Permission denied'/, 'generator writes the concise message' );
like( $written, qr/source    => 'lib\/QBTL\/Process\/Local\.pm'/, 'generator writes the exception source' );
like( $written, qr/line      => 527/, 'generator writes the exception line' );

# A second generation attempt is harmless; the source-file duplicate check
# prevents another entry without relying on run-level occurrence counts.
QBTL::Process::Errors::_ensure_unhandled_entry(
  _file     => $file,
  signature => $signature,
  message   => $message,
  source    => $source,
  line      => $line,
  path      => '/tmp/example.torrent',
);

open $check, '<', $file or die "open $file: $!";
local $/;
$written = <$check>;
close $check;

my $entry_count = () = $written =~ /signature => 'open failed'/g;
is( $entry_count, 1, 'repeated generation attempts write one persistent entry' );

unlink $file;

done_testing;
