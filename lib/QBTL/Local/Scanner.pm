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

  my @path;
  my @problem;

  my $query = q{kMDItemFSName == "*.torrent"cd};

  if ( !open $fh, '-|', $mdfind, $query ) {
    return {
            ok       => 0,
            backend  => 'mdfind',
            paths    => [],
            count    => 0,
            problems => ["could not run mdfind: $!"],};
  }

  while ( my $line = <$fh> ) {
    chomp $line;
    next if !defined $line;
    next if $line eq '';
    push @path, $line;
  }

  if ( !close $fh ) {
    push @problem, 'mdfind exited with an error';
  }

  my %seen;
  @path = grep { !$seen{$_}++ } @path;
  @path = grep { -e $_ || -l $_ } @path;
  @path = grep { -f $_ } @path;

  if (    defined $self->{limit}
       && $self->{limit} =~ /\A\d+\z/
       && $self->{limit} > 0 )
  {
    @path = @path[ 0 .. $self->{limit} - 1 ] if @path > $self->{limit};
  }

  return {
          ok       => @problem ? 0 : 1,
          backend  => 'mdfind',
          paths    => \@path,
          count    => scalar @path,
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
