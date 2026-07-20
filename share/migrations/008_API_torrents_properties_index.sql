CREATE TABLE API_torrents_properties_index (
    infohash   TEXT PRIMARY KEY,
    fetched_on INTEGER NOT NULL,
    comment    TEXT,

    FOREIGN KEY (infohash)
        REFERENCES torrents(infohash)
        ON DELETE CASCADE
);
