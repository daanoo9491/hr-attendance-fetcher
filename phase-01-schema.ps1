# =====================================================================
# HR Auto Attendance Fetcher - PHASE 1 : D1 database schema
# Run from the ROOT of the repo (hr-attendance-fetcher):
#   powershell -ExecutionPolicy Bypass -File .\phase-01-schema.ps1
# =====================================================================
$ErrorActionPreference = "Stop"

function Write-File([string]$Path, [string]$Content) {
    $full = Join-Path (Get-Location) $Path
    $dir  = Split-Path $full -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($full, $Content.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  wrote $Path" -ForegroundColor Green
}

if (-not (Test-Path "worker/wrangler.toml")) {
    throw "Run this from the repo root (worker/wrangler.toml not found)."
}

Write-Host "Phase 1: writing D1 schema..." -ForegroundColor Cyan

# ---------------------------------------------------------------- migration
Write-File "worker/migrations/0001_init.sql" @'
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
'@

# ---------------------------------------------------------------- worker (health now checks schema)
Write-File "worker/src/index.ts" @'
export interface Env {
  DB: D1Database;
}

const VERSION = "0.1.0-phase1";

const REQUIRED_TABLES = [
  "companies",
  "users",
  "sessions",
  "connectors",
  "devices",
  "employees",
  "sync_jobs",
  "attendance_logs",
];

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

async function checkSchema(db: D1Database) {
  const { results } = await db
    .prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
    .all<{ name: string }>();
  const existing = new Set((results ?? []).map((r) => r.name));
  const missing = REQUIRED_TABLES.filter((t) => !existing.has(t));
  return { ok: missing.length === 0, tables: REQUIRED_TABLES.length - missing.length, missing };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/api/health") {
      try {
        const ping = await env.DB.prepare("SELECT 1 AS ok").first<{ ok: number }>();
        const schema = await checkSchema(env.DB);
        const healthy = ping?.ok === 1 && schema.ok;
        return json(
          {
            status: healthy ? "ok" : "degraded",
            version: VERSION,
            d1: ping?.ok === 1 ? "connected" : "unknown",
            schema: schema.ok ? "ready" : "missing tables",
            tables: `${schema.tables}/${REQUIRED_TABLES.length}`,
            missing: schema.missing,
          },
          healthy ? 200 : 503,
        );
      } catch (err) {
        return json({ status: "error", version: VERSION, d1: "failed", error: String(err) }, 500);
      }
    }

    if (url.pathname === "/") {
      return new Response(`HR Auto Attendance Fetcher - ${VERSION}`, {
        headers: { "content-type": "text/plain; charset=utf-8" },
      });
    }

    return json({ error: "Not found" }, 404);
  },
};
'@

# ---------------------------------------------------------------- connector env template (your K50)
Write-File "connector/.env.example" @'
# --- ZKTeco K50 on your LAN ---
DEVICE_IP=192.168.10.21
DEVICE_PORT=4370
DEVICE_COMM_KEY=0
DEVICE_TIMEOUT_MS=10000

# --- Attendance Fetcher SaaS (Cloudflare Worker) ---
API_BASE_URL=https://hr-attendance-fetcher.bilaljahangir1995.workers.dev
CONNECTOR_TOKEN=will-be-issued-in-phase-3
'@

# ---------------------------------------------------------------- remove phase 0 placeholder
if (Test-Path "worker/migrations/.gitkeep") { Remove-Item "worker/migrations/.gitkeep" -Force }

Write-Host ""
Write-Host "Phase 1 files written. Next steps are listed in the chat." -ForegroundColor Cyan
