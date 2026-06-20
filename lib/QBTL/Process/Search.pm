package QBTL::Process::Search;

use v5.40;
use common::sense;
use feature qw( signatures );

use QBTL::Process::WithDB;
use QBTL::Util qw( parse_byte_values );

sub new ( $class, %arg ) {
  $arg{db_process} //= QBTL::Process::WithDB->new( db_path => $arg{db_path}, );

  return bless \%arg, $class;
}

sub db_process ( $self ) {
  return $self->{db_process};
}

sub search_list ( $self ) {
  return $self->db_process->with_db(
    sub ( $db, $dbh ) {
      return {
              ok     => 1,
              action => 'search_list',
              fields => [ $db->qbt_info_columns( $dbh ) ],};
    } );
}

sub search ( $self, %arg ) {
  my $field = $arg{field};
  my $input = $arg{input};
  my $limit = $arg{limit} // 25;

  return $self->db_process->with_db(
    sub ( $db, $dbh ) {
      my $size_query = $self->_size_query( $field, $input );

      if ( $size_query ) {
        my $result =
            $db->search_qbt_size( $dbh, $size_query, limit => $limit, );

        $result->{action} = 'search';

        return $result;
      }

      my $result =
          $db->search_qbt_info( $dbh, $field, $input, limit => $limit, );

      $result->{action} = 'search';

      return $result;
    } );
}

sub _size_field ( $self, $field ) {
  return 1 if $field eq 'total_size';
  return 1 if $field eq 'amount_left';
  return;
}

sub _size_query ( $self, $field, $input ) {
  return if !$self->_size_field( $field );
  return if !defined $input;

  my $text = $input;
  $text =~ s/^\s+//;
  $text =~ s/\s+$//;

  if ( $text =~ /\A([<>]=?)\s*(.+)\z/ ) {
    my $op    = $1;
    my @bytes = parse_byte_values( $2 );

    return if !@bytes;

    return {
            type   => 'size_compare',
            field  => $field,
            op     => $op,
            values => \@bytes,};
  }

  if ( $text =~ /\A(.+?)\s+(\d+(?:\.\d+)?)%\z/ ) {
    my @bytes   = parse_byte_values( $1 );
    my $percent = $2 + 0;

    return if !@bytes;

    my @range;

    for my $bytes ( @bytes ) {
      my $spread = int( $bytes * ( $percent / 100 ) );

      push @range,
          {
           low   => $bytes - $spread,
           high  => $bytes + $spread,
           bytes => $bytes,};
    }

    return {
            type   => 'size_range',
            field  => $field,
            pct    => $percent,
            ranges => \@range,};
  }

  return;
}

1;
