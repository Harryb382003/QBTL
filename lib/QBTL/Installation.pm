package QBTL::Installation;

use v5.40;
use common::sense;
use feature qw( signatures );

use File::Spec;

sub new ( $class, %arg ) {
  die 'db is required'     if !$arg{db};
  die 'dbh is required'    if !$arg{dbh};
  die 'config is required' if !$arg{config};

  return bless \%arg, $class;
}

sub db     ($self) { return $self->{db}; }
sub dbh    ($self) { return $self->{dbh}; }
sub config ($self) { return $self->{config}; }

sub configured_values ($self) {
  my $config = $self->config;

  return {
    installation_root => $config->installation_root,
    database_path     => $config->db_path,
    torrent_pool      => $config->torrent_pool,
  };
}

sub derived_values ($self) {
  my $root = $self->config->installation_root;

  return {
    logs_path    => File::Spec->catdir( $root, 'logs' ),
    backups_path => File::Spec->catdir( $root, 'backups' ),
    tmp_path     => File::Spec->catdir( $root, 'tmp' ),
  };
}

sub prime ($self) {
  my $rows = $self->db->installation_prime(
    $self->dbh,
    configured => $self->configured_values,
    derived    => $self->derived_values,
  );

  my $logs = $self->db->installation_get( $self->dbh, 'logs_path' );
  $ENV{QBTL_LOG_DIR} = $logs if defined $logs && $logs ne '';

  return $rows;
}

sub set_configurable ( $self, %arg ) {
  my $key   = $arg{key};
  my $value = $arg{value};
  my $write = $arg{write_config};

  die 'installation key is required'
      if !defined $key || $key eq '';
  die "installation value is required for $key"
      if !defined $value;
  die 'write_config callback is required'
      if ref($write) ne 'CODE';

  # .qbtlrc remains authoritative. Persist it first. A failed config write
  # must not leave the runtime DB claiming that the change succeeded.
  $write->( $key, $value );

  return $self->db->installation_set(
    $self->dbh,
    key    => $key,
    value  => $value,
    source => 'config',
  );
}

sub sync_status ($self) {
  return $self->db->installation_sync_status(
    $self->dbh,
    $self->configured_values,
  );
}

sub exit_check ($self) {
  my $sync = $self->sync_status;
  return $sync if $sync->{ok};

  for my $difference ( @{ $sync->{differences} } ) {
    my $config = defined $difference->{config_value}
        ? $difference->{config_value}
        : '<undef>';
    my $db = defined $difference->{db_value}
        ? $difference->{db_value}
        : '<undef>';

    warn "installation/config mismatch for $difference->{key}: "
       . ".qbtlrc=$config db=$db\n";
  }

  return $sync;
}

1;
