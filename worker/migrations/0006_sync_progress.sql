-- =============================================================
-- Phase 11 - live sync progress, heartbeats and cancelling
-- =============================================================
ALTER TABLE sync_jobs ADD COLUMN progress_stage TEXT;     -- connecting | reading | uploading | names | finishing
ALTER TABLE sync_jobs ADD COLUMN progress_pct INTEGER;    -- 0-100 for the current stage
ALTER TABLE sync_jobs ADD COLUMN progress_msg TEXT;       -- short human-readable status line
ALTER TABLE sync_jobs ADD COLUMN heartbeat_at TEXT;       -- last time the connector reported on this job