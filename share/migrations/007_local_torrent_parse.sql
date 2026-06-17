ALTER TABLE local_torrent_files
ADD COLUMN infohash TEXT;

ALTER TABLE local_torrent_files
ADD COLUMN torrent_name TEXT;

ALTER TABLE local_torrent_files
ADD COLUMN comment TEXT;

ALTER TABLE local_torrent_files
ADD COLUMN announce TEXT;

ALTER TABLE local_torrent_files
ADD COLUMN created_by TEXT;

ALTER TABLE local_torrent_files
ADD COLUMN creation_date INTEGER;

ALTER TABLE local_torrent_files
ADD COLUMN parsed_on TEXT;

ALTER TABLE local_torrent_files
ADD COLUMN parse_ok INTEGER;

ALTER TABLE local_torrent_files
ADD COLUMN parse_problem TEXT;

CREATE INDEX idx_local_torrent_files_infohash
ON local_torrent_files(infohash);

UPDATE schema_version
SET version = 7,
    updated_at = datetime('now')
WHERE id = 1;
