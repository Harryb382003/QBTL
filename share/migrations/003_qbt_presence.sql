ALTER TABLE qbt_info
ADD COLUMN current_qbt INTEGER NOT NULL DEFAULT 1;

ALTER TABLE qbt_info
ADD COLUMN discovered_on TEXT;

ALTER TABLE qbt_info
ADD COLUMN discovered_by TEXT;

UPDATE qbt_info
SET discovered_on = COALESCE(discovered_on, seen_on),
    discovered_by = COALESCE(discovered_by, 'qbt'),
    current_qbt = 1;

UPDATE schema_version
SET version = 3,
    updated_at = datetime('now')
WHERE id = 1;
