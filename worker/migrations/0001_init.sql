-- =============================================================
-- Phase 1 - core schema (multi-tenant)
-- All times are TEXT. punch_time = device local time
-- ('YYYY-MM-DD HH:MM:SS'), everything else = UTC ISO-8601.
-- =============================================================

-- Tenants (each customer company)
CREATE TABLE companies (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  slug        TEXT NOT NULL UNIQUE,
  timezone    TEXT NOT NULL DEFAULT 'Asia/Karachi',
  status      TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','suspended')),
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

-- Dashboard users
CREATE TABLE users (
  id             TEXT PRIMARY KEY,
  company_id     TEXT NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  email          TEXT NOT NULL UNIQUE COLLATE NOCASE,
  full_name      TEXT NOT NULL,
  password_hash  TEXT NOT NULL,
  role           TEXT NOT NULL DEFAULT 'viewer' CHECK (role IN ('owner','admin','viewer')),
  is_active      INTEGER NOT NULL DEFAULT 1,
  last_login_at  TEXT,
  created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX idx_users_company ON users(company_id);

-- Login sessions (used in Phase 2)
CREATE TABLE sessions (
  id          TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at  TEXT NOT NULL,
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX idx_sessions_user ON sessions(user_id);

-- ZKT Connector installs (one per office PC). Only the token HASH is stored.
CREATE TABLE connectors (
  id            TEXT PRIMARY KEY,
  company_id    TEXT NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  token_hash    TEXT NOT NULL UNIQUE,
  version       TEXT,
  last_seen_at  TEXT,
  is_active     INTEGER NOT NULL DEFAULT 1,
  created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX idx_connectors_company ON connectors(company_id);

-- Attendance machines (e.g. ZKTeco K50)
CREATE TABLE devices (
  id             TEXT PRIMARY KEY,
  company_id     TEXT NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  connector_id   TEXT REFERENCES connectors(id) ON DELETE SET NULL,
  name           TEXT NOT NULL,
  model          TEXT NOT NULL DEFAULT 'K50',
  ip_address     TEXT NOT NULL,
  port           INTEGER NOT NULL DEFAULT 4370,
  comm_key       INTEGER NOT NULL DEFAULT 0,
  serial_number  TEXT,
  last_sync_at   TEXT,
  is_active      INTEGER NOT NULL DEFAULT 1,
  created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX idx_devices_company   ON devices(company_id);
CREATE INDEX idx_devices_connector ON devices(connector_id);

-- Employees, mapped from the user ID enrolled on the machine
CREATE TABLE employees (
  id              TEXT PRIMARY KEY,
  company_id      TEXT NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  device_user_id  TEXT NOT NULL,
  full_name       TEXT NOT NULL,
  department      TEXT,
  is_active       INTEGER NOT NULL DEFAULT 1,
  created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  UNIQUE (company_id, device_user_id)
);

-- One row per sync run (scheduled every 2 days, or manual)
CREATE TABLE sync_jobs (
  id                TEXT PRIMARY KEY,
  company_id        TEXT NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  device_id         TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  trigger_type      TEXT NOT NULL DEFAULT 'scheduled' CHECK (trigger_type IN ('scheduled','manual')),
  status            TEXT NOT NULL DEFAULT 'pending'  CHECK (status IN ('pending','running','success','failed')),
  requested_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  started_at        TEXT,
  finished_at       TEXT,
  records_fetched   INTEGER NOT NULL DEFAULT 0,
  records_inserted  INTEGER NOT NULL DEFAULT 0,
  error_message     TEXT
);
CREATE INDEX idx_sync_jobs_device_status ON sync_jobs(device_id, status);
CREATE INDEX idx_sync_jobs_company       ON sync_jobs(company_id, requested_at);

-- Raw attendance punches from the machine. The UNIQUE key makes
-- re-imports safe: the same punch is never stored twice.
CREATE TABLE attendance_logs (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  company_id      TEXT NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  device_id       TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  device_user_id  TEXT NOT NULL,
  punch_time      TEXT NOT NULL,
  punch_state     INTEGER,
  verify_mode     INTEGER,
  sync_job_id     TEXT REFERENCES sync_jobs(id) ON DELETE SET NULL,
  imported_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  UNIQUE (device_id, device_user_id, punch_time)
);
CREATE INDEX idx_logs_company_time ON attendance_logs(company_id, punch_time);
CREATE INDEX idx_logs_user_time    ON attendance_logs(company_id, device_user_id, punch_time);