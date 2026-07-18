use v5.40;
use common::sense;
use feature qw( signatures );

use Test::More;
use lib 'lib';

use QBTL::Process::QBT::Dedupe;

my $lower = '0123456789abcdef0123456789abcdef01234567';
my $upper = '0123456789ABCDEF0123456789ABCDEF01234567';

ok QBTL::Process::QBT::Dedupe::_same_infohash( $lower, $lower ),
    'identical lowercase hashes match';
ok QBTL::Process::QBT::Dedupe::_same_infohash( $lower, $upper ),
    'lowercase parser hash matches uppercase qBT hash';
ok QBTL::Process::QBT::Dedupe::_same_infohash( $upper, $lower ),
    'uppercase qBT hash matches lowercase parser hash';
ok !QBTL::Process::QBT::Dedupe::_same_infohash(
  $lower, '1123456789abcdef0123456789abcdef01234567'
), 'different hashes do not match';
ok !QBTL::Process::QBT::Dedupe::_same_infohash( 'not-a-hash', $lower ),
    'invalid hash does not match';

done_testing;
