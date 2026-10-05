# =====================================================================
# HR Auto Attendance Fetcher - PHASE 3 : Connector API + device setup
# Run from the ROOT of the repo (hr-attendance-fetcher):
#   powershell -ExecutionPolicy Bypass -File .\phase-03-connector-api.ps1
# =====================================================================
$ErrorActionPreference = "Stop"

function Write-File([string]$Path, [string]$Content) {
    $full = Join-Path (Get-Location) $Path
    $dir  = Split-Path $full -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($full, $Content.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  wrote $Path" -ForegroundColor Green
}

if (-not (Test-Path "worker/src/lib/auth.ts")) {
    throw "Run this from the repo root, after Phase 2 (worker/src/lib/auth.ts not found)."
}

Write-Host "Phase 3: writing connector API + device management..." -ForegroundColor Cyan

# ---------------------------------------------------------------- worker/migrations/0002_connector_api.sql
Write-File "worker/migrations/0002_connector_api.sql" @'
-- =============================================================
-- Phase 3 - connector API support
-- =============================================================

-- Last 4 characters of the connector token, so the dashboard can
-- show which token is which without ever storing the token itself.
ALTER TABLE connectors ADD COLUMN token_hint TEXT;

-- Fast lookup of pending / stale running jobs.
CREATE INDEX idx_sync_jobs_status ON sync_jobs(status, requested_at);
'@

# ---------------------------------------------------------------- worker/src/env.ts
Write-File "worker/src/env.ts" @'
export interface Env {
  DB: D1Database;
  /** Optional. When set, sign-up requires this code (set with: wrangler secret put SIGNUP_CODE). */
  SIGNUP_CODE?: string;
}

export const VERSION = "0.3.0-phase3";

/** Number of files in worker/migrations. The health check reports "degraded" until all are applied. */
export const EXPECTED_MIGRATIONS = 2;
'@

# ---------------------------------------------------------------- worker/src/routes/health.ts
Write-File "worker/src/routes/health.ts" @'
import { EXPECTED_MIGRATIONS, VERSION, type Env } from "../env";
import { json } from "../lib/http";

const REQUIRED_TABLES = [
  "companies", "users", "sessions", "connectors",
  "devices", "employees", "sync_jobs", "attendance_logs",
];

async function appliedMigrations(env: Env): Promise<number> {
  try {
    const row = await env.DB.prepare("SELECT COUNT(*) AS n FROM d1_migrations").first<{ n: number }>();
    return row?.n ?? 0;
  } catch {
    return 0;
  }
}

export async function health(env: Env): Promise<Response> {
  try {
    const ping = await env.DB.prepare("SELECT 1 AS ok").first<{ ok: number }>();
    const { results } = await env.DB
      .prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
      .all<{ name: string }>();
    const existing = new Set((results ?? []).map((r) => r.name));
    const missing = REQUIRED_TABLES.filter((t) => !existing.has(t));
    const migrations = await appliedMigrations(env);
    const healthy = ping?.ok === 1 && missing.length === 0 && migrations >= EXPECTED_MIGRATIONS;

    return json(
      {
        status: healthy ? "ok" : "degraded",
        version: VERSION,
        d1: ping?.ok === 1 ? "connected" : "unknown",
        schema: missing.length === 0 ? "ready" : "missing tables",
        tables: `${REQUIRED_TABLES.length - missing.length}/${REQUIRED_TABLES.length}`,
        migrations: `${migrations}/${EXPECTED_MIGRATIONS}`,
        missing,
      },
      healthy ? 200 : 503,
    );
  } catch (err) {
    return json({ status: "error", version: VERSION, d1: "failed", error: String(err) }, 500);
  }
}
'@

# ---------------------------------------------------------------- worker/src/routes/manage.ts
Write-File "worker/src/routes/manage.ts" @'
// Dashboard (session-authenticated) API: connectors, devices, sync jobs.
// Every query is filtered by auth.companyId, so tenants never see each other's data.
import type { Env } from "../env";
import { HttpError, json, readJson } from "../lib/http";
import { requireAuth, requireRole } from "../lib/auth";
import { randomToken, sha256Hex } from "../lib/crypto";

const IPV4 = /^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$/;

function cleanText(value: unknown, field: string, max = 80): string {
  const v = typeof value === "string" ? value.trim() : "";
  if (v.length < 2) throw new HttpError(400, `${field} is required`);
  if (v.length > max) throw new HttpError(400, `${field} is too long`);
  return v;
}

function cleanInt(value: unknown, field: string, min: number, max: number, fallback: number): number {
  if (value === undefined || value === null || value === "") return fallback;
  const n = Number(value);
  if (!Number.isInteger(n) || n < min || n > max) {
    throw new HttpError(400, `${field} must be a whole number between ${min} and ${max}`);
  }
  return n;
}

// ------------------------------------------------------------------ connectors

/** GET /api/connectors */
export async function listConnectors(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  const { results } = await env.DB.prepare(
    `SELECT c.id, c.name, c.token_hint, c.version, c.last_seen_at, c.is_active, c.created_at,
            (SELECT COUNT(*) FROM devices d WHERE d.connector_id = c.id AND d.is_active = 1) AS device_count
       FROM connectors c
      WHERE c.company_id = ?
      ORDER BY c.is_active DESC, c.created_at DESC`,
  ).bind(auth.companyId).all();
  return json({ connectors: results ?? [] });
}

/** POST /api/connectors  { name } -> returns the token ONCE */
export async function createConnector(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  const body = await readJson<Record<string, unknown>>(request);
  const name = cleanText(body.name, "Connector name");

  const id = crypto.randomUUID();
  const token = `zkc_${randomToken(32)}`;
  await env.DB.prepare(
    "INSERT INTO connectors (id, company_id, name, token_hash, token_hint) VALUES (?, ?, ?, ?, ?)",
  ).bind(id, auth.companyId, name, await sha256Hex(token), token.slice(-4)).run();

  return json(
    {
      connector: { id, name },
      token,
      note: "Copy this token into connector/.env as CONNECTOR_TOKEN. It will not be shown again.",
    },
    201,
  );
}

/** POST /api/connectors/:id/revoke */
export async function revokeConnector(request: Request, env: Env, id: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  const res = await env.DB.prepare("UPDATE connectors SET is_active = 0 WHERE id = ? AND company_id = ?")
    .bind(id, auth.companyId).run();
  if (!res.meta.changes) throw new HttpError(404, "Connector not found");
  return json({ ok: true });
}

// ------------------------------------------------------------------ devices

/** GET /api/devices */
export async function listDevices(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  const { results } = await env.DB.prepare(
    `SELECT d.id, d.name, d.model, d.ip_address, d.port, d.comm_key, d.serial_number,
            d.connector_id, c.name AS connector_name, c.is_active AS connector_active,
            d.last_sync_at, d.is_active, d.created_at,
            (SELECT COUNT(*) FROM attendance_logs l WHERE l.device_id = d.id) AS log_count,
            (SELECT j.status FROM sync_jobs j WHERE j.device_id = d.id ORDER BY j.requested_at DESC LIMIT 1) AS last_job_status
       FROM devices d
       LEFT JOIN connectors c ON c.id = d.connector_id
      WHERE d.company_id = ?
      ORDER BY d.is_active DESC, d.created_at DESC`,
  ).bind(auth.companyId).all();
  return json({ devices: results ?? [] });
}

/** POST /api/devices  { name, ip_address, port?, comm_key?, model?, connector_id? } */
export async function createDevice(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  const body = await readJson<Record<string, unknown>>(request);

  const name = cleanText(body.name, "Device name");
  const ip = typeof body.ip_address === "string" ? body.ip_address.trim() : "";
  if (!IPV4.test(ip)) throw new HttpError(400, "A valid IPv4 address is required (e.g. 192.168.10.21)");
  const port = cleanInt(body.port, "Port", 1, 65535, 4370);
  const commKey = cleanInt(body.comm_key, "Comm key", 0, 999999, 0);
  const model = typeof body.model === "string" && body.model.trim() ? cleanText(body.model, "Model", 40) : "K50";

  let connectorId: string | null = null;
  if (typeof body.connector_id === "string" && body.connector_id) {
    const ok = await env.DB.prepare("SELECT 1 FROM connectors WHERE id = ? AND company_id = ? AND is_active = 1")
      .bind(body.connector_id, auth.companyId).first();
    if (!ok) throw new HttpError(400, "Connector not found or revoked");
    connectorId = body.connector_id;
  }

  const id = crypto.randomUUID();
  await env.DB.prepare(
    `INSERT INTO devices (id, company_id, connector_id, name, model, ip_address, port, comm_key)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind(id, auth.companyId, connectorId, name, model, ip, port, commKey).run();

  return json({ device: { id, name } }, 201);
}

/** POST /api/devices/:id/deactivate (data is kept; pending jobs are cancelled) */
export async function deactivateDevice(request: Request, env: Env, id: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  const now = new Date().toISOString();
  const [res] = await env.DB.batch([
    env.DB.prepare("UPDATE devices SET is_active = 0 WHERE id = ? AND company_id = ?").bind(id, auth.companyId),
    env.DB.prepare(
      `UPDATE sync_jobs SET status = 'failed', finished_at = ?, error_message = 'Device deactivated'
        WHERE device_id = ? AND company_id = ? AND status = 'pending'`,
    ).bind(now, id, auth.companyId),
  ]);
  if (!res.meta.changes) throw new HttpError(404, "Device not found");
  return json({ ok: true });
}

// ------------------------------------------------------------------ sync jobs

/** POST /api/devices/:id/sync - queue a manual sync (one open job per device). */
export async function queueSync(request: Request, env: Env, id: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);

  const device = await env.DB.prepare(
    `SELECT d.id, d.is_active, d.connector_id, c.is_active AS connector_active
       FROM devices d LEFT JOIN connectors c ON c.id = d.connector_id
      WHERE d.id = ? AND d.company_id = ?`,
  ).bind(id, auth.companyId).first<{ id: string; is_active: number; connector_id: string | null; connector_active: number | null }>();

  if (!device) throw new HttpError(404, "Device not found");
  if (device.is_active !== 1) throw new HttpError(409, "Device is deactivated");
  if (!device.connector_id || device.connector_active !== 1) {
    throw new HttpError(409, "Assign an active connector to this device first");
  }

  const open = await env.DB.prepare(
    "SELECT id, status FROM sync_jobs WHERE device_id = ? AND status IN ('pending','running') LIMIT 1",
  ).bind(id).first<{ id: string; status: string }>();
  if (open) return json({ job: open, already_queued: true });

  const jobId = crypto.randomUUID();
  await env.DB.prepare(
    "INSERT INTO sync_jobs (id, company_id, device_id, trigger_type, status) VALUES (?, ?, ?, 'manual', 'pending')",
  ).bind(jobId, auth.companyId, id).run();
  return json({ job: { id: jobId, status: "pending" }, already_queued: false }, 201);
}

/** GET /api/sync-jobs?limit=20 */
export async function listSyncJobs(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  const limit = Math.min(Math.max(Number(new URL(request.url).searchParams.get("limit")) || 20, 1), 100);
  const { results } = await env.DB.prepare(
    `SELECT j.id, j.device_id, d.name AS device_name, j.trigger_type, j.status,
            j.requested_at, j.started_at, j.finished_at, j.records_fetched, j.records_inserted, j.error_message
       FROM sync_jobs j JOIN devices d ON d.id = j.device_id
      WHERE j.company_id = ?
      ORDER BY j.requested_at DESC
      LIMIT ?`,
  ).bind(auth.companyId, limit).all();
  return json({ jobs: results ?? [] });
}
'@

# ---------------------------------------------------------------- worker/src/routes/connector.ts
Write-File "worker/src/routes/connector.ts" @'
// ZKT Connector API. Authenticated with "Authorization: Bearer zkc_..." (not a browser session).
// A connector can only see devices assigned to it, and jobs of those devices.
import type { Env } from "../env";
import { HttpError, json, readJson } from "../lib/http";
import { sha256Hex } from "../lib/crypto";

const MAX_RECORDS_PER_UPLOAD = 1000;
const STALE_JOB_MINUTES = 30;
const TOKEN_RE = /^Bearer\s+(zkc_[A-Za-z0-9_-]{20,})$/;
const TIMESTAMP_RE = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})$/;

interface ConnectorContext {
  connectorId: string;
  connectorName: string;
  companyId: string;
  companyTimezone: string;
}

async function requireConnector(request: Request, env: Env): Promise<ConnectorContext> {
  const match = TOKEN_RE.exec(request.headers.get("authorization") ?? "");
  if (!match) throw new HttpError(401, "Missing or invalid connector token");

  const row = await env.DB.prepare(
    `SELECT c.id, c.name, c.company_id, co.timezone
       FROM connectors c JOIN companies co ON co.id = c.company_id
      WHERE c.token_hash = ? AND c.is_active = 1 AND co.status = 'active'`,
  ).bind(await sha256Hex(match[1])).first<{ id: string; name: string; company_id: string; timezone: string }>();
  if (!row) throw new HttpError(401, "Connector token is not valid or has been revoked");

  const version = (request.headers.get("x-connector-version") ?? "").trim().slice(0, 40) || null;
  await env.DB.prepare("UPDATE connectors SET last_seen_at = ?, version = COALESCE(?, version) WHERE id = ?")
    .bind(new Date().toISOString(), version, row.id).run();

  return { connectorId: row.id, connectorName: row.name, companyId: row.company_id, companyTimezone: row.timezone };
}

/** Loads a job only if it belongs to one of this connector's devices. */
async function loadOwnJob(env: Env, ctx: ConnectorContext, jobId: string) {
  const job = await env.DB.prepare(
    `SELECT j.id, j.status, j.device_id, j.company_id
       FROM sync_jobs j JOIN devices d ON d.id = j.device_id
      WHERE j.id = ? AND j.company_id = ? AND d.connector_id = ?`,
  ).bind(jobId, ctx.companyId, ctx.connectorId).first<{ id: string; status: string; device_id: string; company_id: string }>();
  if (!job) throw new HttpError(404, "Job not found");
  return job;
}

// ------------------------------------------------------------------ GET /api/connector/config
export async function connectorConfig(request: Request, env: Env): Promise<Response> {
  const ctx = await requireConnector(request, env);
  const { results } = await env.DB.prepare(
    `SELECT id, name, model, ip_address, port, comm_key, serial_number, last_sync_at
       FROM devices
      WHERE connector_id = ? AND company_id = ? AND is_active = 1
      ORDER BY name`,
  ).bind(ctx.connectorId, ctx.companyId).all();

  return json({
    connector: { id: ctx.connectorId, name: ctx.connectorName },
    company: { timezone: ctx.companyTimezone },
    devices: results ?? [],
    server_time: new Date().toISOString(),
  });
}

// ------------------------------------------------------------------ POST /api/connector/jobs/claim
export async function claimJob(request: Request, env: Env): Promise<Response> {
  const ctx = await requireConnector(request, env);
  const now = new Date();
  const staleBefore = new Date(now.getTime() - STALE_JOB_MINUTES * 60_000).toISOString();

  // 1) Jobs this connector started but never finished are marked failed.
  await env.DB.prepare(
    `UPDATE sync_jobs
        SET status = 'failed', finished_at = ?, error_message = 'Timed out: connector did not report completion'
      WHERE status = 'running' AND started_at < ?
        AND device_id IN (SELECT id FROM devices WHERE connector_id = ?)`,
  ).bind(now.toISOString(), staleBefore, ctx.connectorId).run();

  // 2) Atomically take the oldest pending job for this connector's devices.
  const job = await env.DB.prepare(
    `UPDATE sync_jobs
        SET status = 'running', started_at = ?
      WHERE status = 'pending'
        AND id = (
          SELECT j.id FROM sync_jobs j JOIN devices d ON d.id = j.device_id
           WHERE j.status = 'pending' AND j.company_id = ? AND d.connector_id = ? AND d.is_active = 1
           ORDER BY j.requested_at
           LIMIT 1)
      RETURNING id, device_id, trigger_type, requested_at, started_at`,
  ).bind(now.toISOString(), ctx.companyId, ctx.connectorId)
    .first<{ id: string; device_id: string; trigger_type: string; requested_at: string; started_at: string }>();

  if (!job) return json({ job: null });

  const device = await env.DB.prepare(
    "SELECT id, name, model, ip_address, port, comm_key, last_sync_at FROM devices WHERE id = ?",
  ).bind(job.device_id).first();

  return json({ job: { ...job, device } });
}

// ------------------------------------------------------------------ POST /api/connector/jobs/:id/logs
interface CleanRecord { u: string; t: string; s: number | null; v: number | null }

function cleanRecord(raw: unknown): CleanRecord | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;

  const userId = String(r.user_id ?? "").trim();
  if (!userId || userId.length > 32) return null;

  const m = TIMESTAMP_RE.exec(typeof r.timestamp === "string" ? r.timestamp.trim() : "");
  if (!m) return null;
  const [mo, d, h, mi, s] = [m[2], m[3], m[4], m[5], m[6]].map(Number);
  if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || s > 59) return null;

  const state = Number.isInteger(r.state) ? (r.state as number) : null;
  const verify = Number.isInteger(r.verify_mode) ? (r.verify_mode as number) : null;
  return { u: userId, t: `${m[1]}-${m[2]}-${m[3]} ${m[4]}:${m[5]}:${m[6]}`, s: state, v: verify };
}

export async function uploadLogs(request: Request, env: Env, jobId: string): Promise<Response> {
  const ctx = await requireConnector(request, env);
  const job = await loadOwnJob(env, ctx, jobId);
  if (job.status !== "running") throw new HttpError(409, `Job is ${job.status}, not running`);

  const body = await readJson<{ records?: unknown }>(request);
  if (!Array.isArray(body.records)) throw new HttpError(400, "Body must be { records: [...] }");
  if (body.records.length > MAX_RECORDS_PER_UPLOAD) {
    throw new HttpError(413, `Send at most ${MAX_RECORDS_PER_UPLOAD} records per request`);
  }

  const clean = body.records.map(cleanRecord).filter((r): r is CleanRecord => r !== null);
  const rejected = body.records.length - clean.length;

  let inserted = 0;
  if (clean.length > 0) {
    // One statement for the whole chunk; duplicates are skipped by the UNIQUE key.
    const res = await env.DB.prepare(
      `INSERT OR IGNORE INTO attendance_logs
         (company_id, device_id, device_user_id, punch_time, punch_state, verify_mode, sync_job_id)
       SELECT ?1, ?2,
              json_extract(value, '$.u'), json_extract(value, '$.t'),
              json_extract(value, '$.s'), json_extract(value, '$.v'), ?3
         FROM json_each(?4)`,
    ).bind(job.company_id, job.device_id, job.id, JSON.stringify(clean)).run();
    inserted = res.meta.changes ?? 0;
  }

  await env.DB.prepare(
    "UPDATE sync_jobs SET records_fetched = records_fetched + ?, records_inserted = records_inserted + ? WHERE id = ?",
  ).bind(clean.length, inserted, job.id).run();

  return json({
    received: body.records.length,
    accepted: clean.length,
    rejected,
    inserted,
    duplicates: clean.length - inserted,
  });
}

// ------------------------------------------------------------------ POST /api/connector/jobs/:id/complete
export async function completeJob(request: Request, env: Env, jobId: string): Promise<Response> {
  const ctx = await requireConnector(request, env);
  const job = await loadOwnJob(env, ctx, jobId);
  if (job.status !== "running") throw new HttpError(409, `Job is ${job.status}, not running`);

  const body = await readJson<Record<string, unknown>>(request);
  const status = body.status;
  if (status !== "success" && status !== "failed") throw new HttpError(400, "status must be 'success' or 'failed'");
  const errorMessage = status === "failed"
    ? (typeof body.error_message === "string" && body.error_message.trim() ? body.error_message.trim().slice(0, 500) : "Unknown error")
    : null;
  const serial = typeof body.device_serial === "string" && body.device_serial.trim()
    ? body.device_serial.trim().slice(0, 64)
    : null;

  const now = new Date().toISOString();
  const statements = [
    env.DB.prepare("UPDATE sync_jobs SET status = ?, finished_at = ?, error_message = ? WHERE id = ?")
      .bind(status, now, errorMessage, job.id),
  ];
  if (status === "success") {
    statements.push(
      env.DB.prepare("UPDATE devices SET last_sync_at = ?, serial_number = COALESCE(?, serial_number) WHERE id = ?")
        .bind(now, serial, job.device_id),
    );
  }
  await env.DB.batch(statements);

  const summary = await env.DB.prepare(
    "SELECT id, status, records_fetched, records_inserted, finished_at, error_message FROM sync_jobs WHERE id = ?",
  ).bind(job.id).first();
  return json({ job: summary });
}
'@

# ---------------------------------------------------------------- worker/src/pages.ts
Write-File "worker/src/pages.ts" @'
import { VERSION } from "./env";
import type { AuthContext } from "./lib/auth";
import { escapeHtml } from "./lib/http";

const STYLE = `
:root { --bg:#f5f6f8; --card:#ffffff; --text:#1c2330; --muted:#667085; --border:#d9dde3; --accent:#1f6feb; --error:#c62828; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#0f1318; --card:#171c23; --text:#e6e9ee; --muted:#98a2b3; --border:#2a313b; --accent:#4c8dff; --error:#ff6b6b; }
}
* { box-sizing:border-box; }
body { margin:0; font-family:system-ui,-apple-system,"Segoe UI",sans-serif; background:var(--bg); color:var(--text); }
.wrap { max-width:420px; margin:8vh auto; padding:0 16px; }
.wide { max-width:860px; }
.card { background:var(--card); border:1px solid var(--border); border-radius:12px; padding:28px; }
h1 { font-size:20px; margin:0 0 4px; }
p.sub { color:var(--muted); margin:0 0 20px; font-size:14px; }
label { display:block; font-size:13px; margin:14px 0 6px; color:var(--muted); }
input { width:100%; padding:10px 12px; border:1px solid var(--border); border-radius:8px; background:var(--bg); color:var(--text); font-size:15px; }
button { margin-top:20px; width:100%; padding:11px; border:0; border-radius:8px; background:var(--accent); color:#fff; font-size:15px; cursor:pointer; }
button:disabled { opacity:.6; cursor:default; }
.msg { color:var(--error); font-size:14px; min-height:20px; margin-top:12px; }
.alt { text-align:center; font-size:14px; margin-top:16px; color:var(--muted); }
a { color:var(--accent); }
.top { display:flex; justify-content:space-between; align-items:center; margin-bottom:20px; }
.top button { width:auto; margin:0; padding:8px 14px; background:transparent; color:var(--text); border:1px solid var(--border); }
dl { display:grid; grid-template-columns:140px 1fr; gap:10px 16px; margin:0; font-size:15px; }
dt { color:var(--muted); }
dd { margin:0; word-break:break-word; }
.foot { color:var(--muted); font-size:12px; text-align:center; margin-top:16px; }
.dash { max-width:1100px; margin:24px auto; padding:0 16px; }
.dash .card { margin-bottom:20px; padding:20px; }
.dash h2 { font-size:16px; margin:0 0 4px; }
.dash p.sub { margin-bottom:14px; }
.row { display:flex; flex-wrap:wrap; gap:10px; align-items:flex-end; }
.row .f { display:flex; flex-direction:column; flex:1 1 140px; }
.row .f label { margin:0 0 4px; }
.row input, .row select { padding:8px 10px; border:1px solid var(--border); border-radius:8px; background:var(--bg); color:var(--text); font-size:14px; width:100%; }
.row button, .sm { width:auto; margin:0; padding:9px 14px; font-size:14px; }
.sm { padding:5px 10px; font-size:13px; margin-left:4px; background:transparent; color:var(--text); border:1px solid var(--border); }
.sm.primary { background:var(--accent); color:#fff; border-color:var(--accent); }
.tbl { overflow-x:auto; margin-top:14px; }
table { width:100%; border-collapse:collapse; font-size:13px; }
th, td { text-align:left; padding:8px 6px; border-bottom:1px solid var(--border); white-space:nowrap; }
th { color:var(--muted); font-weight:500; }
td.err { white-space:normal; color:var(--error); max-width:280px; }
.badge { display:inline-block; padding:2px 8px; border-radius:999px; font-size:12px; border:1px solid var(--border); }
.b-success, .b-active { color:#1a7f37; border-color:#1a7f37; }
.b-failed, .b-revoked, .b-inactive { color:var(--error); border-color:var(--error); }
.b-running, .b-pending { color:#b26b00; border-color:#b26b00; }
.token { margin-top:14px; padding:12px; border:1px dashed var(--accent); border-radius:8px; font-size:13px; }
.token code { display:block; margin:8px 0; padding:8px; background:var(--bg); border-radius:6px; word-break:break-all; font-size:13px; }
.empty { color:var(--muted); font-size:13px; padding:10px 0; }
.dash .msg { margin-top:8px; min-height:0; }
`;

function layout(title: string, body: string): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title}</title>
<style>${STYLE}</style>
</head>
<body>${body}</body>
</html>`;
}

/** Shared client script: posts the form as JSON and follows the redirect. */
function formScript(endpoint: string): string {
  return `<script>
document.getElementById("f").addEventListener("submit", async function (e) {
  e.preventDefault();
  var btn = this.querySelector("button");
  var msg = document.getElementById("msg");
  msg.textContent = "";
  btn.disabled = true;
  try {
    var data = Object.fromEntries(new FormData(this));
    var res = await fetch("${endpoint}", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(data)
    });
    var out = await res.json().catch(function () { return {}; });
    if (res.ok) { location.href = out.redirect || "/app"; return; }
    msg.textContent = out.error || "Something went wrong";
  } catch (err) {
    msg.textContent = "Network error, please try again";
  }
  btn.disabled = false;
});
</script>`;
}

export function loginPage(): string {
  return layout("Sign in", `
<div class="wrap"><div class="card">
  <h1>HR Attendance</h1>
  <p class="sub">Sign in to your company account</p>
  <form id="f">
    <label for="email">Email</label>
    <input id="email" name="email" type="email" autocomplete="email" required>
    <label for="password">Password</label>
    <input id="password" name="password" type="password" autocomplete="current-password" required>
    <button type="submit">Sign in</button>
    <div class="msg" id="msg"></div>
  </form>
  <div class="alt">New company? <a href="/signup">Create an account</a></div>
</div><div class="foot">${VERSION}</div></div>
${formScript("/api/auth/login")}`);
}

export function signupPage(requireCode: boolean): string {
  const codeField = requireCode
    ? `<label for="signup_code">Sign-up code</label>
    <input id="signup_code" name="signup_code" type="text" autocomplete="off" required>`
    : "";
  return layout("Create account", `
<div class="wrap"><div class="card">
  <h1>Create your company account</h1>
  <p class="sub">You will be the owner of this company workspace</p>
  <form id="f">
    <label for="company_name">Company name</label>
    <input id="company_name" name="company_name" type="text" required>
    <label for="full_name">Your full name</label>
    <input id="full_name" name="full_name" type="text" autocomplete="name" required>
    <label for="email">Email</label>
    <input id="email" name="email" type="email" autocomplete="email" required>
    <label for="password">Password (min 8 characters)</label>
    <input id="password" name="password" type="password" autocomplete="new-password" minlength="8" required>
    ${codeField}
    <button type="submit">Create account</button>
    <div class="msg" id="msg"></div>
  </form>
  <div class="alt">Already have an account? <a href="/login">Sign in</a></div>
</div><div class="foot">${VERSION}</div></div>
${formScript("/api/auth/signup")}`);
}

export function appPage(auth: AuthContext): string {
  const e = escapeHtml;
  const canManage = auth.role === "owner" || auth.role === "admin";
  const hide = canManage ? "" : ` style="display:none"`;
  return layout("Dashboard", `
<div class="dash">
  <div class="top">
    <div>
      <h1>${e(auth.companyName)}</h1>
      <p class="sub" style="margin:0">${e(auth.fullName)} &middot; ${e(auth.role)}</p>
    </div>
    <button id="logout" type="button">Sign out</button>
  </div>

  <div class="card">
    <h2>1. Connectors</h2>
    <p class="sub">A connector is the ZKT Connector app on an office PC that can reach the machine. Its token goes into connector/.env.</p>
    <div class="row"${hide}>
      <div class="f"><label for="c_name">Connector name</label><input id="c_name" placeholder="Office PC - Lahore"></div>
      <button id="c_add" type="button">Create connector</button>
    </div>
    <div class="msg" id="c_msg"></div>
    <div id="c_token"></div>
    <div class="tbl"><table>
      <thead><tr><th>Name</th><th>Token</th><th>Status</th><th>Version</th><th>Last seen</th><th>Devices</th><th></th></tr></thead>
      <tbody id="c_rows"></tbody>
    </table></div>
  </div>

  <div class="card">
    <h2>2. Devices</h2>
    <p class="sub">Attendance machines on your LAN, each assigned to the connector that reads it.</p>
    <div class="row"${hide}>
      <div class="f"><label for="d_name">Device name</label><input id="d_name" placeholder="Main entrance K50"></div>
      <div class="f"><label for="d_ip">IP address</label><input id="d_ip" placeholder="192.168.10.21"></div>
      <div class="f" style="flex:0 1 90px"><label for="d_port">Port</label><input id="d_port" value="4370"></div>
      <div class="f" style="flex:0 1 90px"><label for="d_key">Comm key</label><input id="d_key" value="0"></div>
      <div class="f"><label for="d_conn">Connector</label><select id="d_conn"></select></div>
      <button id="d_add" type="button">Add device</button>
    </div>
    <div class="msg" id="d_msg"></div>
    <div class="tbl"><table>
      <thead><tr><th>Name</th><th>Address</th><th>Connector</th><th>Serial</th><th>Last sync</th><th>Logs</th><th>Last job</th><th></th></tr></thead>
      <tbody id="d_rows"></tbody>
    </table></div>
  </div>

  <div class="card">
    <h2>3. Sync jobs</h2>
    <p class="sub">Each import run. The connector picks up pending jobs and uploads the machine's attendance logs.</p>
    <div class="tbl"><table>
      <thead><tr><th>Requested</th><th>Device</th><th>Trigger</th><th>Status</th><th>Fetched</th><th>New</th><th>Finished</th><th>Error</th></tr></thead>
      <tbody id="j_rows"></tbody>
    </table></div>
  </div>

  <div class="foot">${VERSION}</div>
</div>
<script>
var CAN_MANAGE = ${canManage ? "true" : "false"};

async function api(method, path, body) {
  var opts = { method: method, headers: {} };
  if (body !== undefined) { opts.headers["content-type"] = "application/json"; opts.body = JSON.stringify(body); }
  var res = await fetch(path, opts);
  var data = await res.json().catch(function () { return {}; });
  if (res.status === 401) { location.href = "/login"; throw new Error("Signed out"); }
  if (!res.ok) throw new Error(data.error || ("Request failed (" + res.status + ")"));
  return data;
}

function when(v) { return v ? new Date(v).toLocaleString() : "\\u2014"; }
function td(text, cls) { var c = document.createElement("td"); c.textContent = (text === null || text === undefined || text === "") ? "\\u2014" : String(text); if (cls) c.className = cls; return c; }
function badge(text) { var c = document.createElement("td"); if (!text) { c.textContent = "\\u2014"; return c; } var s = document.createElement("span"); s.className = "badge b-" + text; s.textContent = text; c.appendChild(s); return c; }
function btn(label, primary, onClick) { var b = document.createElement("button"); b.type = "button"; b.className = primary ? "sm primary" : "sm"; b.textContent = label; b.addEventListener("click", onClick); return b; }
function emptyRow(tbody, cols, text) { var tr = document.createElement("tr"); var c = document.createElement("td"); c.colSpan = cols; c.className = "empty"; c.textContent = text; tr.appendChild(c); tbody.appendChild(tr); }
function showMsg(id, text) { document.getElementById(id).textContent = text || ""; }

async function loadConnectors() {
  var data = await api("GET", "/api/connectors");
  var tbody = document.getElementById("c_rows");
  var select = document.getElementById("d_conn");
  tbody.textContent = ""; select.textContent = "";
  var none = document.createElement("option"); none.value = ""; none.textContent = "(none yet)"; select.appendChild(none);
  if (!data.connectors.length) emptyRow(tbody, 7, "No connectors yet. Create one first.");
  data.connectors.forEach(function (c) {
    var tr = document.createElement("tr");
    tr.appendChild(td(c.name));
    tr.appendChild(td(c.token_hint ? "zkc_\\u2026" + c.token_hint : ""));
    tr.appendChild(badge(c.is_active ? "active" : "revoked"));
    tr.appendChild(td(c.version));
    tr.appendChild(td(when(c.last_seen_at)));
    tr.appendChild(td(c.device_count));
    var actions = document.createElement("td");
    if (CAN_MANAGE && c.is_active) {
      actions.appendChild(btn("Revoke", false, async function () {
        if (!confirm("Revoke connector '" + c.name + "'? It will stop working immediately.")) return;
        try { await api("POST", "/api/connectors/" + c.id + "/revoke", {}); await refresh(); } catch (err) { alert(err.message); }
      }));
    }
    tr.appendChild(actions);
    tbody.appendChild(tr);
    if (c.is_active) { var o = document.createElement("option"); o.value = c.id; o.textContent = c.name; select.appendChild(o); }
  });
  if (select.options.length > 1) select.selectedIndex = 1;
}

async function loadDevices() {
  var data = await api("GET", "/api/devices");
  var tbody = document.getElementById("d_rows");
  tbody.textContent = "";
  if (!data.devices.length) emptyRow(tbody, 8, "No devices yet.");
  data.devices.forEach(function (d) {
    var tr = document.createElement("tr");
    tr.appendChild(td(d.name + (d.is_active ? "" : " (inactive)")));
    tr.appendChild(td(d.ip_address + ":" + d.port));
    tr.appendChild(td(d.connector_name));
    tr.appendChild(td(d.serial_number));
    tr.appendChild(td(when(d.last_sync_at)));
    tr.appendChild(td(d.log_count));
    tr.appendChild(badge(d.last_job_status));
    var actions = document.createElement("td");
    if (CAN_MANAGE && d.is_active) {
      actions.appendChild(btn("Sync now", true, async function () {
        try {
          var r = await api("POST", "/api/devices/" + d.id + "/sync", {});
          showMsg("d_msg", r.already_queued ? "A sync for this device is already " + r.job.status + "." : "");
          await refresh();
        } catch (err) { alert(err.message); }
      }));
      actions.appendChild(btn("Deactivate", false, async function () {
        if (!confirm("Deactivate device '" + d.name + "'? Its attendance data is kept.")) return;
        try { await api("POST", "/api/devices/" + d.id + "/deactivate", {}); await refresh(); } catch (err) { alert(err.message); }
      }));
    }
    tr.appendChild(actions);
    tbody.appendChild(tr);
  });
}

async function loadJobs() {
  var data = await api("GET", "/api/sync-jobs?limit=20");
  var tbody = document.getElementById("j_rows");
  tbody.textContent = "";
  if (!data.jobs.length) emptyRow(tbody, 8, "No sync jobs yet.");
  data.jobs.forEach(function (j) {
    var tr = document.createElement("tr");
    tr.appendChild(td(when(j.requested_at)));
    tr.appendChild(td(j.device_name));
    tr.appendChild(td(j.trigger_type));
    tr.appendChild(badge(j.status));
    tr.appendChild(td(j.records_fetched));
    tr.appendChild(td(j.records_inserted));
    tr.appendChild(td(when(j.finished_at)));
    tr.appendChild(td(j.error_message, j.error_message ? "err" : ""));
    tbody.appendChild(tr);
  });
}

async function refresh() {
  try { await Promise.all([loadConnectors(), loadDevices(), loadJobs()]); }
  catch (err) { showMsg("d_msg", err.message); }
}

document.getElementById("c_add").addEventListener("click", async function () {
  showMsg("c_msg", "");
  var box = document.getElementById("c_token"); box.textContent = "";
  try {
    var r = await api("POST", "/api/connectors", { name: document.getElementById("c_name").value });
    var wrap = document.createElement("div"); wrap.className = "token";
    var title = document.createElement("strong"); title.textContent = "Connector token for '" + r.connector.name + "'";
    var code = document.createElement("code"); code.textContent = r.token;
    var note = document.createElement("div"); note.textContent = r.note;
    var copy = btn("Copy token", true, function () { navigator.clipboard.writeText(r.token); copy.textContent = "Copied"; });
    wrap.appendChild(title); wrap.appendChild(code); wrap.appendChild(note); wrap.appendChild(copy);
    box.appendChild(wrap);
    document.getElementById("c_name").value = "";
    await refresh();
  } catch (err) { showMsg("c_msg", err.message); }
});

document.getElementById("d_add").addEventListener("click", async function () {
  showMsg("d_msg", "");
  try {
    await api("POST", "/api/devices", {
      name: document.getElementById("d_name").value,
      ip_address: document.getElementById("d_ip").value,
      port: document.getElementById("d_port").value,
      comm_key: document.getElementById("d_key").value,
      connector_id: document.getElementById("d_conn").value
    });
    document.getElementById("d_name").value = "";
    document.getElementById("d_ip").value = "";
    await refresh();
  } catch (err) { showMsg("d_msg", err.message); }
});

document.getElementById("logout").addEventListener("click", async function () {
  await fetch("/api/auth/logout", { method: "POST", headers: { "content-type": "application/json" }, body: "{}" });
  location.href = "/login";
});

refresh();
setInterval(loadJobs, 15000);
</script>`);
}
'@

# ---------------------------------------------------------------- worker/src/index.ts
Write-File "worker/src/index.ts" @'
import type { Env } from "./env";
import { HttpError, html, json, redirect } from "./lib/http";
import { getAuth } from "./lib/auth";
import { health } from "./routes/health";
import { login, logout, me, signup } from "./routes/auth";
import {
  createConnector, createDevice, deactivateDevice, listConnectors,
  listDevices, listSyncJobs, queueSync, revokeConnector,
} from "./routes/manage";
import { claimJob, completeJob, connectorConfig, uploadLogs } from "./routes/connector";
import { appPage, loginPage, signupPage } from "./pages";

export type { Env };

const ID = "([0-9a-f-]{36})";
const R_CONNECTOR_REVOKE = new RegExp(`^/api/connectors/${ID}/revoke$`);
const R_DEVICE_DEACTIVATE = new RegExp(`^/api/devices/${ID}/deactivate$`);
const R_DEVICE_SYNC = new RegExp(`^/api/devices/${ID}/sync$`);
const R_JOB_LOGS = new RegExp(`^/api/connector/jobs/${ID}/logs$`);
const R_JOB_COMPLETE = new RegExp(`^/api/connector/jobs/${ID}/complete$`);

async function route(request: Request, env: Env): Promise<Response> {
  const { pathname } = new URL(request.url);
  const method = request.method;
  let m: RegExpExecArray | null;

  // ---- Public / auth
  if (pathname === "/api/health" && method === "GET") return health(env);
  if (pathname === "/api/auth/signup" && method === "POST") return signup(request, env);
  if (pathname === "/api/auth/login" && method === "POST") return login(request, env);
  if (pathname === "/api/auth/logout" && method === "POST") return logout(request, env);
  if (pathname === "/api/auth/me" && method === "GET") return me(request, env);

  // ---- Dashboard API (browser session)
  if (pathname === "/api/connectors" && method === "GET") return listConnectors(request, env);
  if (pathname === "/api/connectors" && method === "POST") return createConnector(request, env);
  if (method === "POST" && (m = R_CONNECTOR_REVOKE.exec(pathname))) return revokeConnector(request, env, m[1]);
  if (pathname === "/api/devices" && method === "GET") return listDevices(request, env);
  if (pathname === "/api/devices" && method === "POST") return createDevice(request, env);
  if (method === "POST" && (m = R_DEVICE_DEACTIVATE.exec(pathname))) return deactivateDevice(request, env, m[1]);
  if (method === "POST" && (m = R_DEVICE_SYNC.exec(pathname))) return queueSync(request, env, m[1]);
  if (pathname === "/api/sync-jobs" && method === "GET") return listSyncJobs(request, env);

  // ---- ZKT Connector API (Bearer token)
  if (pathname === "/api/connector/config" && method === "GET") return connectorConfig(request, env);
  if (pathname === "/api/connector/jobs/claim" && method === "POST") return claimJob(request, env);
  if (method === "POST" && (m = R_JOB_LOGS.exec(pathname))) return uploadLogs(request, env, m[1]);
  if (method === "POST" && (m = R_JOB_COMPLETE.exec(pathname))) return completeJob(request, env, m[1]);

  if (pathname.startsWith("/api/")) return json({ error: "Not found" }, 404);

  // ---- Pages
  if (method === "GET") {
    if (pathname === "/") {
      return redirect((await getAuth(request, env)) ? "/app" : "/login");
    }
    if (pathname === "/login") {
      return (await getAuth(request, env)) ? redirect("/app") : html(loginPage());
    }
    if (pathname === "/signup") {
      return (await getAuth(request, env)) ? redirect("/app") : html(signupPage(Boolean(env.SIGNUP_CODE)));
    }
    if (pathname === "/app") {
      const auth = await getAuth(request, env);
      return auth ? html(appPage(auth)) : redirect("/login");
    }
  }

  return json({ error: "Not found" }, 404);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await route(request, env);
    } catch (err) {
      if (err instanceof HttpError) return json({ error: err.message }, err.status);
      console.error(err);
      return json({ error: "Internal server error" }, 500);
    }
  },
};
'@

# ---------------------------------------------------------------- connector/package.json
Write-File "connector/package.json" @'
{
  "name": "zkt-connector",
  "version": "0.3.0",
  "private": true,
  "type": "module",
  "scripts": {
    "start": "node src/index.js",
    "api-test": "node src/api-test.js"
  },
  "dependencies": {
    "dotenv": "^16.4.5"
  }
}
'@

# ---------------------------------------------------------------- connector/.env.example
Write-File "connector/.env.example" @'
# --- Attendance Fetcher SaaS (Cloudflare Worker) ---
API_BASE_URL=https://hr-attendance-fetcher.bilaljahangir1995.workers.dev
# Create a connector in the dashboard (/app) and paste its token here
CONNECTOR_TOKEN=zkc_paste_your_token_here

# --- Local fallback only. Device IP / port / comm key now come from the
# --- dashboard (Devices section) through /api/connector/config.
DEVICE_TIMEOUT_MS=10000
'@

# ---------------------------------------------------------------- connector/src/api.js
Write-File "connector/src/api.js" @'
// HTTP client for the Attendance Fetcher Worker (connector side).
export const CONNECTOR_VERSION = "0.3.0";

export class ApiClient {
  constructor(baseUrl, token) {
    this.baseUrl = baseUrl.replace(/\/+$/, "");
    this.token = token;
  }

  async request(method, path, body) {
    const res = await fetch(this.baseUrl + path, {
      method,
      headers: {
        authorization: `Bearer ${this.token}`,
        "content-type": "application/json",
        "x-connector-version": CONNECTOR_VERSION,
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });

    const text = await res.text();
    let data;
    try {
      data = text ? JSON.parse(text) : {};
    } catch {
      data = { error: text.slice(0, 200) };
    }

    if (!res.ok) {
      const err = new Error(`${method} ${path} -> ${res.status}: ${data.error ?? "request failed"}`);
      err.status = res.status;
      throw err;
    }
    return data;
  }

  getConfig() {
    return this.request("GET", "/api/connector/config");
  }

  claimJob() {
    return this.request("POST", "/api/connector/jobs/claim", {});
  }

  /** records: [{ user_id, timestamp: "YYYY-MM-DD HH:MM:SS", state, verify_mode }] (max 1000 per call) */
  uploadLogs(jobId, records) {
    return this.request("POST", `/api/connector/jobs/${encodeURIComponent(jobId)}/logs`, { records });
  }

  /** payload: { status: "success" | "failed", error_message?, device_serial? } */
  completeJob(jobId, payload) {
    return this.request("POST", `/api/connector/jobs/${encodeURIComponent(jobId)}/complete`, payload);
  }
}

export function clientFromEnv() {
  const base = process.env.API_BASE_URL;
  const token = process.env.CONNECTOR_TOKEN;
  if (!base) throw new Error("API_BASE_URL is not set in .env");
  if (!token || !token.startsWith("zkc_")) {
    throw new Error("CONNECTOR_TOKEN is not set in .env (create a connector in the dashboard and paste its token)");
  }
  return new ApiClient(base, token);
}
'@

# ---------------------------------------------------------------- connector/src/api-test.js
Write-File "connector/src/api-test.js" @'
// Phase 3 end-to-end test of the connector API, WITHOUT the machine.
// Uploads two fake punches for user "TEST" dated 2000-01-01, then uploads
// them again to prove duplicates are skipped. Run: npm run api-test
import "dotenv/config";
import { clientFromEnv, CONNECTOR_VERSION } from "./api.js";

const TEST_RECORDS = [
  { user_id: "TEST", timestamp: "2000-01-01 09:00:00", state: 0, verify_mode: 1 },
  { user_id: "TEST", timestamp: "2000-01-01 18:00:00", state: 1, verify_mode: 1 },
];

async function main() {
  console.log(`ZKT Connector ${CONNECTOR_VERSION} - API test`);
  const api = clientFromEnv();

  const config = await api.getConfig();
  console.log(`\n[1] Token OK. Connector: ${config.connector.name}`);
  if (!config.devices.length) {
    console.log("    No devices assigned to this connector. Add one in the dashboard first.");
    return;
  }
  for (const d of config.devices) {
    console.log(`    Device: ${d.name}  ${d.ip_address}:${d.port}  comm key ${d.comm_key}`);
  }

  const claim = await api.claimJob();
  if (!claim.job) {
    console.log("\n[2] No pending job. Click 'Sync now' on the device in the dashboard, then run this again.");
    return;
  }
  const job = claim.job;
  console.log(`\n[2] Claimed job ${job.id} for device "${job.device.name}" (${job.trigger_type})`);

  const first = await api.uploadLogs(job.id, TEST_RECORDS);
  console.log(`\n[3] First upload : inserted ${first.inserted}, duplicates ${first.duplicates}, rejected ${first.rejected}`);

  const second = await api.uploadLogs(job.id, TEST_RECORDS);
  console.log(`[4] Second upload: inserted ${second.inserted}, duplicates ${second.duplicates}  (expected 0 inserted)`);

  const done = await api.completeJob(job.id, { status: "success" });
  console.log(`\n[5] Job ${done.job.status}: fetched ${done.job.records_fetched}, new ${done.job.records_inserted}`);
  console.log("\nAPI test passed.");
}

main().catch((err) => {
  console.error("\nAPI test FAILED:", err.message);
  process.exitCode = 1;
});
'@

# ---------------------------------------------------------------- connector/src/index.js
Write-File "connector/src/index.js" @'
import "dotenv/config";
import { CONNECTOR_VERSION, clientFromEnv } from "./api.js";

async function main() {
  console.log(`ZKT Connector ${CONNECTOR_VERSION}`);
  console.log(`API : ${process.env.API_BASE_URL ?? "(not set)"}`);

  if (!process.env.API_BASE_URL) {
    console.log("API_BASE_URL not set - copy .env.example to .env first.");
    return;
  }

  try {
    const res = await fetch(`${process.env.API_BASE_URL.replace(/\/+$/, "")}/api/health`);
    const health = await res.json();
    console.log(`Worker: ${health.status} (${health.version})`);

    const config = await clientFromEnv().getConfig();
    console.log(`Connector: ${config.connector.name}`);
    if (!config.devices.length) console.log("Devices: none assigned yet");
    for (const d of config.devices) {
      console.log(`Device: ${d.name}  ${d.ip_address}:${d.port}  comm key ${d.comm_key}`);
    }
  } catch (err) {
    console.error("Error:", err.message);
    process.exitCode = 1;
  }
}

main();
'@

Write-Host ""
Write-Host "Phase 3 files written. Next steps are listed in the chat." -ForegroundColor Cyan
