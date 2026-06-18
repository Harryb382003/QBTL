package QBTL::Local::Scanner;

use v5.40;
use common::sense;
use feature qw( signatures );

use File::Find qw(find);
use File::Spec;

sub new ( $class, %arg ) {
  $arg{limit} //= undef;
  return bless \%arg, $class;
}

sub _path_torrents ( $self, $path ) {
  my @paths;
  my @problems;

  if ( !-e $path ) {
    return {
            ok       => 0,
            backend  => 'path',
            paths    => [],
            count    => 0,
            problems => ["path does not exist: $path"],};
  }

  if ( -f $path ) {
    if ( $path =~ /\.torrent\z/i ) {
      push @paths, File::Spec->rel2abs( $path );
    } else {
      push @problems, "not a .torrent file: $path";
    }

    return {
            ok       => @problems ? 0 : 1,
            backend  => 'path',
            paths    => \@paths,
            count    => scalar @paths,
            problems => \@problems,};
  }

  if ( -d $path ) {
    find(
      {
       wanted => sub {
         return if !-f $_;
         return if $_ !~ /\.torrent\z/i;

         push @paths, $File::Find::name;
       },
       no_chdir => 1,
      },
      $path, );

    @paths = map { File::Spec->rel2abs( $_ ) } sort @paths;

    return {
            ok       => 1,
            backend  => 'path',
            paths    => \@paths,
            count    => scalar @paths,
            problems => [],};
  }

  return {
          ok       => 0,
          backend  => 'path',
          paths    => [],
          count    => 0,
          problems => ["path is not a file or directory: $path"],};
}

sub scan_torrents ( $self, %arg ) {
  my $path = $arg{path};

  if ( defined $path && $path ne '' ) {
    return $self->_path_torrents( $path );
  }

  return $self->_mdfind_torrents;
}

sub _mdfind_torrents ( $self ) {
  my $mdfind = _command_path( 'mdfind' );
  my $fh;

  if ( !$mdfind ) {
    return {
            ok       => 0,
            backend  => 'mdfind',
            paths    => [],
            count    => 0,
            problems => ['mdfind not available'],};
  }

  my @type = qw(torrent fastresume);
  my %type;
  my @problem;

  for my $type ( @type ) {
    $type{$type} = {
                    count => 0,
                    paths => [],};

    my $query = qq{kMDItemFSName == "*.$type"cd};

    my @path;

    open my $fh, '-|', $mdfind, $query
        or do {
      push @problem, "mdfind failed for .$type: $!";
      next;
        };

    while ( my $path = <$fh> ) {
      chomp $path;
      next if $path eq '';

      push @path, $path;
    }

    close $fh
        or push @problem, "mdfind close failed for .$type: $!";

    $type{$type} = {
                    count => scalar @path,
                    paths => \@path,};
  }

  my $count = 0;
  $count += $type{$_}{count} for @type;

  return {
    ok      => @problem ? 0 : 1,
    backend => 'mdfind',
    count   => $count,

    # compatibility for existing Process::Local code
    paths => $type{torrent}{paths},

    # new grouped result
    types => \%type,

    problems => \@problem,};
}

sub _command_path ( $command ) {
  for my $dir ( split /:/, $ENV{PATH} // '' ) {
    my $path = "$dir/$command";
    return $path if -x $path;
  }

  return;
}

1;
