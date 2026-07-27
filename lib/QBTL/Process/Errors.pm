package QBTL::Process::Errors;

use v5.40;
use common::sense;
use feature qw( signatures );

use Exporter qw( import );

# 1000–1099  local torrent parsing
# 1100–1199  local fastresume parsing
# 2000–2099  filesystem operations
# 3000–3099  database/storage
# 4000–4099  qBittorrent API
# 5000–5099  metadata conflicts

our @EXPORT_OK = qw(
    ERR_TORRENT_BDECODE_FAILED
    ERR_TORRENT_INFO_MISSING

    classify_torrent_parse_error
    error_name
    is_quarantinable
);

use constant {
              ERR_TORRENT_BDECODE_FAILED => 1001,
              ERR_TORRENT_INFO_MISSING   => 1002,};

sub classify_torrent_parse_error ( $problem ) {
  return if !defined $problem;

  return ERR_TORRENT_BDECODE_FAILED
      if $problem =~ /\Abdecode failed\b/;

  return ERR_TORRENT_INFO_MISSING
      if $problem =~ /\Amissing info dictionary\b/;

  return;
}

sub error_name ( $code ) {
  return 'torrent bdecode failed'
      if defined $code
      && $code == ERR_TORRENT_BDECODE_FAILED;

  return 'torrent info dictionary missing'
      if defined $code
      && $code == ERR_TORRENT_INFO_MISSING;

  return 'unknown QBTL error';
}

sub is_quarantinable ( $code ) {
  return 0 if !defined $code;

  return 1001
      if $code == ERR_TORRENT_BDECODE_FAILED;

  return 1002
      if $code == ERR_TORRENT_INFO_MISSING;

  return 0;
}

1;
