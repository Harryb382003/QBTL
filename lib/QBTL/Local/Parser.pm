package QBTL::Local::Parser;

use v5.40;
use common::sense;
use feature qw( signatures );

use Bencode        qw( bdecode bencode );
use Digest::SHA    qw( sha1_hex );
use File::Basename qw( basename );

sub new ( $class, %arg ) {
  return bless \%arg, $class;
}

sub _bencoded_value_end ( $raw, $start ) {
  return undef if !defined $raw || !defined $start || $start >= length $raw;

  my $type = substr( $raw, $start, 1 );

  if ( $type =~ /[0-9]/ ) {
    my $colon = index( $raw, ':', $start );
    return undef if $colon < 0;

    my $length_text = substr( $raw, $start, $colon - $start );
    return undef if $length_text !~ /\A(?:0|[1-9][0-9]*)\z/;

    my $end = $colon + 1 + $length_text;
    return undef if $end > length $raw;
    return $end;
  }

  if ( $type eq 'i' ) {
    my $end = index( $raw, 'e', $start + 1 );
    return undef if $end < 0;
    return $end + 1;
  }

  if ( $type eq 'l' || $type eq 'd' ) {
    my $position = $start + 1;

    while ( $position < length $raw && substr( $raw, $position, 1 ) ne 'e' ) {
      my $next = _bencoded_value_end( $raw, $position );
      return undef if !defined $next;
      $position = $next;

      if ( $type eq 'd' ) {
        $next = _bencoded_value_end( $raw, $position );
        return undef if !defined $next;
        $position = $next;
      }
    }

    return undef if $position >= length $raw;
    return $position + 1;
  }

  return undef;
}

sub _raw_top_level_value ( $raw, $wanted_key ) {
  return undef if !defined $raw || substr( $raw, 0, 1 ) ne 'd';

  my $position = 1;

  while ( $position < length $raw && substr( $raw, $position, 1 ) ne 'e' ) {
    my $colon = index( $raw, ':', $position );
    return undef if $colon < 0;

    my $length_text = substr( $raw, $position, $colon - $position );
    return undef if $length_text !~ /\A(?:0|[1-9][0-9]*)\z/;

    my $key_start = $colon + 1;
    my $key_end   = $key_start + $length_text;
    return undef if $key_end > length $raw;

    my $key       = substr( $raw, $key_start, $length_text );
    my $value_end = _bencoded_value_end( $raw, $key_end );
    return undef if !defined $value_end;

    return substr( $raw, $key_end, $value_end - $key_end )
        if $key eq $wanted_key;

    $position = $value_end;
  }

  return undef;
}

sub raw_info_from_bytes ( $self, $raw ) {
  return _raw_top_level_value( $raw, 'info' );
}

sub _integer_value ( $value ) {
  return undef if !defined $value;
  return undef if ref $value;
  return undef if $value !~ /\A\d+\z/;
  return $value + 0;
}

sub _metadata_value_type ( $value ) {
  return 'null'  if !defined $value;
  return 'array' if ref $value eq 'ARRAY';
  return 'hash'  if ref $value eq 'HASH';

  if ( !ref $value && $value =~ /\A-?[0-9]+\z/ ) {
    return 'integer';
  }

  return 'text';
}

sub _metadata_value_text ( $value ) {
  return '' if !defined $value;

  if ( ref $value eq 'ARRAY' ) {
    return '[array:' . scalar( @{$value} ) . ']';
  }

  if ( ref $value eq 'HASH' ) {
    return '[hash:' . scalar( keys %{$value} ) . ']';
  }

  return "$value";
}

sub _observed_top_level_keys ( $torrent ) {
  my %handled = map { $_ => 1 }
      ( 'announce', 'comment', 'created by', 'creation date', 'info', );

  my @observed;

  for my $key ( sort keys %{$torrent} ) {
    next if $handled{$key};

    my $value = $torrent->{$key};

    push @observed,
        {
         key        => $key,
         value      => _metadata_value_text( $value ),
         value_type => _metadata_value_type( $value ),};
  }

  return \@observed;
}

sub _observed_info_keys ( $info ) {
  return [] if ref( $info ) ne 'HASH';

  my @observed;

  if ( exists $info->{name} ) {
    push @observed,
        {
         key        => 'info.name',
         value      => _metadata_value_text( $info->{name} ),
         value_type => _metadata_value_type( $info->{name} ),};
  }

  if ( exists $info->{length} ) {
    push @observed,
        {
         key        => 'info.length',
         value      => _metadata_value_text( $info->{length} ),
         value_type => _metadata_value_type( $info->{length} ),};
  }

  if ( ref( $info->{files} ) eq 'ARRAY' ) {
    push @observed,
        {
         key        => 'info.files.count',
         value      => scalar @{$info->{files}},
         value_type => 'integer',};

    my $index = 0;
    for my $file ( @{$info->{files}} ) {
      next if ref( $file ) ne 'HASH';

      my $path = _torrent_file_path( $file->{path} );

      if ( defined $path ) {
        push @observed,
            {
             key        => "info.files.$index.path",
             value      => $path,
             value_type => 'text',};
      }

      if ( exists $file->{length} ) {
        push @observed,
            {
             key        => "info.files.$index.length",
             value      => _metadata_value_text( $file->{length} ),
             value_type => _metadata_value_type( $file->{length} ),};
      }

      $index++;
    }
  }

  return \@observed;
}

sub _torrent_file_path ( $path ) {
  return undef if !defined $path;
  return undef if !ref( $path ) && $path eq '';

  if ( ref( $path ) eq 'ARRAY' ) {
    my @part = grep { defined $_ && !ref( $_ ) && $_ ne '' } @{$path};
    return undef if !@part;
    return join '/', @part;
  }

  return undef if ref( $path );
  return "$path";
}

sub _payload_metadata ( $info ) {
  return {} if ref( $info ) ne 'HASH';

  my $name = _string_value( $info->{name} );

  if ( ref( $info->{files} ) eq 'ARRAY' ) {
    my $file_count = 0;
    my $total_size = 0;
    my $probe_path;

    for my $file ( @{$info->{files}} ) {
      next if ref( $file ) ne 'HASH';

      $file_count++;
      $total_size += $file->{length}
          if defined $file->{length}
          && !ref( $file->{length} )
          && $file->{length} =~ /\A\d+\z/;
      $probe_path //= _torrent_file_path( $file->{path} );
    }

    return {
            payload_kind       => 'multi_file',
            payload_root_name  => $name,
            payload_file_count => $file_count,
            payload_total_size => $total_size,
            payload_probe_path => $probe_path,
            payload_probe_name => defined $probe_path
            ? basename( $probe_path )
            : undef,};
  }

  return {
          payload_kind       => 'single_file',
          payload_root_name  => $name,
          payload_file_count => 1,
          payload_total_size => _integer_value( $info->{length} ),
          payload_probe_path => $name,
          payload_probe_name => defined $name ? basename( $name ) : undef,};
}

sub _trackers ( $torrent ) {
  my @tracker;
  my %seen;

  my $add = sub ( $url, $tier, $position ) {
    return if !defined $url || ref $url || $url eq '';

    my $key = join "\0", $url, $tier // '', $position // '';
    return if $seen{$key}++;

    my $host = _url_host( $url );

    push @tracker,
        {
         tracker_url    => "$url",
         tracker_host   => $host,
         tracker_domain => _domain_label( $host ),
         tier           => $tier,
         position       => $position,};
  };

  $add->( $torrent->{announce}, 0, 0 );

  my $announce_list = $torrent->{'announce-list'};
  if ( ref $announce_list eq 'ARRAY' ) {
    my $tier = 1;
    for my $row ( @{$announce_list} ) {
      my @url      = ref $row eq 'ARRAY' ? @{$row} : ( $row );
      my $position = 0;
      for my $url ( @url ) {
        $add->( $url, $tier, $position );
        $position++;
      }
      $tier++;
    }
  }

  return \@tracker;
}

sub _payload_files ( $info ) {
  my @file;

  if ( ref $info->{files} eq 'ARRAY' ) {
    my $index = 0;
    for my $row ( @{$info->{files}} ) {
      next if ref $row ne 'HASH';

      my $path = _torrent_file_path( $row->{path} );
      next if !defined $path || $path eq '';

      push @file,
          {
           file_index => $index,
           path       => $path,
           name       => basename( $path ),
           size       => _integer_value( $row->{length} ),};

      $index++;
    }

    return \@file;
  }

  my $name = _string_value( $info->{name} );
  return \@file if !defined $name || $name eq '';

  push @file,
      {
       file_index => 0,
       path       => $name,
       name       => basename( $name ),
       size       => _integer_value( $info->{length} ),};

  return \@file;
}

sub _info_fields ( $info ) {
  my @field;

  return \@field if ref $info ne 'HASH';

  for my $key ( sort keys %{$info} ) {
    my $value = $info->{$key};

    if ( $key eq 'pieces' && !ref $value ) {
      push @field,
          {
        key             => 'pieces',
        value           => undef,
        value_type      => 'binary_piece_hash_blob',
        storage_policy  => 'omitted_blob',
        byte_length     => length( $value ),
        omission_reason => 'raw info.pieces hash blob intentionally not stored',
          };

      push @field,
          {
           key        => 'pieces_count',
           value      => int( length( $value ) / 20 ),
           value_type => 'integer',};
      next;
    }

    if ( $key eq 'files' && ref $value eq 'ARRAY' ) {
      push @field,
          {
           key        => 'files_count',
           value      => scalar @{$value},
           value_type => 'integer',};
      next;
    }

    push @field,
        {
         key        => $key,
         value      => _metadata_value_text( $value ),
         value_type => _metadata_value_type( $value ),};
  }

  return \@field;
}

sub _url_host ( $url ) {
  return undef if !defined $url;
  my ( $host ) = $url =~ m{\A[a-z][a-z0-9+.-]*://([^/:?#]+)}i;
  return $host;
}

sub _domain_label ( $host ) {
  return undef if !defined $host || $host eq '';

  my @part = grep {length} split /\./, $host;
  return undef    if !@part;
  return $part[0] if @part == 1;
  return $part[-2];
}

sub parse_file ( $self, $path ) {
  return {
          ok      => 0,
          path    => $path,
          problem => 'path is missing',}
      if !defined $path || $path eq '';

  return {
          ok      => 0,
          path    => $path,
          problem => 'path does not exist',}
      if !-e $path;

  return {
          ok      => 0,
          path    => $path,
          problem => 'path is not a file',}
      if !-f $path;

  my $raw = do {
    open my $fh, '<:raw',
        $path
        or return {
                   ok      => 0,
                   path    => $path,
                   problem => "open failed: $!",};

    local $/;
    <$fh>;
  };

  my $data;
  my $decode_error;

  {
    local $SIG{__WARN__} = sub {
      my $warning = shift;
      warn $warning if $warning !~ m{/Bencode\.pm line \d+};
    };

    $data = eval { bdecode( $raw ) };
    $decode_error = $@;
  }

  if ( $decode_error || ref $data ne 'HASH' ) {
    my $problem = $decode_error || 'decoded value is not a dictionary';
    $problem =~ s/\s+\z//;

    return {
            ok      => 0,
            problem => "bdecode failed for $path: $problem",};
  }

  my $hash;
  my $file_type;

  if ( $path =~ /\.fastresume\z/i ) {
    $file_type = 'fastresume';

    ( $hash ) = $path =~ m{([0-9a-f]{40})\.fastresume\z};

    if ( !$hash ) {
      return {
        ok        => 0,
        file_type => $file_type,
        problem   => 'fastresume filename does not match lowercase
hash.fastresume',};
    }

    return {
            ok            => 1,
            file_type     => $file_type,
            hash      => $hash,
            observed_keys => _observed_top_level_keys( $data ),};
  }

  $file_type = 'torrent';

  if ( !exists $data->{info} ) {
    return {
            ok        => 0,
            file_type => $file_type,
            problem   => 'missing info dictionary',};
  }

  my $raw_info = _raw_top_level_value( $raw, 'info' );
  if ( !defined $raw_info ) {
    return {
            ok        => 0,
            file_type => $file_type,
            problem   => 'raw info dictionary was not found',};
  }

  $hash = sha1_hex($raw_info);
  my $observed_keys = _observed_top_level_keys( $data );
  push @{$observed_keys}, @{_observed_info_keys( $data->{info} )};

  my $payload = _payload_metadata( $data->{info} );

  return {
          ok                 => 1,
          path               => $path,
          hash           => $hash,
          hash               => $hash,
          torrent_name       => _string_value( $data->{info}{name} ),
          comment            => _string_value( $data->{comment} ),
          announce           => _string_value( $data->{announce} ),
          created_by         => _string_value( $data->{'created by'} ),
          creation_date      => _integer_value( $data->{'creation date'} ),
          payload_kind       => $payload->{payload_kind},
          payload_root_name  => $payload->{payload_root_name},
          payload_file_count => $payload->{payload_file_count},
          payload_total_size => $payload->{payload_total_size},
          payload_probe_path => $payload->{payload_probe_path},
          payload_probe_name => $payload->{payload_probe_name},
          trackers           => _trackers( $data ),
          payload_files      => _payload_files( $data->{info} ),
          info_fields        => _info_fields( $data->{info} ),
          observed_keys      => $observed_keys,
          file_type          => $file_type,};
}

sub _string_value ( $value ) {
  return undef if !defined $value;
  return undef if ref $value;
  return "$value";
}

1;
