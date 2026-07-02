ALTER TABLE qbt_info
ADD COLUMN qbt_export_dir_file INTEGER;

ALTER TABLE qbt_info
ADD COLUMN qbt_export_dir_fin_file INTEGER;

ALTER TABLE qbt_info
ADD COLUMN qbt_export_dirs_checked_on TEXT;

UPDATE schema_version
SET version = 20,
    updated_at = datetime('now')
WHERE id = 1;
