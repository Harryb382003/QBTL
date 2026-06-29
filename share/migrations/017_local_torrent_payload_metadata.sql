ALTER TABLE local_torrent_files
ADD COLUMN payload_kind TEXT;

ALTER TABLE local_torrent_files
ADD COLUMN payload_root_name TEXT;

ALTER TABLE local_torrent_files
ADD COLUMN payload_file_count INTEGER;

ALTER TABLE local_torrent_files
ADD COLUMN payload_total_size INTEGER;

ALTER TABLE local_torrent_files
ADD COLUMN payload_probe_path TEXT;

ALTER TABLE local_torrent_files
ADD COLUMN payload_probe_name TEXT;

CREATE INDEX IF NOT EXISTS idx_local_torrent_files_payload_root_name
ON local_torrent_files(payload_root_name);

CREATE INDEX IF NOT EXISTS idx_local_torrent_files_payload_probe_name
ON local_torrent_files(payload_probe_name);

UPDATE schema_version
SET version = 17,
    updated_at = datetime('now')
WHERE id = 1;
