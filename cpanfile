requires 'perl', '5.040';
requires 'common::sense';
requires 'DBI';
requires 'DBD::SQLite';
requires 'URI';
requires 'URI::Escape';
requires 'LWP::UserAgent';
requires 'HTTP::Cookies';
requires 'JSON::PP'

on 'test' => sub {
    requires 'Test::More';
};
