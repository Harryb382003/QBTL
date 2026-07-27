CREATE TABLE LOC_hash_values (
    hash       TEXT NOT NULL,
    key        TEXT NOT NULL,
    value      TEXT NOT NULL,
    value_type TEXT NOT NULL,

    PRIMARY KEY (
        hash,
        key,
        value,
        value_type
    )
);
