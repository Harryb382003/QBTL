CREATE TABLE IF NOT EXISTS qbt_info (
    hash              TEXT PRIMARY KEY,
    name              TEXT,
    state             TEXT,
    progress          REAL,
    save_path         TEXT,
    content_path      TEXT,
    category          TEXT,
    tags              TEXT,
    amount_left       INTEGER,
    total_size        INTEGER,
    added_on          INTEGER,
    completion_on     INTEGER,
    last_activity     INTEGER,
    tracker           TEXT,
    ratio             REAL,
    seen_on           TEXT NOT NULL
);

UPDATE schema_version
SET version = 2,
    updated_at = datetime('now')
WHERE id = 1;
