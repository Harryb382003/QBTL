CREATE TABLE API_torrents_info (
    hash     TEXT PRIMARY KEY,
    fetched_on   INTEGER NOT NULL,
    payload_json TEXT NOT NULL,

    FOREIGN KEY (hash)
        REFERENCES torrents(hash)
        ON DELETE CASCADE
);
