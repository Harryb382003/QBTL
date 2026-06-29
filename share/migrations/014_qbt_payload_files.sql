CREATE TABLE IF NOT EXISTS qbt_payload_files (
  hash TEXT NOT NULL,
  path TEXT NOT NULL,
  size INTEGER,
  progress REAL,
  priority INTEGER,
  availability REAL,

  first_seen_on TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen_on TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (hash, path)
);

CREATE INDEX IF NOT EXISTS idx_qbt_payload_files_hash
ON qbt_payload_files(hash);

CREATE INDEX IF NOT EXISTS idx_qbt_payload_files_path
ON qbt_payload_files(path);

UPDATE schema_version
SET version = 14,
    updated_at = datetime('now')
WHERE id = 1;
