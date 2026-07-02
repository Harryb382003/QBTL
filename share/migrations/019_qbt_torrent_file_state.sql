ALTER TABLE qbt_info
ADD COLUMN qbt_torrent_file INTEGER;

ALTER TABLE qbt_info
ADD COLUMN qbt_torrent_file_checked_on TEXT;

UPDATE schema_version
SET version = 19,
    updated_at = datetime('now')
WHERE id = 1;
