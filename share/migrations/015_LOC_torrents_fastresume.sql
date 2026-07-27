CREATE TABLE LOC_torrents_fastresume (
    path          TEXT PRIMARY KEY,
    size          INTEGER,
    mtime         INTEGER,
    backend       TEXT NOT NULL,
    seen          INTEGER NOT NULL DEFAULT 1,

    hash          TEXT,
    parse_ok      INTEGER,
    parse_problem TEXT
);
