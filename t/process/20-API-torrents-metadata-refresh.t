use v5.40;
use common::sense;
use feature qw( signatures );

use Test2::V0;
use lib 'lib';

use QBTL::Process::QBT;

{
  package Local::QBT;

  use parent 'QBTL::Process::QBT';

  sub new ( $class, %arg ) {
    $arg{calls} //= [];
    return bless \%arg, $class;
  }

  sub calls ( $self ) { return $self->{calls}; }

  sub info ( $self, %params ) {
    push $self->{calls}->@*, {method => 'info', params => {%params}};
    return $self->{responses}{info};
  }

  sub properties ( $self, $hash ) {
    push $self->{calls}->@*, {method => 'properties', hash => $hash};
    return $self->{responses}{properties}{$hash};
  }

  sub files ( $self, $hash ) {
    push $self->{calls}->@*, {method => 'files', hash => $hash};
    return $self->{responses}{files}{$hash};
  }

  sub trackers ( $self, $hash, $ ) {
    push $self->{calls}->@*, {
      method     => 'trackers',
      hash       => $hash,
       => $,
    };
    return $self->{responses}{trackers}{$hash};
  }
}

{
  package Local::DB;

  sub new ( $class, %arg ) {
    $arg{calls} //= [];
    return bless \%arg, $class;
  }

  sub calls ( $self ) { return $self->{calls}; }

  sub S_API_torrents_refresh ( $self, %arg ) {
    push $self->{calls}->@*, {%arg};

    my $method = $arg{method};
    my $hash   = $arg{hash};
    my $key    = defined $hash ? "$method:$hash" : $method;

    return $self->{responses}{$key}
        if exists $self->{responses}{$key};

    my $payload = $arg{payload};
    my $stored = ref($payload) eq 'ARRAY' ? scalar $payload->@* : 1;

    return {
      ok     => 1,
      stored => $stored,
    };
  }
}

sub method_calls ( $calls, $method ) {
  return [ grep { $_->{method} eq $method } $calls->@* ];
}

subtest 'stores complete metadata and skips private tracker lists' => sub {
  my $private = '1111111111111111111111111111111111111111';
  my $public  = '2222222222222222222222222222222222222222';

  my $qbt = Local::QBT->new(
    responses => {
      info => {
        ok   => 1,
        rows => [
          {hash => $private,  => 1},
          {hash => $public,   => 0},
        ],
      },
      properties => {
        $private => {ok => 1, properties => {comment => 'private comment'}},
        $public  => {ok => 1, properties => {comment => 'public comment'}},
      },
      files => {
        $private => {ok => 1, rows => [ {index => 0}, {index => 1} ]},
        $public  => {ok => 1, rows => [ {index => 0} ]},
      },
      trackers => {
        $public => {ok => 1, rows => [ {url => 'udp://one'}, {url => 'udp://two'}
]},
      },
    },
  );
  my $db = Local::DB->new;

  my $result = $qbt->refresh_API_torrents_metadata(
    db         => $db,
    dbh        => 'dbh',
    fetched_on => 1784512046,
  );

  is(
    $result,
    hash {
      field ok                 => 1;
      field torrents           => 2;
      field info_stored        => 2;
      field properties_stored  => 2;
      field files_stored       => 3;
      field trackers_stored    => 2;
      field trackers_skipped   => 1;
      field preserved_existing => 0;
      field problems           => [];
      etc;
    },
    'complete metadata refresh summarized',
  );

  is(
    method_calls( $qbt->calls, 'trackers' ),
    [
      {
        method     => 'trackers',
        hash       => $public,
         => 0,
      },
    ],
    'full tracker list requested only for public torrent',
  );

  is(
    [ map { $_->{method} } $db->calls->@* ],
    [qw( info properties files properties files trackers )],
    'DB receives info first followed by per-torrent metadata',
  );
};

subtest 'endpoint failures preserve old metadata and do not stop later work' => sub
{
  my $hash = '3333333333333333333333333333333333333333';

  my $qbt = Local::QBT->new(
    responses => {
      info => {ok => 1, rows => [ {hash => $hash,  => 0} ]},
      properties => {
        $hash => {ok => 1, properties => {comment => 'new comment'}},
      },
      files => {
        $hash => {
          ok       => 0,
          problems => [ {error => 'files unavailable'} ],
        },
      },
      trackers => {
        $hash => {ok => 1, rows => [ {url => 'udp://tracker'} ]},
      },
    },
  );
  my $db = Local::DB->new(
    responses => {
      "properties:$hash" => {
        ok       => 0,
        problems => [ {error => 'properties rejected'} ],
      },
    },
  );

  my $result = $qbt->refresh_API_torrents_metadata(
    db  => $db,
    dbh => 'dbh',
  );

  is(
    $result,
    hash {
      field ok                 => 0;
      field preserved_existing => 2;
      field files_stored       => 0;
      field properties_stored  => 0;
      field trackers_stored    => 1;
      field problems => bag {
        item hash {
          field hash   => $hash;
          field method => 'files';
          field error  => 'qBittorrent torrents/files request failed';
        };
        item hash { field error => 'properties rejected'; };
      };
      etc;
    },
    'failed endpoints preserve prior rows while successful endpoint continues',
  );

  is(
    [ map { $_->{method} } $db->calls->@* ],
    [qw( info properties trackers )],
    'failed files fetch is not stored and tracker work still runs',
  );
};

subtest 'hash-limited refresh passes selection to torrents info' => sub {
  my $hash = '4444444444444444444444444444444444444444';

  my $qbt = Local::QBT->new(
    responses => {
      info       => {ok => 1, rows => [ {hash => $hash,  => 1} ]},
      properties => {$hash => {ok => 1, properties => {}}},
      files      => {$hash => {ok => 1, rows => []}},
      trackers   => {},
    },
  );

  my $result = $qbt->refresh_API_torrents_metadata(
    db          => Local::DB->new,
    dbh         => 'dbh',
    info_params => {hashes => $hash},
  );

  is $result->{ok}, 1, 'limited refresh succeeds';
  is $qbt->calls->[0],
      {method => 'info', params => {hashes => $hash}},
      'hash selection is passed unchanged to torrents info';
};

subtest 'failed torrents info does not touch the database' => sub {
  my $qbt = Local::QBT->new(
    responses => {
      info => {
        ok       => 0,
        problems => [ {error => 'info unavailable'} ],
      },
    },
  );
  my $db = Local::DB->new;

  my $result = $qbt->refresh_API_torrents_metadata(
    db  => $db,
    dbh => 'dbh',
  );

  is(
    $result,
    hash {
      field ok                 => 0;
      field preserved_existing => 1;
      field problems           => [ {error => 'info unavailable'} ];
      etc;
    },
    'failed inventory fetch preserves existing database state',
  );
  is $db->calls, [], 'database is untouched';
};

done_testing;
