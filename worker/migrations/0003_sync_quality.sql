-- =============================================================
-- Phase 5 - sync data quality
-- =============================================================

-- Punches the connector did not import (e.g. dated in the future
-- because the machine clock was wrong when they were recorded).
ALTER TABLE sync_jobs ADD COLUMN records_skipped INTEGER NOT NULL DEFAULT 0;

-- Machine clock minus real time, measured at each sync (seconds).
ALTER TABLE devices ADD COLUMN clock_offset_seconds INTEGER;
ALTER TABLE devices ADD COLUMN clock_checked_at TEXT;