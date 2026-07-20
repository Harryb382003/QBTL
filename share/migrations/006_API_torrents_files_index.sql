CREATE TABLE API_torrents_files_index (
    infohash      TEXT NOT NULL,
    file_index    INTEGER NOT NULL,
    fetched_on    INTEGER NOT NULL,
    name          TEXT,
    size          INTEGER,
    progress      REAL,
    priority      INTEGER,
    is_seed       INTEGER,
    piece_start   INTEGER,
    piece_end     INTEGER,
    availability  REAL,

    PRIMARY KEY (infohash, file_index),

    FOREIGN KEY (infohash)
        REFERENCES torrents(infohash)
        ON DELETE CASCADE
);
