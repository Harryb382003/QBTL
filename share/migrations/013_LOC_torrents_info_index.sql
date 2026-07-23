CREATE TABLE LOC_torrents_info_index (
    path                TEXT PRIMARY KEY,
    hash                TEXT,
    torrent_name        TEXT,
    comment             TEXT,
    announce            TEXT,
    created_by          TEXT,
    creation_date       INTEGER,
    parsed_on           TEXT NOT NULL,
    parse_ok            INTEGER NOT NULL,
    parse_problem       TEXT,
    payload_kind        TEXT,
    payload_root_name   TEXT,
    payload_file_count  INTEGER,
    payload_total_size  INTEGER,
    payload_probe_path  TEXT,
    payload_probe_name  TEXT,

    FOREIGN KEY (path)
        REFERENCES LOC_torrents(path)
        ON DELETE CASCADE
);
