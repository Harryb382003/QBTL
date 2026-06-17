use v5.40;
use common::sense;
use feature qw( signatures );

use Test::More;

use_ok( 'QBTL' );

use_ok( 'QBTL::QBT::API' );

use_ok( 'QBTL::App' );
use_ok( 'QBTL::Config' );
use_ok( 'QBTL::DB' );
use_ok('QBTL::Help');

use_ok( 'QBTL::Local::Parser' );
use_ok( 'QBTL::Local::Scanner' );

use_ok( 'QBTL::Process::Browse' );
use_ok( 'QBTL::Process::Local' );
use_ok( 'QBTL::Process::Metadata' );
use_ok( 'QBTL::Process::QBT' );
use_ok( 'QBTL::Process::Search' );
use_ok( 'QBTL::Process::Setup' );
use_ok( 'QBTL::Process::WithDB' );

use_ok( 'QBTL::Render::Chandra' );
use_ok( 'QBTL::Render::CLI' );
use_ok( 'QBTL::Render::Mojo' );

done_testing;
