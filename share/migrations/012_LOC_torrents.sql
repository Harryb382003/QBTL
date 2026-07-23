CREATE TABLE LOC_torrents (
    path    TEXT PRIMARY KEY,
    seen    INTEGER NOT NULL,
    hash    TEXT,
    backend TEXT
);
