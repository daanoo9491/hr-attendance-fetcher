-- =============================================================
-- Phase 3 - connector API support
-- =============================================================

-- Last 4 characters of the connector token, so the dashboard can
-- show which token is which without ever storing the token itself.
ALTER TABLE connectors ADD COLUMN token_hint TEXT;

-- Fast lookup of pending / stale running jobs.
CREATE INDEX idx_sync_jobs_status ON sync_jobs(status, requested_at);