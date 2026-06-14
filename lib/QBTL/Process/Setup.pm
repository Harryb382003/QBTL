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

    my $db_result;

    if ( defined $self->{db} ) {
        my $connect = $self->{db}->connect;

        if ( !$connect->{ok} ) {
            return {
                ok        => 0,
                home      => $home,
                created   => \@created,
                existing  => \@existing,
                db_result => $connect,
            };
        }

        my $migration = $self->{db}->migrate( $connect->{dbh} );

        $connect->{dbh}->disconnect;

        $db_result = {
            ok        => 1,
            migration => $migration,
        };
    }

    return {
        ok        => 1,
        home      => $home,
        created   => \@created,
        existing  => \@existing,
        db_result => $db_result,
    };
}

1;
