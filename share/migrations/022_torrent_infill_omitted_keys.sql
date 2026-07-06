ALTER TABLE torrent_info_fields
ADD COLUMN storage_policy TEXT;

ALTER TABLE torrent_info_fields
ADD COLUMN byte_length INTEGER;

ALTER TABLE torrent_info_fields
ADD COLUMN omission_reason TEXT;
