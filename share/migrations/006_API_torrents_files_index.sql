CREATE TABLE API_torrents_files_index (
    hash      TEXT NOT NULL,
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

    PRIMARY KEY (hash, file_index),

    FOREIGN KEY (hash)
        REFERENCES torrents(hash)
        ON DELETE CASCADE
);
