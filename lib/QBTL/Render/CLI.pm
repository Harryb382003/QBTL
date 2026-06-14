package QBTL::Render::CLI;

use v5.40;
use common::sense;
use feature qw( signatures );

sub new ($class, %arg) {
    $arg{out} //= \*STDOUT;

    return bless \%arg, $class;
}

sub version ($self, $version) {
    my $out = $self->{out};

    say {$out} "QBTL $version";

    return 0;
}

sub help ($self) {
    my $out = $self->{out};

    say {$out} "Usage: qbtl <command>";
    say {$out} "";
    say {$out} "Commands:";
    say {$out} "  version    Show QBTL version";

    return 0;
}

1;
