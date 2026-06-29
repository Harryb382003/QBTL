CREATE TABLE IF NOT EXISTS qbt_payload_audits (
  hash TEXT PRIMARY KEY,
  audited_on TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

  save_path TEXT,
  content_path TEXT,

  save_path_exists INTEGER,
  content_path_exists INTEGER,
  save_path_type TEXT,
  content_path_type TEXT,

  qbt_files_ok INTEGER,
  qbt_file_count INTEGER,
  qbt_file_total_size INTEGER,

  direct_probe_status TEXT,
  needs_deep_scan INTEGER NOT NULL DEFAULT 0,

  problem TEXT
);

CREATE INDEX IF NOT EXISTS idx_qbt_payload_audits_needs_deep_scan
ON qbt_payload_audits(needs_deep_scan);

UPDATE schema_version
SET version = 13,
    updated_at = datetime('now')
WHERE id = 1;
