requires 'perl', '5.040';
requires 'common::sense';
requires 'DBI';
requires 'DBD::SQLite';

on 'test' => sub {
    requires 'Test::More';
};
