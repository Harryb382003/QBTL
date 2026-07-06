use v5.40;
use common::sense;
use feature qw( signatures );

use Test::More;
use lib 'lib';

use QBTL::Process::QBT::ExportInfill;

subtest 'is_private normalization' => sub {
  is QBTL::Process::QBT::ExportInfill::_is_private_value(1),         1,     '1 is private';
  is QBTL::Process::QBT::ExportInfill::_is_private_value(0),         0,     '0 is public';
  is QBTL::Process::QBT::ExportInfill::_is_private_value('true'),    1,     'true is private';
  is QBTL::Process::QBT::ExportInfill::_is_private_value('false'),   0,     'false is public';
  is QBTL::Process::QBT::ExportInfill::_is_private_value('private'), 1,     'private string is private';
  is QBTL::Process::QBT::ExportInfill::_is_private_value('public'),  0,     'public string is public';
  is QBTL::Process::QBT::ExportInfill::_is_private_value(undef),     undef, 'undef remains unknown';
};

subtest 'tracker list policy' => sub {
  ok !QBTL::Process::QBT::ExportInfill::_torrent_needs_tracker_list(
    { hash => 'privatehash', is_private => 1 },
  ), 'private torrent does not need full tracker list';

  ok QBTL::Process::QBT::ExportInfill::_torrent_needs_tracker_list(
    { hash => 'publichash', is_private => 0 },
  ), 'public torrent needs full tracker list';

  ok QBTL::Process::QBT::ExportInfill::_torrent_needs_tracker_list(
    { hash => 'unknownhash' },
  ), 'unknown private/public state fetches full tracker list conservatively';
};

subtest 'live API infill plan' => sub {
  my @plan = QBTL::Process::QBT::ExportInfill::_live_api_infill_plan(
    { hash => 'privatehash', name => 'private', is_private => 1 },
    { hash => 'publichash',  name => 'public',  is_private => 0 },
    { hash => 'unknownhash', name => 'unknown' },
  );

  is scalar @plan, 3, 'three plan rows';

  is $plan[0]{fetch_comment},      1, 'private fetches comment';
  is $plan[0]{fetch_file_list},    1, 'private fetches file list';
  is $plan[0]{fetch_tracker_list}, 0, 'private skips full tracker list';

  is $plan[1]{fetch_comment},      1, 'public fetches comment';
  is $plan[1]{fetch_file_list},    1, 'public fetches file list';
  is $plan[1]{fetch_tracker_list}, 1, 'public fetches full tracker list';

  is $plan[2]{fetch_comment},      1, 'unknown fetches comment';
  is $plan[2]{fetch_file_list},    1, 'unknown fetches file list';
  is $plan[2]{fetch_tracker_list}, 1, 'unknown fetches full tracker list';
};

done_testing;
