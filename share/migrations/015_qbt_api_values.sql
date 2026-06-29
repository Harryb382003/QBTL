CREATE TABLE IF NOT EXISTS qbt_api_values (
  hash TEXT NOT NULL,
  endpoint TEXT NOT NULL,
  key TEXT NOT NULL,
  value TEXT,
  value_type TEXT NOT NULL DEFAULT 'text',
  first_seen_on TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen_on TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (hash, endpoint, key)
);

CREATE INDEX IF NOT EXISTS idx_qbt_api_values_key
ON qbt_api_values (key);

CREATE INDEX IF NOT EXISTS idx_qbt_api_values_endpoint_key
ON qbt_api_values (endpoint, key);

UPDATE schema_version
SET version = 15,
    updated_at = datetime('now')
WHERE id = 1;
