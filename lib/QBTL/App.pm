package QBTL::App;

use v5.40;
use common::sense;
use feature qw( signatures );

use QBTL;
use QBTL::Render::CLI;

sub new ($class, %arg) {
    $arg{renderer} //= QBTL::Render::CLI->new;

    return bless \%arg, $class;
}

sub run_cli ($self, @argv) {
    my $cmd = shift @argv // 'help';

    if ( $cmd eq 'version' ) {
        return $self->{renderer}->version($QBTL::VERSION);
    }

    return $self->{renderer}->help;
}

1;
