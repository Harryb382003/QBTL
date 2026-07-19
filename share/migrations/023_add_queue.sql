CREATE TABLE add_queue (
  hash TEXT PRIMARY KEY NOT NULL,
  path TEXT NOT NULL UNIQUE
);

UPDATE schema_version
SET version = 23,
    updated_at = datetime('now')
WHERE id = 1;
