ALTER TABLE qbt_info
ADD COLUMN comment TEXT;

UPDATE schema_version
SET version = 4,
    updated_at = datetime('now')
WHERE id = 1;
