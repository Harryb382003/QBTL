package QBTL::Process::Local;

use v5.40;
use common::sense;
use feature qw( signatures );

use Time::HiRes qw( time );

use QBTL::Local::Parser;
use QBTL::Local::Scanner;
use QBTL::Process::WithDB;

sub new ( $class, %arg ) {
  $arg{db_process} //= QBTL::Process::WithDB->new( db_path => $arg{db_path}, );
  $arg{parser}     //= QBTL::Local::Parser->new;
  $arg{scanner}    //= QBTL::Local::Scanner->new(
    search_tool => $arg{search_tool},
  );

  return bless \%arg, $class;
}

sub db_process ( $self ) {
  return $self->{db_process};
}

sub _elapsed ( $started ) {
  return sprintf( '%.2f', time - $started );
}

sub parser ( $self ) {
  return $self->{parser};
}

sub scanner ( $self ) {
  return $self->{scanner};
}

sub scan ( $self, %arg ) {
  my $started   = time;
  my $threshold = $arg{threshold} // 20;
  my $scan      = $self->scanner->scan_torrents( path => $arg{path}, );

  if ( !$scan->{ok} ) {
    return {
            ok             => 0,
            action         => 'local_scan',
            backend        => $scan->{backend},
            target         => $scan->{path},
            search_tool    => $scan->{search_tool},
            seen           => $scan->{count} // 0,
            stored         => 0,
            parsed         => 0,
            parse_problems => 0,
            total          => 0,
            elapsed        => _elapsed( $started ),
            problems       => $scan->{problems} // [],};
  }

  return $self->db_process->with_db(
    sub ( $db, $dbh ) {
      my $stored                   = 0;
      my $parsed                   = 0;
      my $parse_problem            = 0;
      my $fastresume_stored        = 0;
      my $fastresume_parsed        = 0;
      my $fastresume_parse_problem = 0;
      my @problem;

      for my $type ( qw(torrent fastresume) ) {

        for my $path ( @{$scan->{types}{$type}{paths} // []} ) {

          if ( $type eq 'fastresume' ) {
            my @stat = stat( $path );

            if ( !@stat ) {
              push @problem, "stat failed for $path: $!";
              next;
            }

            my $store = eval {
              $db->upsert_local_fastresume_file(
                                                 $dbh,
                                                 {
                                                  path    => $path,
                                                  size    => $stat[7],
                                                  mtime   => $stat[9],
                                                  backend => $scan->{backend},
                                                 } );
            };

            if ( $@ ) {
              push @problem, "fastresume store failed for $path: $@";
              next;
            }

            if ( !$store->{ok} ) {
              push @problem, "fastresume store failed for $path";
              next;
            }

            $fastresume_stored++;

            my $parse = $self->parser->parse_file( $path );

            my $parse_store = eval {
              $db->update_local_fastresume_parse(
                     $dbh,
                     {
                      path          => $path,
                      infohash      => $parse->{infohash},
                      parse_ok      => $parse->{ok} ? 1     : 0,
                      parse_problem => $parse->{ok} ? undef : $parse->{problem},
                     } );
            };

            if ( $@ ) {
              push @problem, "fastresume parse store failed for $path: $@";
              next;
            }

            if ( !$parse_store->{ok} ) {
              push @problem, "fastresume parse store failed for $path";
              next;
            }

            if ( $parse->{ok} && $parse->{infohash} ) {
              for my $key ( @{$parse->{observed_keys} // []} ) {
                my $stored_key = eval {
                  $db->upsert_hash_value(
                                     $dbh,
                                     hash       => $parse->{infohash},
                                     key        => $key->{key},
                                     value      => $key->{value},
                                     value_type => $key->{value_type} // 'text',
                  );
                };

                if ( $@ ) {
                  push @problem,
                      "fastresume metadata key store failed for $path: $@";
                  next;
                }

                if ( !$stored_key->{ok} ) {
                  push @problem,
                      "fastresume metadata key store failed for $path: "
                      . ( $stored_key->{error} // $key->{key} );
                  next;
                }
              }
            }

            if ( $parse->{ok} ) {
              $fastresume_parsed++;
            } else {
              $fastresume_parse_problem++;
            }

            next;
          }
          my @stat = stat( $path );

          if ( !@stat ) {
            push @problem, "stat failed for $path: $!";
            next;
          }

          my $result = eval {
            $db->upsert_local_torrent_file(
                                            $dbh,
                                            {
                                             path    => $path,
                                             size    => $stat[7],
                                             mtime   => $stat[9],
                                             backend => $scan->{backend},
                                            } );
          };

          if ( $@ ) {
            push @problem, "store failed for $path: $@";
            next;
          }

          if ( !$result->{ok} ) {
            push @problem, "store failed for $path";
            next;
          }

          $stored++;

          my $parse = $self->parser->parse_file( $path );

          my $parse_result = eval {
            $db->update_local_torrent_parse(
                     $dbh,
                     {
                      path          => $path,
                      infohash      => $parse->{infohash},
                      torrent_name  => $parse->{torrent_name},
                      comment       => $parse->{comment},
                      announce      => $parse->{announce},
                      created_by    => $parse->{created_by},
                      creation_date => $parse->{creation_date},
                      parse_ok      => $parse->{ok} ? 1     : 0,
                      parse_problem => $parse->{ok} ? undef : $parse->{problem},
                     } );
          };

          if ( $@ ) {
            push @problem, "parse store failed for $path: $@";
            next;
          }

          if ( !$parse_result->{ok} ) {
            push @problem, "parse store failed for $path";
            next;
          }

          if ( $parse->{ok} && $parse->{infohash} ) {
            for my $key ( @{$parse->{observed_keys} // []} ) {
              my $stored_key = eval {
                $db->upsert_hash_value(
                                     $dbh,
                                     hash       => $parse->{infohash},
                                     key        => $key->{key},
                                     value      => $key->{value},
                                     value_type => $key->{value_type} // 'text',
                );
              };

              if ( $@ ) {
                push @problem, "metadata key store failed for $path: $@";
                next;
              }

              if ( !$stored_key->{ok} ) {
                push @problem,
                    "metadata key store failed for $path: "
                    . ( $stored_key->{error} // $key->{key} );
                next;
              }
            }
          }

          if ( $parse->{ok} ) {
            $parsed++;
          } else {
            $parse_problem++;
          }
        }
      }

      my $metadata_candidates =
          $db->promotion_candidates( $dbh, threshold => $threshold, );

      return {
        ok      => @problem ? 0 : 1,
        action  => 'local_scan',
        backend => $scan->{backend},
        target  => $scan->{path},
        search_tool => $scan->{search_tool},
        seen    => $scan->{count},

        torrent_seen    => $scan->{types}{torrent}{count} // 0,
        stored          => $stored,
        parsed          => $parsed,
        parse_problems  => $parse_problem,
        fastresume_seen => $scan->{types}{fastresume}{count} // 0,
        total           => $db->local_torrent_file_count( $dbh ),

        fastresume_stored         => $fastresume_stored,
        fastresume_parsed         => $fastresume_parsed,
        fastresume_parse_problems => $fastresume_parse_problem,
        fastresume_total          => $db->local_fastresume_file_count( $dbh ),

        elapsed             => _elapsed( $started ),
        problems            => \@problem,
        metadata_candidates => $metadata_candidates,};
    } );
}

sub summary ( $self ) {
  return $self->db_process->with_db(
    sub ( $db, $dbh ) {
      return {
              ok      => 1,
              action  => 'local_summary',
              summary => $db->local_torrent_summary( $dbh ),};
    } );
}

1;
