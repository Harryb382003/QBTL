CREATE TABLE BT_torrents (
    hash TEXT PRIMARY KEY,
    path     TEXT NOT NULL UNIQUE,
    seen     INTEGER NOT NULL,
    FOREIGN KEY (hash)
        REFERENCES torrents(hash)
        ON DELETE CASCADE
);
