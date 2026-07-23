CREATE TABLE API_torrents_properties_index (
    hash   TEXT PRIMARY KEY,
    fetched_on INTEGER NOT NULL,
    comment    TEXT,

    FOREIGN KEY (hash)
        REFERENCES torrents(hash)
        ON DELETE CASCADE
);
