CREATE TABLE IF NOT EXISTS key_accessors (
  "key" TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  source TEXT,
  accessor TEXT,
  status TEXT NOT NULL DEFAULT 'todo',
  note TEXT,
  first_seen_on TEXT DEFAULT CURRENT_TIMESTAMP,
  last_seen_on TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_key_accessors_kind
  ON key_accessors(kind);

CREATE INDEX IF NOT EXISTS idx_key_accessors_status
  ON key_accessors(status);

INSERT INTO key_accessors
  ("key", kind, source, accessor, status, note)
VALUES
  ('infohash', 'core', 'local_torrent_files.infohash', NULL, 'todo', 'Torrent identity hash from local evidence'),
  ('torrent_name', 'core', 'local_torrent_files.torrent_name', NULL, 'todo', 'Name from local .torrent metadata'),
  ('comment', 'core', 'local_torrent_files.comment', NULL, 'todo', 'Top-level .torrent comment field'),
  ('announce', 'core', 'local_torrent_files.announce', NULL, 'todo', 'Top-level .torrent announce URL'),
  ('created_by', 'core', 'local_torrent_files.created_by', NULL, 'todo', 'Top-level .torrent created by field'),
  ('creation_date', 'core', 'local_torrent_files.creation_date', NULL, 'todo', 'Top-level .torrent creation date field'),
  ('path', 'core', 'local_torrent_files.path', NULL, 'todo', 'Local evidence file path'),
  ('size', 'core', 'local_torrent_files.size', NULL, 'todo', 'Local evidence file size'),
  ('mtime', 'core', 'local_torrent_files.mtime', NULL, 'todo', 'Local evidence file modification time'),
  ('parse_ok', 'core', 'local_torrent_files.parse_ok', NULL, 'todo', 'Local evidence parse success flag'),
  ('parse_problem', 'core', 'local_torrent_files.parse_problem', NULL, 'todo', 'Local evidence parse problem text'),
  ('hash', 'core', 'qbt_info.hash', NULL, 'todo', 'qBittorrent torrent hash'),
  ('name', 'core', 'qbt_info.name', NULL, 'todo', 'qBittorrent torrent name'),
  ('save_path', 'core', 'qbt_info.save_path', NULL, 'todo', 'qBittorrent save path'),
  ('content_path', 'core', 'qbt_info.content_path', NULL, 'todo', 'qBittorrent content path'),
  ('category', 'core', 'qbt_info.category', NULL, 'todo', 'qBittorrent category'),
  ('tags', 'core', 'qbt_info.tags', NULL, 'todo', 'qBittorrent tags'),
  ('state', 'core', 'qbt_info.state', NULL, 'todo', 'qBittorrent state'),
  ('progress', 'core', 'qbt_info.progress', NULL, 'todo', 'qBittorrent progress'),
  ('amount_left', 'core', 'qbt_info.amount_left', NULL, 'todo', 'qBittorrent amount left'),
  ('total_size', 'core', 'qbt_info.total_size', NULL, 'todo', 'qBittorrent total size'),
  ('added_on', 'core', 'qbt_info.added_on', NULL, 'todo', 'qBittorrent added on timestamp'),
  ('completion_on', 'core', 'qbt_info.completion_on', NULL, 'todo', 'qBittorrent completion timestamp'),
  ('last_activity', 'core', 'qbt_info.last_activity', NULL, 'todo', 'qBittorrent last activity timestamp'),
  ('tracker', 'core', 'qbt_info.tracker', NULL, 'todo', 'qBittorrent tracker field'),
  ('ratio', 'core', 'qbt_info.ratio', NULL, 'todo', 'qBittorrent ratio'),
  ('current_qbt', 'core', 'qbt_info.current_qbt', NULL, 'todo', 'Whether row was present in the latest qBT refresh')
ON CONFLICT("key")
DO UPDATE SET
  last_seen_on = CURRENT_TIMESTAMP;


INSERT INTO key_accessors
  ("key", kind, source, accessor, status, note)
SELECT DISTINCT
  hv."key",
  'observed',
  'hash_values',
  'qbtl meta key ' || hv."key",
  'implemented',
  'Discovered from observed hash metadata'
FROM hash_values hv
WHERE 1
ON CONFLICT("key")
DO UPDATE SET
  last_seen_on = CURRENT_TIMESTAMP;

INSERT INTO key_accessors
  ("key", kind, source, accessor, status, note)
SELECT DISTINCT
  mv."key",
  'manual',
  'manual_values',
  'qbtl meta get <hash>',
  'implemented',
  'User-supplied manual metadata key'
FROM manual_values mv
WHERE 1
ON CONFLICT("key")
DO UPDATE SET
  kind = excluded.kind,
  source = excluded.source,
  accessor = excluded.accessor,
  status = excluded.status,
  note = excluded.note,
  last_seen_on = CURRENT_TIMESTAMP;

INSERT INTO key_accessors
  ("key", kind, source, accessor, status, note)
SELECT DISTINCT
  pk."key",
  'core',
  'promoted_values.' || pk.target_column,
  NULL,
  'todo',
  'Promoted from observed metadata key'
FROM promoted_keys pk
WHERE 1
ON CONFLICT("key")
DO UPDATE SET
  kind = excluded.kind,
  source = excluded.source,
  accessor = excluded.accessor,
  status = excluded.status,
  note = excluded.note,
  last_seen_on = CURRENT_TIMESTAMP;

UPDATE schema_version
SET version = 10;
