package QBTL::DB;

use v5.40;
use common::sense;
use feature qw( signatures );

use DBI;
use File::Basename qw( dirname );
use File::Spec;
use Unicode::Normalize qw( NFC NFD );

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
      . ( $summary->{distinct_values} // 0 )
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

sub qbt_preference_value ( $self, $dbh, $key ) {
  my ( $value ) = $dbh->selectrow_array(
    q{
      SELECT value
      FROM qbt_preferences
      WHERE "key" = ?
      LIMIT 1
    },
    undef,
    $key, );

  return $value;
}

sub ensure_qbt_info_hash ( $self, $dbh, %arg ) {
  my $hash = $arg{hash} // '';

  if ( $hash !~ /\A[0-9A-Fa-f]{40}\z/ ) {
    return {
            ok     => 0,
            status => 'invalid_hash',
            hash   => $arg{hash},};
  }

  my ( $exists ) = $dbh->selectrow_array(
    q{
      SELECT 1
      FROM qbt_info
      WHERE hash = ?
      LIMIT 1
    },
    undef,
    $hash, );

  return {ok => 1, hash => $hash, created => 0} if $exists;

  my %column = $self->qbt_info_column_map( $dbh );

  my @column = ( 'hash' );
  my @value  = ( '?' );
  my @bind   = ( $hash );

  if ( $column{name} ) {
    push @column, 'name';
    push @value,  '?';
    push @bind,   $arg{name} // $hash;
  }

  if ( $column{seen_on} ) {
    push @column, 'seen_on';
    push @value,  q{datetime('now')};
  }

  if ( $column{current_qbt} ) {
    push @column, 'current_qbt';
    push @value,  '0';
  }

  if ( $column{seen} ) {
    push @column, 'seen';
    push @value,  '0';
  }

  if ( $column{discovered_on} ) {
    push @column, 'discovered_on';
    push @value,  q{datetime('now')};
  }

  if ( $column{discovered_by} ) {
    push @column, 'discovered_by';
    push @value,  '?';
    push @bind,   $arg{discovered_by} // 'qbt_export_dedupe';
  }

  my $columns = join ', ', @column;
  my $values  = join ', ', @value;

  $dbh->do(
    qq{
      INSERT INTO qbt_info ($columns)
      VALUES ($values)
    },
    undef,
    @bind, );

  return {ok => 1, hash => $hash, created => 1};
}

sub reset_qbt_export_dir_file_state ( $self, $dbh, %arg ) {
  my $which = $arg{which} // die 'export dir state requires which';

  my %column = (
                 export_dir     => 'qbt_export_dir_file',
                 export_dir_fin => 'qbt_export_dir_fin_file', );

  my $column = $column{$which} // die "unknown qBT export dir state: $which";

  $dbh->do(
    qq{
      UPDATE qbt_info
      SET $column = 0,
          qbt_export_dirs_checked_on = CURRENT_TIMESTAMP
    }
  );

  return {ok => 1, which => $which};
}

sub update_qbt_export_dir_file_state ( $self, $dbh, %arg ) {
  my $hash  = $arg{hash}  // '';
  my $which = $arg{which} // die 'export dir state requires which';

  my %column = (
                 export_dir     => 'qbt_export_dir_file',
                 export_dir_fin => 'qbt_export_dir_fin_file', );

  my $column = $column{$which} // die "unknown qBT export dir state: $which";

  my $ensure =
      $self->ensure_qbt_info_hash(
                                   $dbh,
                                   hash          => $hash,
                                   name          => $arg{name},
                                   discovered_by => 'qbt_export_dedupe', );

  return $ensure if !$ensure->{ok};

  $dbh->do(
    qq{
      UPDATE qbt_info
      SET $column = ?,
          qbt_export_dirs_checked_on = CURRENT_TIMESTAMP
      WHERE hash = ?
    },
    undef,
    $arg{exists} ? 1 : 0,
    $hash, );

  return {
          ok     => 1,
          hash   => $hash,
          which  => $which,
          exists => $arg{exists} ? 1 : 0};
}

sub update_local_torrent_file_path ( $self, $dbh, %arg ) {
  my $old = $arg{old_path} // die 'old_path is required';
  my $new = $arg{new_path} // die 'new_path is required';

  return {ok => 1, old_path => $old, new_path => $new, changed => 0}
      if $old eq $new;

  my $old_row = $self->local_torrent_file_by_path( $dbh, $old );
  my $new_row = $self->local_torrent_file_by_path( $dbh, $new );

  my $stored_old = $old_row && defined $old_row->{path} ? $old_row->{path} : $old;

  if ($new_row) {
    my $stored_new = $new_row->{path};

    if ( defined $stored_new && $stored_new ne $stored_old ) {
      my $old_hash = $old_row->{infohash};
      my $new_hash = $new_row->{infohash};

      if (
           defined $old_hash
        && defined $new_hash
        && $old_hash ne ''
        && $new_hash ne ''
        && $old_hash ne $new_hash
      ) {
        return {
                ok       => 0,
                old_path => $old,
                db_path  => $stored_old,
                new_path => $new,
                target   => $stored_new,
                problem  => 'target path already exists with different infohash'};
      }

      my $deleted = $dbh->do(
        q{
          DELETE FROM local_torrent_files
          WHERE path = ?
        },
        undef,
        $stored_old, );

      return {
              ok        => 1,
              old_path  => $old,
              db_path   => $stored_old,
              new_path  => $new,
              target    => $stored_new,
              changed   => $deleted ? 1 : 0,
              merged    => 1};
    }
  }

  my $rows = $dbh->do(
    q{
      UPDATE local_torrent_files
      SET path = ?
      WHERE path = ?
    },
    undef,
    $new,
    $stored_old, );

  return {
          ok       => 1,
          old_path => $old,
          db_path  => $stored_old,
          new_path => $new,
          changed  => $rows ? 1 : 0};
}

sub delete_local_torrent_file_path ( $self, $dbh, $path ) {
  my $stored_path = $path;
  my $existing    = $self->local_torrent_file_by_path( $dbh, $path );
  $stored_path = $existing->{path} if $existing && defined $existing->{path};

  my $rows = $dbh->do(
    q{
      DELETE FROM local_torrent_files
      WHERE path = ?
    },
    undef,
    $stored_path, );

  return {
          ok      => 1,
          path    => $path,
          db_path => $stored_path,
          deleted => $rows + 0};
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
          total           => $total           // 0,
          scanner_backend => $scanner_backend // 'unknown',
          latest_seen     => $latest_seen     // '',
          parsed          => $parsed          // 0,
          parse_problems  => $parse_problems  // 0,};
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

sub qbt_mismatch_rows ( $self, $dbh, %arg ) {
  my $limit = $arg{limit};

  my $sql = q{
    SELECT
      f.infohash AS infohash,
      f.path AS fastresume_path,
      q.name AS qbt_name,
      q.state AS qbt_state,
      q.total_size AS qbt_total_size,
      COUNT(loose.path) AS repair_candidates,
      GROUP_CONCAT(DISTINCT loose.path) AS repair_candidate_paths
    FROM local_fastresume_files f
    LEFT JOIN local_torrent_files bt
      ON bt.infohash = f.infohash
     AND bt.parse_ok = 1
     AND bt.path LIKE '%/BT_backup/%'
    LEFT JOIN local_torrent_files loose
      ON loose.infohash = f.infohash
     AND loose.parse_ok = 1
     AND loose.path NOT LIKE '%/BT_backup/%'
     AND loose.path NOT LIKE '%/queued_for_deletion/%'
     AND loose.path NOT LIKE '%/queued_for_restoration/%'
    LEFT JOIN qbt_info q
      ON q.hash = f.infohash
    WHERE f.parse_ok = 1
      AND f.infohash IS NOT NULL
      AND f.infohash != ''
      AND f.path LIKE '%/BT_backup/%'
      AND bt.path IS NULL
    GROUP BY
      f.infohash,
      f.path,
      q.name,
      q.state,
      q.total_size
    ORDER BY f.infohash ASC
  };

  if ( defined $limit && $limit =~ /\A[0-9]+\z/ && $limit > 0 ) {
    $sql .= q{ LIMIT } . int( $limit );
  }

  my $rows = $dbh->selectall_arrayref( $sql, {Slice => {}} );

  for my $row ( @{$rows} ) {
    my $paths = $row->{repair_candidate_paths} // '';

    $row->{repair_candidate_paths} =
        length $paths
        ? [ split /,/, $paths ]
        : [];
  }

  return {
          ok    => 1,
          rows  => $rows,
          count => scalar @{$rows},};
}

sub qbt_mismatch_count ( $self, $dbh ) {
  return $self->qbt_mismatch_rows( $dbh )->{count};
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

sub qbt_info_by_hash ( $self, $dbh, $hash ) {
  return undef if !defined $hash || $hash eq '';

  return $dbh->selectrow_hashref(
    q{
      SELECT *
      FROM qbt_info
      WHERE hash = ?
      LIMIT 1
    },
    undef,
    $hash, );
}

sub local_torrent_file_exists ( $self, $dbh, $path ) {
  return 0 if !defined $path || $path eq '';

  my ( $exists ) = $dbh->selectrow_array(
    q{
      SELECT 1
      FROM local_torrent_files
      WHERE path = ?
      LIMIT 1
    },
    undef,
    $path, );

  return $exists ? 1 : 0;
}

sub local_fastresume_file_exists ( $self, $dbh, $path ) {
  return 0 if !defined $path || $path eq '';

  my ( $exists ) = $dbh->selectrow_array(
    q{
      SELECT 1
      FROM local_fastresume_files
      WHERE path = ?
      LIMIT 1
    },
    undef,
    $path, );

  return $exists ? 1 : 0;
}

sub local_torrent_file_by_path ( $self, $dbh, $path ) {
  return undef if !defined $path || $path eq '';

  my $row = $dbh->selectrow_hashref(
    q{
      SELECT *
      FROM local_torrent_files
      WHERE path = ?
      LIMIT 1
    },
    undef,
    $path, );

  return $row if $row;

  my $dir = dirname( $path );

  my $rows = $dbh->selectall_arrayref(
    q{
      SELECT *
      FROM local_torrent_files
      WHERE path LIKE ?
    },
    {Slice => {}},
    $dir . '/%', );

  my $wanted_nfc = NFC( $path );
  my $wanted_nfd = NFD( $path );

  for my $candidate ( @{$rows} ) {
    return $candidate
        if NFC( $candidate->{path} ) eq $wanted_nfc
        || NFD( $candidate->{path} ) eq $wanted_nfd;
  }

  return undef;
}

sub best_local_torrent_file_for_hash ( $self, $dbh, $hash ) {
  return undef if !defined $hash || $hash eq '';

  return $dbh->selectrow_hashref(
    q{
      SELECT *
      FROM local_torrent_files
      WHERE infohash = ?
        AND COALESCE(parse_ok, 0) = 1
      ORDER BY
        CASE WHEN path LIKE '%/BT_backup/%' THEN 0 ELSE 1 END,
        parsed_on DESC,
        seen_on DESC,
        path ASC
      LIMIT 1
    },
    undef,
    $hash, );
}

sub qbt_info_by_hash ( $self, $dbh, $hash ) {
  my $row = $dbh->selectrow_hashref(
    q{
      SELECT *
      FROM qbt_info
      WHERE hash = ?
      LIMIT 1
    },
    undef,
    $hash, );

  return $row;
}

sub current_qbt_hashes ( $self, $dbh ) {
  my $rows = $dbh->selectall_arrayref(
    q{
      SELECT hash
      FROM qbt_info
      WHERE current_qbt = 1
      ORDER BY hash ASC
    },
    {Slice => {}}, );

  return [ map { $_->{hash} } @{$rows} ];
}


sub current_qbt_name_map ( $self, $dbh ) {
  my $rows = $dbh->selectall_arrayref(
    q{
      SELECT hash, name
      FROM qbt_info
      WHERE current_qbt = 1
      ORDER BY hash ASC
    },
    {Slice => {}}, );

  my %name_by_hash;

  for my $row ( @{$rows} ) {
    next if !defined $row->{hash} || $row->{hash} eq '';

    $name_by_hash{ $row->{hash} } = $row->{name};
  }

  return \%name_by_hash;
}

sub update_qbt_torrent_file_state ( $self, $dbh, %arg ) {
  my $hash   = $arg{hash} // die 'qbt torrent file state requires hash';
  my $exists = $arg{exists} ? 1 : 0;

  $dbh->do(
    q{
      UPDATE qbt_info
      SET qbt_torrent_file = ?,
          qbt_torrent_file_checked_on = CURRENT_TIMESTAMP
      WHERE hash = ?
    },
    undef,
    $exists,
    $hash, );

  return {
          ok     => 1,
          hash   => $hash,
          exists => $exists,};
}

sub local_torrent_matches_for_hash ( $self, $dbh, $hash ) {
  my $hash_column = 'infohash';

  my $rows = $dbh->selectall_arrayref(
    qq{
      SELECT
        path,
        $hash_column AS hash
      FROM local_torrent_files
      WHERE parse_ok = 1
        AND $hash_column = ?
      ORDER BY path ASC
    },
    {Slice => {}},
    $hash, );

  return {
          ok          => 1,
          rows        => $rows,
          count       => scalar @{$rows},
          hash_column => $hash_column,};
}

sub replace_qbt_hash_as_name ( $self, $dbh, $rows ) {
  $rows //= [];

  my $delete = $dbh->prepare( q{DELETE FROM qbt_hash_as_name} );
  my $insert = $dbh->prepare(
    q{
      INSERT INTO qbt_hash_as_name
        (hash, fastresume_path, observed_on)
      VALUES
        (?, ?, CURRENT_TIMESTAMP)
    }
  );

  $dbh->begin_work;

  eval {
    $delete->execute;

    for my $row ( @{$rows} ) {
      next if !defined $row->{hash};
      next if $row->{hash} !~ /\A[0-9a-f]{40}\z/;

      $insert->execute( $row->{hash}, $row->{fastresume_path} // '' );
    }

    $dbh->commit;
    1;
  } or do {
    my $error = $@ || 'unknown qbt_hash_as_name replace error';
    eval { $dbh->rollback };
    die $error;
  };

  return {
          ok     => 1,
          stored => scalar @{$rows},};
}

sub qbt_hash_as_name_count ( $self, $dbh ) {
  my ( $count ) = $dbh->selectrow_array(
    q{
      SELECT COUNT(*)
      FROM qbt_info
      WHERE current_qbt = 1
        AND qbt_torrent_file = 0
    }
  );

  return $count // 0;
}

sub search_hash_as_name ( $self, $dbh ) {
  my $hash_column = 'infohash';

  my $rows = $dbh->selectall_arrayref(
    qq{
      SELECT
        q.hash,
        ltf.path AS torrent_path
      FROM qbt_info q
      JOIN local_torrent_files ltf
        ON ltf.$hash_column = q.hash
      WHERE q.current_qbt = 1
        AND q.qbt_torrent_file = 0
        AND ltf.parse_ok = 1
      ORDER BY q.hash ASC, ltf.path ASC
    },
    {Slice => {}}, );

  my ( $hashes_with_matches ) = $dbh->selectrow_array(
    qq{
      SELECT COUNT(DISTINCT q.hash)
      FROM qbt_info q
      JOIN local_torrent_files ltf
        ON ltf.$hash_column = q.hash
      WHERE q.current_qbt = 1
        AND q.qbt_torrent_file = 0
        AND ltf.parse_ok = 1
    }
  );

  return {
          ok                  => 1,
          rows                => $rows,
          count               => scalar @{$rows},
          hashes_with_matches => $hashes_with_matches // 0,
          hash_column         => $hash_column,};
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
  my $column = $key;

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
        payload_kind = ?,
        payload_root_name = ?,
        payload_file_count = ?,
        payload_total_size = ?,
        payload_probe_path = ?,
        payload_probe_name = ?,
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
    $row->{payload_kind},
    $row->{payload_root_name},
    $row->{payload_file_count},
    $row->{payload_total_size},
    $row->{payload_probe_path},
    $row->{payload_probe_name},
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

sub replace_qbt_payload_audit ( $self, $dbh, $row ) {
  die 'qbt payload audit row requires hash' if !defined $row->{hash};

  $dbh->do(
    q{
      INSERT INTO qbt_payload_audits (
        hash,
        audited_on,
        save_path,
        content_path,
        save_path_exists,
        content_path_exists,
        save_path_type,
        content_path_type,
        qbt_files_ok,
        qbt_file_count,
        qbt_file_total_size,
        direct_probe_status,
        needs_deep_scan,
        problem
      )
      VALUES (
        ?,
        datetime('now'),
        ?,
        ?,
        ?,
        ?,
        ?,
        ?,
        ?,
        ?,
        ?,
        ?,
        ?,
        ?
      )
      ON CONFLICT(hash) DO UPDATE SET
        audited_on = excluded.audited_on,
        save_path = excluded.save_path,
        content_path = excluded.content_path,
        save_path_exists = excluded.save_path_exists,
        content_path_exists = excluded.content_path_exists,
        save_path_type = excluded.save_path_type,
        content_path_type = excluded.content_path_type,
        qbt_files_ok = excluded.qbt_files_ok,
        qbt_file_count = excluded.qbt_file_count,
        qbt_file_total_size = excluded.qbt_file_total_size,
        direct_probe_status = excluded.direct_probe_status,
        needs_deep_scan = excluded.needs_deep_scan,
        problem = excluded.problem
    },
    undef,
    $row->{hash},
    $row->{save_path},
    $row->{content_path},
    $row->{save_path_exists},
    $row->{content_path_exists},
    $row->{save_path_type},
    $row->{content_path_type},
    $row->{qbt_files_ok},
    $row->{qbt_file_count},
    $row->{qbt_file_total_size},
    $row->{direct_probe_status},
    $row->{needs_deep_scan} // 0,
    $row->{problem}, );

  return {
          ok   => 1,
          hash => $row->{hash},};
}

sub qbt_payload_audit ( $self, $dbh, $hash ) {
  return $dbh->selectrow_hashref(
    q{
      SELECT *
      FROM qbt_payload_audits
      WHERE hash = ?
    },
    undef,
    $hash, );
}

sub replace_qbt_payload_files ( $self, $dbh, %arg ) {
  my $hash  = $arg{hash}  // die 'qbt payload files require hash';
  my $files = $arg{files} // [];

  $dbh->do( q{DELETE FROM qbt_payload_files WHERE hash = ?}, undef, $hash );

  my $insert = $dbh->prepare(
    q{
      INSERT INTO qbt_payload_files (
        hash,
        path,
        size,
        progress,
        priority,
        availability,
        first_seen_on,
        last_seen_on
      )
      VALUES (
        ?,
        ?,
        ?,
        ?,
        ?,
        ?,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      )
    }
  );

  my $stored = 0;

  for my $file ( @{$files} ) {
    next if !defined $file->{path} || $file->{path} eq '';

    $insert->execute( $hash, $file->{path}, $file->{size}, $file->{progress},
                      $file->{priority}, $file->{availability}, );

    $stored++;
  }

  return {
          ok     => 1,
          hash   => $hash,
          stored => $stored,};
}

sub qbt_payload_files ( $self, $dbh, $hash ) {
  my $rows = $dbh->selectall_arrayref(
    q{
      SELECT *
      FROM qbt_payload_files
      WHERE hash = ?
      ORDER BY path ASC
    },
    {Slice => {}},
    $hash, );

  return {
          ok    => 1,
          hash  => $hash,
          rows  => $rows,
          count => scalar @{$rows},};
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

sub replace_qbt_api_values ( $self, $dbh, %arg ) {
  my $hash     = $arg{hash}     // die 'qBT API values require hash';
  my $endpoint = $arg{endpoint} // die 'qBT API values require endpoint';
  my $data     = $arg{data}     // {};

  die 'qBT API values data must be a hashref' if ref $data ne 'HASH';

  require JSON::PP;

  my $json = JSON::PP->new->canonical( 1 )->allow_nonref( 1 );

  my $insert = $dbh->prepare(
    q{
      INSERT INTO qbt_api_values (
        hash,
        endpoint,
        key,
        value,
        value_type,
        first_seen_on,
        last_seen_on
      )
      VALUES (
        ?,
        ?,
        ?,
        ?,
        ?,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      )
      ON CONFLICT(hash, endpoint, key) DO UPDATE SET
        value = excluded.value,
        value_type = excluded.value_type,
        last_seen_on = excluded.last_seen_on
    }
  );

  my $stored = 0;

  for my $key ( sort keys %{$data} ) {
    my $raw = $data->{$key};

    my $value_type =
         !defined $raw                          ? 'null'
        : ref $raw                              ? 'json'
        : $raw =~ /\A-?\d+\z/                   ? 'integer'
        : $raw =~ /\A-?(?:\d+\.\d*|\d*\.\d+)\z/ ? 'real'
        :                                         'text';

    my $value =
         !defined $raw ? undef
        : ref $raw     ? $json->encode( $raw )
        :                "$raw";

    $insert->execute( $hash, $endpoint, $key, $value, $value_type );
    $stored++;
  }

  return {
          ok       => 1,
          hash     => $hash,
          endpoint => $endpoint,
          stored   => $stored,};
}

sub qbt_api_values ( $self, $dbh, %arg ) {
  my @where;
  my @bind;

  if ( defined $arg{hash} ) {
    push @where, 'hash = ?';
    push @bind,  $arg{hash};
  }

  if ( defined $arg{endpoint} ) {
    push @where, 'endpoint = ?';
    push @bind,  $arg{endpoint};
  }

  if ( defined $arg{key} ) {
    push @where, 'key = ?';
    push @bind,  $arg{key};
  }

  my $where = @where ? 'WHERE ' . join( ' AND ', @where ) : '';

  my $rows = $dbh->selectall_arrayref(
    qq{
      SELECT *
      FROM qbt_api_values
      $where
      ORDER BY hash ASC, endpoint ASC, key ASC
    },
    {Slice => {}},
    @bind, );

  return {
          ok    => 1,
          rows  => $rows,
          count => scalar @{$rows},};
}

sub update_qbt_last ( $self, $dbh, %arg ) {
  my $hash   = $arg{hash}   // die 'qbt_last update requires hash';
  my $caller = $arg{caller} // die 'qbt_last update requires caller';
  my $error  = $arg{error};

  my $value = defined $error && $error ne '' ? "$caller: $error" : $caller;

  my $sth = $dbh->prepare(
    q{
      UPDATE qbt_info
      SET qbt_last = ?
      WHERE hash = ?
    }
  );

  $sth->execute( $value, $hash );

  return {
          ok       => 1,
          hash     => $hash,
          qbt_last => $value,
          updated  => $sth->rows,};
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
      qbt_last
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
1;
