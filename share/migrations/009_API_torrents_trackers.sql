CREATE TABLE API_torrents_trackers (
    infohash     TEXT PRIMARY KEY,
    fetched_on   INTEGER NOT NULL,
    payload_json TEXT NOT NULL,

    FOREIGN KEY (infohash)
        REFERENCES torrents(infohash)
        ON DELETE CASCADE
);
