package QBTL::App;

use v5.40;
use common::sense;
use feature qw( signatures );

use QBTL;

sub new ($class, %arg) {
    return bless { %arg }, $class;
}

sub run_cli ($self, @argv) {
    my $cmd = shift @argv // 'help';

    if ( $cmd eq 'version' ) {
        say 'QBTL ' . $QBTL::VERSION;
        return 0;
    }

    say "Usage: qbtl <command>";
    say "";
    say "Commands:";
    say "  version    Show QBTL version";

    return 0;
}

1;
