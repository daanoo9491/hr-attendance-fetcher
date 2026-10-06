# =====================================================================
# HR Auto Attendance Fetcher - PHASE 7 : Employee names
# (read from the machine's user list + editable in the dashboard)
# Run from the ROOT of the repo (hr-attendance-fetcher):
#   powershell -ExecutionPolicy Bypass -File .\phase-07-employee-names.ps1
# =====================================================================
$ErrorActionPreference = "Stop"

function Write-File([string]$Path, [string]$Content) {
    $full = Join-Path (Get-Location) $Path
    $dir  = Split-Path $full -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($full, $Content.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  wrote $Path" -ForegroundColor Green
}

if (-not (Test-Path "worker/src/scheduler.ts")) {
    throw "Run this from the repo root, after Phase 6 (worker/src/scheduler.ts not found)."
}

Write-Host "Phase 7: writing employee names..." -ForegroundColor Cyan

# ---------------------------------------------------------------- worker/migrations/0005_employee_names.sql
Write-File "worker/migrations/0005_employee_names.sql" @'
-- =============================================================
-- Phase 7 - employee names
-- employees.full_name = name shown in reports ('' = not known yet).
-- It follows the machine's name until someone edits it in the
-- dashboard (name_edited = 1); after that the machine never overwrites it.
-- =============================================================
ALTER TABLE employees ADD COLUMN machine_name TEXT;
ALTER TABLE employees ADD COLUMN name_edited INTEGER NOT NULL DEFAULT 0;
ALTER TABLE employees ADD COLUMN updated_at TEXT;
'@

# ---------------------------------------------------------------- worker/src/env.ts
Write-File "worker/src/env.ts" @'
export interface Env {
  DB: D1Database;
  /** Optional. When set, sign-up requires this code (set with: wrangler secret put SIGNUP_CODE). */
  SIGNUP_CODE?: string;
}

export const VERSION = "0.7.0-phase7";

/** Number of files in worker/migrations. The health check reports "degraded" until all are applied. */
export const EXPECTED_MIGRATIONS = 5;
'@

# ---------------------------------------------------------------- worker/src/routes/employees.ts
Write-File "worker/src/routes/employees.ts" @'
// Employees (dashboard). Lists every user ID known from the machine's user list
// or from attendance, and lets owners/admins set the name and department.
import type { Env } from "../env";
import { HttpError, json, readJson } from "../lib/http";
import { requireAuth, requireRole } from "../lib/auth";

export const USER_ID_RE = /^[A-Za-z0-9_.-]{1,32}$/;

function cleanOptional(value: unknown, field: string, max: number): string {
  if (value === undefined || value === null) return "";
  if (typeof value !== "string") throw new HttpError(400, `${field} must be text`);
  const v = value.trim().replace(/\s+/g, " ");
  if (v.length > max) throw new HttpError(400, `${field} is too long (max ${max})`);
  return v;
}

/** GET /api/employees */
export async function listEmployees(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  const { results } = await env.DB.prepare(
    `WITH ids AS (
       SELECT device_user_id FROM employees WHERE company_id = ?1
       UNION
       SELECT DISTINCT device_user_id FROM attendance_logs WHERE company_id = ?1
     )
     SELECT ids.device_user_id AS user_id,
            COALESCE(e.full_name, '') AS name,
            e.machine_name, COALESCE(e.department, '') AS department,
            COALESCE(e.name_edited, 0) AS name_edited,
            (SELECT MAX(l.punch_time) FROM attendance_logs l
              WHERE l.company_id = ?1 AND l.device_user_id = ids.device_user_id) AS last_punch
       FROM ids
       LEFT JOIN employees e ON e.company_id = ?1 AND e.device_user_id = ids.device_user_id
      ORDER BY CASE WHEN ids.device_user_id GLOB '[0-9]*' AND ids.device_user_id NOT GLOB '*[^0-9]*'
                    THEN CAST(ids.device_user_id AS INTEGER) END,
               ids.device_user_id`,
  ).bind(auth.companyId).all();

  const employees = results ?? [];
  const unnamed = employees.filter((e) => !(e as { name: string }).name).length;
  return json({ employees, total: employees.length, unnamed });
}

/**
 * PUT /api/employees/:userId  { name?, department? }
 * An empty name means "use the name from the machine again".
 */
export async function saveEmployee(request: Request, env: Env, userId: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  if (!USER_ID_RE.test(userId)) throw new HttpError(400, "Invalid user ID");

  const body = await readJson<Record<string, unknown>>(request);
  const name = cleanOptional(body.name, "Name", 80);
  const department = cleanOptional(body.department, "Department", 60);
  const now = new Date().toISOString();

  await env.DB.prepare(
    `INSERT INTO employees (id, company_id, device_user_id, full_name, department, name_edited, updated_at)
     VALUES (?1, ?2, ?3, ?4, NULLIF(?5, ''), ?6, ?7)
     ON CONFLICT (company_id, device_user_id) DO UPDATE SET
       full_name   = CASE WHEN ?6 = 1 THEN ?4 ELSE COALESCE(employees.machine_name, '') END,
       name_edited = ?6,
       department  = NULLIF(?5, ''),
       updated_at  = ?7`,
  ).bind(crypto.randomUUID(), auth.companyId, userId, name, department, name ? 1 : 0, now).run();

  const row = await env.DB.prepare(
    `SELECT device_user_id AS user_id, full_name AS name, machine_name,
            COALESCE(department, '') AS department, name_edited
       FROM employees WHERE company_id = ? AND device_user_id = ?`,
  ).bind(auth.companyId, userId).first();
  return json({ employee: row });
}
'@

# ---------------------------------------------------------------- worker/src/routes/connector.ts
Write-File "worker/src/routes/connector.ts" @'
// ZKT Connector API. Authenticated with "Authorization: Bearer zkc_..." (not a browser session).
// A connector can only see devices assigned to it, and jobs of those devices.
import type { Env } from "../env";
import { HttpError, json, readJson } from "../lib/http";
import { sha256Hex } from "../lib/crypto";
import { finalizeReportIfDone } from "../scheduler";

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
    `SELECT j.id, j.status, j.device_id, j.company_id, j.report_id
       FROM sync_jobs j JOIN devices d ON d.id = j.device_id
      WHERE j.id = ? AND j.company_id = ? AND d.connector_id = ?`,
  ).bind(jobId, ctx.companyId, ctx.connectorId)
    .first<{ id: string; status: string; device_id: string; company_id: string; report_id: string | null }>();
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

  // If this was the last machine for a scheduled report, the report is ready now.
  if (job.report_id) await finalizeReportIfDone(env, job.report_id);

  const summary = await env.DB.prepare(
    `SELECT id, status, records_fetched, records_inserted, records_skipped, finished_at, error_message
       FROM sync_jobs WHERE id = ?`,
  ).bind(job.id).first();
  return json({ job: summary });
}

// ------------------------------------------------------------------ POST /api/connector/jobs/:id/users
const MAX_USERS_PER_UPLOAD = 5000;
const USER_ID_RE = /^[A-Za-z0-9_.-]{1,32}$/;

/**
 * Receives the machine's user list ({ users: [{ user_id, name }] }).
 * New user IDs become employees; the machine name is stored and shown in
 * reports unless someone has edited that employee's name in the dashboard.
 */
export async function uploadUsers(request: Request, env: Env, jobId: string): Promise<Response> {
  const ctx = await requireConnector(request, env);
  const job = await loadOwnJob(env, ctx, jobId);
  if (job.status !== "running") throw new HttpError(409, `Job is ${job.status}, not running`);

  const body = await readJson<{ users?: unknown }>(request);
  if (!Array.isArray(body.users)) throw new HttpError(400, "Body must be { users: [...] }");
  if (body.users.length > MAX_USERS_PER_UPLOAD) throw new HttpError(413, `Send at most ${MAX_USERS_PER_UPLOAD} users`);

  const clean = new Map<string, string>();
  for (const raw of body.users) {
    if (!raw || typeof raw !== "object") continue;
    const u = raw as Record<string, unknown>;
    const id = String(u.user_id ?? "").trim();
    if (!USER_ID_RE.test(id)) continue;
    const name = typeof u.name === "string"
      ? u.name.replace(/[\u0000-\u001f\u007f]/g, "").replace(/\s+/g, " ").trim().slice(0, 80)
      : "";
    clean.set(id, name);
  }
  const rows = [...clean].map(([u, n]) => ({ u, n }));
  if (!rows.length) return json({ received: body.users.length, accepted: 0, named: 0, added: 0 });

  const before = await env.DB.prepare("SELECT COUNT(*) AS n FROM employees WHERE company_id = ?")
    .bind(job.company_id).first<{ n: number }>();

  // A blank name on the machine never wipes a name we already have.
  await env.DB.prepare(
    `INSERT INTO employees (id, company_id, device_user_id, full_name, machine_name, updated_at)
     SELECT lower(hex(randomblob(16))), ?1, json_extract(value, '$.u'),
            json_extract(value, '$.n'), NULLIF(json_extract(value, '$.n'), ''), ?2
       FROM json_each(?3) WHERE true
     ON CONFLICT (company_id, device_user_id) DO UPDATE SET
       machine_name = COALESCE(excluded.machine_name, employees.machine_name),
       full_name    = CASE
                        WHEN employees.name_edited = 1 THEN employees.full_name
                        WHEN excluded.machine_name IS NOT NULL THEN excluded.machine_name
                        ELSE employees.full_name
                      END,
       updated_at   = CASE
                        WHEN COALESCE(excluded.machine_name, '') <> COALESCE(employees.machine_name, '') THEN excluded.updated_at
                        ELSE employees.updated_at
                      END`,
  ).bind(job.company_id, new Date().toISOString(), JSON.stringify(rows)).run();

  const after = await env.DB.prepare("SELECT COUNT(*) AS n FROM employees WHERE company_id = ?")
    .bind(job.company_id).first<{ n: number }>();

  return json({
    received: body.users.length,
    accepted: rows.length,
    named: rows.filter((r) => r.n).length,
    added: (after?.n ?? 0) - (before?.n ?? 0),
  });
}
'@

# ---------------------------------------------------------------- worker/src/report.ts
Write-File "worker/src/report.ts" @'
// Builds the attendance Excel workbook for a date range (inclusive, company local dates).
import type { Env } from "./env";
import { STYLE, buildXlsx, type CellValue } from "./lib/xlsx";
import { addDays, excelDate, excelTime } from "./lib/dates";

const STATES: Record<number, string> = { 0: "Check-in", 1: "Check-out", 2: "Break-out", 3: "Break-in", 4: "OT-in", 5: "OT-out" };
const VERIFY: Record<number, string> = { 0: "Password", 1: "Fingerprint", 2: "Card", 15: "Face" };

interface PunchRow {
  device_user_id: string;
  punch_time: string;
  punch_state: number | null;
  verify_mode: number | null;
  device_name: string;
  full_name: string | null;
  department: string | null;
}

export interface ReportContext {
  companyId: string;
  companyName: string;
  timezone: string;
  /** Extra lines for the "Report Info" sheet (e.g. sync status of a scheduled report). */
  notes?: string[];
}

export interface ReportStats {
  punches: number;
  employees: number;
}

/** Numeric machine IDs go into Excel as numbers (no "number stored as text" warnings). */
function userCell(id: string): CellValue {
  return /^[1-9]\d{0,8}$/.test(id) ? Number(id) : id;
}

function byUserId(a: string, b: string): number {
  const na = Number(a);
  const nb = Number(b);
  if (Number.isFinite(na) && Number.isFinite(nb) && na !== nb) return na - nb;
  return a.localeCompare(b);
}

export async function attendanceStats(env: Env, companyId: string, from: string, to: string): Promise<ReportStats> {
  const row = await env.DB.prepare(
    `SELECT COUNT(*) AS punches, COUNT(DISTINCT device_user_id) AS employees
       FROM attendance_logs
      WHERE company_id = ? AND punch_time >= ? AND punch_time < ?`,
  ).bind(companyId, `${from} 00:00:00`, `${addDays(to, 1)} 00:00:00`).first<{ punches: number; employees: number }>();
  return { punches: row?.punches ?? 0, employees: row?.employees ?? 0 };
}

export async function buildAttendanceReport(env: Env, ctx: ReportContext, from: string, to: string) {
  const { results } = await env.DB.prepare(
    `SELECT l.device_user_id, l.punch_time, l.punch_state, l.verify_mode,
            d.name AS device_name, NULLIF(e.full_name, '') AS full_name, NULLIF(e.department, '') AS department
       FROM attendance_logs l
       JOIN devices d ON d.id = l.device_id
       LEFT JOIN employees e ON e.company_id = l.company_id AND e.device_user_id = l.device_user_id
      WHERE l.company_id = ? AND l.punch_time >= ? AND l.punch_time < ?
      ORDER BY l.punch_time, l.device_user_id`,
  ).bind(ctx.companyId, `${from} 00:00:00`, `${addDays(to, 1)} 00:00:00`).all<PunchRow>();
  const punches = results ?? [];

  // ---- Daily summary: one row per person per day
  type Day = { date: string; userId: string; name: string; dept: string; first: string; last: string; count: number };
  const days = new Map<string, Day>();
  for (const p of punches) {
    const date = p.punch_time.slice(0, 10);
    const time = p.punch_time.slice(11, 19);
    const key = `${date}|${p.device_user_id}`;
    const d = days.get(key);
    if (!d) {
      days.set(key, { date, userId: p.device_user_id, name: p.full_name ?? "", dept: p.department ?? "", first: time, last: time, count: 1 });
    } else {
      if (time < d.first) d.first = time;
      if (time > d.last) d.last = time;
      d.count++;
    }
  }
  const summary = [...days.values()].sort((a, b) => a.date.localeCompare(b.date) || byUserId(a.userId, b.userId));

  const summaryRows: CellValue[][] = [
    ["Date", "User ID", "Name", "Department", "First In", "Last Out", "Hours", "Punches", "Note"],
  ];
  for (const d of summary) {
    const single = d.count === 1;
    summaryRows.push([
      { v: excelDate(d.date), s: STYLE.date },
      userCell(d.userId),
      d.name,
      d.dept,
      { v: excelTime(d.first), s: STYLE.time },
      single ? null : { v: excelTime(d.last), s: STYLE.time },
      single ? null : { v: excelTime(d.last) - excelTime(d.first), s: STYLE.duration },
      d.count,
      single ? "Only one punch - check-out missing" : "",
    ]);
  }

  // ---- All punches
  const punchRows: CellValue[][] = [["Date", "Time", "User ID", "Name", "Type", "Verified By", "Device"]];
  for (const p of punches) {
    punchRows.push([
      { v: excelDate(p.punch_time.slice(0, 10)), s: STYLE.date },
      { v: excelTime(p.punch_time.slice(11, 19)), s: STYLE.time },
      userCell(p.device_user_id),
      p.full_name ?? "",
      p.punch_state === null ? "" : STATES[p.punch_state] ?? `State ${p.punch_state}`,
      p.verify_mode === null ? "" : VERIFY[p.verify_mode] ?? `Mode ${p.verify_mode}`,
      p.device_name,
    ]);
  }

  // ---- Info
  const employees = new Set(punches.map((p) => p.device_user_id)).size;
  const bold = (s: string) => ({ v: s, s: STYLE.bold });
  const infoRows: CellValue[][] = [
    [bold("Attendance Report"), ""],
    ["", ""],
    [bold("Company"), ctx.companyName],
    [bold("Period"), from === to ? from : `${from} to ${to}`],
    [bold("Generated"), `${new Date().toISOString().replace("T", " ").slice(0, 16)} UTC`],
    [bold("Time zone"), `${ctx.timezone} (times are as recorded by the machine)`],
    [bold("Employees with punches"), employees],
    [bold("Total punches"), punches.length],
    ["", ""],
    [bold("Notes"), "A day runs 00:00-23:59. Hours = Last Out - First In (breaks are not deducted)."],
    ["", "Names come from the machine's user list or the Employees page of the dashboard."],
    ...(ctx.notes ?? []).map((n) => ["", n] as CellValue[]),
  ];

  const bytes = buildXlsx([
    { name: "Daily Summary", widths: [13, 10, 24, 18, 10, 10, 8, 9, 34], rows: summaryRows, header: true },
    { name: "All Punches", widths: [13, 10, 10, 24, 12, 13, 18], rows: punchRows, header: true },
    { name: "Report Info", widths: [24, 70], rows: infoRows },
  ]);

  return { bytes, stats: { punches: punches.length, employees } };
}

export function reportFilename(companyName: string, from: string, to: string): string {
  const slug = companyName.replace(/[^A-Za-z0-9]+/g, "_").replace(/^_+|_+$/g, "").slice(0, 40) || "Company";
  return from === to ? `Attendance_${slug}_${from}.xlsx` : `Attendance_${slug}_${from}_to_${to}.xlsx`;
}

export function xlsxResponse(bytes: Uint8Array, filename: string): Response {
  return new Response(bytes, {
    headers: {
      "content-type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      "content-disposition": `attachment; filename="${filename}"`,
      "cache-control": "no-store",
    },
  });
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
.b-success, .b-active, .b-ready { color:#1a7f37; border-color:#1a7f37; }
.b-collecting { color:#b26b00; border-color:#b26b00; }
a.dl { display:inline-block; text-decoration:none; border-radius:8px; }
.b-failed, .b-revoked, .b-inactive { color:var(--error); border-color:var(--error); }
.b-running, .b-pending { color:#b26b00; border-color:#b26b00; }
.token { margin-top:14px; padding:12px; border:1px dashed var(--accent); border-radius:8px; font-size:13px; }
.token code { display:block; margin:8px 0; padding:8px; background:var(--bg); border-radius:6px; word-break:break-all; font-size:13px; }
.empty { color:var(--muted); font-size:13px; padding:10px 0; }
.dash .msg { margin-top:8px; min-height:0; }
.sm.primary:disabled { opacity:.3; }
input.cell { padding:6px 8px; border:1px solid var(--border); border-radius:6px; background:var(--bg); color:var(--text); font-size:13px; width:100%; min-width:140px; }
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
    <h2>Attendance reports</h2>
    <p class="sub" id="r_sched">Every 2 days an Excel report of the previous 2 days is prepared automatically.</p>
    <div class="tbl"><table>
      <thead><tr><th>Period</th><th>Status</th><th>Machines synced</th><th>Employees</th><th>Punches</th><th>Ready at</th><th>Note</th><th></th></tr></thead>
      <tbody id="r_rows"></tbody>
    </table></div>
    <div class="row" style="margin-top:16px">
      <div class="f" style="flex:0 1 170px"><label for="x_from">Custom export from</label><input id="x_from" type="date"></div>
      <div class="f" style="flex:0 1 170px"><label for="x_to">to</label><input id="x_to" type="date"></div>
      <button id="x_go" type="button">Download Excel</button>
    </div>
    <div class="msg" id="x_msg"></div>
  </div>

  <div class="card">
    <h2>Employees</h2>
    <p class="sub" id="e_sub">Names are read from the machine's user list on every sync. Type a name here to override it, or leave it blank to use the machine's name.</p>
    <div class="tbl"><table>
      <thead><tr><th>User ID</th><th>Name</th><th>Department</th><th>Name source</th><th>Last punch</th><th></th></tr></thead>
      <tbody id="e_rows"></tbody>
    </table></div>
    <div class="msg" id="e_msg"></div>
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

function fmtDate(d) { var p = d.split("-"); var m = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"][Number(p[1]) - 1]; return p[2] + " " + m + " " + p[0]; }
function period(a, b) { return a === b ? fmtDate(a) : fmtDate(a) + " \\u2013 " + fmtDate(b); }
function isoLocal(offsetDays) { var d = new Date(); d.setDate(d.getDate() + offsetDays); var p = function (n) { return String(n).padStart(2, "0"); }; return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate()); }

async function loadReports() {
  var data = await api("GET", "/api/reports");
  var s = data.schedule;
  document.getElementById("r_sched").textContent =
    "Every " + s.every_days + " days an Excel report of the previous " + s.every_days + " days is prepared automatically. Next: " +
    period(s.next_start, s.next_end) + ", ready on " + fmtDate(s.next_due) + " after " + String(s.hour).padStart(2, "0") + ":00 (" + s.timezone + ").";
  var tbody = document.getElementById("r_rows");
  tbody.textContent = "";
  if (!data.reports.length) emptyRow(tbody, 8, "No reports yet. The first one is created at the next scheduled time.");
  data.reports.forEach(function (r) {
    var tr = document.createElement("tr");
    tr.appendChild(td(period(r.period_start, r.period_end)));
    tr.appendChild(badge(r.status === "ready" ? "ready" : "collecting"));
    tr.appendChild(td(r.devices_synced + " / " + r.devices_total));
    tr.appendChild(td(r.status === "ready" ? r.employee_count : ""));
    tr.appendChild(td(r.status === "ready" ? r.punch_count : ""));
    tr.appendChild(td(when(r.ready_at)));
    tr.appendChild(td(r.note, r.note ? "warn" : ""));
    var actions = document.createElement("td");
    var a = document.createElement("a");
    a.href = "/api/reports/" + r.id + "/download";
    a.className = "sm primary dl";
    a.textContent = "Download Excel";
    actions.appendChild(a);
    tr.appendChild(actions);
    tbody.appendChild(tr);
  });
}

var empEditing = false;

function input(value, placeholder, maxLength) {
  var i = document.createElement("input");
  i.value = value || "";
  i.placeholder = placeholder || "";
  i.maxLength = maxLength;
  i.className = "cell";
  return i;
}

async function loadEmployees() {
  if (empEditing) return; // don't wipe what someone is typing
  var data = await api("GET", "/api/employees");
  document.getElementById("e_sub").textContent =
    data.total + " employee(s), " + data.unnamed + " without a name. Names are read from the machine's user list on every sync. " +
    (CAN_MANAGE ? "Type a name to override it, or leave it blank to use the machine's name." : "");
  var tbody = document.getElementById("e_rows");
  tbody.textContent = "";
  if (!data.employees.length) emptyRow(tbody, 6, "No employees yet. They appear after the first sync.");
  data.employees.forEach(function (e) {
    var tr = document.createElement("tr");
    tr.appendChild(td(e.user_id));
    var source = e.name_edited ? "Edited" : (e.machine_name ? "Machine" : "");
    if (!CAN_MANAGE) {
      tr.appendChild(td(e.name, e.name ? "" : "warn"));
      tr.appendChild(td(e.department));
      tr.appendChild(td(source));
      tr.appendChild(td(e.last_punch));
      tr.appendChild(document.createElement("td"));
      tbody.appendChild(tr);
      return;
    }
    var nameIn = input(e.name_edited ? e.name : "", e.machine_name || "Enter name", 80);
    var deptIn = input(e.department, "Department", 60);
    var c1 = document.createElement("td"); c1.appendChild(nameIn); tr.appendChild(c1);
    var c2 = document.createElement("td"); c2.appendChild(deptIn); tr.appendChild(c2);
    tr.appendChild(td(source, source ? "" : "warn"));
    tr.appendChild(td(e.last_punch));
    var save = btn("Save", true, async function () {
      save.disabled = true;
      try {
        await api("PUT", "/api/employees/" + encodeURIComponent(e.user_id), { name: nameIn.value, department: deptIn.value });
        showMsg("e_msg", "");
        empEditing = false;
        await loadEmployees();
      } catch (err) { showMsg("e_msg", err.message); save.disabled = false; }
    });
    save.disabled = true;
    var orig = nameIn.value + "|" + deptIn.value;
    [nameIn, deptIn].forEach(function (el) {
      el.addEventListener("input", function () { save.disabled = (nameIn.value + "|" + deptIn.value) === orig; empEditing = !save.disabled; });
      el.addEventListener("keydown", function (ev) { if (ev.key === "Enter" && !save.disabled) save.click(); });
    });
    var c3 = document.createElement("td"); c3.appendChild(save); tr.appendChild(c3);
    tbody.appendChild(tr);
  });
}

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
  try { await Promise.all([loadReports(), loadEmployees(), loadConnectors(), loadDevices(), loadJobs()]); }
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

document.getElementById("x_from").value = isoLocal(-2);
document.getElementById("x_to").value = isoLocal(-1);
document.getElementById("x_go").addEventListener("click", function () {
  var from = document.getElementById("x_from").value;
  var to = document.getElementById("x_to").value;
  if (!from || !to) { showMsg("x_msg", "Choose both dates."); return; }
  if (to < from) { showMsg("x_msg", "'to' must be on or after 'from'."); return; }
  showMsg("x_msg", "");
  location.href = "/api/export.xlsx?from=" + encodeURIComponent(from) + "&to=" + encodeURIComponent(to);
});

document.getElementById("logout").addEventListener("click", async function () {
  await fetch("/api/auth/logout", { method: "POST", headers: { "content-type": "application/json" }, body: "{}" });
  location.href = "/login";
});

refresh();
setInterval(function () { loadJobs(); loadReports(); }, 15000);
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
import { claimJob, completeJob, connectorConfig, uploadLogs, uploadUsers } from "./routes/connector";
import { listEmployees, saveEmployee } from "./routes/employees";
import { downloadReport, exportRange, listReports } from "./routes/reports";
import { runScheduler } from "./scheduler";
import { appPage, loginPage, signupPage } from "./pages";

export type { Env };

const ID = "([0-9a-f-]{36})";
const R_CONNECTOR_REVOKE = new RegExp(`^/api/connectors/${ID}/revoke$`);
const R_DEVICE_DEACTIVATE = new RegExp(`^/api/devices/${ID}/deactivate$`);
const R_DEVICE_SYNC = new RegExp(`^/api/devices/${ID}/sync$`);
const R_JOB_LOGS = new RegExp(`^/api/connector/jobs/${ID}/logs$`);
const R_JOB_COMPLETE = new RegExp(`^/api/connector/jobs/${ID}/complete$`);
const R_REPORT_DOWNLOAD = new RegExp(`^/api/reports/${ID}/download$`);
const R_JOB_USERS = new RegExp(`^/api/connector/jobs/${ID}/users$`);
const R_EMPLOYEE = /^\/api\/employees\/([^/]{1,100})$/;

function safeDecode(s: string): string {
  try {
    return decodeURIComponent(s);
  } catch {
    throw new HttpError(400, "Invalid URL");
  }
}

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
  if (pathname === "/api/reports" && method === "GET") return listReports(request, env);
  if (method === "GET" && (m = R_REPORT_DOWNLOAD.exec(pathname))) return downloadReport(request, env, m[1]);
  if (pathname === "/api/export.xlsx" && method === "GET") return exportRange(request, env);
  if (pathname === "/api/employees" && method === "GET") return listEmployees(request, env);
  if (method === "PUT" && (m = R_EMPLOYEE.exec(pathname))) return saveEmployee(request, env, safeDecode(m[1]));

  // ---- ZKT Connector API (Bearer token)
  if (pathname === "/api/connector/config" && method === "GET") return connectorConfig(request, env);
  if (pathname === "/api/connector/jobs/claim" && method === "POST") return claimJob(request, env);
  if (method === "POST" && (m = R_JOB_LOGS.exec(pathname))) return uploadLogs(request, env, m[1]);
  if (method === "POST" && (m = R_JOB_USERS.exec(pathname))) return uploadUsers(request, env, m[1]);
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

  // Cloudflare cron (see [triggers] in wrangler.toml): runs every hour.
  async scheduled(controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(runScheduler(env, new Date(controller.scheduledTime)));
  },
};
'@

# ---------------------------------------------------------------- connector/package.json
Write-File "connector/package.json" @'
{
  "name": "zkt-connector",
  "version": "0.7.0",
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

# ---------------------------------------------------------------- connector/src/api.js
Write-File "connector/src/api.js" @'
// HTTP client for the Attendance Fetcher Worker (connector side).
export const CONNECTOR_VERSION = "0.7.0";

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

  /** users: [{ user_id, name }] from the machine's user list */
  uploadUsers(jobId, users) {
    return this.request("POST", `/api/connector/jobs/${encodeURIComponent(jobId)}/users`, { users });
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

# ---------------------------------------------------------------- connector/src/zk/protocol.js
Write-File "connector/src/zk/protocol.js" @'
// ZKTeco "ZK6" TCP protocol helpers (port 4370).
// Packet layout, checksum, comm-key scrambling and time decoding follow the
// public pyzk / zkemsdk implementations.

export const CMD = Object.freeze({
  USERTEMP_RRQ: 9,       // read user list (with FCT_USER)
  OPTIONS_RRQ: 11,       // read a device option, e.g. ~SerialNumber
  ATTLOG_RRQ: 13,        // read all attendance records
  GET_FREE_SIZES: 50,    // read record counts / capacity
  GET_TIME: 201,         // read device clock
  CONNECT: 1000,
  EXIT: 1001,
  AUTH: 1102,            // send comm key
  PREPARE_DATA: 1500,    // device -> "large data follows"
  DATA: 1501,            // device -> data packet
  FREE_DATA: 1502,       // release the device's read buffer
  PREPARE_BUFFER: 1503,  // ask device to buffer a dataset
  READ_BUFFER: 1504,     // read a chunk of that buffer
  ACK_OK: 2000,
  ACK_ERROR: 2001,
  ACK_DATA: 2002,
  ACK_UNAUTH: 2005,
});

/**
 * The ONLY commands the connector is allowed to send. None of them change
 * anything on the machine: no clearing logs, no users, no time, no restart.
 */
export const READ_ONLY_COMMANDS = new Set([
  CMD.CONNECT, CMD.EXIT, CMD.AUTH,
  CMD.GET_FREE_SIZES, CMD.OPTIONS_RRQ, CMD.GET_TIME,
  CMD.PREPARE_BUFFER, CMD.READ_BUFFER, CMD.FREE_DATA,
]);

/** Datasets the connector may read through PREPARE_BUFFER: attendance log and user list only. */
export const FCT_USER = 5;
export const READ_ONLY_DATASETS = new Map([
  [CMD.ATTLOG_RRQ, 0],
  [CMD.USERTEMP_RRQ, FCT_USER],
]);

export const USHRT_MAX = 65535;
const TCP_MAGIC_1 = 0x5050;
const TCP_MAGIC_2 = 0x7d82;

export function checksum(buf) {
  let sum = 0;
  let i = 0;
  for (; i + 1 < buf.length; i += 2) {
    sum += buf[i] | (buf[i + 1] << 8);
    if (sum > USHRT_MAX) sum -= USHRT_MAX;
  }
  if (i < buf.length) sum += buf[buf.length - 1];
  while (sum > USHRT_MAX) sum -= USHRT_MAX;
  sum = ~sum;
  while (sum < 0) sum += USHRT_MAX;
  return sum & 0xffff;
}

/** Builds one TCP frame. Returns the bytes and the reply id that was used. */
export function buildFrame(command, sessionId, replyId, data = Buffer.alloc(0)) {
  const body = Buffer.alloc(8 + data.length);
  body.writeUInt16LE(command, 0);
  body.writeUInt16LE(0, 2);
  body.writeUInt16LE(sessionId, 4);
  body.writeUInt16LE(replyId, 6);
  data.copy(body, 8);

  const cs = checksum(body);
  let nextReply = replyId + 1;
  if (nextReply >= USHRT_MAX) nextReply -= USHRT_MAX;
  body.writeUInt16LE(cs, 2);
  body.writeUInt16LE(nextReply, 6);

  const top = Buffer.alloc(8);
  top.writeUInt16LE(TCP_MAGIC_1, 0);
  top.writeUInt16LE(TCP_MAGIC_2, 2);
  top.writeUInt32LE(body.length, 4);
  return Buffer.concat([top, body]);
}

/**
 * Splits a byte stream into frames. Returns { frames, rest }.
 * Throws if the stream is not ZKTeco TCP.
 */
export function parseFrames(buffer) {
  const frames = [];
  let buf = buffer;
  while (buf.length >= 8) {
    if (buf.readUInt16LE(0) !== TCP_MAGIC_1 || buf.readUInt16LE(2) !== TCP_MAGIC_2) {
      throw new Error("Invalid packet from device (not a ZKTeco TCP response)");
    }
    const len = buf.readUInt32LE(4);
    if (len < 8 || len > 64 * 1024 * 1024) throw new Error(`Invalid packet length from device: ${len}`);
    if (buf.length < 8 + len) break;
    const p = buf.subarray(8, 8 + len);
    frames.push({
      command: p.readUInt16LE(0),
      sessionId: p.readUInt16LE(4),
      replyId: p.readUInt16LE(6),
      data: Buffer.from(p.subarray(8)),
    });
    buf = buf.subarray(8 + len);
  }
  return { frames, rest: buf };
}

/** Scrambles the numeric comm key with the session id (zkemsdk MakeKey). */
export function makeCommKey(key, sessionId, ticks = 50) {
  const k0 = Number(key) >>> 0;
  let k = 0;
  for (let i = 0; i < 32; i++) {
    k = ((k2(k) | ((k0 >>> i) & 1)) >>> 0);
  }
  k = (k + Number(sessionId)) % 0x100000000;

  const b = Buffer.alloc(4);
  b.writeUInt32LE(k >>> 0, 0);
  const x = [b[0] ^ 0x5a, b[1] ^ 0x4b, b[2] ^ 0x53, b[3] ^ 0x4f]; // 'Z','K','S','O'
  const swapped = [x[2], x[3], x[0], x[1]];                          // swap the two 16-bit halves
  const B = ticks & 0xff;
  return Buffer.from([swapped[0] ^ B, swapped[1] ^ B, B, swapped[3] ^ B]);

  function k2(v) { return (v << 1) >>> 0; }
}

/** Device timestamps are packed local times (zkemsdk DecodeTime). */
export function decodeTime(t) {
  let v = t >>> 0;
  const second = v % 60; v = Math.floor(v / 60);
  const minute = v % 60; v = Math.floor(v / 60);
  const hour = v % 24; v = Math.floor(v / 24);
  const day = (v % 31) + 1; v = Math.floor(v / 31);
  const month = (v % 12) + 1; v = Math.floor(v / 12);
  const year = v + 2000;
  const p = (n) => String(n).padStart(2, "0");
  return `${year}-${p(month)}-${p(day)} ${p(hour)}:${p(minute)}:${p(second)}`;
}

/** Inverse of decodeTime (used by the mock device in tests). */
export function encodeTime(ts) {
  const m = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$/.exec(ts);
  if (!m) throw new Error(`Bad timestamp ${ts}`);
  const [y, mo, d, h, mi, s] = m.slice(1).map(Number);
  return ((((y - 2000) * 12 * 31 + (mo - 1) * 31 + (d - 1)) * 24 + h) * 60 + mi) * 60 + s;
}

/**
 * Parses the attendance buffer. Record layout depends on firmware:
 *  40 bytes (TFT devices such as K40/K50), 16 bytes, or 8 bytes (old models).
 */
export function parseAttendance(buffer, recordCount) {
  if (buffer.length < 4 || recordCount <= 0) return { recordSize: 0, records: [] };
  const total = buffer.readUInt32LE(0);
  const body = buffer.subarray(4, 4 + total);
  const ratio = total / recordCount;
  const recordSize = ratio === 8 ? 8 : ratio === 16 ? 16 : 40;

  const records = [];
  for (let off = 0; off + recordSize <= body.length; off += recordSize) {
    const r = body.subarray(off, off + recordSize);
    if (recordSize === 40) {
      const uid = r.readUInt16LE(0);
      const userId = r.subarray(2, 26).toString("latin1").split("\0")[0].trim();
      records.push({
        user_id: userId || String(uid),
        timestamp: decodeTime(r.readUInt32LE(27)),
        state: r.readUInt8(31),
        verify_mode: r.readUInt8(26),
      });
    } else if (recordSize === 16) {
      records.push({
        user_id: String(r.readUInt32LE(0)),
        timestamp: decodeTime(r.readUInt32LE(4)),
        state: r.readUInt8(9),
        verify_mode: r.readUInt8(8),
      });
    } else {
      records.push({
        user_id: String(r.readUInt16LE(0)), // 8-byte format only stores the internal uid
        timestamp: decodeTime(r.readUInt32LE(3)),
        state: r.readUInt8(7),
        verify_mode: r.readUInt8(2),
      });
    }
  }
  return { recordSize, records };
}

/**
 * Parses the user list. Only the user ID and name are kept; passwords and
 * card numbers stored on the machine are never read out of the buffer.
 * Record layout: 72 bytes (TFT devices such as K40/K50) or 28 bytes (old models).
 */
export function parseUsers(buffer, userCount) {
  if (buffer.length < 4 || userCount <= 0) return { recordSize: 0, users: [] };
  const total = buffer.readUInt32LE(0);
  const body = buffer.subarray(4, 4 + total);
  const recordSize = total / userCount === 28 ? 28 : 72;
  const text = (b) => b.toString("utf8").split("\0")[0].replace(/\uFFFD/g, "").trim();

  const users = [];
  for (let off = 0; off + recordSize <= body.length; off += recordSize) {
    const r = body.subarray(off, off + recordSize);
    if (recordSize === 72) {
      users.push({ uid: r.readUInt16LE(0), user_id: text(r.subarray(48, 72)) || String(r.readUInt16LE(0)), name: text(r.subarray(11, 35)) });
    } else {
      users.push({ uid: r.readUInt16LE(0), user_id: String(r.readUInt32LE(24)), name: text(r.subarray(8, 16)) });
    }
  }
  return { recordSize, users };
}
'@

# ---------------------------------------------------------------- connector/src/zk/client.js
Write-File "connector/src/zk/client.js" @'
// Read-only ZKTeco TCP client. Every outgoing command is checked against
// READ_ONLY_COMMANDS, so this client cannot clear logs or change the machine.
import net from "node:net";
import {
  CMD, READ_ONLY_COMMANDS, READ_ONLY_DATASETS, USHRT_MAX,
  buildFrame, makeCommKey, parseFrames, parseAttendance, parseUsers, decodeTime,
} from "./protocol.js";

const MAX_CHUNK = 0xffc0; // max bytes per READ_BUFFER request over TCP

class FrameReader {
  constructor(socket) {
    this.buf = Buffer.alloc(0);
    this.frames = [];
    this.waiters = [];
    this.error = null;
    socket.on("data", (chunk) => {
      this.buf = Buffer.concat([this.buf, chunk]);
      try {
        const { frames, rest } = parseFrames(this.buf);
        this.buf = rest;
        for (const f of frames) {
          const w = this.waiters.shift();
          if (w) w.resolve(f);
          else this.frames.push(f);
        }
      } catch (err) {
        this.fail(err);
        socket.destroy();
      }
    });
    socket.on("error", (err) => this.fail(err));
    socket.on("close", () => this.fail(new Error("Connection closed by device")));
  }

  fail(err) {
    if (this.error) return;
    this.error = err;
    for (const w of this.waiters.splice(0)) w.reject(err);
  }

  next(timeoutMs) {
    if (this.frames.length) return Promise.resolve(this.frames.shift());
    if (this.error) return Promise.reject(this.error);
    return new Promise((resolve, reject) => {
      const w = {
        resolve: (f) => { clearTimeout(timer); resolve(f); },
        reject: (e) => { clearTimeout(timer); reject(e); },
      };
      const timer = setTimeout(() => {
        const i = this.waiters.indexOf(w);
        if (i >= 0) this.waiters.splice(i, 1);
        reject(new Error(`Device did not respond within ${timeoutMs} ms`));
      }, timeoutMs);
      this.waiters.push(w);
    });
  }
}

export class ZkClient {
  constructor({ ip, port = 4370, commKey = 0, timeoutMs = 10000 }) {
    this.ip = ip;
    this.port = Number(port);
    this.commKey = Number(commKey) || 0;
    this.timeoutMs = Number(timeoutMs) || 10000;
    this.socket = null;
    this.reader = null;
    this.sessionId = 0;
    this.replyId = USHRT_MAX - 1;
  }

  async connect() {
    this.socket = await new Promise((resolve, reject) => {
      const s = net.createConnection({ host: this.ip, port: this.port });
      const timer = setTimeout(() => {
        s.destroy();
        reject(new Error(`Cannot reach ${this.ip}:${this.port} (timeout after ${this.timeoutMs} ms). Check the IP, cable/Wi-Fi and that this PC is on the same network.`));
      }, this.timeoutMs);
      s.once("connect", () => { clearTimeout(timer); resolve(s); });
      s.once("error", (err) => {
        clearTimeout(timer);
        reject(new Error(`Cannot connect to ${this.ip}:${this.port}: ${err.code ?? err.message}`));
      });
    });
    this.socket.setNoDelay(true);
    this.reader = new FrameReader(this.socket);

    const res = await this.command(CMD.CONNECT);
    this.sessionId = res.sessionId;
    if (res.command === CMD.ACK_UNAUTH) {
      const auth = await this.command(CMD.AUTH, makeCommKey(this.commKey, this.sessionId));
      if (auth.command !== CMD.ACK_OK) {
        throw new Error("Device rejected the comm key. Check Menu > COMM > Comm Key on the machine and the device settings in the dashboard.");
      }
    } else if (res.command !== CMD.ACK_OK) {
      throw new Error(`Device refused the connection (response ${res.command})`);
    }
  }

  async command(cmd, data = Buffer.alloc(0)) {
    if (!READ_ONLY_COMMANDS.has(cmd)) {
      throw new Error(`Blocked: command ${cmd} is not on the read-only allowlist`);
    }
    if (!this.socket || !this.reader) throw new Error("Not connected");
    this.socket.write(buildFrame(cmd, this.sessionId, this.replyId, data));
    const res = await this.reader.next(this.timeoutMs);
    this.replyId = res.replyId;
    return res;
  }

  async getSizes() {
    const res = await this.command(CMD.GET_FREE_SIZES);
    if (res.command !== CMD.ACK_OK || res.data.length < 80) {
      throw new Error(`Could not read record counts (response ${res.command})`);
    }
    const f = (i) => res.data.readInt32LE(i * 4);
    return { users: f(4), fingerprints: f(6), records: f(8), recordsCapacity: f(16) };
  }

  async getSerialNumber() {
    const res = await this.command(CMD.OPTIONS_RRQ, Buffer.from("~SerialNumber\0", "latin1"));
    if (res.command !== CMD.ACK_OK) return null;
    const text = res.data.toString("latin1").split("\0")[0];
    const eq = text.indexOf("=");
    return eq >= 0 ? text.slice(eq + 1).trim() || null : null;
  }

  async getTime() {
    const res = await this.command(CMD.GET_TIME);
    if (res.command !== CMD.ACK_OK || res.data.length < 4) return null;
    return decodeTime(res.data.readUInt32LE(0));
  }

  async readChunk(start, size) {
    const req = Buffer.alloc(8);
    req.writeInt32LE(start, 0);
    req.writeInt32LE(size, 4);
    const res = await this.command(CMD.READ_BUFFER, req);

    if (res.command === CMD.DATA) return res.data;
    if (res.command === CMD.PREPARE_DATA) {
      const expected = res.data.readUInt32LE(0);
      const parts = [];
      let got = 0;
      while (got < expected) {
        const f = await this.reader.next(this.timeoutMs);
        if (f.command !== CMD.DATA) throw new Error(`Unexpected packet ${f.command} while reading data`);
        parts.push(f.data);
        got += f.data.length;
      }
      const ack = await this.reader.next(this.timeoutMs);
      if (ack.command !== CMD.ACK_OK) throw new Error(`Device did not confirm chunk (response ${ack.command})`);
      return Buffer.concat(parts).subarray(0, expected);
    }
    throw new Error(`Device refused chunk read (response ${res.command})`);
  }

  async readWithBuffer(dataCommand, onProgress) {
    if (!READ_ONLY_DATASETS.has(dataCommand)) {
      throw new Error(`Blocked: dataset ${dataCommand} is not on the read-only allowlist`);
    }
    const req = Buffer.alloc(11);
    req.writeInt8(1, 0);
    req.writeInt16LE(dataCommand, 1);
    req.writeInt32LE(READ_ONLY_DATASETS.get(dataCommand), 3);
    req.writeInt32LE(0, 7);
    const res = await this.command(CMD.PREPARE_BUFFER, req);

    if (res.command === CMD.DATA) return res.data; // small dataset sent directly
    if (res.command !== CMD.ACK_OK || res.data.length < 5) {
      throw new Error(`Device does not support buffered reads (response ${res.command})`);
    }

    const size = res.data.readUInt32LE(1);
    const parts = [];
    let start = 0;
    while (start < size) {
      const len = Math.min(MAX_CHUNK, size - start);
      parts.push(await this.readChunk(start, len));
      start += len;
      if (onProgress) onProgress(start, size);
    }
    await this.command(CMD.FREE_DATA);
    return Buffer.concat(parts);
  }

  /** Reads every attendance record stored on the machine. Nothing is deleted. */
  async getAttendance(onProgress, sizes) {
    const s = sizes ?? (await this.getSizes());
    if (s.records <= 0) return { sizes: s, recordSize: 0, records: [] };
    const buffer = await this.readWithBuffer(CMD.ATTLOG_RRQ, onProgress);
    const { recordSize, records } = parseAttendance(buffer, s.records);
    return { sizes: s, recordSize, records };
  }

  /** Reads the user list (user ID + name only). */
  async getUsers(sizes) {
    const s = sizes ?? (await this.getSizes());
    if (s.users <= 0) return [];
    const buffer = await this.readWithBuffer(CMD.USERTEMP_RRQ);
    return parseUsers(buffer, s.users).users;
  }

  async disconnect() {
    if (!this.socket) return;
    try {
      if (!this.reader.error) {
        this.socket.write(buildFrame(CMD.EXIT, this.sessionId, this.replyId));
        await Promise.race([this.reader.next(2000), new Promise((r) => setTimeout(r, 2000))]).catch(() => {});
      }
    } finally {
      this.socket.destroy();
      this.socket = null;
    }
  }
}

/**
 * Connect, read everything we need, always disconnect.
 * The user list is optional: if the machine refuses it, attendance is still returned
 * (usersError explains why the names are missing).
 */
export async function readDevice(options, onProgress) {
  const client = new ZkClient(options);
  try {
    await client.connect();
    const serialNumber = await client.getSerialNumber();
    const deviceTime = await client.getTime();
    const sizes = await client.getSizes();

    let users = [];
    let usersError = null;
    try {
      users = await client.getUsers(sizes);
    } catch (err) {
      usersError = err.message;
    }

    const { recordSize, records } = await client.getAttendance(onProgress, sizes);

    // Old 8-byte records only store the machine's internal number: map it to the user ID.
    if (recordSize === 8 && users.length) {
      const byUid = new Map(users.map((u) => [String(u.uid), u.user_id]));
      for (const r of records) r.user_id = byUid.get(r.user_id) ?? r.user_id;
    }

    return {
      serialNumber, deviceTime, sizes, recordSize, records,
      users: users.map((u) => ({ user_id: u.user_id, name: u.name })),
      usersError,
    };
  } finally {
    await client.disconnect();
  }
}
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

  // 3) Employee names from the machine (best effort: never fails the sync)
  if (result.users.length) {
    try {
      const res = await withRetry("Uploading names", () => api.uploadUsers(job.id, result.users));
      log.info(`Names: ${result.users.length} users on machine, ${res.named} with a name (${res.added} new employees)`);
    } catch (err) {
      log.warn(`Could not upload employee names: ${err.message}`);
    }
  } else if (result.usersError) {
    log.warn(`Could not read user names from the machine: ${result.usersError}`);
  }

  // 4) Complete
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

# ---------------------------------------------------------------- connector/src/read-device.js
Write-File "connector/src/read-device.js" @'
// Phase 4: read the attendance log from the machine (READ-ONLY) and show a summary.
// Nothing is uploaded and nothing on the machine is changed or cleared.
//
//   npm run read-device                         -> device from the dashboard (via CONNECTOR_TOKEN)
//   npm run read-device -- --device "K40PIA"    -> pick one when the connector has several
//   npm run read-device -- --ip 192.168.10.21   -> skip the dashboard, connect directly
//   npm run read-device -- --csv                -> also save all punches to output/*.csv
import "dotenv/config";
import fs from "node:fs";
import path from "node:path";
import { readDevice } from "./zk/client.js";
import { clientFromEnv, CONNECTOR_VERSION } from "./api.js";

const STATES = { 0: "Check-in", 1: "Check-out", 2: "Break-out", 3: "Break-in", 4: "OT-in", 5: "OT-out" };
const VERIFY = { 0: "Password", 1: "Fingerprint", 2: "Card", 15: "Face" };

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) continue;
    const key = a.slice(2);
    const next = argv[i + 1];
    if (next !== undefined && !next.startsWith("--")) { args[key] = next; i++; }
    else args[key] = true;
  }
  return args;
}

async function resolveDevice(args) {
  const timeoutMs = Number(process.env.DEVICE_TIMEOUT_MS) || 10000;
  if (args.ip) {
    return { name: "(command line)", ip: args.ip, port: Number(args.port) || 4370, commKey: Number(args.key) || 0, timeoutMs, source: "command line" };
  }
  if (process.env.CONNECTOR_TOKEN && process.env.CONNECTOR_TOKEN.startsWith("zkc_")) {
    const config = await clientFromEnv().getConfig();
    const devices = config.devices;
    if (!devices.length) throw new Error("No devices are assigned to this connector in the dashboard.");
    let d = devices[0];
    if (args.device) {
      d = devices.find((x) => x.name.toLowerCase() === String(args.device).toLowerCase());
      if (!d) throw new Error(`No device named "${args.device}". Assigned: ${devices.map((x) => x.name).join(", ")}`);
    } else if (devices.length > 1) {
      console.log(`Connector has ${devices.length} devices; using "${d.name}". Use --device "<name>" to choose.`);
    }
    return { name: d.name, ip: d.ip_address, port: d.port, commKey: d.comm_key, timeoutMs, source: "dashboard" };
  }
  if (process.env.DEVICE_IP) {
    return {
      name: "(.env)", ip: process.env.DEVICE_IP, port: Number(process.env.DEVICE_PORT) || 4370,
      commKey: Number(process.env.DEVICE_COMM_KEY) || 0, timeoutMs, source: ".env",
    };
  }
  throw new Error("No device configured. Set CONNECTOR_TOKEN in .env, or pass --ip 192.168.10.21");
}

function clockDifference(deviceTime) {
  if (!deviceTime) return "";
  const dev = new Date(deviceTime.replace(" ", "T")).getTime();
  const diff = Math.round((dev - Date.now()) / 1000);
  const warn = Math.abs(diff) > 120 ? "  <-- machine clock is off, punches will carry this error" : "";
  return `  (difference vs this PC: ${diff >= 0 ? "+" : ""}${diff} s)${warn}`;
}

function toCsv(records) {
  const lines = ["user_id,timestamp,state,state_label,verify_mode,verify_label"];
  for (const r of records) {
    lines.push([r.user_id, r.timestamp, r.state, STATES[r.state] ?? "", r.verify_mode, VERIFY[r.verify_mode] ?? ""]
      .map((v) => `"${String(v).replace(/"/g, '""')}"`).join(","));
  }
  return lines.join("\r\n") + "\r\n";
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  console.log(`ZKT Connector ${CONNECTOR_VERSION} - read device (read-only, nothing is changed on the machine)\n`);

  const device = await resolveDevice(args);
  console.log(`Device       : ${device.name}  ${device.ip}:${device.port}  comm key ${device.commKey}  [from ${device.source}]`);

  const started = Date.now();
  const result = await readDevice(device, (done, total) => {
    process.stdout.write(`\rReading      : ${Math.floor((done / total) * 100)}% (${done}/${total} bytes)`);
  });
  if (result.sizes.records > 0) process.stdout.write("\n");
  const seconds = ((Date.now() - started) / 1000).toFixed(1);

  const { records, sizes } = result;
  console.log(`Serial number: ${result.serialNumber ?? "(not reported)"}`);
  console.log(`Device clock : ${result.deviceTime ?? "(not reported)"}${clockDifference(result.deviceTime)}`);
  console.log(`Stored       : ${sizes.records} punches (capacity ${sizes.recordsCapacity || "?"}), ${sizes.users} users, record format ${result.recordSize || "-"} bytes`);
  console.log(`Read         : ${records.length} punches in ${seconds} s`);

  if (result.users.length) {
    const named = result.users.filter((u) => u.name);
    console.log(`Names        : ${named.length} of ${result.users.length} users have a name on the machine`);
    for (const u of result.users.slice(0, 10)) console.log(`  user ${u.user_id.padEnd(8)} ${u.name || "(no name on machine)"}`);
    if (result.users.length > 10) console.log(`  ... and ${result.users.length - 10} more`);
  } else if (result.usersError) {
    console.log(`Names        : could not read user list (${result.usersError})`);
  }

  if (!records.length) {
    console.log("\nThe machine has no attendance records.");
    return;
  }

  const sorted = [...records].sort((a, b) => a.timestamp.localeCompare(b.timestamp));
  const users = new Set(records.map((r) => r.user_id));
  console.log(`Range        : ${sorted[0].timestamp}  ->  ${sorted.at(-1).timestamp}`);
  console.log(`Users        : ${users.size} distinct user IDs`);

  console.log("\nLatest 10 punches:");
  for (const r of sorted.slice(-10)) {
    console.log(`  ${r.timestamp}  user ${r.user_id.padEnd(8)} ${String(STATES[r.state] ?? `state ${r.state}`).padEnd(10)} ${VERIFY[r.verify_mode] ?? `verify ${r.verify_mode}`}`);
  }

  if (args.csv) {
    const outDir = path.resolve("output");
    fs.mkdirSync(outDir, { recursive: true });
    const stamp = new Date().toISOString().replace(/[-:]/g, "").slice(0, 13);
    const file = typeof args.csv === "string" ? path.resolve(args.csv) : path.join(outDir, `attendance-${result.serialNumber ?? device.ip}-${stamp}.csv`);
    fs.writeFileSync(file, toCsv(sorted));
    console.log(`\nSaved ${sorted.length} punches to ${file}`);
  }
  console.log("\nNothing was uploaded (this command only reads). Use \"npm start\" or Sync now to import.");
}

main().catch((err) => {
  console.error(`\nFAILED: ${err.message}`);
  if (/Cannot (connect|reach)|did not respond/.test(err.message)) {
    console.error("Checks: 1) ping the machine's IP from this PC  2) this PC is on the same network (e.g. 192.168.10.x)");
    console.error("        3) port 4370 is not blocked  4) close ZKTime/ZKBio or other software connected to the machine, then retry");
  }
  process.exitCode = 1;
});
'@

# ---------------------------------------------------------------- connector/test/mock-device.js
Write-File "connector/test/mock-device.js" @'
// A fake ZKTeco machine for testing without hardware.
//   npm run mock-device              -> listens on 127.0.0.1:4370 with 500 sample punches
//   then: npm run read-device -- --ip 127.0.0.1
import net from "node:net";
import { pathToFileURL } from "node:url";
import { CMD, buildFrame, parseFrames, makeCommKey, encodeTime } from "../src/zk/protocol.js";

export function sampleRecords(count, startDay = "2026-09-01") {
  const base = new Date(`${startDay}T00:00:00Z`).getTime();
  const p = (n) => String(n).padStart(2, "0");
  const out = [];
  for (let i = 0; i < count; i++) {
    const day = Math.floor(i / 50);
    const user = (i % 25) + 1;
    const isOut = (i % 50) >= 25;
    const d = new Date(base + day * 86400000);
    const h = isOut ? 17 + (user % 2) : 8 + (user % 2);
    const mi = (user * 7 + day) % 60;
    out.push({
      user_id: String(user),
      timestamp: `${d.getUTCFullYear()}-${p(d.getUTCMonth() + 1)}-${p(d.getUTCDate())} ${p(h)}:${p(mi)}:${p(i % 60)}`,
      state: isOut ? 1 : 0,
      verify_mode: 1,
    });
  }
  return out;
}

/** Users for the mock: one per distinct user ID in the records, named "Employee <id>". */
export function sampleUsers(records) {
  const ids = [...new Set(records.map((r) => r.user_id))];
  return ids.map((id, i) => ({ uid: i + 1, user_id: id, name: `Employee ${id}`, password: "1234", card: 99887766 }));
}

export function encodeUsers(users, recordSize = 72) {
  const body = Buffer.alloc(users.length * recordSize);
  users.forEach((u, i) => {
    const o = i * recordSize;
    if (recordSize === 72) {
      body.writeUInt16LE(u.uid, o);
      body.writeUInt8(0, o + 2);
      body.write(u.password ?? "", o + 3, 8, "utf8");
      body.write(u.name ?? "", o + 11, 24, "utf8");
      body.writeUInt32LE(u.card ?? 0, o + 35);
      body.write("1", o + 40, 7, "utf8");
      body.write(u.user_id, o + 48, 24, "utf8");
    } else {
      body.writeUInt16LE(u.uid, o);
      body.write(u.password ?? "", o + 3, 5, "utf8");
      body.write(u.name ?? "", o + 8, 8, "utf8");
      body.writeUInt32LE(u.card ?? 0, o + 16);
      body.writeUInt8(1, o + 21);
      body.writeUInt32LE(Number(u.user_id), o + 24);
    }
  });
  const total = Buffer.alloc(4);
  total.writeUInt32LE(body.length, 0);
  return Buffer.concat([total, body]);
}

export function encodeRecords(records, recordSize = 40) {
  const body = Buffer.alloc(records.length * recordSize);
  records.forEach((r, i) => {
    const o = i * recordSize;
    if (recordSize === 40) {
      body.writeUInt16LE(Number(r.user_id) || i + 1, o);
      body.write(r.user_id, o + 2, 24, "latin1");
      body.writeUInt8(r.verify_mode, o + 26);
      body.writeUInt32LE(encodeTime(r.timestamp), o + 27);
      body.writeUInt8(r.state, o + 31);
    } else if (recordSize === 16) {
      body.writeUInt32LE(Number(r.user_id), o);
      body.writeUInt32LE(encodeTime(r.timestamp), o + 4);
      body.writeUInt8(r.verify_mode, o + 8);
      body.writeUInt8(r.state, o + 9);
    } else {
      body.writeUInt16LE(Number(r.user_id), o);
      body.writeUInt8(r.verify_mode, o + 2);
      body.writeUInt32LE(encodeTime(r.timestamp), o + 3);
      body.writeUInt8(r.state, o + 7);
    }
  });
  const total = Buffer.alloc(4);
  total.writeUInt32LE(body.length, 0);
  return Buffer.concat([total, body]);
}

/**
 * options: { records, recordSize=40, users, userRecordSize=72, refuseUsers, commKey=0, directLimit=1024, dataFrameSize=Infinity, serial }
 * Returns { server, port, received } - received lists every command code the client sent.
 */
export function startMockDevice(options = {}) {
  const records = options.records ?? sampleRecords(500);
  const recordSize = options.recordSize ?? 40;
  const commKey = options.commKey ?? 0;
  const directLimit = options.directLimit ?? 1024;
  const dataFrameSize = options.dataFrameSize ?? Infinity; // real devices send each chunk as one DATA packet
  const serial = options.serial ?? "MOCK0000K50";
  const users = options.users ?? sampleUsers(records);
  const userRecordSize = options.userRecordSize ?? 72;
  const received = [];
  const SESSION = 0x2a3b;

  const server = net.createServer((sock) => {
    let buf = Buffer.alloc(0);
    let authed = commKey === 0;
    let buffered = null;

    const reply = (command, replyId, data = Buffer.alloc(0)) => {
      // buildFrame bumps the reply id; pass replyId - 1 so the device echoes the client's id.
      const prev = replyId === 0 ? 65534 : replyId - 1;
      return buildFrame(command, SESSION, prev, data);
    };

    sock.on("data", (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      const { frames, rest } = parseFrames(buf);
      buf = rest;
      for (const f of frames) {
        received.push(f.command);
        const out = [];
        if (f.command === CMD.CONNECT) {
          out.push(reply(authed ? CMD.ACK_OK : CMD.ACK_UNAUTH, f.replyId));
        } else if (f.command === CMD.AUTH) {
          authed = f.data.equals(makeCommKey(commKey, SESSION));
          out.push(reply(authed ? CMD.ACK_OK : CMD.ACK_UNAUTH, f.replyId));
        } else if (!authed) {
          out.push(reply(CMD.ACK_UNAUTH, f.replyId));
        } else if (f.command === CMD.GET_FREE_SIZES) {
          const d = Buffer.alloc(92);
          d.writeInt32LE(users.length, 4 * 4);
          d.writeInt32LE(50, 6 * 4);
          d.writeInt32LE(records.length, 8 * 4);
          d.writeInt32LE(100000, 16 * 4);
          out.push(reply(CMD.ACK_OK, f.replyId, d));
        } else if (f.command === CMD.OPTIONS_RRQ) {
          out.push(reply(CMD.ACK_OK, f.replyId, Buffer.from(`~SerialNumber=${serial}\0`, "latin1")));
        } else if (f.command === CMD.GET_TIME) {
          const d = Buffer.alloc(4);
          d.writeUInt32LE(encodeTime("2026-10-05 20:30:00"), 0);
          out.push(reply(CMD.ACK_OK, f.replyId, d));
        } else if (f.command === CMD.PREPARE_BUFFER) {
          const dataset = f.data.readInt16LE(1);
          received.push(`buffer:${dataset}`);
          if (dataset === CMD.ATTLOG_RRQ) {
            buffered = encodeRecords(records, recordSize);
          } else if (dataset === CMD.USERTEMP_RRQ && f.data.readInt32LE(3) === 5 && !options.refuseUsers) {
            buffered = encodeUsers(users, userRecordSize);
          } else {
            out.push(reply(CMD.ACK_ERROR, f.replyId));
            sock.write(Buffer.concat(out));
            continue;
          }
          if (buffered.length <= directLimit) {
            out.push(reply(CMD.DATA, f.replyId, buffered));
          } else {
            const d = Buffer.alloc(9);
            d.writeUInt32LE(buffered.length, 1);
            out.push(reply(CMD.ACK_OK, f.replyId, d));
          }
        } else if (f.command === CMD.READ_BUFFER) {
          const start = f.data.readInt32LE(0);
          const len = f.data.readInt32LE(4);
          const slice = buffered.subarray(start, start + len);
          const head = Buffer.alloc(8);
          head.writeUInt32LE(slice.length, 0);
          out.push(reply(CMD.PREPARE_DATA, f.replyId, head));
          for (let o = 0; o < slice.length; o += dataFrameSize) {
            out.push(reply(CMD.DATA, f.replyId, slice.subarray(o, o + dataFrameSize)));
          }
          out.push(reply(CMD.ACK_OK, f.replyId));
        } else if (f.command === CMD.FREE_DATA) {
          buffered = null;
          out.push(reply(CMD.ACK_OK, f.replyId));
        } else if (f.command === CMD.EXIT) {
          sock.end(reply(CMD.ACK_OK, f.replyId));
          continue;
        } else {
          out.push(reply(CMD.ACK_ERROR, f.replyId)); // anything else is refused (and recorded)
        }
        // Coalesce into one write, like real devices often do.
        sock.write(Buffer.concat(out));
      }
    });
    sock.on("error", () => {});
  });

  return new Promise((resolve) => {
    server.listen(options.port ?? 0, "127.0.0.1", () => {
      resolve({ server, port: server.address().port, received, records });
    });
  });
}

// CLI
if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const port = Number(process.argv[2]) || 4370;
  const { records } = await startMockDevice({ port, records: sampleRecords(500) });
  console.log(`Mock ZKTeco device on 127.0.0.1:${port} with ${records.length} punches (comm key 0). Ctrl+C to stop.`);
}
'@

# ---------------------------------------------------------------- connector/test/zk.test.js
Write-File "connector/test/zk.test.js" @'
// Run: npm test   (uses the mock device, no hardware needed)
import test from "node:test";
import assert from "node:assert/strict";
import { startMockDevice, sampleRecords, sampleUsers } from "./mock-device.js";
import { ZkClient, readDevice } from "../src/zk/client.js";
import { READ_ONLY_COMMANDS, decodeTime, encodeTime } from "../src/zk/protocol.js";

async function withMock(options, fn) {
  const mock = await startMockDevice(options);
  try {
    return await fn(mock);
  } finally {
    mock.server.close();
  }
}

function assertReadOnly(received) {
  for (const c of received) {
    if (typeof c === "string") {
      assert.ok(c === "buffer:13" || c === "buffer:9", `unexpected dataset requested: ${c}`);
    } else {
      assert.ok(READ_ONLY_COMMANDS.has(c), `non read-only command sent to device: ${c}`);
    }
  }
}

test("time encode/decode round-trip", () => {
  for (const ts of ["2000-01-01 00:00:00", "2026-10-05 20:11:59", "2030-12-31 23:59:59"]) {
    assert.equal(decodeTime(encodeTime(ts)), ts);
  }
});

test("small log is sent directly (40-byte records)", () =>
  withMock({ records: sampleRecords(20) }, async (mock) => {
    const r = await readDevice({ ip: "127.0.0.1", port: mock.port, timeoutMs: 3000 });
    assert.equal(r.serialNumber, "MOCK0000K50");
    assert.equal(r.deviceTime, "2026-10-05 20:30:00");
    assert.equal(r.recordSize, 40);
    assert.deepEqual(r.records, mock.records);
    assertReadOnly(mock.received);
  }));

test("large log is read in chunks (60,000 punches)", () =>
  withMock({ records: sampleRecords(60000) }, async (mock) => {
    let progressCalls = 0;
    const r = await readDevice({ ip: "127.0.0.1", port: mock.port, timeoutMs: 5000 }, () => progressCalls++);
    assert.equal(r.records.length, 60000);
    assert.deepEqual(r.records.at(-1), mock.records.at(-1));
    assert.ok(progressCalls >= 2);
    assertReadOnly(mock.received);
  }));

test("chunk split over several DATA packets", () =>
  withMock({ records: sampleRecords(3000), dataFrameSize: 1000 }, async (mock) => {
    const r = await readDevice({ ip: "127.0.0.1", port: mock.port, timeoutMs: 3000 });
    assert.deepEqual(r.records, mock.records);
  }));

test("16-byte and 8-byte record formats", async () => {
  for (const recordSize of [16, 8]) {
    await withMock({ records: sampleRecords(300), recordSize }, async (mock) => {
      const r = await readDevice({ ip: "127.0.0.1", port: mock.port, timeoutMs: 3000 });
      assert.equal(r.recordSize, recordSize);
      assert.deepEqual(r.records, mock.records);
    });
  }
});

test("comm key: correct key works, wrong key is rejected", () =>
  withMock({ records: sampleRecords(50), commKey: 123456 }, async (mock) => {
    const ok = await readDevice({ ip: "127.0.0.1", port: mock.port, commKey: 123456, timeoutMs: 3000 });
    assert.equal(ok.records.length, 50);
    await assert.rejects(
      readDevice({ ip: "127.0.0.1", port: mock.port, commKey: 1, timeoutMs: 3000 }),
      /comm key/,
    );
  }));

test("empty log returns no records", () =>
  withMock({ records: [] }, async (mock) => {
    const r = await readDevice({ ip: "127.0.0.1", port: mock.port, timeoutMs: 3000 });
    assert.equal(r.records.length, 0);
  }));

test("write commands are blocked before reaching the device", () =>
  withMock({ records: sampleRecords(5) }, async (mock) => {
    const c = new ZkClient({ ip: "127.0.0.1", port: mock.port, timeoutMs: 3000 });
    await c.connect();
    await assert.rejects(c.command(15), /read-only allowlist/);   // 15 = CMD_CLEAR_ATTLOG
    await assert.rejects(c.command(1004), /read-only allowlist/); // 1004 = CMD_RESTART
    await c.disconnect();
    assert.ok(!mock.received.includes(15) && !mock.received.includes(1004));
  }));

test("unreachable device fails with a clear message", async () => {
  await assert.rejects(
    readDevice({ ip: "127.0.0.1", port: 1, timeoutMs: 1500 }),
    /Cannot (connect|reach)/,
  );
});

test("user list: names read (72-byte), no passwords or card numbers", () =>
  withMock({ records: sampleRecords(100) }, async (mock) => {
    const r = await readDevice({ ip: "127.0.0.1", port: mock.port, timeoutMs: 3000 });
    assert.equal(r.users.length, 25);
    const expected = sampleUsers(mock.records)[0];
    assert.deepEqual(r.users[0], { user_id: expected.user_id, name: expected.name });
    for (const u of r.users) assert.deepEqual(Object.keys(u).sort(), ["name", "user_id"]);
    assertReadOnly(mock.received);
  }));

test("user list: 28-byte format and blank / non-English names", () => {
  const records = sampleRecords(20);
  const users = sampleUsers(records);
  users[0].name = "";
  users[1].name = "\u0639\u0644\u06cc"; // Urdu "Ali"
  return withMock({ records, users, userRecordSize: 28 }, async (mock) => {
    const r = await readDevice({ ip: "127.0.0.1", port: mock.port, timeoutMs: 3000 });
    assert.equal(r.users[0].name, "");
    assert.equal(r.users[1].name, "\u0639\u0644\u06cc");
  });
});

test("machine refuses user list: attendance still returned", () =>
  withMock({ records: sampleRecords(30), refuseUsers: true }, async (mock) => {
    const r = await readDevice({ ip: "127.0.0.1", port: mock.port, timeoutMs: 3000 });
    assert.equal(r.records.length, 30);
    assert.equal(r.users.length, 0);
    assert.match(r.usersError, /buffered reads/);
  }));

test("8-byte records are mapped from internal number to user ID", () => {
  const records = sampleRecords(40);
  const users = sampleUsers(records).map((u) => ({ ...u, user_id: String(1000 + u.uid) }));
  // In the 8-byte format the machine stores its internal number (uid), not the user ID.
  const byId = new Map(sampleUsers(records).map((u) => [u.user_id, u.uid]));
  const stored = records.map((r) => ({ ...r, user_id: String(byId.get(r.user_id)) }));
  return withMock({ records: stored, recordSize: 8, users }, async (mock) => {
    const r = await readDevice({ ip: "127.0.0.1", port: mock.port, timeoutMs: 3000 });
    assert.ok(r.records.every((x) => Number(x.user_id) > 1000));
  });
});

test("other datasets (e.g. fingerprints) are blocked", () =>
  withMock({ records: sampleRecords(5) }, async (mock) => {
    const c = new ZkClient({ ip: "127.0.0.1", port: mock.port, timeoutMs: 3000 });
    await c.connect();
    await assert.rejects(c.readWithBuffer(1503), /read-only allowlist/);
    await c.disconnect();
  }));
'@

Write-Host ""
Write-Host "Phase 7 files written. Next steps are listed in the chat." -ForegroundColor Cyan
