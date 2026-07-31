CREATE TABLE installation (
    key        TEXT PRIMARY KEY NOT NULL,
    value      TEXT NOT NULL,
    source     TEXT NOT NULL,
    updated_on INTEGER NOT NULL
);

UPDATE schema_version
SET version = 16,
    updated_at = datetime('now')
WHERE id = 1;
