package QBTL::DB;

use v5.40;
use common::sense;
use feature qw( signatures );

use DBI;

sub new ($class, %arg) {
    die 'db_path is required' if !defined $arg{db_path};

    return bless \%arg, $class;
}

sub db_path ($self) {
    return $self->{db_path};
}

sub connect ($self) {
    my $dbh = DBI->connect(
        'dbi:SQLite:dbname=' . $self->db_path,
        '',
        '',
        {
            RaiseError         => 1,
            PrintError         => 0,
            AutoCommit         => 1,
            sqlite_unicode     => 1,
            sqlite_use_immediate_transaction => 1,
        },
    );

    return $dbh;
}

1;
