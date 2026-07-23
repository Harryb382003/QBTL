CREATE TABLE API_torrents_info_index (
    hash      TEXT PRIMARY KEY,
    fetched_on    INTEGER NOT NULL,
    name          TEXT,
    state         TEXT,
    progress      REAL,
    save_path     TEXT,
    content_path  TEXT,
    category      TEXT,
    tags          TEXT,
    tracker       TEXT,
    amount_left   INTEGER,
    size          INTEGER,
    total_size    INTEGER,
    added_on      INTEGER,
    completion_on INTEGER,
    last_activity INTEGER,
    ratio         REAL,
    private    INTEGER,

    FOREIGN KEY (hash)
        REFERENCES torrents(hash)
        ON DELETE CASCADE
);
