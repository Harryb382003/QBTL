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

sub upsert_qbt_info ( $self, $dbh, $row ) {
  die 'qbt info row requires hash' if !defined $row->{hash};

  my @field = qw(
      hash
      name
      state
      progress
      save_path
      content_path
      category
      tags
      amount_left
      total_size
      added_on
      completion_on
      last_activity
      tracker
      ratio
  );

  my $sql = q{
        INSERT INTO qbt_info (
            hash,
            name,
            state,
            progress,
            save_path,
            content_path,
            category,
            tags,
            amount_left,
            total_size,
            added_on,
            completion_on,
            last_activity,
            tracker,
            ratio,
            seen_on
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
        ON CONFLICT(hash) DO UPDATE SET
            name          = excluded.name,
            state         = excluded.state,
            progress      = excluded.progress,
            save_path     = excluded.save_path,
            content_path  = excluded.content_path,
            category      = excluded.category,
            tags          = excluded.tags,
            amount_left   = excluded.amount_left,
            total_size    = excluded.total_size,
            added_on      = excluded.added_on,
            completion_on = excluded.completion_on,
            last_activity = excluded.last_activity,
            tracker       = excluded.tracker,
            ratio         = excluded.ratio,
            seen_on       = excluded.seen_on
    };

  $dbh->do( $sql, undef, map { $row->{$_} } @field, );

  return {
          ok   => 1,
          hash => $row->{hash},};
}

1;
