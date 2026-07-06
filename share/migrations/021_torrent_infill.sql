CREATE TABLE IF NOT EXISTS torrent_evidence_sources (
  id INTEGER PRIMARY KEY,
  hash TEXT NOT NULL,
  source TEXT NOT NULL,
  path TEXT NOT NULL DEFAULT '',
  bucket TEXT,
  evidence_kind TEXT,
  first_seen_on TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen_on TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_torrent_evidence_sources_identity
ON torrent_evidence_sources(hash, source, path);

CREATE INDEX IF NOT EXISTS idx_torrent_evidence_sources_hash
ON torrent_evidence_sources(hash);

CREATE TABLE IF NOT EXISTS torrent_trackers (
  id INTEGER PRIMARY KEY,
  hash TEXT NOT NULL,
  source TEXT NOT NULL,
  tracker_url TEXT NOT NULL,
  tracker_host TEXT,
  tracker_domain TEXT,
  tier INTEGER,
  position INTEGER,
  first_seen_on TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen_on TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_torrent_trackers_hash
ON torrent_trackers(hash);

CREATE INDEX IF NOT EXISTS idx_torrent_trackers_domain
ON torrent_trackers(tracker_domain);

CREATE TABLE IF NOT EXISTS torrent_payload_files (
  id INTEGER PRIMARY KEY,
  hash TEXT NOT NULL,
  source TEXT NOT NULL,
  file_index INTEGER NOT NULL,
  path TEXT NOT NULL,
  name TEXT,
  size INTEGER,
  first_seen_on TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen_on TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(hash, source, file_index)
);

CREATE INDEX IF NOT EXISTS idx_torrent_payload_files_hash
ON torrent_payload_files(hash);

CREATE TABLE IF NOT EXISTS torrent_info_fields (
  id INTEGER PRIMARY KEY,
  hash TEXT NOT NULL,
  source TEXT NOT NULL,
  key TEXT NOT NULL,
  value TEXT,
  value_type TEXT,
  first_seen_on TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen_on TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(hash, source, key)
);

CREATE INDEX IF NOT EXISTS idx_torrent_info_fields_hash
ON torrent_info_fields(hash);
