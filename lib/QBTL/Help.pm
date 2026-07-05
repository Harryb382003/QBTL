package QBTL::Help;

use v5.40;
use common::sense;
use feature qw( signatures );

sub topic ( $class, $name ) {
  my %topics = $class->topics;
  return $topics{$name} // $topics{main};
}

sub all ( $class ) {
  my %topics = $class->topics;

  return [ @topics{qw( main local meta qbt search )} ];
}

sub topics ( $class ) {
  return (
    main => {
             title    => 'QBTL',
             usage    => 'qbtl <command> [options]',
             commands => [
                     [ help => 'Show this help; use help all for every topic' ],
                     [ init => 'initialize/update the QBTL database' ],
                     [ local   => 'local scan and summary commands' ],
                     [ meta    => 'hash-centered metadata commands' ],
                     [ qbt     => 'qBittorrent API commands' ],
                     [ search  => 'search qBT data' ],
                     [ setup   => 'create/update the QBTL database' ],
                     [ version => 'Show QBTL version' ],
             ],
    },

    local => {
           title    => 'QBTL local commands',
           usage    => 'qbtl local <command>',
           commands => [
                    [ help    => 'Show this help' ],
                    [ summary => 'Show local torrent file scan summary' ],
                    [ scan    => 'Full local .torrent/.fastresume scan' ],
                    [ refresh => 'Incrementally scan only new local evidence' ],
           ],
           examples => [
                         'qbtl local summary',
                         'qbtl local scan',
                         'qbtl local refresh',
                         'qbtl local refresh /path/to/directory',
                         'qbtl local scan /path/to/file.torrent',
                         'qbtl local scan /path/to/directory',
           ],
    },

    meta => {
       title    => 'QBTL metadata commands',
       usage    => 'qbtl meta <command>',
       commands => [
         [
           candidates => 'list observed keys that are candidates for promotion'
         ],
         [
           keys => 'list observed metadata keys; use keys all for key inventory'
         ],
         [ key      => 'inspect one observed metadata key' ],
         [ promote  => 'promote an observed metadata key to a real column' ],
         [ promoted => 'list promoted metadata keys' ],
         [ set      => 'set a manual hash-tied value' ],
         [ get      => 'show manual values for a hash' ],
         [ unset    => 'remove a manual hash-tied value' ],
       ],
       examples => [
                     'qbtl meta keys',
                     'qbtl meta keys all',
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
                    [ add  => 'Add/rehydrate a torrent by path or infohash' ],
                    [ help => 'Show this help' ],
                    [ info            => 'Fetch qBittorrent torrents/info' ],
                    [ preferences => 'Store/list qBittorrent app/preferences' ],
                    [ refresh     => 'Store qBittorrent torrents/info rows' ],
                    [ version     => 'Show qBittorrent version' ],
            ],
            examples => [
                          'qbtl qbt help',
                          'qbtl qbt add /path/to/file.torrent',
                          'qbtl qbt add <infohash>',
                          'qbtl qbt info',
                          'qbtl qbt preferences',
                          'qbtl qbt preferences keys',
                          'qbtl qbt refresh',
                          'qbtl qbt version',
            ],
    },

    search => {
               title    => 'QBTL search commands',
               usage    => 'qbtl search <field> <value>',
               commands => [
                             [ help => 'Show this help' ],
                             [ hat  => 'hash as name' ],
                             [ list => 'List searchable qBT fields' ],
               ],
               examples => [
                             'qbtl search hat',
                             'qbtl search list',
                             'qbtl search name ubuntu',
                             'qbtl search total_size "> 10 G"',
               ],
    }, );
}

1;
