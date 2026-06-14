package QBTL::Process::Setup;

use v5.40;
use common::sense;
use feature qw( signatures );

use File::Path qw( make_path );

sub new ($class, %arg) {
    die 'home is required' if !defined $arg{home};

    return bless \%arg, $class;
}

sub home ($self) {
    return $self->{home};
}

sub run ($self) {
    my $home = $self->home;

    my @dirs = (
        $home,
        "$home/logs",
        "$home/backups",
        "$home/tmp",
    );

    my @created;
    my @existing;

    for my $dir (@dirs) {
        if ( -d $dir ) {
            push @existing, $dir;
            next;
        }

        make_path($dir);
        push @created, $dir;
    }

    return {
        ok       => 1,
        home     => $home,
        created  => \@created,
        existing => \@existing,
    };
}

1;
