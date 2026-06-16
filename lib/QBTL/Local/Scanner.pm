package QBTL::Local::Scanner;

use v5.40;
use common::sense;
use feature qw( signatures );

sub new ( $class, %arg ) {
  $arg{limit} //= undef;
  return bless \%arg, $class;
}

sub scan_torrents ( $self ) {
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
