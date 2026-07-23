CREATE TABLE torrents (
    hash      TEXT PRIMARY KEY,
    discovered_on TEXT NOT NULL,
    discovered_by TEXT NOT NULL
);
