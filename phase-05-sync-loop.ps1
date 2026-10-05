# =====================================================================
# HR Auto Attendance Fetcher - PHASE 5 : Connector <-> Worker sync loop
# Run from the ROOT of the repo (hr-attendance-fetcher):
#   powershell -ExecutionPolicy Bypass -File .\phase-05-sync-loop.ps1
# =====================================================================
$ErrorActionPreference = "Stop"

function Write-File([string]$Path, [string]$Content) {
    $full = Join-Path (Get-Location) $Path
    $dir  = Split-Path $full -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($full, $Content.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  wrote $Path" -ForegroundColor Green
}

if (-not (Test-Path "connector/src/zk/client.js")) {
    throw "Run this from the repo root, after Phase 4 (connector/src/zk/client.js not found)."
}

Write-Host "Phase 5: writing sync loop..." -ForegroundColor Cyan

# ---------------------------------------------------------------- worker/migrations/0003_sync_quality.sql
Write-File "worker/migrations/0003_sync_quality.sql" @'
-- =============================================================
-- Phase 5 - sync data quality
-- =============================================================

-- Punches the connector did not import (e.g. dated in the future
-- because the machine clock was wrong when they were recorded).
ALTER TABLE sync_jobs ADD COLUMN records_skipped INTEGER NOT NULL DEFAULT 0;

-- Machine clock minus real time, measured at each sync (seconds).
ALTER TABLE devices ADD COLUMN clock_offset_seconds INTEGER;
ALTER TABLE devices ADD COLUMN clock_checked_at TEXT;
'@

# ---------------------------------------------------------------- worker/src/env.ts
Write-File "worker/src/env.ts" @'
export interface Env {
  DB: D1Database;
  /** Optional. When set, sign-up requires this code (set with: wrangler secret put SIGNUP_CODE). */
  SIGNUP_CODE?: string;
}

export const VERSION = "0.5.0-phase5";

/** Number of files in worker/migrations. The health check reports "degraded" until all are applied. */
export const EXPECTED_MIGRATIONS = 3;
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
  const skipped = Number.isInteger(body.records_skipped) && (body.records_skipped as number) >= 0
    ? (body.records_skipped as number)
    : 0;
  const clockOffset = Number.isInteger(body.clock_offset_seconds) && Math.abs(body.clock_offset_seconds as number) < 20 * 365 * 86400
    ? (body.clock_offset_seconds as number)
    : null;

  const now = new Date().toISOString();
  const statements = [
    env.DB.prepare("UPDATE sync_jobs SET status = ?, finished_at = ?, error_message = ?, records_skipped = ? WHERE id = ?")
      .bind(status, now, errorMessage, skipped, job.id),
  ];
  if (status === "success") {
    statements.push(
      env.DB.prepare(
        `UPDATE devices
            SET last_sync_at = ?, serial_number = COALESCE(?, serial_number),
                clock_offset_seconds = COALESCE(?, clock_offset_seconds),
                clock_checked_at = CASE WHEN ? IS NULL THEN clock_checked_at ELSE ? END
          WHERE id = ?`,
      ).bind(now, serial, clockOffset, clockOffset, now, job.device_id),
    );
  }
  await env.DB.batch(statements);

  const summary = await env.DB.prepare(
    `SELECT id, status, records_fetched, records_inserted, records_skipped, finished_at, error_message
       FROM sync_jobs WHERE id = ?`,
  ).bind(job.id).first();
  return json({ job: summary });
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
            d.last_sync_at, d.clock_offset_seconds, d.clock_checked_at, d.is_active, d.created_at,
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
            j.requested_at, j.started_at, j.finished_at, j.records_fetched, j.records_inserted, j.records_skipped, j.error_message
       FROM sync_jobs j JOIN devices d ON d.id = j.device_id
      WHERE j.company_id = ?
      ORDER BY j.requested_at DESC
      LIMIT ?`,
  ).bind(auth.companyId, limit).all();
  return json({ jobs: results ?? [] });
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
td.warn { color:#b26b00; }
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
      <thead><tr><th>Name</th><th>Address</th><th>Connector</th><th>Serial</th><th>Clock</th><th>Last sync</th><th>Logs</th><th>Last job</th><th></th></tr></thead>
      <tbody id="d_rows"></tbody>
    </table></div>
  </div>

  <div class="card">
    <h2>3. Sync jobs</h2>
    <p class="sub">Each import run. The connector picks up pending jobs and uploads the machine's attendance logs.</p>
    <div class="tbl"><table>
      <thead><tr><th>Requested</th><th>Device</th><th>Trigger</th><th>Status</th><th>Read</th><th>New</th><th>Skipped</th><th>Finished</th><th>Error</th></tr></thead>
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
function clockCell(sec) {
  var c = document.createElement("td");
  if (sec === null || sec === undefined) { c.textContent = "\\u2014"; return c; }
  var a = Math.abs(sec);
  var txt = a < 60 ? a + " s" : a < 3600 ? Math.round(a / 60) + " min" : a < 86400 ? (a / 3600).toFixed(1) + " h" : Math.round(a / 86400) + " days";
  c.textContent = a <= 60 ? "OK" : (sec < 0 ? txt + " slow" : txt + " fast");
  if (a > 60) { c.className = "warn"; c.title = "The machine clock is off. Correct the time on the machine so punches are recorded at the right time."; }
  return c;
}
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
  if (!data.devices.length) emptyRow(tbody, 9, "No devices yet.");
  data.devices.forEach(function (d) {
    var tr = document.createElement("tr");
    tr.appendChild(td(d.name + (d.is_active ? "" : " (inactive)")));
    tr.appendChild(td(d.ip_address + ":" + d.port));
    tr.appendChild(td(d.connector_name));
    tr.appendChild(td(d.serial_number));
    tr.appendChild(clockCell(d.clock_offset_seconds));
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
  if (!data.jobs.length) emptyRow(tbody, 9, "No sync jobs yet.");
  data.jobs.forEach(function (j) {
    var tr = document.createElement("tr");
    tr.appendChild(td(when(j.requested_at)));
    tr.appendChild(td(j.device_name));
    tr.appendChild(td(j.trigger_type));
    tr.appendChild(badge(j.status));
    tr.appendChild(td(j.records_fetched + (j.records_skipped || 0)));
    tr.appendChild(td(j.records_inserted));
    tr.appendChild(td(j.records_skipped, j.records_skipped ? "warn" : ""));
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

# ---------------------------------------------------------------- connector/package.json
Write-File "connector/package.json" @'
{
  "name": "zkt-connector",
  "version": "0.5.0",
  "private": true,
  "type": "module",
  "scripts": {
    "start": "node src/index.js",
    "api-test": "node src/api-test.js",
    "read-device": "node src/read-device.js",
    "mock-device": "node test/mock-device.js",
    "test": "node --test test/zk.test.js test/sync.test.js"
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

# How long to wait for the machine before giving up (ms)
DEVICE_TIMEOUT_MS=10000

# How often the connector asks the server for sync jobs (seconds, 15-3600)
POLL_INTERVAL_SECONDS=60

# First retry delay when the machine or server fails (seconds; 2nd retry waits 3x)
RETRY_DELAY_SECONDS=10

# --- Optional fallback when no CONNECTOR_TOKEN is set. Normally the
# --- device IP / port / comm key come from the dashboard.
# DEVICE_IP=192.168.10.21
# DEVICE_PORT=4370
# DEVICE_COMM_KEY=0
'@

# ---------------------------------------------------------------- connector/src/api.js
Write-File "connector/src/api.js" @'
// HTTP client for the Attendance Fetcher Worker (connector side).
export const CONNECTOR_VERSION = "0.5.0";

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

# ---------------------------------------------------------------- connector/src/log.js
Write-File "connector/src/log.js" @'
// Timestamped console logging (Phase 6 will also write these lines to a file).
function stamp() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

export const log = {
  info: (msg) => console.log(`${stamp()}  INFO   ${msg}`),
  warn: (msg) => console.warn(`${stamp()}  WARN   ${msg}`),
  error: (msg) => console.error(`${stamp()}  ERROR  ${msg}`),
};
'@

# ---------------------------------------------------------------- connector/src/sync.js
Write-File "connector/src/sync.js" @'
// Phase 5: process one sync job end to end.
// read machine (read-only, with retries) -> filter -> upload in batches -> complete job
import { readDevice } from "./zk/client.js";
import { log } from "./log.js";

const BATCH_SIZE = 1000;
const FUTURE_TOLERANCE_MS = 24 * 60 * 60 * 1000; // punches > 1 day after the machine's own clock are skipped

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function retryDelaysMs() {
  const base = Number(process.env.RETRY_DELAY_SECONDS);
  const s = Number.isFinite(base) && base >= 0 ? base : 10;
  return [s * 1000, s * 3000]; // wait 10 s, then 30 s (3 attempts in total)
}

/** "YYYY-MM-DD HH:MM:SS" (machine local time) -> Date in this PC's local time zone */
function parseLocal(ts) {
  return new Date(ts.replace(" ", "T"));
}

function formatLocal(d) {
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

/** Machine clock minus this PC's clock, in seconds (null if the machine did not report its time). */
export function clockOffsetSeconds(deviceTime, now = Date.now()) {
  if (!deviceTime) return null;
  const t = parseLocal(deviceTime).getTime();
  return Number.isFinite(t) ? Math.round((t - now) / 1000) : null;
}

/**
 * Splits records into ones to import and ones to skip.
 * Skipped: dated more than 1 day after the machine's current clock - these were
 * recorded while the machine clock was set wrong and would show as future attendance.
 */
export function filterRecords(records, deviceTime, now = Date.now()) {
  const ref = deviceTime ? parseLocal(deviceTime).getTime() : now;
  const limit = formatLocal(new Date((Number.isFinite(ref) ? ref : now) + FUTURE_TOLERANCE_MS));
  const keep = [];
  const skipped = [];
  for (const r of records) (r.timestamp <= limit ? keep : skipped).push(r);
  keep.sort((a, b) => a.timestamp.localeCompare(b.timestamp));
  return { keep, skipped, limit };
}

function isRetryable(err) {
  return !err.status || err.status >= 500 || err.status === 429;
}

async function withRetry(label, fn) {
  const delays = retryDelaysMs();
  for (let attempt = 1; ; attempt++) {
    try {
      return await fn();
    } catch (err) {
      if (attempt > delays.length || !isRetryable(err)) throw err;
      const wait = delays[attempt - 1];
      log.warn(`${label} failed (attempt ${attempt}/${delays.length + 1}): ${err.message}. Retrying in ${Math.round(wait / 1000)} s`);
      await sleep(wait);
    }
  }
}

async function safeFail(api, jobId, message) {
  try {
    await api.completeJob(jobId, { status: "failed", error_message: message.slice(0, 480) });
  } catch (err) {
    log.error(`Could not report failure for job ${jobId}: ${err.message}`);
  }
}

/** Returns a summary object; never throws for device/upload problems (they are reported on the job). */
export async function processJob(api, job, { timeoutMs = 10000 } = {}) {
  const d = job.device;
  const started = Date.now();
  log.info(`Job ${job.id.slice(0, 8)} (${job.trigger_type}): reading "${d.name}" at ${d.ip_address}:${d.port}`);

  // 1) Read the machine (read-only)
  let result;
  try {
    result = await withRetry("Reading machine", () =>
      readDevice({ ip: d.ip_address, port: d.port, commKey: d.comm_key, timeoutMs }));
  } catch (err) {
    const msg = `Could not read machine ${d.ip_address}:${d.port}: ${err.message}`;
    log.error(msg);
    await safeFail(api, job.id, msg);
    return { ok: false, error: msg };
  }

  const offset = clockOffsetSeconds(result.deviceTime);
  const { keep, skipped, limit } = filterRecords(result.records, result.deviceTime);
  log.info(`Read ${result.records.length} punches (serial ${result.serialNumber ?? "?"}, clock offset ${offset ?? "?"} s)`);
  if (offset !== null && Math.abs(offset) > 60) {
    log.warn(`Machine clock is ${Math.abs(offset)} s ${offset < 0 ? "behind" : "ahead"}. Correct the time on the machine.`);
  }
  if (skipped.length) {
    const sample = skipped.slice(0, 3).map((r) => `${r.timestamp} (user ${r.user_id})`).join(", ");
    log.warn(`Skipping ${skipped.length} punch(es) dated after ${limit}: ${sample}${skipped.length > 3 ? ", ..." : ""}`);
  }

  // 2) Upload in batches (duplicates are ignored by the server)
  let inserted = 0;
  let duplicates = 0;
  let rejected = 0;
  try {
    for (let i = 0; i < keep.length; i += BATCH_SIZE) {
      const batch = keep.slice(i, i + BATCH_SIZE);
      const res = await withRetry("Upload", () => api.uploadLogs(job.id, batch));
      inserted += res.inserted;
      duplicates += res.duplicates;
      rejected += res.rejected;
    }
  } catch (err) {
    const msg = `Upload failed: ${err.message}`;
    log.error(msg);
    if (err.status !== 409) await safeFail(api, job.id, msg); // 409 = job already closed by the server
    return { ok: false, error: msg };
  }

  // 3) Complete
  try {
    await withRetry("Completing job", () => api.completeJob(job.id, {
      status: "success",
      device_serial: result.serialNumber ?? undefined,
      records_skipped: skipped.length + rejected,
      clock_offset_seconds: offset ?? undefined,
    }));
  } catch (err) {
    log.error(`Could not complete job: ${err.message}`);
    return { ok: false, error: err.message };
  }

  const secs = ((Date.now() - started) / 1000).toFixed(1);
  log.info(`Job ${job.id.slice(0, 8)} done in ${secs} s: ${inserted} new, ${duplicates} already imported, ${skipped.length + rejected} skipped`);
  return { ok: true, read: result.records.length, inserted, duplicates, skipped: skipped.length + rejected };
}
'@

# ---------------------------------------------------------------- connector/src/index.js
Write-File "connector/src/index.js" @'
// ZKT Connector main loop.
//   npm start                 -> runs continuously: picks up sync jobs and imports attendance
//   npm start -- --once       -> processes at most one pending job, then exits
import "dotenv/config";
import { CONNECTOR_VERSION, clientFromEnv } from "./api.js";
import { processJob } from "./sync.js";
import { log } from "./log.js";

const once = process.argv.includes("--once");
const pollSeconds = Math.min(Math.max(Number(process.env.POLL_INTERVAL_SECONDS) || 60, 15), 3600);
const timeoutMs = Number(process.env.DEVICE_TIMEOUT_MS) || 10000;

let stopping = false;
process.on("SIGINT", () => {
  if (stopping) process.exit(1);
  stopping = true;
  log.info("Stopping after the current step (press Ctrl+C again to force)...");
});
process.on("SIGTERM", () => { stopping = true; });

async function sleepUnlessStopping(seconds) {
  for (let i = 0; i < seconds && !stopping; i++) await new Promise((r) => setTimeout(r, 1000));
}

async function main() {
  log.info(`ZKT Connector ${CONNECTOR_VERSION} starting${once ? " (single run)" : ""}`);
  const api = clientFromEnv();

  const config = await api.getConfig();
  log.info(`Connected to ${api.baseUrl} as connector "${config.connector.name}"`);
  if (!config.devices.length) log.warn("No devices assigned to this connector yet (add one in the dashboard).");
  for (const d of config.devices) log.info(`Device "${d.name}" at ${d.ip_address}:${d.port}`);
  if (!once) log.info(`Checking for sync jobs every ${pollSeconds} s. Press Ctrl+C to stop.`);

  while (!stopping) {
    try {
      const { job } = await api.claimJob();
      if (job) {
        await processJob(api, job, { timeoutMs });
        if (once) break;
        continue; // another job may be waiting (e.g. several devices)
      }
      if (once) {
        log.info("No pending sync job. Click 'Sync now' in the dashboard, then run again.");
        break;
      }
    } catch (err) {
      if (err.status === 401) {
        log.error(`${err.message}. Create a new connector token in the dashboard and update .env.`);
        process.exitCode = 1;
        return;
      }
      log.error(`Could not reach the server: ${err.message}`);
      if (once) { process.exitCode = 1; return; }
    }
    await sleepUnlessStopping(pollSeconds);
  }
  log.info("Connector stopped.");
}

main().catch((err) => {
  log.error(err.message);
  process.exitCode = 1;
});
'@

# ---------------------------------------------------------------- connector/test/sync.test.js
Write-File "connector/test/sync.test.js" @'
// Run: npm test
import test from "node:test";
import assert from "node:assert/strict";
import { filterRecords, clockOffsetSeconds } from "../src/sync.js";

const rec = (timestamp, user_id = "1") => ({ user_id, timestamp, state: 0, verify_mode: 1 });

test("future-dated punches (machine clock was wrong) are skipped", () => {
  const records = [
    rec("2027-07-28 13:10:47", "6"),
    rec("2015-05-13 12:15:30", "1"),
    rec("2026-10-05 19:00:16", "10"),
    rec("2026-10-06 20:31:32", "3"), // exactly 1 day after machine clock: kept
    rec("2026-10-06 20:31:33", "4"), // 1 s later: skipped
  ];
  const { keep, skipped } = filterRecords(records, "2026-10-05 20:31:32");
  assert.deepEqual(keep.map((r) => r.timestamp), ["2015-05-13 12:15:30", "2026-10-05 19:00:16", "2026-10-06 20:31:32"]);
  assert.deepEqual(skipped.map((r) => r.user_id), ["6", "4"]);
});

test("clock offset is machine minus PC time", () => {
  const now = new Date("2026-10-05T20:35:28").getTime();
  assert.equal(clockOffsetSeconds("2026-10-05 20:31:32", now), -236);
  assert.equal(clockOffsetSeconds(null, now), null);
});
'@

Write-Host ""
Write-Host "Phase 5 files written. Next steps are listed in the chat." -ForegroundColor Cyan
