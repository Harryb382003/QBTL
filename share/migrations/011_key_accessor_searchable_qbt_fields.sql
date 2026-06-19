UPDATE key_accessors
SET
  accessor = 'qbtl search ' || "key" || ' <value>',
  status = 'implemented',
  note = 'Searchable qBittorrent field from qbt_info'
WHERE source LIKE 'qbt_info.%';

UPDATE schema_version
SET version = 11;
