package QBTL::Help;

use v5.40;
use common::sense;
use feature qw( signatures );

sub topic ( $class, $name ) {
  my %topics = $class->topics;
  return $topics{$name} // $topics{main};
}

sub topics ( $class ) {
  return (
    main => {
             title    => 'QBTL',
             usage    => 'qbtl <command> [options]',
             commands => [
                           [ help    => 'Show this help' ],
                           [ version => 'Show QBTL version' ],
                           [ setup   => 'create/update the QBTL database' ],
                           [ qbt     => 'qBittorrent API commands' ],
                           [ local   => 'local scan and summary commands' ],
                           [ search  => 'search qBT data' ],
                           [ meta    => 'hash-centered metadata commands' ],
             ],
    },

    meta => {
        title    => 'QBTL metadata commands',
        usage    => 'qbtl meta <command>',
        commands => [
          [
            candidates => 'list observed keys that are candidates for promotion'
          ],
          [ keys     => 'list observed metadata keys' ],
          [ key      => 'inspect one observed metadata key' ],
          [ promote  => 'promote an observed metadata key to a real column' ],
          [ promoted => 'list promoted metadata keys' ],
          [ set      => 'set a manual hash-tied value' ],
          [ get      => 'show manual values for a hash' ],
          [ unset    => 'remove a manual hash-tied value' ],
        ],
        examples => [
                      'qbtl meta keys',
                      'qbtl meta key qBt-savePath',
                      'qbtl meta set <hash> preferred_path /Volumes/Media',
                      'qbtl meta get <hash>',
                      'qbtl meta promote qBt-savePath',
                      'qbtl meta promoted',
                      'qbtl meta unset <hash> preferred_path',
        ],
    },

    qbt => {
            title    => 'QBT qBittorrent commands',
            usage    => 'qbtl qbt <command>',
            commands => [
                          [ help    => 'Show this help' ],
                          [ info    => 'Fetch qBittorrent torrents/info' ],
                          [ refresh => 'Store qBittorrent torrents/info rows' ],
                          [ version => 'Show qBittorrent version' ],
            ],
            examples => [
                          'qbtl qbt help',
                          'qbtl qbt info',
                          'qbtl qbt refresh',
                          'qbtl qbt version',
            ],
    },

    search => {
               title    => 'QBTL search commands',
               usage    => 'qbtl search <field> <value>',
               commands => [
                             [ help => 'Show this help' ],
                             [ list => 'List searchable qBT fields' ],
               ],
               examples => [
                             'qbtl search list',
                             'qbtl search name ubuntu',
                             'qbtl search total_size "> 10 G"',
               ],
    }, );
}

1;
