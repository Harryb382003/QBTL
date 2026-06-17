CREATE TABLE IF NOT EXISTS hash_values (
    id INTEGER PRIMARY KEY,
    hash TEXT NOT NULL,
    key TEXT NOT NULL,
    value TEXT,
    value_type TEXT DEFAULT 'text',
    seen_count INTEGER NOT NULL DEFAULT 1,
    first_seen_on TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_seen_on TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(hash, key, value)
);

CREATE INDEX IF NOT EXISTS hash_values_hash_idx ON hash_values(hash);
CREATE INDEX IF NOT EXISTS hash_values_key_idx ON hash_values(key);
CREATE INDEX IF NOT EXISTS hash_values_key_value_idx ON hash_values(key, value);

CREATE TABLE IF NOT EXISTS manual_values (
    id INTEGER PRIMARY KEY,
    hash TEXT NOT NULL,
    key TEXT NOT NULL,
    value TEXT,
    value_type TEXT DEFAULT 'text',
    note TEXT,
    created_on TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_on TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(hash, key)
);

CREATE INDEX IF NOT EXISTS manual_values_hash_idx ON manual_values(hash);
CREATE INDEX IF NOT EXISTS manual_values_key_idx ON manual_values(key);

CREATE TABLE IF NOT EXISTS promoted_keys (
    id INTEGER PRIMARY KEY,
    key TEXT NOT NULL UNIQUE,
    target_column TEXT NOT NULL UNIQUE,
    value_type TEXT DEFAULT 'text',
    created_on TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS promoted_values (
    hash TEXT PRIMARY KEY
);

CREATE TABLE IF NOT EXISTS hash_conflicts (
    id INTEGER PRIMARY KEY,
    hash TEXT NOT NULL,
    key TEXT NOT NULL,
    value_count INTEGER NOT NULL,
    details TEXT,
    first_seen_on TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_seen_on TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(hash, key)
);

CREATE INDEX IF NOT EXISTS hash_conflicts_hash_idx ON hash_conflicts(hash);
CREATE INDEX IF NOT EXISTS hash_conflicts_key_idx ON hash_conflicts(key);
