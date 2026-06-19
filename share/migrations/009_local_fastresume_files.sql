CREATE TABLE IF NOT EXISTS local_fastresume_files (
  path TEXT PRIMARY KEY,
  infohash TEXT,
  size INTEGER,
  mtime INTEGER,
  backend TEXT,
  seen_on TEXT DEFAULT CURRENT_TIMESTAMP,

  parse_ok INTEGER DEFAULT 0,
  parse_problem TEXT
);

CREATE INDEX IF NOT EXISTS idx_local_fastresume_files_infohash
  ON local_fastresume_files(infohash);

  UPDATE schema_version
SET version = 9;
