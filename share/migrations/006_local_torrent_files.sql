CREATE TABLE local_torrent_files (
    id INTEGER PRIMARY KEY,
    path TEXT NOT NULL UNIQUE,
    size INTEGER,
    mtime INTEGER,
    backend TEXT,
    seen_on TEXT NOT NULL
);

UPDATE schema_version
SET version = 6,
    updated_at = datetime('now')
WHERE id = 1;
