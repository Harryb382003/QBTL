package QBTL::Process::Setup;

use v5.40;
use common::sense;
use feature qw( signatures );

use File::Path qw( make_path );
use File::Spec;

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

    my $local_search = $self->_detect_local_search_tool;

    my $db_result;

    if ( defined $self->{db} ) {
        my $connect = $self->{db}->connect;

        if ( !$connect->{ok} ) {
            return {
                ok        => 0,
                home      => $home,
                created   => \@created,
                existing  => \@existing,
                db_result    => $connect,
                local_search => $local_search,
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
        db_result    => $db_result,
        local_search => $local_search,
    };
}

sub _detect_local_search_tool ($self) {
    my @tools = (
        { name => 'mdfind',  indexed => 1 },
        { name => 'plocate', indexed => 1 },
        { name => 'mlocate', indexed => 1 },
        { name => 'locate',  indexed => 1 },
        { name => 'slocate', indexed => 1 },
        { name => 'find',    indexed => 0 },
    );

    my @found;

    for my $tool (@tools) {
        my $path = $self->_command_path( $tool->{name} );

        push @found, {
            name    => $tool->{name},
            path    => $path,
            indexed => $tool->{indexed},
            found   => defined $path ? 1 : 0,
        };
    }

    my ($selected) = grep { $_->{found} && $_->{indexed} } @found;
    my $warning;

    if ( !defined $selected ) {
        ($selected) = grep { $_->{found} && $_->{name} eq 'find' } @found;

        if ( defined $selected ) {
            $warning =
                'No indexed local search tool found. Consider installing ' .
                'plocate, mlocate, or locate for DB-driven local file discovery. ' .
                'Using filesystem fallback: find';
        }
    }

    if ( !defined $selected ) {
        return {
            ok       => 0,
            status   => 'no_local_search_tool',
            tools    => \@found,
            problems => [ 'No local search tool found' ],
        };
    }

    return {
        ok          => 1,
        tools       => \@found,
        search_tool => $selected->{name},
        path        => $selected->{path},
        indexed     => $selected->{indexed},
        warning     => $warning,
    };
}

sub _command_path ( $self, $command ) {
    return if !defined $command || $command eq '';

    for my $dir ( File::Spec->path ) {
        next if !defined $dir || $dir eq '';

        my $path = File::Spec->catfile( $dir, $command );
        return $path if -x $path && !-d $path;
    }

    return;
}

1;
