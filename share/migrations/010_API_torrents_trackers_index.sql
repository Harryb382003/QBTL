CREATE TABLE API_torrents_trackers_index (
    hash       TEXT NOT NULL,
    tracker_index  INTEGER NOT NULL,
    fetched_on     INTEGER NOT NULL,
    url            TEXT NOT NULL,
    status         INTEGER,
    tier           INTEGER,
    num_peers      INTEGER,
    num_seeds      INTEGER,
    num_leeches    INTEGER,
    num_downloaded INTEGER,
    msg            TEXT,

    PRIMARY KEY (hash, tracker_index),

    FOREIGN KEY (hash)
        REFERENCES torrents(hash)
        ON DELETE CASCADE
);
