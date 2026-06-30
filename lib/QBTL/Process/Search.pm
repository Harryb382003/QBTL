package QBTL::Process::Search;

use v5.40;
use common::sense;
use feature qw( signatures );

use QBTL::Process::WithDB;
use QBTL::Local::Parser;
use QBTL::Util qw( parse_byte_values );

sub new ( $class, %arg ) {
  $arg{db_process} //= QBTL::Process::WithDB->new( db_path => $arg{db_path}, );

  return bless \%arg, $class;
}

sub db_process ( $self ) {
  return $self->{db_process};
}

sub search_list ( $self ) {
  return $self->db_process->with_db(
    sub ( $db, $dbh ) {
      return {
              ok     => 1,
              action => 'search_list',
              fields => [ $db->qbt_info_columns( $dbh ) ],};
    } );
}

sub search ( $self, %arg ) {
  my $field = $arg{field};
  my $input = $arg{input};
  my $limit = $arg{limit} // 25;

  return $self->db_process->with_db(
    sub ( $db, $dbh ) {
      if ( $field eq 'hash' && defined $input && $input =~ /\A[0-9A-Fa-f]{40}\z/ ) {
        return $self->_search_hash( $db, $dbh, lc $input );
      }

      my $size_query = $self->_size_query( $field, $input );

      if ( $size_query ) {
        my $result =
            $db->search_qbt_size( $dbh, $size_query, limit => $limit, );

        $result->{action} = 'search';

        return $result;
      }

      my $result =
          $db->search_qbt_info( $dbh, $field, $input, limit => $limit, );

      $result->{action} = 'search';

      return $result;
    } );
}


sub hat ( $self ) {
  return $self->db_process->with_db(
    sub ( $db, $dbh ) {
      my $inventory = $self->_refresh_hash_as_name_inventory( $db, $dbh );
      my $result    = $db->search_hash_as_name($dbh);

      $result->{action}              = 'search_hat';
      $result->{definition}          = 'hash as name';
      $result->{inventory}           = $inventory;
      $result->{hash_as_name_hashes} = $db->qbt_hash_as_name_count($dbh);

      return $result;
    } );
}

sub _search_hash ( $self, $db, $dbh, $hash ) {
  my $row           = $db->qbt_info_by_hash( $dbh, $hash );
  my $qbt_loaded    = $row && $row->{current_qbt} ? 1 : 0;
  my $torrent_state = undef;

  if ($qbt_loaded) {
    $torrent_state = $self->_check_qbt_torrent_file( $db, $dbh, $hash );
    $row           = $db->qbt_info_by_hash( $dbh, $hash );
  }

  my $matches = $db->local_torrent_matches_for_hash( $dbh, $hash );

  my $status = 'NOT LOADED';

  if ($qbt_loaded) {
    $status = $row->{qbt_torrent_file} ? 'LOADED/RUNNING' : 'NEEDS TORRENT';
  }

  return {
          ok              => 1,
          action          => 'search_hash',
          field           => 'hash',
          input           => $hash,
          hash            => $hash,
          rows            => $row ? [$row] : [],
          row             => $row,
          qbt_loaded      => $qbt_loaded,
          qbt_status      => $status,
          qbt_torrent     => $torrent_state,
          local_matches   => $matches->{rows},
          local_count     => $matches->{count},
          local_hash_field => $matches->{hash_column},};
}

sub _check_qbt_torrent_file ( $self, $db, $dbh, $hash ) {
  my $home = $ENV{HOME} // '';
  my $dir  = $home . '/Library/Application Support/qBittorrent/BT_backup';
  my $path = $dir . '/' . $hash . '.torrent';

  my $exists = $home ne '' && -e $path ? 1 : 0;

  $db->update_qbt_torrent_file_state(
                                      $dbh,
                                      hash   => $hash,
                                      exists => $exists,
  );

  my $parsed = $exists ? $self->_store_qbt_backup_torrent( $db, $dbh, $path ) : undef;

  return {
          ok     => $home ne '' ? 1 : 0,
          dir    => $dir,
          path   => $path,
          exists => $exists,
          parsed => $parsed,};
}

sub _store_qbt_backup_torrent ( $self, $db, $dbh, $path ) {
  my @stat = stat $path;

  my $stored = $db->upsert_local_torrent_file(
                                               $dbh,
                                               {
                                                path    => $path,
                                                size    => $stat[7] // 0,
                                                mtime   => $stat[9] // 0,
                                                backend => 'qbt_bt_backup',
                                               } );

  my $parse = QBTL::Local::Parser->new->parse_file($path);

  my $parse_result = $db->update_local_torrent_parse(
    $dbh,
    {
     path               => $path,
     infohash           => $parse->{infohash},
     torrent_name       => $parse->{torrent_name},
     comment            => $parse->{comment},
     announce           => $parse->{announce},
     created_by         => $parse->{created_by},
     creation_date      => $parse->{creation_date},
     payload_kind       => $parse->{payload_kind},
     payload_root_name  => $parse->{payload_root_name},
     payload_file_count => $parse->{payload_file_count},
     payload_total_size => $parse->{payload_total_size},
     payload_probe_path => $parse->{payload_probe_path},
     payload_probe_name => $parse->{payload_probe_name},
     parse_ok           => $parse->{ok} ? 1     : 0,
     parse_problem      => $parse->{ok} ? undef : $parse->{problem},
    } );

  if ( $parse->{ok} && $parse->{infohash} ) {
    for my $key ( @{ $parse->{observed_keys} // [] } ) {
      $db->upsert_hash_value(
                              $dbh,
                              hash       => $parse->{infohash},
                              key        => $key->{key},
                              value      => $key->{value},
                              value_type => $key->{value_type} // 'text',
      );
    }
  }

  return {
          ok      => $stored->{ok} && $parse_result->{ok} ? 1 : 0,
          path    => $path,
          parse_ok => $parse->{ok} ? 1 : 0,};
}

sub _refresh_hash_as_name_inventory ( $self, $db, $dbh ) {
  my $hashes = $db->current_qbt_hashes($dbh);

  my $home = $ENV{HOME} // '';
  my $dir  = $home . '/Library/Application Support/qBittorrent/BT_backup';

  if ( $home eq '' || !-d $dir ) {
    return {
            ok          => 0,
            status      => 'bt_backup_not_found',
            dir         => $dir,
            current_qbt => scalar @{$hashes},
            torrents    => 0,
            missing     => 0,};
  }

  my ( $torrent_files, $missing ) = ( 0, 0 );

  for my $hash ( @{$hashes} ) {
    next if !defined $hash;
    next if $hash !~ /\A[0-9A-Fa-f]{40}\z/;

    my $exists = -e "$dir/$hash.torrent" ? 1 : 0;

    $db->update_qbt_torrent_file_state(
                                        $dbh,
                                        hash   => $hash,
                                        exists => $exists,
    );

    if ($exists) {
      $torrent_files++;
    } else {
      $missing++;
    }
  }

  return {
          ok          => 1,
          dir         => $dir,
          current_qbt => scalar @{$hashes},
          torrents    => $torrent_files,
          missing     => $missing,};
}

sub _size_field ( $self, $field ) {
  return 1 if $field eq 'total_size';
  return 1 if $field eq 'amount_left';
  return;
}

sub _size_query ( $self, $field, $input ) {
  return if !$self->_size_field( $field );
  return if !defined $input;

  my $text = $input;
  $text =~ s/^\s+//;
  $text =~ s/\s+$//;

  if ( $text =~ /\A([<>]=?)\s*(.+)\z/ ) {
    my $op    = $1;
    my @bytes = parse_byte_values( $2 );

    return if !@bytes;

    return {
            type   => 'size_compare',
            field  => $field,
            op     => $op,
            values => \@bytes,};
  }

  if ( $text =~ /\A(.+?)\s+(\d+(?:\.\d+)?)%\z/ ) {
    my @bytes   = parse_byte_values( $1 );
    my $percent = $2 + 0;

    return if !@bytes;

    my @range;

    for my $bytes ( @bytes ) {
      my $spread = int( $bytes * ( $percent / 100 ) );

      push @range,
          {
           low   => $bytes - $spread,
           high  => $bytes + $spread,
           bytes => $bytes,};
    }

    return {
            type   => 'size_range',
            field  => $field,
            pct    => $percent,
            ranges => \@range,};
  }

  return;
}

1;
