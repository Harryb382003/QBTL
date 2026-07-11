package QBTL::Process::Metadata;

use v5.40;
use common::sense;
use feature qw( signatures );

use File::Spec;
use QBTL::Process::WithDB;
use QBTL::Local::Parser;

sub new ( $class, %arg ) {
  my $self =
      {with_db => QBTL::Process::WithDB->new( db_path => $arg{db_path}, ),};

  return bless $self, $class;
}

sub key ( $self, %arg ) {
  return $self->{with_db}->with_db(
    sub ( $db, $dbh ) {
      return
          $db->hash_key_detail(
                                $dbh,
                                key   => $arg{key},
                                limit => $arg{limit} // 25, );
    } );
}

sub keys ( $self ) {
  return $self->{with_db}->with_db(
    sub ( $db, $dbh ) {
      return $db->hash_keys( $dbh );
    } );
}

sub keys_all ( $self ) {
  return $self->{with_db}->with_db(
    sub ( $db, $dbh ) {
      return $db->key_accessors( $dbh );
    } );
}

sub set_manual ( $self, %arg ) {
  return $self->{with_db}->with_db(
    sub ( $db, $dbh ) {
      return
          $db->set_manual_value(
                                 $dbh,
                                 hash  => $arg{hash},
                                 key   => $arg{key},
                                 value => $arg{value},
                                 note  => $arg{note}, );
    } );
}

sub get_manual ( $self, %arg ) {
  return $self->{with_db}->with_db(
    sub ( $db, $dbh ) {
      return $db->manual_values_for_hash( $dbh, $arg{hash} );
    } );
}

sub unset_manual ( $self, %arg ) {
  return $self->{with_db}->with_db(
    sub ( $db, $dbh ) {
      return
          $db->unset_manual_value(
                                   $dbh,
                                   hash => $arg{hash},
                                   key  => $arg{key}, );
    } );
}

sub promote ( $self, %arg ) {
  return $self->{with_db}->with_db(
    sub ( $db, $dbh ) {
      return $db->promote_hash_key(
        $dbh,
        key    => $arg{key},
        column => $arg{column},
      );
    }
  );
}

sub promoted ($self) {
  return $self->{with_db}->with_db(
    sub ( $db, $dbh ) {
      return $db->promoted_hash_keys($dbh);
    }
  );
}

sub candidates ( $self, %arg ) {
  my $threshold = $arg{threshold} // 20;

  return $self->{with_db}->with_db(
    sub ( $db, $dbh ) {
      my $result = $db->promotion_candidates(
        $dbh,
        threshold => $threshold,
      );

      return $result if !$result->{ok};

      for my $row ( @{ $result->{candidates} // [] } ) {
        $row->{action} =
          'meta promote ' . $row->{key};

        $row->{message} =
          'Metadata key "' . $row->{key} . '" has appeared '
          . ( $row->{seen} // 0 ) . ' times.';

        $row->{question} =
          'Promote it to a hash-centered column?';
      }

      return $result;
    }
  );
}


sub infill_known_exports ( $self, %arg ) {
  my $db      = $arg{db};
  my $dbh     = $arg{dbh};
  my $buckets = $arg{buckets} // [];
  my $parser  = QBTL::Local::Parser->new;

  my @problem;

  my $result = {
                ok                 => 1,
                action             => 'qbt_metadata',
                torrents           => 0,
                evidence_sources   => 0,
                trackers           => 0,
                payload_files      => 0,
                info_fields        => 0,
                bt_backup_evidence => 0,
                problems           => \@problem,};

  for my $bucket ( @{$buckets} ) {
    next if ref $bucket ne 'HASH';

    my $which = $bucket->{which} // next;
    my $keeper_by_hash = $bucket->{keeper_by_hash} // {};

    for my $hash ( sort keys %{$keeper_by_hash} ) {
      my $keeper = $keeper_by_hash->{$hash};
      next if ref $keeper ne 'HASH';

      my $path = $keeper->{path};

      if ( !defined $path || $path eq '' || !-f $path ) {
        next;
      }

      my $decoded = $parser->parse_file($path);

      if ( !$decoded->{ok} ) {
        push @problem,
            {
             which => $which,
             path  => $path,
             hash  => $hash,
             error => 'metadata parse failed',
             parse_problem => $decoded->{problem},};
        next;
      }

      if ( ( $decoded->{infohash} // '' ) ne $hash ) {
        push @problem,
            {
             which => $which,
             path  => $path,
             hash  => $hash,
             error => 'metadata source hash mismatch',
             expected_hash => $hash,
             actual_hash   => $decoded->{infohash},
             parse_ok      => 1,
             parse_problem => undef,};
        next;
      }

      $db->record_torrent_evidence_source(
        $dbh,
        hash          => $hash,
        source        => $which,
        path          => $path,
        bucket        => $which,
        evidence_kind => 'torrent_metadata',
      );
      $result->{evidence_sources}++;

      my $tracker_result = $db->replace_torrent_trackers(
        $dbh,
        hash     => $hash,
        source   => $which,
        trackers => $decoded->{trackers},
      );

      my $payload_result = $db->replace_torrent_payload_files(
        $dbh,
        hash   => $hash,
        source => $which,
        files  => $decoded->{payload_files},
      );

      my $field_result = $db->replace_torrent_info_fields(
        $dbh,
        hash   => $hash,
        source => $which,
        fields => $decoded->{info_fields},
      );

      $result->{torrents}++;
      $result->{trackers}      += $tracker_result->{stored} // 0;
      $result->{payload_files} += $payload_result->{stored} // 0;
      $result->{info_fields}   += $field_result->{stored}   // 0;
    }
  }

  my $bt_backup = $self->_infill_bt_backup_evidence( db => $db, dbh => $dbh );
  $result->{bt_backup_evidence} = $bt_backup->{stored} // 0;
  $result->{evidence_sources} += $bt_backup->{stored} // 0;
  push @problem, @{ $bt_backup->{problems} // [] };

  $result->{ok} = @problem ? 0 : 1;

  return $result;
}

sub _infill_bt_backup_evidence ( $self, %arg ) {
  my $db  = $arg{db};
  my $dbh = $arg{dbh};

  my @problem;
  my $stored = 0;
  my $dir = $self->_bt_backup_dir;

  return { ok => 1, stored => 0, problems => \@problem }
      if !length $dir || !-d $dir;

  for my $hash ( @{ $db->current_qbt_hashes( $dbh ) } ) {
    my $path = File::Spec->catfile( $dir, $hash . '.torrent' );
    next if !-f $path;

    $db->record_torrent_evidence_source(
      $dbh,
      hash          => $hash,
      source        => 'bt_backup',
      path          => $path,
      bucket        => 'BT_backup',
      evidence_kind => 'qbt_hash_named_torrent',
    );

    $stored++;
  }

  return { ok => @problem ? 0 : 1, stored => $stored, problems => \@problem };
}

sub _bt_backup_dir ( $self ) {
  my $home = $ENV{HOME} // '';
  return '' if !length $home;

  return File::Spec->catdir(
    $home,
    'Library',
    'Application Support',
    'qBittorrent',
    'BT_backup',
  );
}


sub _is_private_value ($value) {
  return undef if !defined $value;

  return $value ? 1 : 0
      if !ref($value) && $value =~ /\A[01]\z/;

  if ( !ref($value) ) {
    my $v = $value;

    return 1 if $v =~ /\A(?:true|yes|private)\z/;
    return 0 if $v =~ /\A(?:false|no|public)\z/;
  }

  return $value ? 1 : 0;
}

sub _torrent_is_private ($torrent) {
  die "_torrent_is_private requires a hashref torrent\n"
      unless ref($torrent) eq 'HASH';

  return _is_private_value( $torrent->{is_private} );
}

sub _torrent_needs_tracker_list ($torrent) {
  my $is_private = _torrent_is_private($torrent);

  # Unknown should be conservative.  Do not silently lose multi-tracker data
  # just because this row does not expose is_private.
  return 1 if !defined $is_private;

  # Private torrents can rely on the single tracker/announce already present
  # from torrents_info. Public torrents need the full trackers API result.
  return $is_private ? 0 : 1;
}

sub _live_api_infill_plan (@torrents) {
  my @plan;

  for my $torrent (@torrents) {
    die "_live_api_infill_plan requires hashref torrents\n"
        unless ref($torrent) eq 'HASH';

    my $hash =
           $torrent->{hash}
        // $torrent->{infohash}
        // $torrent->{info_hash};

    die "torrent is missing hash/infohash\n"
        unless defined $hash && length $hash;

    push @plan,
        {
          hash               => $hash,
          name               => $torrent->{name},
          is_private         => _torrent_is_private($torrent),
          fetch_comment      => 1,
          fetch_file_list    => 1,
          fetch_tracker_list => _torrent_needs_tracker_list($torrent),
        };
  }

  return @plan;
}


1;
