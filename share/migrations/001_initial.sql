CREATE TABLE IF NOT EXISTS schema_version (
    id         INTEGER PRIMARY KEY CHECK (id = 1),
    version    INTEGER NOT NULL,
    updated_at TEXT NOT NULL
);

INSERT INTO schema_version (id, version, updated_at)
VALUES (1, 1, datetime('now'))
ON CONFLICT(id) DO UPDATE SET
    version    = excluded.version,
    updated_at = excluded.updated_at;
