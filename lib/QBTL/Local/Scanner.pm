package QBTL::Local::Scanner;

use v5.40;
use common::sense;
use feature            qw( signatures );
use Encode             qw(decode);
use String::ShellQuote qw( shell_quote );

use File::Spec;

sub new ( $class, %arg ) {
  $arg{limit}       //= undef;
  $arg{search_tool} //= 'mdfind';

  return bless \%arg, $class;
}

sub _empty_types () {
  return {
          torrent    => {count => 0, paths => [],},
          fastresume => {count => 0, paths => [],},};
}

sub _command_path ( $command ) {
  for my $dir ( File::Spec->path ) {
    next if !defined $dir || $dir eq '';

    my $path = File::Spec->catfile( $dir, $command );
    return $path if -x $path && !-d $path;
  }

  return;
}

sub _count_types ( $types ) {
  my $count = 0;
  $count += $types->{$_}{count} // 0 for qw(torrent fastresume);

  return $count;
}

sub _find_torrents ( $self, %arg ) {
  my $find = _command_path( 'find' );
  my $path = $arg{path};

  if ( !$find ) {
    return {
            ok          => 0,
            backend     => 'find',
            search_tool => 'find',
            path        => $path,
            paths       => [],
            types       => _empty_types(),
            count       => 0,
            problems    => ['find not available'],};
  }

  if ( !defined $path || $path eq '' ) {
    return {
      ok          => 0,
      backend     => 'find',
      search_tool => 'find',
      paths       => [],
      types       => _empty_types(),
      count       => 0,
      problems    => [
        'search_tool=find requires an explicit path; refusing to scan the
whole filesystem'
      ],};
  }

  my @type = qw(torrent fastresume);
  my $type = _empty_types();
  my @problem;

  for my $kind ( @type ) {
    my $suffix = _suffix_for_type( $kind );
    my @path;

    open my $fh, '-|', $find, $path, '-type', 'f', '-iname', "*.$suffix"
        or do {
      push @problem, "find failed for .$suffix: $!";
      next;
        };

    while ( my $found = <$fh> ) {
      chomp $found;
      next if $found eq '';

      push @path, File::Spec->rel2abs( $found );
    }

    close $fh
        or push @problem, "find close failed for .$suffix: $!";

    @path = sort @path;

    $type->{$kind} = {
                      count => scalar @path,
                      paths => \@path,};
  }

  return {
          ok          => @problem ? 0 : 1,
          backend     => 'find',
          search_tool => 'find',
          path        => $path,
          count       => _count_types( $type ),
          paths       => $type->{torrent}{paths},
          types       => $type,
          problems    => \@problem,};
}

sub _locate_torrents ( $self, %arg ) {
  my $command = $arg{command} // 'locate';
  my $tool    = _command_path( $command );
  my $path    = $arg{path};

  if ( !$tool ) {
    return {
            ok          => 0,
            backend     => $command,
            search_tool => $command,
            path        => $path,
            paths       => [],
            types       => _empty_types(),
            count       => 0,
            problems    => ["$command not available"],};
  }

  my $root;

  if ( defined $path && $path ne '' ) {
    $root = File::Spec->rel2abs( $path );
    $root =~ s{/+\z}{};
  }

  my @type = qw(torrent fastresume);
  my $type = _empty_types();
  my @problem;

  for my $kind ( @type ) {
    my $suffix = _suffix_for_type( $kind );
    my @path;

    open my $fh, '-|', $tool, "*.$suffix"
        or do {
      push @problem, "$command failed for .$suffix: $!";
      next;
        };

    while ( my $found = <$fh> ) {
      chomp $found;
      next if $found eq '';

      $found = File::Spec->rel2abs( $found );

      if ( defined $root ) {
        next if index( $found, "$root/" ) != 0;
      }

      push @path, $found;
    }

    close $fh
        or push @problem, "$command close failed for .$suffix: $!";

    @path = sort @path;

    $type->{$kind} = {
                      count => scalar @path,
                      paths => \@path,};
  }

  return {
          ok          => @problem ? 0 : 1,
          backend     => $command,
          search_tool => $command,
          path        => $path,
          count       => _count_types( $type ),
          paths       => $type->{torrent}{paths},
          types       => $type,
          problems    => \@problem,};
}

sub _mdfind_torrents ( $self, %arg ) {
  my $mdfind = _command_path( 'mdfind' );
  my $path   = $arg{path};

  if ( !$mdfind ) {
    return {
            ok          => 0,
            backend     => 'mdfind',
            search_tool => 'mdfind',
            path        => $path,
            paths       => [],
            types       => _empty_types(),
            count       => 0,
            problems    => ['mdfind not available'],};
  }

  my @type = qw(torrent fastresume);
  my $type = _empty_types();
  my @problem;

  for my $kind ( @type ) {
    my $suffix = _suffix_for_type( $kind );
    my $query  = qq{kMDItemFSName == "*.$suffix"cd};
    my @cmd    = ( $mdfind );

    if ( defined $path && $path ne '' ) {
      push @cmd, '-onlyin', $path;
    }

    push @cmd, $query;

    my @path;

    open my $fh, '-|', @cmd
        or do {
      push @problem, "mdfind failed for .$suffix: $!";
      next;
        };

    while ( my $found = <$fh> ) {
      chomp $found;
      next if $found eq '';

      $found = decode( 'UTF-8', $found, 1 );
      push @path, File::Spec->rel2abs( $found );
    }

    close $fh
        or push @problem, "mdfind close failed for .$suffix: $!";

    @path = sort @path;

    $type->{$kind} = {
                      count => scalar @path,
                      paths => \@path,};
  }

  return {
    ok          => @problem ? 0 : 1,
    backend     => 'mdfind',
    search_tool => 'mdfind',
    path        => $path,
    count       => _count_types( $type ),

    # compatibility for existing Process::Local code
    paths => $type->{torrent}{paths},

    # new grouped result
    types => $type,

    problems => \@problem,};
}

sub _path_torrents ( $self, $path ) {
  if ( !-e $path ) {
    return {
            ok          => 0,
            backend     => $self->{search_tool},
            search_tool => $self->{search_tool},
            path        => $path,
            paths       => [],
            types       => _empty_types(),
            count       => 0,
            problems    => ["path does not exist: $path"],};
  }

  if ( -f $path ) {
    my @type = qw(torrent fastresume);
    my $type = _empty_types();
    my $matched;

    for my $kind ( @type ) {
      my $suffix = _suffix_for_type( $kind );

      if ( $path =~ /\.\Q$suffix\E\z/i ) {
        push @{$type->{$kind}{paths}}, File::Spec->rel2abs( $path );
        $type->{$kind}{count} = 1;
        $matched = 1;
        last;
      }
    }

    if ( !$matched ) {
      return {
              ok          => 0,
              backend     => 'path',
              search_tool => $self->{search_tool},
              path        => $path,
              count       => 0,
              paths       => [],
              types       => $type,
              problems    => ["not a .torrent or .fastresume file: $path"],};
    }

    return {
      ok          => 1,
      backend     => 'path',
      search_tool => $self->{search_tool},
      path        => $path,
      count       => _count_types( $type ),

      # compatibility for existing torrent callers
      paths => $type->{torrent}{paths},

      # grouped result
      types => $type,

      problems => [],};
  }

  if ( -d $path ) {
    if ( File::Spec->rel2abs( $path ) eq '/' ) {
      return $self->_scan_global;
    }

    return $self->_scan_directory( $path );
  }

  return {
          ok          => 0,
          backend     => $self->{search_tool},
          search_tool => $self->{search_tool},
          path        => $path,
          paths       => [],
          types       => _empty_types(),
          count       => 0,
          problems    => ["path is not a file or directory: $path"],};
}

sub _scan_directory ( $self, $path ) {
  my $tool = $self->{search_tool} // 'mdfind';

  if ( $tool eq 'mdfind' ) {
    return $self->_mdfind_torrents( path => $path );
  }

  if ( $tool =~ /\A(?:plocate|mlocate|locate|slocate)\z/ ) {
    return $self->_locate_torrents( path => $path, command => $tool );
  }

  if ( $tool eq 'find' ) {
    return $self->_find_torrents( path => $path );
  }

  return {
          ok          => 0,
          backend     => $tool,
          search_tool => $tool,
          path        => $path,
          paths       => [],
          types       => _empty_types(),
          count       => 0,
          problems    => ["unknown local search_tool: $tool"],};
}

sub _scan_global ( $self ) {
  my $tool = $self->{search_tool} // 'mdfind';

  if ( $tool eq 'mdfind' ) {
    return $self->_mdfind_torrents;
  }

  if ( $tool =~ /\A(?:plocate|mlocate|locate|slocate)\z/ ) {
    return $self->_locate_torrents( command => $tool );
  }

  if ( $tool eq 'find' ) {
    return {
      ok          => 0,
      backend     => 'find',
      search_tool => 'find',
      paths       => [],
      types       => _empty_types(),
      count       => 0,
      problems    => [
        'search_tool=find requires an explicit path; refusing to scan the
whole filesystem'
      ],};
  }

  return {
          ok          => 0,
          backend     => $tool,
          search_tool => $tool,
          paths       => [],
          types       => _empty_types(),
          count       => 0,
          problems    => ["unknown local search_tool: $tool"],};
}

sub scan_torrents ( $self, %arg ) {
  my $path = $arg{path};

  if ( defined $path && $path ne '' ) {
    return $self->_path_torrents( $path );
  }

  return $self->_scan_global;
}

sub _suffix_for_type ( $type ) {
  return $type eq 'fastresume' ? 'fastresume' : 'torrent';
}

1;
