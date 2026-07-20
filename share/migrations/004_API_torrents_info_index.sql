CREATE TABLE API_torrents_info_index (
    infohash      TEXT PRIMARY KEY,
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
    is_private    INTEGER,

    FOREIGN KEY (infohash)
        REFERENCES torrents(infohash)
        ON DELETE CASCADE
);
-- share/migrations/004_API_torrents_info_index.sql

CREATE TABLE API_torrents_info_index (
    infohash      TEXT PRIMARY KEY,
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
    is_private    INTEGER,

    FOREIGN KEY (infohash)
        REFERENCES torrents(infohash)
        ON DELETE CASCADE
);
