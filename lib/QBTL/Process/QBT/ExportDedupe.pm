package QBTL::Process::QBT::ExportDedupe;

use v5.40;
use common::sense;
use feature qw( signatures );

use File::Basename qw( basename dirname );
use File::Copy     qw( move );
use File::Path     qw( make_path );
use File::Spec;
use Encode qw( decode FB_DEFAULT );

use QBTL::Local::Parser;
use QBTL::Process::WithDB;

sub new ( $class, %arg ) {
  $arg{db_process} //= QBTL::Process::WithDB->new( db_path => $arg{db_path}, );
  $arg{parser}     //= QBTL::Local::Parser->new;

  return bless \%arg, $class;
}

sub _choose_keeper ( $self, %arg ) {
  my $meta_basenames = $arg{meta_basenames};
  my $items          = $arg{items};

  my $qbt_name = $items->[0]->{qbt_name};
  my $qbt_base = $self->_safe_basename( $qbt_name // '' );

  my @ranked =
      sort { $b->{_score} <=> $a->{_score} || $a->{path} cmp $b->{path} } map {
    my $base  = $self->_torrent_basename( $_->{path} );
    my $score = 0;

    # When qBT currently has this hash loaded, qBT's API name wins.
    $score += 300 if length $qbt_base && $base eq $qbt_base;

    $score += 100 if $meta_basenames->{$base};

    my $torrent_base = $self->_safe_basename( $_->{torrent_name} // '' );
    $score += 20 if length $torrent_base && $base eq $torrent_base;

    +{
      %{$_},
      _base  => $base,
      _score => $score,};
      } @{$items};

  my $keeper = $ranked[0];

  if ( length $qbt_base ) {
    $keeper->{desired_base}       = $qbt_base;
    $keeper->{desired_name_source} = 'qbt_info.name';
    $keeper->{should_rename}      = $keeper->{_base} eq $qbt_base ? 0 : 1;
    return $keeper;
  }

  if ( $keeper->{_score} >= 100 ) {
    $keeper->{desired_base}       = $keeper->{_base};
    $keeper->{desired_name_source} = 'meta';
    $keeper->{should_rename}      = 0;
    return $keeper;
  }

  my $torrent_base = $self->_safe_basename( $keeper->{torrent_name} // '' );

  $keeper->{desired_base} =
      length $torrent_base ? $torrent_base : $keeper->{_base};
  $keeper->{desired_name_source} =
      length $torrent_base ? 'torrent_name' : 'existing_filename';
  $keeper->{should_rename} =
      $keeper->{_base} eq $keeper->{desired_base} ? 0 : 1;

  return $keeper;
}

sub db_process ( $self ) {
  return $self->{db_process};
}

sub _dedupe_bucket ( $self, %arg ) {
  my $db        = $arg{db};
  my $dbh       = $arg{dbh};
  my $which     = $arg{which};
  my $dir       = $arg{dir};
  my $queue_dir         = $arg{queue_dir};
  my $qbt_name_by_hash = $arg{qbt_name_by_hash} // {};

  my @problem;

  my $result = {
                ok               => 1,
                which            => $which,
                directory        => $dir,
                scanned          => 0,
                stored           => 0,
                from_db          => 0,
                parsed           => 0,
                parse_problems   => 0,
                hashes           => 0,
                duplicate_groups => 0,
                kept             => 0,
                moved            => 0,
                renamed          => 0,
                problems         => \@problem,};

  if ( !defined $dir || $dir eq '' ) {
    push @problem,
        {
       which => $which,
       path  => undef,
       error => "qBT preference $which is not stored; run qbtl qbt preferences",
        };

    $result->{ok} = 0;
    return $result;
  }

  if ( !-d $dir ) {
    push @problem,
        {
         which => $which,
         path  => $dir,
         error => 'export directory does not exist',};

    $result->{ok} = 0;
    return $result;
  }

  $db->reset_qbt_export_dir_file_state( $dbh, which => $which );

  my ( $torrent_files, $meta_basenames ) = $self->_directory_inventory( $dir );

  $result->{scanned} = scalar @{$torrent_files};

  my %group;

  for my $path ( @{$torrent_files} ) {
    my $stored = $self->_store_torrent_file( $db, $dbh, $path, $which );

    $result->{stored}++  if $stored->{stored};
    $result->{from_db}++ if $stored->{from_db};

    if ( !$stored->{parse_ok} || !$stored->{hash} ) {
      $result->{parse_problems}++;
      push @problem,
          {
           which => $which,
           path  => $path,
           error => $stored->{problem} // 'torrent parse failed',};
      next;
    }

    $result->{parsed}++ if $stored->{parsed};

    if ( exists $qbt_name_by_hash->{ $stored->{hash} } ) {
      $stored->{current_qbt} = 1;
      $stored->{qbt_name}    = $qbt_name_by_hash->{ $stored->{hash} };
    }
    else {
      $stored->{current_qbt} = 0;
      $stored->{qbt_name}    = undef;
    }

    push @{$group{$stored->{hash}}}, $stored;
  }

  $result->{hashes} = scalar keys %group;

  for my $hash ( sort keys %group ) {
    my @items = sort { $a->{path} cmp $b->{path} } @{$group{$hash}};

    my $keeper = $self->_choose_keeper(
                                        dir            => $dir,
                                        meta_basenames => $meta_basenames,
                                        items          => \@items, );

    $result->{duplicate_groups}++ if @items > 1;

    for my $item ( @items ) {
      next if $item->{path} eq $keeper->{path};

      my $move = $self->_move_duplicate(
                                         db        => $db,
                                         dbh       => $dbh,
                                         item      => $item,
                                         queue_dir => $queue_dir,
                                         which     => $which, );

      if ( !$move->{ok} ) {
        push @problem, $move->{problem};
        next;
      }

      $result->{moved}++;
    }

    my $rename = $self->_rename_keeper(
                                        db            => $db,
                                        dbh           => $dbh,
                                        dir           => $dir,
                                        keeper        => $keeper,
                                        which         => $which,
                                        should_rename => $keeper->{should_rename} // ( @items > 1 ? 1 : 0 ), );

    if ( !$rename->{ok} ) {
      push @problem, $rename->{problem};
    } elsif ( $rename->{renamed} ) {
      $result->{renamed}++;
      $keeper->{path} = $rename->{new_path};
    }

    $db->update_qbt_export_dir_file_state(
                                           $dbh,
                                           which  => $which,
                                           hash   => $hash,
                                           name   => $keeper->{torrent_name},
                                           exists => 1, );

    $result->{kept}++;
  }

  $result->{ok} = @problem ? 0 : 1;

  return $result;
}

sub _directory_inventory ( $self, $dir ) {
  opendir my $dh, $dir or die "opendir $dir: $!";

  my @torrent;
  my %meta;

  while ( defined( my $entry = readdir $dh ) ) {
    next if $entry eq '.' || $entry eq '..';

    my $name =
        utf8::is_utf8( $entry )
        ? $entry
        : decode( 'UTF-8', $entry, FB_DEFAULT );

    if ( $name =~ /\.torrent\z/ ) {
      push @torrent, File::Spec->catfile( $dir, $name );
      next;
    }

    if ( my ( $base ) = $name =~ /\A(.+)\.meta\z/ ) {
      $meta{$base} = 1;
      next;
    }
  }

  closedir $dh;

  return ( [ sort @torrent ], \%meta );
}

sub _move_duplicate ( $self, %arg ) {
  my $db        = $arg{db};
  my $dbh       = $arg{dbh};
  my $item      = $arg{item};
  my $queue_dir = $arg{queue_dir};
  my $which     = $arg{which};

  my $old_path = $item->{path};
  my $target   = $self->_unique_path( $queue_dir, basename( $old_path ) );

  if ( !move( $old_path, $target ) ) {
    return {
            ok      => 0,
            problem => {
                        which => $which,
                        path  => $old_path,
                        error => "move to queued_for_deletion failed: $!",
            },};
  }

  $db->delete_local_torrent_file_path( $dbh, $old_path );

  return {ok => 1, old_path => $old_path, new_path => $target};
}

sub parser ( $self ) {
  return $self->{parser};
}

sub _queue_dir ( $self, $installation_root, $db ) {
  if ( defined $installation_root && length $installation_root ) {
    return File::Spec->catdir( $installation_root, 'queued_for_deletion' );
  }

  my $db_path = $db->{db_path} // '';
  my $root    = dirname( $db_path );

  return File::Spec->catdir( $root, 'queued_for_deletion' );
}

sub _rename_keeper ( $self, %arg ) {
  my $db            = $arg{db};
  my $dbh           = $arg{dbh};
  my $dir           = $arg{dir};
  my $keeper        = $arg{keeper};
  my $which         = $arg{which};
  my $should_rename = $arg{should_rename};

  return {ok => 1, renamed => 0} if !$should_rename;

  my $desired_base = $keeper->{desired_base}
      // $self->_torrent_basename( $keeper->{path} );
  my $desired_name = $desired_base . '.torrent';
  my $new_path     = File::Spec->catfile( $dir, $desired_name );
  my $old_path     = $keeper->{path};

  return {
          ok       => 1,
          renamed  => 0,
          old_path => $old_path,
          new_path => $old_path}
      if $old_path eq $new_path;

  $new_path = $self->_unique_path( $dir, $desired_name ) if -e $new_path;

  if ( !move( $old_path, $new_path ) ) {
    return {
            ok      => 0,
            problem => {
                        which => $which,
                        path  => $old_path,
                        error => "keeper rename failed: $!",
            },};
  }

  $db->update_local_torrent_file_path(
                                       $dbh,
                                       old_path => $old_path,
                                       new_path => $new_path, );

  return {
          ok       => 1,
          renamed  => 1,
          old_path => $old_path,
          new_path => $new_path};
}

sub run ( $self, %arg ) {
  my $installation_root = $arg{installation_root};
  my $started = time;

  return $self->db_process->with_db(
    sub ( $db, $dbh ) {
      my $queue_dir = $self->_queue_dir( $installation_root, $db );
      make_path( $queue_dir ) if !-d $queue_dir;

      my $qbt_name_by_hash = $db->current_qbt_name_map( $dbh );

      my @bucket;
      my @problem;

      for my $which ( qw( export_dir export_dir_fin ) ) {
        my $dir = $db->qbt_preference_value( $dbh, $which );

        my $result =
            $self->_dedupe_bucket(
                                   db        => $db,
                                   dbh       => $dbh,
                                   which            => $which,
                                   dir              => $dir,
                                   queue_dir        => $queue_dir,
                                   qbt_name_by_hash => $qbt_name_by_hash, );

        push @bucket,  $result;
        push @problem, @{$result->{problems} // []};
      }

      my $moved   = 0;
      my $renamed = 0;
      my $kept    = 0;

      for my $bucket ( @bucket ) {
        $moved   += $bucket->{moved}   // 0;
        $renamed += $bucket->{renamed} // 0;
        $kept    += $bucket->{kept}    // 0;
      }

      return {
              ok        => @problem ? 0 : 1,
              action    => 'qbt_export_dedupe',
              queue_dir => $queue_dir,
              buckets   => \@bucket,
              kept      => $kept,
              moved     => $moved,
              renamed   => $renamed,
              problems  => \@problem,};
    } );
}

sub _safe_basename ( $self, $name ) {
  return '' if !defined $name;

  $name =~ s{/+}{_}g;
  $name =~ s{:}{_}g;
  $name =~ s{\A\s+}{};
  $name =~ s{\s+\z}{};
  $name =~ s{\s+}{ }g;

  return $name;
}

sub _store_torrent_file ( $self, $db, $dbh, $path, $backend ) {

  my $existing = $db->local_torrent_file_by_path( $dbh, $path );
  if (    $existing
       && ( $existing->{parse_ok} // 0 )
       && defined $existing->{infohash}
       && length $existing->{infohash} )
  {
    return {
            ok           => 1,
            stored       => 0,
            parsed       => 0,
            from_db      => 1,
            path         => $path,
            hash         => $existing->{infohash},
            torrent_name => $existing->{torrent_name},
            parse_ok     => 1,
            problem      => undef,};
  }
  if ( !-f $path ) {
    return {
            ok           => 0,
            stored       => 0,
            parsed       => 0,
            from_db      => 0,
            path         => $path,
            hash         => undef,
            torrent_name => undef,
            parse_ok     => 0,
            problem      => 'path does not exist',};
  }

  my @stat = stat $path;

  my $stored =
      $db->upsert_local_torrent_file(
                                      $dbh,
                                      {
                                       path    => $path,
                                       size    => $stat[7] // 0,
                                       mtime   => $stat[9] // 0,
                                       backend => 'qbt_' . $backend,
                                      }, );

  my $parse = $self->parser->parse_file( $path );

  my $parse_result =
      $db->update_local_torrent_parse(
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
                             parse_ok           => $parse->{ok} ? 1 : 0,
                             parse_problem      => $parse->{ok}
                             ? undef
                             : $parse->{problem},
                            }, );

  if ( $parse->{ok} && $parse->{infohash} ) {
    for my $key ( @{$parse->{observed_keys} // []} ) {
      $db->upsert_hash_value(
                              $dbh,
                              hash       => $parse->{infohash},
                              key        => $key->{key},
                              value      => $key->{value},
                              value_type => $key->{value_type} // 'text', );
    }
  }

  return {
          ok           => $stored->{ok} && $parse_result->{ok} ? 1 : 0,
          stored       => $stored->{ok}                        ? 1 : 0,
          parsed       => $parse->{ok}                         ? 1 : 0,
          from_db      => 0,
          path         => $path,
          hash         => $parse->{infohash} ? $parse->{infohash} : undef,
          torrent_name => $parse->{torrent_name},
          parse_ok     => $parse->{ok} ? 1 : 0,
          problem      => $parse->{problem},};
}

sub _torrent_basename ( $self, $path ) {
  my $base = basename( $path );
  $base =~ s/\.torrent\z//;

  return $base;
}

sub _unique_path ( $self, $dir, $filename ) {
  my $path = File::Spec->catfile( $dir, $filename );

  return $path if !-e $path;

  my ( $base, $suffix ) =
      $filename =~ /\A(.+?)(\.torrent)\z/
      ? ( $1, $2 )
      : ( $filename, '' );

  my $n = 2;

  while ( 1 ) {
    my $candidate = File::Spec->catfile( $dir, $base . '-' . $n . $suffix );

    return $candidate if !-e $candidate;

    $n++;
  }
}

1;
