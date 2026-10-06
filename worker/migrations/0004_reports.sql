-- =============================================================
-- Phase 6 - scheduled 2-day attendance reports
-- =============================================================

-- Report schedule per company: every N days, generated after this local hour.
ALTER TABLE companies ADD COLUMN report_every_days INTEGER NOT NULL DEFAULT 2;
ALTER TABLE companies ADD COLUMN report_hour INTEGER NOT NULL DEFAULT 1;

-- One row per scheduled report period. The Excel file itself is built on
-- download from attendance_logs, so it always includes the latest punches.
CREATE TABLE reports (
  id              TEXT PRIMARY KEY,
  company_id      TEXT NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  period_start    TEXT NOT NULL,   -- YYYY-MM-DD, inclusive (company local date)
  period_end      TEXT NOT NULL,   -- YYYY-MM-DD, inclusive
  status          TEXT NOT NULL DEFAULT 'collecting' CHECK (status IN ('collecting','ready')),
  devices_total   INTEGER NOT NULL DEFAULT 0,
  devices_synced  INTEGER NOT NULL DEFAULT 0,
  punch_count     INTEGER NOT NULL DEFAULT 0,
  employee_count  INTEGER NOT NULL DEFAULT 0,
  note            TEXT,
  created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  ready_at        TEXT,
  UNIQUE (company_id, period_start)
);
CREATE INDEX idx_reports_company ON reports(company_id, period_end);

-- Scheduled sync jobs are linked to the report they collect data for.
ALTER TABLE sync_jobs ADD COLUMN report_id TEXT REFERENCES reports(id) ON DELETE SET NULL;
CREATE INDEX idx_sync_jobs_report ON sync_jobs(report_id);