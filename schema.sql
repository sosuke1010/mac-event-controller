-- mac-event-collector: SQLite schema for local event store
-- Location: ~/.timelapse/events.db

PRAGMA journal_mode=WAL;

CREATE TABLE IF NOT EXISTS events (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  event_type      TEXT    NOT NULL,
  event_at        TEXT    NOT NULL,  -- ISO8601 with +09:00
  source          TEXT    NOT NULL,  -- 'sleepwatcher', 'hammerspoon'
  location        TEXT,              -- 'office', 'home', NULL
  log_date        TEXT    NOT NULL,  -- YYYY-MM-DD
  meta            TEXT,              -- JSON string
  synced_at       TEXT,              -- NULL = not yet synced
  retry_count     INTEGER DEFAULT 0,
  last_error      TEXT,
  last_attempt_at TEXT,
  created_at      TEXT    DEFAULT (datetime('now', 'localtime')),
  UNIQUE(source, event_type, event_at)
);

-- Partial index: only pending events with retries remaining
CREATE INDEX IF NOT EXISTS idx_events_pending
  ON events(synced_at) WHERE synced_at IS NULL AND retry_count < 20;

CREATE INDEX IF NOT EXISTS idx_events_log_date
  ON events(log_date);
