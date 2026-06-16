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

sub db_path ( $self ) {
  return $self->{db_path};
}

sub migration_dir ( $self ) {
  return $self->{migration_dir};
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

1;
