ALTER TABLE qbt_info
ADD COLUMN qbt_last TEXT;

UPDATE schema_version
SET version = 16,
    updated_at = datetime('now')
WHERE id = 1;
