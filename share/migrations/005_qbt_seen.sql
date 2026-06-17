ALTER TABLE qbt_info
ADD COLUMN seen INTEGER;

UPDATE qbt_info
SET seen = 1
WHERE current_qbt = 1;

UPDATE schema_version
SET version = 5,
    updated_at = datetime('now')
WHERE id = 1;
