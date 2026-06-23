ALTER TABLE qbt_info
ADD COLUMN seen INTEGER DEFAULT 0;

ALTER TABLE qbt_info
ADD COLUMN last_seen_on TEXT;

UPDATE qbt_info
SET seen = 1,
    last_seen_on = datetime('now')
WHERE current_qbt = 1;

UPDATE schema_version
SET version = 5,
    updated_at = datetime('now')
WHERE id = 1;
