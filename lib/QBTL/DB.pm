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

sub _column_exists ( $dbh, $table, $column ) {
  my $columns = $dbh->selectall_arrayref( qq{PRAGMA table_info("$table")},
                                          {Slice => {}}, );

  for my $row ( @{$columns} ) {
    if ( $row->{name} eq $column ) {
      return 1;
    }
  }

  return 0;
}

sub _column_value_summary ( $self, $dbh, $table, $column ) {
  my %allowed_table = map { $_ => 1 } qw(
      local_torrent_files
      local_fastresume_files
      qbt_info
      promoted_values
  );

  return '' if !$allowed_table{$table};

  my $quoted_table  = '"' . $table . '"';
  my $quoted_column = '"' . $column . '"';

  my $summary = $dbh->selectrow_hashref(
    qq{
      SELECT
        COUNT($quoted_column) AS value_count,
        COUNT(DISTINCT $quoted_column) AS distinct_values
      FROM $quoted_table
      WHERE $quoted_column IS NOT NULL
        AND $quoted_column != ''
    } );

  return
        ( $summary->{value_count} // 0 )
      . ' values / '
      . ( $summary->{distinct_count} // 0 )
      . ' distinct';
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

sub key_accessors ( $self, $dbh ) {
  my $rows = $dbh->selectall_arrayref(
    q{
      SELECT
        "key",
        kind,
        source,
        accessor,
        status,
        note,
        first_seen_on,
        last_seen_on
      FROM key_accessors
      ORDER BY kind ASC, "key" ASC
    },
    {Slice => {}}, );

  for my $row ( @{$rows} ) {
    $row->{data} = $self->_key_accessor_data( $dbh, $row );
  }

  return {
          ok   => 1,
          rows => $rows,};
}

sub _key_accessor_data ( $self, $dbh, $row ) {
  my $key    = $row->{key};
  my $source = $row->{source} // '';

  if ( $source eq 'hash_values' ) {
    my $summary = $dbh->selectrow_hashref(
      q{
        SELECT
  COALESCE(SUM(seen_count), 0) AS seen,
  COUNT(DISTINCT value) AS value_count,
  COUNT(DISTINCT hash) AS hash_count
FROM hash_values
WHERE "key" = ?
      },
      undef,
      $key, );

    return
          ( $summary->{seen} // 0 )
        . ' seen / '
        . ( $summary->{value_count} // 0 )
        . ' values / '
        . ( $summary->{hash_count} // 0 )
        . ' hashes';
  }

  if ( $source =~ /\Aqbt_preferences\./ ) {
    my $value = $dbh->selectrow_array(
      q{
        SELECT value
        FROM qbt_preferences
        WHERE "key" = ?
      },
      undef,
      $key, );

    return defined $value ? $value : '';
  }

  if ( $source =~ /\Alocal_torrent_files\.([A-Za-z_][A-Za-z0-9_]*)\z/ ) {
    return $self->_column_value_summary( $dbh, 'local_torrent_files', $1 );
  }

  if ( $source =~ /\Alocal_fastresume_files\.([A-Za-z_][A-Za-z0-9_]*)\z/ ) {
    return $self->_column_value_summary( $dbh, 'local_fastresume_files', $1 );
  }

  if ( $source =~ /\Aqbt_info\.([A-Za-z_][A-Za-z0-9_]*)\z/ ) {
    return $self->_column_value_summary( $dbh, 'qbt_info', $1 );
  }

  if ( $source =~ /\Apromoted_values\.([A-Za-z_][A-Za-z0-9_]*)\z/ ) {
    return $self->_column_value_summary( $dbh, 'promoted_values', $1 );
  }

  if ( $source eq 'manual_values' ) {
    my $count = $dbh->selectrow_array(
      q{
        SELECT COUNT(*)
        FROM manual_values
        WHERE "key" = ?
      },
      undef,
      $key, );

    return ( $count // 0 ) . ' values';
  }

  return '';
}

sub local_fastresume_file_count ( $self, $dbh ) {
  return $dbh->selectrow_array(
    q{
      SELECT COUNT(*)
      FROM local_fastresume_files
    }
  );
}

sub local_fastresume_summary ( $self, $dbh ) {
  return $dbh->selectrow_hashref(
    q{
      SELECT
        COUNT(*) AS total,
        SUM(CASE WHEN parse_ok = 1 THEN 1 ELSE 0 END) AS parsed,
        SUM(CASE WHEN parse_ok = 0 THEN 1 ELSE 0 END) AS parse_problems,
        COUNT(DISTINCT backend) AS backend_count,
        MAX(seen_on) AS latest_seen
      FROM local_fastresume_files
    }
  );
}

sub local_flush_evidence ( $self, $dbh ) {
  my $torrent_rows = $dbh->do( q{DELETE FROM local_torrent_files} );
  my $fastres_rows = $dbh->do( q{DELETE FROM local_fastresume_files} );

  return {
          ok              => 1,
          torrent_deleted => $torrent_rows eq '0E0' ? 0 : $torrent_rows,
          fastres_deleted => $fastres_rows eq '0E0' ? 0 : $fastres_rows,};
}

sub local_torrent_file_count ( $self, $dbh ) {
  my ( $count ) =
      $dbh->selectrow_array( q{SELECT COUNT(*) FROM local_torrent_files} );

  return $count // 0;
}

sub local_torrent_summary ( $self, $dbh ) {
  my ( $total ) =
      $dbh->selectrow_array( q{SELECT COUNT(*) FROM local_torrent_files} );

  my ( $scanner_backend ) = $dbh->selectrow_array(
    q{
      SELECT GROUP_CONCAT(DISTINCT backend)
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
          scanner_backend => $scanner_backend // 'unknown',
          latest_seen    => $latest_seen    // '',
          parsed         => $parsed         // 0,
          parse_problems => $parse_problems // 0,};
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

sub promote_hash_key ( $self, $dbh, %arg ) {
  my $key = $arg{key};

  if ( !defined $key || $key eq '' ) {
    return {
            ok     => 0,
            status => 'invalid_key',
            error  => 'key is required',};
  }

  my $exists = $dbh->selectrow_array(
    q{
      SELECT COUNT(*)
      FROM hash_values
      WHERE "key" = ?
    },
    undef,
    $key, );

  if ( !$exists ) {
    return {
            ok     => 0,
            status => 'key_not_found',
            error  => "observed key not found: $key",
            key    => $key,};
  }

  my $column = $arg{column} // _safe_promoted_column_name( $key );

  if ( $column !~ /\A[a-z][a-z0-9_]*\z/ ) {
    return {
            ok     => 0,
            status => 'invalid_column',
            error  => "invalid promoted column name: $column",
            key    => $key,};
  }

  my $already = $dbh->selectrow_hashref(
    q{
      SELECT key, target_column
      FROM promoted_keys
      WHERE "key" = ?
    },
    undef,
    $key, );

  if ( $already ) {
    return {
            ok            => 1,
            status        => 'already_promoted',
            key           => $key,
            target_column => $already->{target_column},
            promoted      => 0,
            backfilled    => 0,};
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
    $arg{value_type} // 'text', );

  $self->upsert_key_accessor(
                              $dbh,
                              key    => $key,
                              kind   => 'core',
                              source => 'promoted_values.' . $column,
                              status => 'todo',
                              note   => 'Promoted from observed metadata key',
  );

  my $rows = $dbh->selectall_arrayref(
    q{
      SELECT hash, value
      FROM hash_values
      WHERE "key" = ?
      ORDER BY last_seen_on DESC, id DESC
    },
    {Slice => {}},
    $key, );

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
    next if $seen_hash{$row->{hash}}++;

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
          backfilled    => $backfilled,};
}

sub qbt_hash_as_name_count ( $self, $dbh ) {
  my ( $count ) = $dbh->selectrow_array(
    q{
      SELECT COUNT(*)
      FROM qbt_info
      WHERE current_qbt = 1
        AND total_size = -1
        AND LENGTH(name) = 40
        AND LOWER(name) = name
        AND name NOT GLOB '*[^0123456789abcdef]*'
    }
  );

  return $count // 0;
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

sub qbt_preferences ( $self, $dbh ) {
  my $rows = $dbh->selectall_arrayref(
    q{
      SELECT
        "key",
        value,
        value_type,
        first_seen_on,
        last_seen_on
      FROM qbt_preferences
      ORDER BY "key" ASC
    },
    {Slice => {}}, );

  return {
          ok   => 1,
          rows => $rows,};
}

sub qbt_preference_keys ( $self, $dbh ) {
  my $rows = $dbh->selectall_arrayref(
    q{
      SELECT
        "key",
        value,
        value_type,
        last_seen_on
      FROM qbt_preferences
      ORDER BY "key" ASC
    },
    {Slice => {}}, );

  return {
          ok    => 1,
          rows  => $rows,
          count => scalar @{$rows},};
}

sub qbt_preferences_count ( $self, $dbh ) {
  return $dbh->selectrow_array(
    q{
      SELECT COUNT(*)
      FROM qbt_preferences
    }
  );
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

sub qbt_status ( $self, $dbh ) {
  my $summary = $dbh->selectrow_hashref(
    q{
      SELECT
        SUM(CASE WHEN current_qbt = 1 THEN 1 ELSE 0 END) AS current_count,
        SUM(CASE WHEN current_qbt = 0 THEN 1 ELSE 0 END) AS removed_count,
        COUNT(*) AS total_count,
        0 AS hash_as_name_count,
        NULL AS latest_seen_on
        FROM qbt_info
      },
    {Slice => {}}, );
  $summary->{hash_as_name_count} = $self->qbt_hash_as_name_count( $dbh );
  my $states = $dbh->selectall_arrayref(
    q{
      SELECT state, COUNT(*) AS count
      FROM qbt_info
      WHERE current_qbt = 1
        AND state IS NOT NULL
        AND state != ''
      GROUP BY state
      ORDER BY count DESC, state ASC
    },
    {Slice => {}}, );

  my $categories = $dbh->selectrow_hashref(
    q{
      SELECT
        SUM(
          CASE
            WHEN current_qbt = 1
             AND category IS NOT NULL
             AND category != ''
            THEN 1
            ELSE 0
          END
        ) AS categorized,
        SUM(
          CASE
            WHEN current_qbt = 1
             AND (category IS NULL OR category = '')
            THEN 1
            ELSE 0
          END
        ) AS uncategorized
      FROM qbt_info
    },
    {Slice => {}}, );

  return {
          ok         => 1,
          summary    => $summary    // {},
          states     => $states     // [],
          categories => $categories // {},};
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
    {Slice => {}}, );

  return {
          ok   => 1,
          rows => $rows,};
}

sub promotion_candidates ( $self, $dbh, %arg ) {
  my $threshold = $arg{threshold} // 20;

  if ( $threshold !~ /\A[0-9]+\z/ ) {
    return {
            ok     => 0,
            status => 'invalid_threshold',
            error  => 'threshold must be a non-negative integer',};
  }

  $threshold = 0 + $threshold;

  if ( $threshold == 0 ) {
    return {
            ok         => 1,
            threshold  => 0,
            candidates => [],};
  }

  my $rows = $dbh->selectall_arrayref(
    q{
      SELECT
        hv."key",
        COUNT(DISTINCT hv.hash) AS hashes,
        COUNT(DISTINCT hv.value) AS values_seen,
        SUM(hv.seen_count) AS seen
      FROM hash_values hv
      LEFT JOIN promoted_keys pk
        ON pk."key" = hv."key"
      WHERE pk."key" IS NULL
      GROUP BY hv."key"
            HAVING SUM(hv.seen_count) >= CAST(? AS INTEGER)
      ORDER BY seen DESC, hv."key" ASC
    },
    {Slice => {}},
    $threshold, );

  return {
          ok         => 1,
          threshold  => $threshold,
          candidates => $rows,};
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

sub _safe_promoted_column_name ( $key ) {
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

  $self->upsert_key_accessor(
                              $dbh,
                              key      => $key,
                              kind     => 'manual',
                              source   => 'manual_values',
                              accessor => 'qbtl meta get <hash>',
                              status   => 'implemented', );

  return {
          ok    => 1,
          hash  => $hash,
          key   => $key,
          value => $value,};
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

  $self->upsert_key_accessor(
                              $dbh,
                              key      => $key,
                              kind     => 'observed',
                              source   => 'hash_values',
                              accessor => 'qbtl meta key ' . $key,
                              status   => 'implemented', );

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

sub update_local_fastresume_parse ( $self, $dbh, $row ) {
  $dbh->do(
    q{
      UPDATE local_fastresume_files
      SET
        infohash      = ?,
        parse_ok      = ?,
        parse_problem = ?
      WHERE path = ?
    },
    undef,
    $row->{infohash},
    $row->{parse_ok},
    $row->{parse_problem},
    $row->{path}, );

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

sub upsert_key_accessor ( $self, $dbh, %arg ) {
  my $key = $arg{key};

  if ( !defined $key || $key eq '' ) {
    return {
            ok     => 0,
            status => 'invalid_key',
            error  => 'key is required',};
  }

  my $kind     = $arg{kind} // 'observed';
  my $source   = $arg{source};
  my $accessor = $arg{accessor};
  my $status   = $arg{status} // 'todo';
  my $note     = $arg{note};

  $dbh->do(
    q{
      INSERT INTO key_accessors
        ("key", kind, source, accessor, status, note)
      VALUES
        (?, ?, ?, ?, ?, ?)
      ON CONFLICT("key")
      DO UPDATE SET
        kind = CASE
          WHEN key_accessors.kind = 'core'
           AND excluded.kind = 'observed'
          THEN key_accessors.kind
          ELSE COALESCE(excluded.kind, key_accessors.kind)
        END,
        source = CASE
          WHEN key_accessors.kind = 'core'
           AND excluded.kind = 'observed'
          THEN key_accessors.source
          ELSE COALESCE(excluded.source, key_accessors.source)
        END,
        accessor = CASE
          WHEN key_accessors.kind = 'core'
           AND excluded.kind = 'observed'
          THEN key_accessors.accessor
          ELSE COALESCE(excluded.accessor, key_accessors.accessor)
        END,
        status = CASE
          WHEN key_accessors.kind = 'core'
           AND excluded.kind = 'observed'
          THEN key_accessors.status
          ELSE COALESCE(excluded.status, key_accessors.status)
        END,
        note = CASE
          WHEN key_accessors.kind = 'core'
           AND excluded.kind = 'observed'
          THEN key_accessors.note
          ELSE COALESCE(excluded.note, key_accessors.note)
        END,
        last_seen_on = CURRENT_TIMESTAMP
    },
    undef,
    $key,
    $kind,
    $source,
    $accessor,
    $status,
    $note, );

  return {
          ok       => 1,
          key      => $key,
          kind     => $kind,
          source   => $source,
          accessor => $accessor,
          status   => $status,};
}

sub upsert_local_fastresume_file ( $self, $dbh, $row ) {
  $dbh->do(
    q{
      INSERT INTO local_fastresume_files
        (path, size, mtime, backend, seen_on)
      VALUES
        (?, ?, ?, ?, CURRENT_TIMESTAMP)
      ON CONFLICT(path)
      DO UPDATE SET
        size    = excluded.size,
        mtime   = excluded.mtime,
        backend = excluded.backend,
        seen_on = CURRENT_TIMESTAMP
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

sub restoration_queue_totals ( $self, $dbh, %arg ) {
  my $classified = $self->_classified_local_torrent_rows( $dbh, %arg );

  my $should_restore        = 0;
  my $should_queue_deletion = 0;

  for my $row ( @{$classified->{restoration}} ) {
    if ( $classified->{loose_hash}{$row->{infohash}} ) {
      $should_queue_deletion++;
    } else {
      $should_restore++;
    }
  }

  return {
          ok                    => 1,
          queue                 => 'restoration',
          total                 => scalar @{$classified->{restoration}},
          should_restore        => $should_restore,
          should_queue_deletion => $should_queue_deletion,};
}

sub deletion_queue_totals ( $self, $dbh, %arg ) {
  my $classified = $self->_classified_local_torrent_rows( $dbh, %arg );

  my $should_restore       = 0;
  my $should_remain_queued = 0;

  for my $row ( @{$classified->{deletion}} ) {
    if ( $classified->{loose_hash}{$row->{infohash}} ) {
      $should_remain_queued++;
    } else {
      $should_restore++;
    }
  }

  return {
          ok                   => 1,
          queue                => 'deletion',
          total                => scalar @{$classified->{deletion}},
          should_restore       => $should_restore,
          should_remain_queued => $should_remain_queued,};
}

sub _classified_local_torrent_rows ( $self, $dbh, %arg ) {
  my $root = $arg{root} // die 'root is required';

  my $deletion_dir    = File::Spec->catdir( $root, 'queued_for_deletion' );
  my $restoration_dir = File::Spec->catdir( $root, 'queued_for_restoration' );

  my $rows = $dbh->selectall_arrayref(
    q{
      SELECT
        path,
        infohash,
        torrent_name
      FROM local_torrent_files
      WHERE parse_ok = 1
        AND infohash IS NOT NULL
        AND infohash != ''
    },
    {Slice => {}}, );

  my @deletion;
  my @restoration;
  my @loose;
  my %loose_hash;

  for my $row ( @{$rows} ) {
    if ( $self->_path_is_under( $row->{path}, $deletion_dir ) ) {
      push @deletion, $row;
      next;
    }

    if ( $self->_path_is_under( $row->{path}, $restoration_dir ) ) {
      push @restoration, $row;
      next;
    }

    push @loose, $row;
    $loose_hash{$row->{infohash}} = 1;
  }

  return {
          deletion    => \@deletion,
          restoration => \@restoration,
          loose       => \@loose,
          loose_hash  => \%loose_hash,};
}

sub _path_is_under ( $self, $path, $dir ) {
  return 0 if !defined $path || !defined $dir;

  my $clean_path = File::Spec->rel2abs( $path );
  my $clean_dir  = File::Spec->rel2abs( $dir );

  $clean_path =~ s{/+\z}{};
  $clean_dir  =~ s{/+\z}{};

  return 1 if $clean_path eq $clean_dir;
  return index( $clean_path, "$clean_dir/" ) == 0 ? 1 : 0;
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

sub upsert_qbt_preference ( $self, $dbh, $row ) {
  die 'qbt preference row requires key' if !defined $row->{key};

  $dbh->do(
    q{
      INSERT INTO qbt_preferences
        ("key", value, value_type, first_seen_on, last_seen_on)
      VALUES
        (?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      ON CONFLICT("key")
      DO UPDATE SET
        value = excluded.value,
        value_type = excluded.value_type,
        last_seen_on = CURRENT_TIMESTAMP
    },
    undef,
    $row->{key},
    $row->{value},
    $row->{value_type}, );

  $self->upsert_key_accessor(
                              $dbh,
                              key      => $row->{key},
                              kind     => 'core',
                              source   => 'qbt_preferences.' . $row->{key},
                              accessor => 'qbtl qbt preferences',
                              status   => 'implemented',
                              note     => 'qBittorrent application preference',
  );

  return {
          ok  => 1,
          key => $row->{key},};
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

sub restoration_queue_totals ( $self, $dbh, %arg ) {
  my $root = $arg{root} // die 'root is required';

  my $queued_for_restoration = $arg{queued_for_restoration}
      // File::Spec->catdir( $root, 'queued_for_restoration' );

  my $queued_for_deletion = $arg{queued_for_deletion}
      // File::Spec->catdir( $root, 'queued_for_deletion' );

  my @exclude_dir = (
                      $queued_for_restoration,
                      $queued_for_deletion, @{$arg{exclude_dirs} // []}, );

  my $rows = $dbh->selectall_arrayref(
    q{
      SELECT path, infohash
      FROM local_torrent_files
      WHERE parse_ok = 1
        AND infohash IS NOT NULL
        AND infohash != ''
    },
    {Slice => {}}, );

  my %loose_hash;
  my @restoration;

  for my $row ( @{$rows} ) {
    my $path = $row->{path}     // next;
    my $hash = $row->{infohash} // next;

    if ( $self->_path_is_under( $path, $queued_for_restoration ) ) {
      push @restoration, $row;
      next;
    }

    next if $self->_path_is_under_any( $path, \@exclude_dir );

    $loose_hash{$hash} = 1;
  }

  my $should_restore        = 0;
  my $should_queue_deletion = 0;

  for my $row ( @restoration ) {
    if ( $loose_hash{$row->{infohash}} ) {
      $should_queue_deletion++;
      next;
    }

    $should_restore++;
  }

  return {
          ok                    => 1,
          should_restore        => $should_restore,
          should_queue_deletion => $should_queue_deletion,};
}

sub _path_is_under_any ( $self, $path, $dirs ) {
  for my $dir ( @{$dirs} ) {
    return 1 if $self->_path_is_under( $path, $dir );
  }

  return 0;
}

sub _path_is_under ( $self, $path, $dir ) {
  return 0 if !defined $path || !defined $dir || $dir eq '';

  return 1 if $path eq $dir;
  return index( $path, "$dir/" ) == 0 ? 1 : 0;
}
1;
