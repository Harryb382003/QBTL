CREATE TABLE IF NOT EXISTS qbt_preferences (
  "key" TEXT PRIMARY KEY,
  value TEXT,
  value_type TEXT,
  first_seen_on TEXT DEFAULT CURRENT_TIMESTAMP,
  last_seen_on TEXT DEFAULT CURRENT_TIMESTAMP
);

UPDATE schema_version
SET version = 12;
