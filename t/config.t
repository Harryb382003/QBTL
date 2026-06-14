use v5.40;
use common::sense;
use feature qw( signatures );

use Test::More;

use QBTL::Config;

my $config = QBTL::Config->new;

isa_ok( $config, 'QBTL::Config' );

is( $config->db_path, 'var/qbtl.sqlite',       'default db path' );
is( $config->qbt_url, 'http://localhost:8080', 'default qBT URL' );

$config = QBTL::Config->new(
    db_path => 'tmp/test.sqlite',
    qbt_url => 'http://127.0.0.1:8080',
);

is( $config->db_path, 'tmp/test.sqlite',       'custom db path' );
is( $config->qbt_url, 'http://127.0.0.1:8080', 'custom qBT URL' );

done_testing;
