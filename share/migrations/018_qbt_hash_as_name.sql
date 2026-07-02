CREATE TABLE qbt_hash_as_name (
  hash TEXT PRIMARY KEY,
  fastresume_path TEXT NOT NULL,
  observed_on TEXT NOT NULL
);

UPDATE schema_version
SET version = 18,
    updated_at = datetime('now')
WHERE id = 1;
