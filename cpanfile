requires 'perl', '5.040';
requires 'common::sense';
requires 'DBI';
requires 'DBD::SQLite';
requires 'URI';
requires 'URI::Escape';
requires 'LWP::UserAgent';
requires 'HTTP::Cookies';
requires 'Config::Std';
requires 'JSON::PP'
requires 'Bencode';

on 'test' => sub {
    requires 'Test::More';
};
