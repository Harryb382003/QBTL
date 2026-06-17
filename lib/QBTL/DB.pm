package QBTL::DB;

use v5.40;
use common::sense;
use feature qw( signatures );

use DBI;
use File::Basename qw( dirname );
use File::Spec;

sub new ( $class, %arg ) {
  die 'db_path is required' if !defined $arg{db_path};

  $arg{migration_dir} //= File::Spec->catdir( 'share', 'migrations' );

  return bless \%arg, $class;
}

sub clear_current_qbt ( $self, $dbh ) {
  $dbh->do( q{UPDATE qbt_info SET current_qbt = 0} );

  return {ok => 1};
}

sub connect ( $self ) {
  my @problems = $self->verify_path;

  return {
          ok       => 0,
          status   => 'db_path_invalid',
          problems => \@problems,}
      if @problems;

  my $dbh = DBI->connect(
                          'dbi:SQLite:dbname=' . $self->db_path,
                          '', '',
                          {
                           RaiseError                       => 1,
                           PrintError                       => 0,
                           AutoCommit                       => 1,
                           sqlite_unicode                   => 1,
                           sqlite_use_immediate_transaction => 1,
                          }, );

  return {
          ok  => 1,
          dbh => $dbh,};
}

sub db_path ( $self ) {
  return $self->{db_path};
}

sub hash_keys ( $self, $dbh ) {
  my $rows = $dbh->selectall_arrayref(
    q{
      SELECT
        "key",
        COUNT(DISTINCT hash) AS hashes,
        COUNT(DISTINCT value) AS values_seen,
        SUM(seen_count) AS seen
      FROM hash_values
      GROUP BY "key"
      ORDER BY hashes DESC, "key" ASC
    },
    {Slice => {}}, );

  return {
          ok   => 1,
          rows => $rows,};
}

sub hash_key_detail ( $self, $dbh, %arg ) {
  my $key   = $arg{key};
  my $limit = $arg{limit} // 25;

  if ( !defined $key || $key eq '' ) {
    return {
            ok     => 0,
            status => 'invalid_key',
            error  => 'key is required',};
  }

  my $summary = $dbh->selectrow_hashref(
    q{
      SELECT
        "key",
        COUNT(DISTINCT hash) AS hashes,
        COUNT(DISTINCT value) AS values_seen,
        SUM(seen_count) AS seen
      FROM hash_values
      WHERE "key" = ?
      GROUP BY "key"
    },
    undef,
    $key, );

  my $rows = $dbh->selectall_arrayref(
    q{
      SELECT
        hash,
        "key",
        value,
        value_type,
        seen_count,
        first_seen_on,
        last_seen_on
      FROM hash_values
      WHERE "key" = ?
      ORDER BY seen_count DESC, hash ASC
      LIMIT ?
    },
    {Slice => {}},
    $key,
    $limit, );

  return {
          ok      => 1,
          key     => $key,
          summary => $summary,
          rows    => $rows,};
}

sub local_torrent_file_count ( $self, $dbh ) {
  my ( $count ) =
      $dbh->selectrow_array( q{SELECT COUNT(*) FROM local_torrent_files} );

  return $count // 0;
}

sub local_torrent_summary ( $self, $dbh ) {
  my ( $total ) =
      $dbh->selectrow_array( q{SELECT COUNT(*) FROM local_torrent_files} );

  my ( $backend_count ) = $dbh->selectrow_array(
    q{
      SELECT COUNT(DISTINCT backend)
      FROM local_torrent_files
    }
  );

  my ( $latest_seen ) = $dbh->selectrow_array(
    q{
      SELECT MAX(seen_on)
      FROM local_torrent_files
    }
  );

  my ( $parsed ) = $dbh->selectrow_array(
    q{
    SELECT COUNT(*)
    FROM local_torrent_files
    WHERE parse_ok = 1
  }
  );

  my ( $parse_problems ) = $dbh->selectrow_array(
    q{
    SELECT COUNT(*)
    FROM local_torrent_files
    WHERE parse_ok = 0
  }
  );

  return {
          total          => $total          // 0,
          backend_count  => $backend_count  // 0,
          latest_seen    => $latest_seen    // '',
          parsed         => $parsed         // 0,
          parse_problems => $parse_problems // 0,};
}

sub migration_dir ( $self ) {
  return $self->{migration_dir};
}

sub migration_files ( $self ) {
  my $dir = $self->migration_dir;

  opendir my $dh, $dir or die "opendir migration dir $dir: $!";

  my @files = sort
      map { File::Spec->catfile( $dir, $_ ) }
      grep {/\A\d+_.+\.sql\z/} readdir $dh;

  closedir $dh;

  return @files;
}

sub migrate ( $self, $dbh ) {
  my @files           = $self->migration_files;
  my $current_version = 0;
  my $ran             = 0;

  my ( $has_schema_version ) = $dbh->selectrow_array(
    q{
      SELECT name
      FROM sqlite_master
      WHERE type = 'table'
        AND name = 'schema_version'
    }
  );

  if ( $has_schema_version ) {
    ( $current_version ) = $dbh->selectrow_array(
                           q{SELECT version FROM schema_version WHERE id = 1} );

    $current_version //= 0;
  }

  for my $file ( @files ) {
    my ( $file_version ) = $file =~ m{(?:^|/)(\d+)_};

    next if $file_version <= $current_version;

    my $sql = do {
      open my $fh, '<', $file or die "open migration $file: $!";
      local $/;
      <$fh>;
    };

    $dbh->do( $_ ) for grep {/\S/} split /;\s*/, $sql;

    $ran++;
  }

  return {
          ok              => 1,
          migration_count => $ran,};
}

sub promote_hash_key ( $self, $dbh, %arg ) {
  my $key = $arg{key};

  if ( !defined $key || $key eq '' ) {
    return {
      ok     => 0,
      status => 'invalid_key',
      error  => 'key is required',
    };
  }

  my $exists = $dbh->selectrow_array(
    q{
      SELECT COUNT(*)
      FROM hash_values
      WHERE "key" = ?
    },
    undef,
    $key,
  );

  if ( !$exists ) {
    return {
      ok     => 0,
      status => 'key_not_found',
      error  => "observed key not found: $key",
      key    => $key,
    };
  }

  my $column = $arg{column} // _safe_promoted_column_name($key);

  if ( $column !~ /\A[a-z][a-z0-9_]*\z/ ) {
    return {
      ok     => 0,
      status => 'invalid_column',
      error  => "invalid promoted column name: $column",
      key    => $key,
    };
  }

  my $already = $dbh->selectrow_hashref(
    q{
      SELECT key, target_column
      FROM promoted_keys
      WHERE "key" = ?
    },
    undef,
    $key,
  );

  if ($already) {
    return {
      ok            => 1,
      status        => 'already_promoted',
      key           => $key,
      target_column => $already->{target_column},
      promoted      => 0,
      backfilled    => 0,
    };
  }

  my $column_exists = _column_exists( $dbh, 'promoted_values', $column );

  if ( !$column_exists ) {
    $dbh->do(
      qq{
        ALTER TABLE promoted_values
        ADD COLUMN "$column" TEXT
      }
    );
  }

  $dbh->do(
    q{
      INSERT INTO promoted_keys
        ("key", target_column, value_type)
      VALUES
        (?, ?, ?)
    },
    undef,
    $key,
    $column,
    $arg{value_type} // 'text',
  );

  my $rows = $dbh->selectall_arrayref(
    q{
      SELECT hash, value
      FROM hash_values
      WHERE "key" = ?
      ORDER BY last_seen_on DESC, id DESC
    },
    { Slice => {} },
    $key,
  );

  my $insert = $dbh->prepare(
    q{
      INSERT INTO promoted_values (hash)
      VALUES (?)
      ON CONFLICT(hash) DO NOTHING
    }
  );

  my $update = $dbh->prepare(
    qq{
      UPDATE promoted_values
      SET "$column" = ?
      WHERE hash = ?
    }
  );

  my %seen_hash;
  my $backfilled = 0;

  for my $row ( @{$rows} ) {
    next if $seen_hash{ $row->{hash} }++;

    $insert->execute( $row->{hash} );
    $update->execute( $row->{value}, $row->{hash} );

    $backfilled++;
  }

  return {
    ok            => 1,
    status        => 'promoted',
    key           => $key,
    target_column => $column,
    promoted      => 1,
    backfilled    => $backfilled,
  };
}

sub qbt_info_columns ( $self, $dbh ) {
  my $columns = $dbh->selectall_arrayref( q{PRAGMA table_info(qbt_info)},
                                          {Slice => {}}, );

  return map { $_->{name} } @{$columns};
}

sub qbt_info_column_map ( $self, $dbh ) {
  return map { $_ => 1 } $self->qbt_info_columns( $dbh );
}

sub qbt_info_exists ( $self, $dbh, $hash ) {
  my ( $exists ) = $dbh->selectrow_array(
    q{
      SELECT 1
      FROM qbt_info
      WHERE hash = ?
      LIMIT 1
    },
    undef,
    $hash, );

  return $exists ? 1 : 0;
}

sub qbt_summary ( $self, $dbh ) {
  my ( $total ) = $dbh->selectrow_array( q{SELECT COUNT(*) FROM qbt_info} );

  my ( $current ) = $dbh->selectrow_array(
                       q{SELECT COUNT(*) FROM qbt_info WHERE current_qbt = 1} );

  my ( $removed ) = $dbh->selectrow_array(
                       q{SELECT COUNT(*) FROM qbt_info WHERE current_qbt = 0} );

  return {
          total   => $total   // 0,
          current => $current // 0,
          removed => $removed // 0,};
}

sub random_qbt_info ( $self, $dbh ) {
  return $dbh->selectrow_hashref(
    q{
      SELECT *
      FROM qbt_info
      ORDER BY RANDOM()
      LIMIT 1
    }
  );
}

sub removed_qbt_count ( $self, $dbh ) {
  my ( $count ) = $dbh->selectrow_array(
    q{SELECT COUNT(*)
    FROM qbt_info
    WHERE current_qbt = 0
    AND seen = 1}
  );

  return $count // 0;
}

sub _safe_promoted_column_name ($key) {
  my $column = lc $key;

  $column =~ s/[^a-z0-9]+/_/g;
  $column =~ s/\A_+//;
  $column =~ s/_+\z//;
  $column =~ s/_+/_/g;

  if ( $column eq '' ) {
    $column = 'metadata_value';
  }

  if ( $column !~ /\A[a-z]/ ) {
    $column = "metadata_$column";
  }

  return $column;
}

sub _column_exists ( $dbh, $table, $column ) {
  my $columns = $dbh->selectall_arrayref(
    qq{PRAGMA table_info("$table")},
    { Slice => {} },
  );

  for my $row ( @{$columns} ) {
    if ( $row->{name} eq $column ) {
      return 1;
    }
  }

  return 0;
}

sub search_qbt_info ( $self, $dbh, $field, $input, %arg ) {
  my %column = $self->qbt_info_column_map( $dbh );

  return {
          ok     => 0,
          status => 'invalid_search_field',
          field  => $field,
          input  => $input,
          rows   => [],
          count  => 0,}
      if !$column{$field};

  my $limit = $arg{limit} // 25;

  my $sql = qq{
    SELECT *
    FROM qbt_info
    WHERE $field LIKE ?
    ORDER BY name COLLATE NOCASE, hash
    LIMIT ?
  };

  my $rows = $dbh->selectall_arrayref( $sql,
                                       {Slice => {}},
                                       '%' . $input . '%', $limit, );

  return {
          ok    => 1,
          field => $field,
          input => $input,
          rows  => $rows,
          count => scalar @{$rows},
          limit => $limit,};
}

sub search_qbt_size ( $self, $dbh, $query, %arg ) {
  my %column = $self->qbt_info_column_map( $dbh );

  my $field = $query->{field};
  my $limit = $arg{limit} // 25;

  return {
          ok     => 0,
          status => 'invalid_search_field',
          field  => $field,
          rows   => [],
          count  => 0,}
      if !$column{$field};

  my ( $where, @bind );

  if ( $query->{type} eq 'size_compare' ) {
    my @part;

    for my $bytes ( @{$query->{values} // []} ) {
      push @part, "$field $query->{op} ?";
      push @bind, $bytes;
    }

    return {
            ok     => 0,
            status => 'invalid_size_query',
            field  => $field,
            rows   => [],
            count  => 0,}
        if !@part;

    $where = '(' . join( ' OR ', @part ) . ')';
  } elsif ( $query->{type} eq 'size_range' ) {
    my @part;

    for my $range ( @{$query->{ranges} // []} ) {
      push @part, "$field BETWEEN ? AND ?";
      push @bind, $range->{low}, $range->{high};
    }

    return {
            ok     => 0,
            status => 'invalid_size_query',
            field  => $field,
            rows   => [],
            count  => 0,}
        if !@part;

    $where = '(' . join( ' OR ', @part ) . ')';
  } else {
    return {
            ok     => 0,
            status => 'invalid_size_query',
            field  => $field,
            rows   => [],
            count  => 0,};
  }

  my $sql = qq{
    SELECT *
    FROM qbt_info
    WHERE $where
    ORDER BY $field, name COLLATE NOCASE, hash
    LIMIT ?
  };

  my $rows = $dbh->selectall_arrayref( $sql, {Slice => {}}, @bind, $limit, );

  return {
          ok    => 1,
          field => $field,
          input => $query,
          rows  => $rows,
          count => scalar @{$rows},
          limit => $limit,};
}

sub set_manual_value ( $self, $dbh, %arg ) {
  my $hash = $arg{hash};
  my $key  = $arg{key};

  if ( !defined $hash || $hash !~ /\A[0-9a-f]{40}\z/ ) {
    return {
            ok     => 0,
            status => 'invalid_hash',
            error  => 'hash must be a 40-character lowercase hex value',};
  }

  if ( !defined $key || $key eq '' ) {
    return {
            ok     => 0,
            status => 'invalid_key',
            error  => 'key is required',};
  }

  my $value      = defined $arg{value}      ? $arg{value}      : '';
  my $value_type = defined $arg{value_type} ? $arg{value_type} : 'text';
  my $note       = $arg{note};

  $dbh->do(
    q{
      INSERT INTO manual_values
        (hash, "key", value, value_type, note)
      VALUES
        (?, ?, ?, ?, ?)
      ON CONFLICT(hash, "key")
      DO UPDATE SET
        value      = excluded.value,
        value_type = excluded.value_type,
        note       = excluded.note,
        updated_on = CURRENT_TIMESTAMP
    },
    undef,
    $hash,
    $key,
    $value,
    $value_type,
    $note, );

  return {
          ok    => 1,
          hash  => $hash,
          key   => $key,
          value => $value,};
}

sub manual_values_for_hash ( $self, $dbh, $hash ) {
  if ( !defined $hash || $hash !~ /\A[0-9a-f]{40}\z/ ) {
    return {
            ok     => 0,
            status => 'invalid_hash',
            error  => 'hash must be a 40-character lowercase hex value',};
  }

  my $rows = $dbh->selectall_arrayref(
    q{
      SELECT
        hash,
        "key",
        value,
        value_type,
        note,
        created_on,
        updated_on
      FROM manual_values
      WHERE hash = ?
      ORDER BY "key" ASC
    },
    {Slice => {}},
    $hash, );

  return {
          ok   => 1,
          hash => $hash,
          rows => $rows,};
}

sub promoted_hash_keys ( $self, $dbh ) {
  my $rows = $dbh->selectall_arrayref(
    q{
      SELECT
        "key",
        target_column,
        value_type,
        created_on
      FROM promoted_keys
      ORDER BY "key" ASC
    },
    { Slice => {} },
  );

  return {
    ok   => 1,
    rows => $rows,
  };
}

sub upsert_hash_value ( $self, $dbh, %arg ) {
  my $hash = $arg{hash};
  my $key  = $arg{key};

  if ( !defined $hash || $hash !~ /\A[0-9a-f]{40}\z/ ) {
    return {
            ok     => 0,
            status => 'invalid_hash',
            error  => 'hash must be a 40-character lowercase hex value',};
  }

  if ( !defined $key || $key eq '' ) {
    return {
            ok     => 0,
            status => 'invalid_key',
            error  => 'key is required',};
  }

  my $value      = defined $arg{value}      ? $arg{value}      : '';
  my $value_type = defined $arg{value_type} ? $arg{value_type} : 'text';

  $dbh->do(
    q{
      INSERT INTO hash_values
        (hash, "key", value, value_type)
      VALUES
        (?, ?, ?, ?)
      ON CONFLICT(hash, "key", value)
      DO UPDATE SET
        seen_count   = seen_count + 1,
        value_type   = excluded.value_type,
        last_seen_on = CURRENT_TIMESTAMP
    },
    undef,
    $hash,
    $key,
    $value,
    $value_type, );

  return {
          ok    => 1,
          hash  => $hash,
          key   => $key,
          value => $value,};
}

sub unset_manual_value ( $self, $dbh, %arg ) {
  my $hash = $arg{hash};
  my $key  = $arg{key};

  if ( !defined $hash || $hash !~ /\A[0-9a-f]{40}\z/ ) {
    return {
            ok     => 0,
            status => 'invalid_hash',
            error  => 'hash must be a 40-character lowercase hex value',};
  }

  if ( !defined $key || $key eq '' ) {
    return {
            ok     => 0,
            status => 'invalid_key',
            error  => 'key is required',};
  }

  my $rows = $dbh->do(
    q{
      DELETE FROM manual_values
      WHERE hash = ?
      AND "key" = ?
    },
    undef,
    $hash,
    $key, );

  return {
          ok      => 1,
          hash    => $hash,
          key     => $key,
          deleted => $rows + 0,};
}

sub upsert_local_torrent_file ( $self, $dbh, $row ) {
  die 'local torrent file row requires path' if !defined $row->{path};

  $dbh->do(
    q{
      INSERT INTO local_torrent_files (
        path,
        size,
        mtime,
        backend,
        seen_on
      )
      VALUES (
        ?,
        ?,
        ?,
        ?,
        datetime('now')
      )
      ON CONFLICT(path) DO UPDATE SET
        size = excluded.size,
        mtime = excluded.mtime,
        backend = excluded.backend,
        seen_on = excluded.seen_on
    },
    undef,
    $row->{path},
    $row->{size},
    $row->{mtime},
    $row->{backend}, );

  return {
          ok   => 1,
          path => $row->{path},};
}

sub update_local_torrent_parse ( $self, $dbh, $row ) {
  die 'local torrent parse row requires path' if !defined $row->{path};

  $dbh->do(
    q{
      UPDATE local_torrent_files
      SET
        infohash = ?,
        torrent_name = ?,
        comment = ?,
        announce = ?,
        created_by = ?,
        creation_date = ?,
        parsed_on = datetime('now'),
        parse_ok = ?,
        parse_problem = ?
      WHERE path = ?
    },
    undef,
    $row->{infohash},
    $row->{torrent_name},
    $row->{comment},
    $row->{announce},
    $row->{created_by},
    $row->{creation_date},
    $row->{parse_ok},
    $row->{parse_problem},
    $row->{path}, );

  return {
          ok   => 1,
          path => $row->{path},};
}

sub upsert_qbt_info ( $self, $dbh, $row ) {
  die 'qbt info row requires hash' if !defined $row->{hash};

  my %column = $self->qbt_info_column_map( $dbh );

  my %qbtl_owned = map { $_ => 1 } qw(
      seen_on
      current_qbt
      seen
      discovered_on
      discovered_by
  );

  my @qbt_field =
      sort
      grep { exists $column{$_} }
      grep { !$qbtl_owned{$_} }
      keys %{$row};

  die 'qbt info row hash is not storable'
      if !grep { $_ eq 'hash' } @qbt_field;

  my @insert_column = (
    @qbt_field,
    qw(
        seen_on
        current_qbt
        seen
        discovered_on
        discovered_by
    ), );

  my @value = (
                ( q{?} ) x @qbt_field,
                q{datetime('now')}, q{1}, q{1}, q{datetime('now')}, q{'qbt'}, );

  my @update = map {"$_ = excluded.$_"}
      grep { $_ ne 'hash' } @qbt_field;

  push @update,
      q{seen_on = excluded.seen_on},
      q{current_qbt = 1},
      q{seen = 1},
      q{discovered_on = COALESCE(
        qbt_info.discovered_on,
        excluded.discovered_on)
      }, q{discovered_by = COALESCE(
        qbt_info.discovered_by,
        excluded.discovered_by)
      };

  my $columns = join ",\n      ", @insert_column;
  my $values  = join ",\n      ", @value;
  my $updates = join ",\n      ", @update;

  my $sql = qq{
    INSERT INTO qbt_info (
      $columns
    )
    VALUES (
      $values
    )
    ON CONFLICT(hash) DO UPDATE SET
      $updates
  };

  $dbh->do( $sql, undef, map { $row->{$_} } @qbt_field );

  return {
          ok   => 1,
          hash => $row->{hash},};
}

sub verify_path ( $self ) {
  my $db_path = $self->db_path;
  my $dir     = dirname( $db_path );

  my @problems;

  push @problems, "DB directory does not exist: $dir"
      if !-d $dir;

  push @problems, "DB directory is not writable: $dir"
      if -d $dir && !-w $dir;

  return @problems;
}

1;
