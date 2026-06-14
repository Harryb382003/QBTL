package QBTL::App;

use v5.40;
use common::sense;
use feature qw( signatures );

use QBTL;
use QBTL::Config;
use QBTL::Process::Setup;
use QBTL::Render::CLI;

sub new ($class, %arg) {
    $arg{config}   //= QBTL::Config->new;
    $arg{renderer} //= QBTL::Render::CLI->new;

    return bless \%arg, $class;
}

sub run_cli ($self, @argv) {
    my $cmd = shift @argv // 'help';

    if ( $cmd eq 'version' ) {
        return $self->{renderer}->version($QBTL::VERSION);
    }

    if ( $cmd eq 'setup' ) {
        my $setup  = QBTL::Process::Setup->new( home => $self->_qbtl_home );
        my $result = $setup->run;

        return $self->{renderer}->setup($result);
    }

    return $self->{renderer}->help;
}

sub _qbtl_home ($self) {
    my $db_path = $self->{config}->db_path;

    $db_path =~ s{/[^/]+\z}{};

    return $db_path;
}

1;
