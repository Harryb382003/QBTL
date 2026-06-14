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
    say {$out} "  setup      Create QBTL runtime directories";

    return 0;
}

sub setup ($self, $result) {
    my $out = $self->{out};

    if ( !$result->{ok} ) {
        say {$out} "QBTL setup failed.";
        return 1;
    }

    say {$out} "QBTL setup complete.";
    say {$out} "Home: $result->{home}";

    if ( @{ $result->{created} } ) {
        say {$out} "";
        say {$out} "Created:";
        say {$out} "  $_" for @{ $result->{created} };
    }

    if ( @{ $result->{existing} } ) {
        say {$out} "";
        say {$out} "Already existed:";
        say {$out} "  $_" for @{ $result->{existing} };
    }

    return 0;
}

1;
