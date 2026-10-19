# =====================================================================
# HR Auto Attendance Fetcher - PHASE 13 : employee IDs belong to a
# machine (no more "ID 2" overwrites), and machine groups that share
# IDs and are reported as one sheet. Run from the ROOT of the repo:
#   powershell -ExecutionPolicy Bypass -File .\phase-13-machine-scopes.ps1
#   cd worker; npx wrangler d1 migrations apply DB --remote; npm run deploy
# =====================================================================
$ErrorActionPreference = "Stop"

function Write-File([string]$Path, [string]$Content) {
    $full = Join-Path (Get-Location) $Path
    $dir  = Split-Path $full -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($full, $Content.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  wrote $Path" -ForegroundColor Green
}

if (-not (Test-Path "worker/src/lib/jobs.ts")) {
    throw "Run this from the repo root, after Phase 12 (worker/src/lib/jobs.ts not found)."
}

Write-Host "Phase 13: writing machine-scoped employees and groups..." -ForegroundColor Cyan

# ---------------------------------------------------------------- worker/migrations/0007_machine_scoped_employees.sql
Write-File "worker/migrations/0007_machine_scoped_employees.sql" @'
-- =============================================================
-- Phase 13 - employee IDs belong to a machine, and machine groups
--
-- Before: one employee per (company, user ID). Two machines that both
-- had "ID 2" shared one row, so the last machine's name overwrote the other.
-- Now:    one employee per (company, machine, user ID).
--
-- Machines can be put in a group (e.g. two machines at the same office
-- where staff are enrolled with the same IDs). Inside a group, the same
-- user ID on any of its machines is the same person, and reports show the
-- group as one sheet.
-- =============================================================

CREATE TABLE machine_groups (
  id          TEXT PRIMARY KEY,
  company_id  TEXT NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  UNIQUE (company_id, name)
);

ALTER TABLE devices ADD COLUMN group_id TEXT REFERENCES machine_groups(id) ON DELETE SET NULL;
CREATE INDEX idx_devices_group ON devices(group_id);

CREATE TABLE employees_new (
  id              TEXT PRIMARY KEY,
  company_id      TEXT NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  device_id       TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  device_user_id  TEXT NOT NULL,
  full_name       TEXT NOT NULL,
  department      TEXT,
  is_active       INTEGER NOT NULL DEFAULT 1,
  created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  machine_name    TEXT,
  name_edited     INTEGER NOT NULL DEFAULT 0,
  updated_at      TEXT,
  UNIQUE (company_id, device_id, device_user_id)
);

-- 1) Everyone who has punches: one copy on each machine they punched on.
--    Names that came from a machine are refreshed per machine on the next sync.
INSERT INTO employees_new (id, company_id, device_id, device_user_id, full_name, department,
                           is_active, created_at, machine_name, name_edited, updated_at)
SELECT lower(hex(randomblob(16))), e.company_id, x.device_id, e.device_user_id, e.full_name, e.department,
       e.is_active, e.created_at, e.machine_name, e.name_edited, e.updated_at
  FROM employees e
  JOIN (SELECT DISTINCT company_id, device_id, device_user_id FROM attendance_logs) x
    ON x.company_id = e.company_id AND x.device_user_id = e.device_user_id;

-- 2) No punches yet, company has exactly one machine: it belongs to that machine.
INSERT OR IGNORE INTO employees_new (id, company_id, device_id, device_user_id, full_name, department,
                                     is_active, created_at, machine_name, name_edited, updated_at)
SELECT lower(hex(randomblob(16))), e.company_id, d.id, e.device_user_id, e.full_name, e.department,
       e.is_active, e.created_at, e.machine_name, e.name_edited, e.updated_at
  FROM employees e
  JOIN devices d ON d.company_id = e.company_id
 WHERE NOT EXISTS (SELECT 1 FROM attendance_logs l WHERE l.company_id = e.company_id AND l.device_user_id = e.device_user_id)
   AND (SELECT COUNT(*) FROM devices d2 WHERE d2.company_id = e.company_id) = 1;

-- (No punches and several machines: we can't tell which machine they are on.
--  The next sync reads each machine's user list and adds them to the right one.)

DROP TABLE employees;
ALTER TABLE employees_new RENAME TO employees;
CREATE INDEX idx_employees_device ON employees(device_id, device_user_id);
'@

# ---------------------------------------------------------------- worker/src/lib/scopes.ts
Write-File "worker/src/lib/scopes.ts" @'
// Who is who: an employee is a user ID inside a "scope".
//   - A machine that is not in a group is its own scope.
//   - A group of machines is one scope: user ID 2 on any machine of the group is the same person.
// So "ID 2" on two ungrouped machines is two different people.
import type { Env } from "../env";

export interface Scope {
  id: string;               // group id, or the machine id when the machine has no group
  kind: "group" | "machine";
  name: string;
  deviceIds: string[];
  active: boolean;          // at least one active machine
}

export interface Person {
  scopeId: string;
  userId: string;
  name: string;             // "" when unknown
  machineName: string | null;
  department: string;
  edited: boolean;
  active: boolean;
}

interface DeviceRow { id: string; name: string; is_active: number; group_id: string | null; group_name: string | null }

export async function loadScopes(env: Env, companyId: string) {
  const { results } = await env.DB.prepare(
    `SELECT d.id, d.name, d.is_active, d.group_id, g.name AS group_name
       FROM devices d LEFT JOIN machine_groups g ON g.id = d.group_id
      WHERE d.company_id = ?`,
  ).bind(companyId).all<DeviceRow>();

  const byId = new Map<string, Scope>();
  const scopeOfDevice = new Map<string, Scope>();
  for (const d of results ?? []) {
    const id = d.group_id ?? d.id;
    let s = byId.get(id);
    if (!s) {
      s = { id, kind: d.group_id ? "group" : "machine", name: d.group_name ?? d.name, deviceIds: [], active: false };
      byId.set(id, s);
    }
    s.deviceIds.push(d.id);
    if (d.is_active) s.active = true;
    scopeOfDevice.set(d.id, s);
  }
  const scopes = [...byId.values()].sort((a, b) =>
    (a.kind === b.kind ? 0 : a.kind === "group" ? -1 : 1) || a.name.localeCompare(b.name));
  return { scopes, byId, scopeOfDevice };
}

export const personKey = (scopeId: string, userId: string) => `${scopeId}|${userId}`;

/**
 * Employees merged per scope. Inside a group, a name typed in the dashboard wins,
 * then any name read from one of its machines.
 */
export async function loadPeople(env: Env, companyId: string, scopeOfDevice: Map<string, Scope>) {
  const { results } = await env.DB.prepare(
    `SELECT device_id, device_user_id, full_name, machine_name, COALESCE(department, '') AS department,
            name_edited, is_active
       FROM employees WHERE company_id = ?`,
  ).bind(companyId).all<{
    device_id: string; device_user_id: string; full_name: string; machine_name: string | null;
    department: string; name_edited: number; is_active: number;
  }>();

  const people = new Map<string, Person>();
  for (const e of results ?? []) {
    const scope = scopeOfDevice.get(e.device_id);
    if (!scope) continue;
    const key = personKey(scope.id, e.device_user_id);
    const p = people.get(key);
    if (!p) {
      people.set(key, {
        scopeId: scope.id, userId: e.device_user_id, name: e.full_name, machineName: e.machine_name,
        department: e.department, edited: e.name_edited === 1, active: e.is_active === 1,
      });
      continue;
    }
    const edited = e.name_edited === 1;
    if ((edited && !p.edited) || (!p.edited && !p.name && e.full_name)) {
      p.name = e.full_name;
      p.edited = edited;
    }
    if (!p.machineName && e.machine_name) p.machineName = e.machine_name;
    if (!p.department && e.department) p.department = e.department;
    if (e.is_active === 1) p.active = true;
  }
  return people;
}

/** Sorts user IDs numerically when they are numbers. */
export function byUserId(a: string, b: string): number {
  const na = Number(a);
  const nb = Number(b);
  if (Number.isFinite(na) && Number.isFinite(nb) && na !== nb) return na - nb;
  return a.localeCompare(b);
}
'@

# ---------------------------------------------------------------- worker/src/routes/groups.ts
Write-File "worker/src/routes/groups.ts" @'
// Machine groups. Machines in one group share their employees by user ID
// (ID 2 on any machine of the group is the same person) and get one sheet in the Excel report.
import type { Env } from "../env";
import { HttpError, json, readJson } from "../lib/http";
import { requireAuth, requireRole } from "../lib/auth";

function cleanName(value: unknown): string {
  const v = typeof value === "string" ? value.trim().replace(/\s+/g, " ") : "";
  if (v.length < 2) throw new HttpError(400, "Group name is required (at least 2 characters)");
  if (v.length > 40) throw new HttpError(400, "Group name is too long (max 40)");
  return v;
}

/** Returns the group id when it belongs to the company (null = "no group"). */
export async function checkGroup(env: Env, companyId: string, groupId: unknown): Promise<string | null> {
  if (groupId === undefined || groupId === null || groupId === "") return null;
  if (typeof groupId !== "string") throw new HttpError(400, "group_id must be text");
  const ok = await env.DB.prepare("SELECT 1 FROM machine_groups WHERE id = ? AND company_id = ?")
    .bind(groupId, companyId).first();
  if (!ok) throw new HttpError(400, "Group not found");
  return groupId;
}

function duplicate(err: unknown): boolean {
  return err instanceof Error && /UNIQUE/i.test(err.message);
}

/** GET /api/groups */
export async function listGroups(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  const { results } = await env.DB.prepare(
    `SELECT g.id, g.name, g.created_at,
            (SELECT COUNT(*) FROM devices d WHERE d.group_id = g.id) AS machines,
            (SELECT group_concat(d.name, ', ') FROM devices d WHERE d.group_id = g.id) AS machine_names
       FROM machine_groups g WHERE g.company_id = ? ORDER BY g.name`,
  ).bind(auth.companyId).all();
  return json({ groups: results ?? [] });
}

/** POST /api/groups  { name } */
export async function createGroup(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  const body = await readJson<{ name?: unknown }>(request);
  const name = cleanName(body.name);
  const id = crypto.randomUUID();
  try {
    await env.DB.prepare("INSERT INTO machine_groups (id, company_id, name) VALUES (?, ?, ?)")
      .bind(id, auth.companyId, name).run();
  } catch (err) {
    if (duplicate(err)) throw new HttpError(409, `A group called "${name}" already exists`);
    throw err;
  }
  return json({ group: { id, name } }, 201);
}

/** PUT /api/groups/:id  { name } */
export async function renameGroup(request: Request, env: Env, id: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  const body = await readJson<{ name?: unknown }>(request);
  const name = cleanName(body.name);
  let changes = 0;
  try {
    const r = await env.DB.prepare("UPDATE machine_groups SET name = ? WHERE id = ? AND company_id = ?")
      .bind(name, id, auth.companyId).run();
    changes = r.meta.changes ?? 0;
  } catch (err) {
    if (duplicate(err)) throw new HttpError(409, `A group called "${name}" already exists`);
    throw err;
  }
  if (!changes) throw new HttpError(404, "Group not found");
  return json({ group: { id, name } });
}

/** DELETE /api/groups/:id - its machines become ungrouped; no attendance is deleted. */
export async function deleteGroup(request: Request, env: Env, id: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  const results = await env.DB.batch([
    env.DB.prepare("UPDATE devices SET group_id = NULL WHERE group_id = ? AND company_id = ?").bind(id, auth.companyId),
    env.DB.prepare("DELETE FROM machine_groups WHERE id = ? AND company_id = ?").bind(id, auth.companyId),
  ]);
  if (!(results[1].meta.changes ?? 0)) throw new HttpError(404, "Group not found");
  return json({ ok: true, machines_ungrouped: results[0].meta.changes ?? 0 });
}

/** PUT /api/devices/:id/group  { group_id: string | null } */
export async function setDeviceGroup(request: Request, env: Env, deviceId: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  const body = await readJson<{ group_id?: unknown }>(request);
  const groupId = await checkGroup(env, auth.companyId, body.group_id);
  const r = await env.DB.prepare("UPDATE devices SET group_id = ? WHERE id = ? AND company_id = ?")
    .bind(groupId, deviceId, auth.companyId).run();
  if (!(r.meta.changes ?? 0)) throw new HttpError(404, "Machine not found");
  return json({ ok: true, group_id: groupId });
}
'@

# ---------------------------------------------------------------- worker/src/routes/employees.ts
Write-File "worker/src/routes/employees.ts" @'
// Employees (dashboard). A user ID belongs to its machine, or to the machine's group:
// "ID 2" on two separate machines is two people; on two machines of one group it is one person.
import type { Env } from "../env";
import { HttpError, json, readJson } from "../lib/http";
import { requireAuth, requireRole } from "../lib/auth";
import { byUserId, loadPeople, loadScopes, personKey } from "../lib/scopes";

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
  const { scopes, byId, scopeOfDevice } = await loadScopes(env, auth.companyId);
  const people = await loadPeople(env, auth.companyId, scopeOfDevice);

  // Anyone who punched but is not on the machine's user list yet, and their last punch.
  const { results: seen } = await env.DB.prepare(
    `SELECT device_id, device_user_id, MAX(punch_time) AS last_punch
       FROM attendance_logs WHERE company_id = ? GROUP BY device_id, device_user_id`,
  ).bind(auth.companyId).all<{ device_id: string; device_user_id: string; last_punch: string }>();

  const lastPunch = new Map<string, string>();
  for (const r of seen ?? []) {
    const scope = scopeOfDevice.get(r.device_id);
    if (!scope) continue;
    const key = personKey(scope.id, r.device_user_id);
    if (!people.has(key)) {
      people.set(key, {
        scopeId: scope.id, userId: r.device_user_id, name: "", machineName: null,
        department: "", edited: false, active: true,
      });
    }
    if ((lastPunch.get(key) ?? "") < r.last_punch) lastPunch.set(key, r.last_punch);
  }

  const order = new Map(scopes.map((s, i) => [s.id, i]));
  const employees = [...people.values()]
    .sort((a, b) => (order.get(a.scopeId)! - order.get(b.scopeId)!) || byUserId(a.userId, b.userId))
    .map((p) => {
      const scope = byId.get(p.scopeId)!;
      return {
        scope_id: p.scopeId,
        scope_kind: scope.kind,
        scope_name: scope.name,
        user_id: p.userId,
        name: p.name,
        machine_name: p.machineName,
        department: p.department,
        name_edited: p.edited ? 1 : 0,
        last_punch: lastPunch.get(personKey(p.scopeId, p.userId)) ?? null,
      };
    });

  const unnamed = employees.filter((e) => !e.name).length;
  return json({
    employees,
    total: employees.length,
    unnamed,
    scopes: scopes.map((s) => ({ id: s.id, kind: s.kind, name: s.name })),
  });
}

/**
 * PUT /api/employees/:scopeId/:userId  { name?, department? }
 * scopeId is a group id, or a machine id for a machine without a group.
 * The change is saved on every machine of the scope, so the person keeps it
 * even if the group is changed later. An empty name means "use the machine's name again".
 */
export async function saveEmployee(request: Request, env: Env, scopeId: string, userId: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  if (!USER_ID_RE.test(userId)) throw new HttpError(400, "Invalid user ID");

  const { byId } = await loadScopes(env, auth.companyId);
  const scope = byId.get(scopeId);
  if (!scope) throw new HttpError(404, "Machine or group not found");

  const body = await readJson<Record<string, unknown>>(request);
  const name = cleanOptional(body.name, "Name", 80);
  const department = cleanOptional(body.department, "Department", 60);
  const now = new Date().toISOString();

  // Machines of the scope that know this user ID; if none do, all of them.
  const placeholders = scope.deviceIds.map(() => "?").join(",");
  const { results: known } = await env.DB.prepare(
    `SELECT device_id FROM employees WHERE company_id = ? AND device_user_id = ? AND device_id IN (${placeholders})
     UNION
     SELECT DISTINCT device_id FROM attendance_logs WHERE company_id = ? AND device_user_id = ? AND device_id IN (${placeholders})`,
  ).bind(auth.companyId, userId, ...scope.deviceIds, auth.companyId, userId, ...scope.deviceIds)
    .all<{ device_id: string }>();
  const targets = known?.length ? known.map((k) => k.device_id) : scope.deviceIds;

  await env.DB.batch(targets.map((deviceId) => env.DB.prepare(
    `INSERT INTO employees (id, company_id, device_id, device_user_id, full_name, department, name_edited, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, NULLIF(?6, ''), ?7, ?8)
     ON CONFLICT (company_id, device_id, device_user_id) DO UPDATE SET
       full_name   = CASE WHEN ?7 = 1 THEN ?5 ELSE COALESCE(employees.machine_name, '') END,
       name_edited = ?7,
       department  = NULLIF(?6, ''),
       updated_at  = ?8`,
  ).bind(crypto.randomUUID(), auth.companyId, deviceId, userId, name, department, name ? 1 : 0, now)));

  return json({ ok: true, scope_id: scopeId, user_id: userId, machines: targets.length });
}
'@

# ---------------------------------------------------------------- worker/src/routes/overview.ts
Write-File "worker/src/routes/overview.ts" @'
// GET /api/overview?date=YYYY-MM-DD - one day of attendance for the dashboard timeline.
import type { Env } from "../env";
import { HttpError, json } from "../lib/http";
import { requireAuth } from "../lib/auth";
import { addDays, isDate, localNow } from "../lib/dates";
import { schedule } from "./reports";
import { loadPeople, loadScopes, personKey } from "../lib/scopes";

export async function overview(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  const today = localNow(new Date(), auth.companyTimezone).date;
  const q = new URL(request.url).searchParams.get("date");
  if (q !== null && !isDate(q)) throw new HttpError(400, "date must be YYYY-MM-DD");
  const date = q ?? today;

  const { results: punches } = await env.DB.prepare(
    `SELECT l.device_id, l.device_user_id AS user_id, substr(l.punch_time, 12, 5) AS time
       FROM attendance_logs l
      WHERE l.company_id = ? AND l.punch_time >= ? AND l.punch_time < ?
      ORDER BY l.punch_time`,
  ).bind(auth.companyId, `${date} 00:00:00`, `${addDays(date, 1)} 00:00:00`)
    .all<{ device_id: string; user_id: string; time: string }>();

  // A person = user ID within a machine (or within the machine's group).
  const { scopes, byId, scopeOfDevice } = await loadScopes(env, auth.companyId);
  const people = await loadPeople(env, auth.companyId, scopeOfDevice);
  const { results: everPunched } = await env.DB.prepare(
    "SELECT DISTINCT device_id, device_user_id FROM attendance_logs WHERE company_id = ?",
  ).bind(auth.companyId).all<{ device_id: string; device_user_id: string }>();
  for (const r of everPunched ?? []) {
    const scope = scopeOfDevice.get(r.device_id);
    if (!scope) continue;
    const key = personKey(scope.id, r.device_user_id);
    if (!people.has(key)) {
      people.set(key, { scopeId: scope.id, userId: r.device_user_id, name: "", machineName: null, department: "", edited: false, active: true });
    }
  }
  const showWhere = scopes.length > 1;
  const where = (scopeId: string) => (showWhere ? byId.get(scopeId)?.name ?? null : null);

  const sync = await env.DB.prepare(
    "SELECT MAX(last_sync_at) AS last_sync, COUNT(*) AS machines FROM devices WHERE company_id = ? AND is_active = 1",
  ).bind(auth.companyId).first<{ last_sync: string | null; machines: number }>();

  const byPerson = new Map<string, { scopeId: string; userId: string; times: string[] }>();
  for (const p of punches ?? []) {
    const scope = scopeOfDevice.get(p.device_id);
    if (!scope) continue;
    const key = personKey(scope.id, p.user_id);
    const entry = byPerson.get(key) ?? { scopeId: scope.id, userId: p.user_id, times: [] };
    entry.times.push(p.time);
    byPerson.set(key, entry);
  }
  const present = [...byPerson].map(([key, e]) => {
    const info = people.get(key);
    e.times.sort();
    return {
      user_id: e.userId, name: info?.name || null, department: info?.department || null,
      where: where(e.scopeId), punches: e.times,
    };
  });
  present.sort((a, b) => a.punches[0].localeCompare(b.punches[0]) || a.user_id.localeCompare(b.user_id));
  const absent = [...people]
    .filter(([key, p]) => p.active && !byPerson.has(key) && byId.get(p.scopeId)?.active)
    .map(([, p]) => ({ user_id: p.userId, name: p.name || null, where: where(p.scopeId) }))
    .sort((a, b) => (a.name ?? "~").localeCompare(b.name ?? "~") || a.user_id.localeCompare(b.user_id));

  return json({
    date,
    today,
    present,
    absent,
    punches: punches?.length ?? 0,
    last_sync: sync?.last_sync ?? null,
    machines: sync?.machines ?? 0,
    schedule: await schedule(env, auth),
  });
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
import { expireStaleJobs } from "../lib/jobs";

const MAX_RECORDS_PER_UPLOAD = 1000;
const MAX_WAIT_SECONDS = 25;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
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

  // Only the running connector counts as "online"; a one-off Test-Connection does not.
  if (request.headers.get("x-connector-mode") !== "test") {
    const version = (request.headers.get("x-connector-version") ?? "").trim().slice(0, 40) || null;
    await env.DB.prepare("UPDATE connectors SET last_seen_at = ?, version = COALESCE(?, version) WHERE id = ?")
      .bind(new Date().toISOString(), version, row.id).run();
  }

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

// ------------------------------------------------------------------ POST /api/connector/jobs/claim?wait=20
// Long poll: when nothing is waiting, the request is held for up to `wait` seconds and
// returns as soon as a job appears, so "Sync now" starts within about 2 seconds.
async function takeJob(env: Env, ctx: ConnectorContext) {
  const now = new Date().toISOString();
  return env.DB.prepare(
    `UPDATE sync_jobs
        SET status = 'running', started_at = ?1, heartbeat_at = ?1,
            progress_stage = 'connecting', progress_pct = 0, progress_msg = 'Connector picked up the sync'
      WHERE status = 'pending'
        AND id = (
          SELECT j.id FROM sync_jobs j JOIN devices d ON d.id = j.device_id
           WHERE j.status = 'pending' AND j.company_id = ?2 AND d.connector_id = ?3 AND d.is_active = 1
           ORDER BY j.requested_at
           LIMIT 1)
      RETURNING id, device_id, trigger_type, requested_at, started_at`,
  ).bind(now, ctx.companyId, ctx.connectorId)
    .first<{ id: string; device_id: string; trigger_type: string; requested_at: string; started_at: string }>();
}

export async function claimJob(request: Request, env: Env): Promise<Response> {
  const ctx = await requireConnector(request, env);
  const wait = Math.min(Math.max(Number(new URL(request.url).searchParams.get("wait")) || 0, 0), MAX_WAIT_SECONDS);
  const deadline = Date.now() + wait * 1000;

  await expireStaleJobs(env, { connectorId: ctx.connectorId });

  let job = await takeJob(env, ctx);
  while (!job && Date.now() < deadline) {
    await sleep(2000);
    job = await takeJob(env, ctx);
  }
  if (!job) return json({ job: null, waited: wait });

  const device = await env.DB.prepare(
    "SELECT id, name, model, ip_address, port, comm_key, last_sync_at FROM devices WHERE id = ?",
  ).bind(job.device_id).first();

  return json({ job: { ...job, device } });
}

// ------------------------------------------------------------------ POST /api/connector/jobs/:id/progress
// The connector reports what it is doing. The answer tells it whether to stop (job cancelled or timed out).
export async function jobProgress(request: Request, env: Env, jobId: string): Promise<Response> {
  const ctx = await requireConnector(request, env);
  const job = await loadOwnJob(env, ctx, jobId);
  if (job.status !== "running") return json({ ok: false, stop: true, status: job.status });

  const body = await readJson<Record<string, unknown>>(request);
  const stage = typeof body.stage === "string" ? body.stage.slice(0, 20) : null;
  const pct = Number.isFinite(body.pct) ? Math.max(0, Math.min(100, Math.round(body.pct as number))) : null;
  const message = typeof body.message === "string" ? body.message.replace(/[\u0000-\u001f]/g, " ").slice(0, 200) : null;

  await env.DB.prepare(
    `UPDATE sync_jobs SET heartbeat_at = ?, progress_stage = COALESCE(?, progress_stage), progress_pct = ?, progress_msg = COALESCE(?, progress_msg)
      WHERE id = ? AND status = 'running'`,
  ).bind(new Date().toISOString(), stage, pct, message, job.id).run();
  return json({ ok: true, stop: false });
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
    "UPDATE sync_jobs SET records_fetched = records_fetched + ?, records_inserted = records_inserted + ?, heartbeat_at = ? WHERE id = ?",
  ).bind(clean.length, inserted, new Date().toISOString(), job.id).run();

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
    env.DB.prepare(
      `UPDATE sync_jobs SET status = ?, finished_at = ?, error_message = ?, records_skipped = ?,
              progress_stage = NULL, progress_pct = NULL, progress_msg = NULL, heartbeat_at = ?
        WHERE id = ?`,
    ).bind(status, now, errorMessage, skipped, now, job.id),
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
 * New user IDs become employees OF THIS MACHINE (ID 2 on another machine is someone
 * else); the machine name is stored and shown in reports unless someone has edited
 * that employee's name in the dashboard.
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

  const before = await env.DB.prepare("SELECT COUNT(*) AS n FROM employees WHERE device_id = ?")
    .bind(job.device_id).first<{ n: number }>();

  // A blank name on the machine never wipes a name we already have.
  await env.DB.prepare(
    `INSERT INTO employees (id, company_id, device_id, device_user_id, full_name, machine_name, updated_at)
     SELECT lower(hex(randomblob(16))), ?1, ?4, json_extract(value, '$.u'),
            json_extract(value, '$.n'), NULLIF(json_extract(value, '$.n'), ''), ?2
       FROM json_each(?3) WHERE true
     ON CONFLICT (company_id, device_id, device_user_id) DO UPDATE SET
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
  ).bind(job.company_id, new Date().toISOString(), JSON.stringify(rows), job.device_id).run();

  const after = await env.DB.prepare("SELECT COUNT(*) AS n FROM employees WHERE device_id = ?")
    .bind(job.device_id).first<{ n: number }>();

  return json({
    received: body.users.length,
    accepted: rows.length,
    named: rows.filter((r) => r.n).length,
    added: (after?.n ?? 0) - (before?.n ?? 0),
  });
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
import { expireStaleJobs } from "../lib/jobs";
import { checkGroup } from "./groups";

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

/** GET /api/devices - includes the latest sync of each machine, with live progress. */
export async function listDevices(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  await expireStaleJobs(env, { companyId: auth.companyId });
  const { results } = await env.DB.prepare(
    `SELECT d.id, d.name, d.model, d.ip_address, d.port, d.comm_key, d.serial_number,
            d.group_id, g.name AS group_name,
            d.connector_id, c.name AS connector_name, c.is_active AS connector_active, c.last_seen_at AS connector_seen,
            d.last_sync_at, d.clock_offset_seconds, d.clock_checked_at, d.is_active, d.created_at,
            (SELECT COUNT(*) FROM attendance_logs l WHERE l.device_id = d.id) AS log_count,
            j.id AS job_id, j.status AS last_job_status, j.trigger_type AS job_trigger, j.requested_at AS job_requested_at,
            j.progress_stage AS job_stage, j.progress_pct AS job_pct, j.progress_msg AS job_msg,
            j.error_message AS job_error, j.finished_at AS job_finished_at, j.records_inserted AS job_new
       FROM devices d
       LEFT JOIN connectors c ON c.id = d.connector_id
       LEFT JOIN machine_groups g ON g.id = d.group_id
       LEFT JOIN sync_jobs j ON j.id = (SELECT id FROM sync_jobs WHERE device_id = d.id ORDER BY requested_at DESC LIMIT 1)
      WHERE d.company_id = ?
      ORDER BY d.is_active DESC, d.created_at DESC`,
  ).bind(auth.companyId).all();
  return json({ devices: results ?? [], server_time: new Date().toISOString() });
}

/** POST /api/devices  { name, ip_address, port?, comm_key?, model?, connector_id?, group_id? } */
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

  const groupId = await checkGroup(env, auth.companyId, body.group_id);

  const id = crypto.randomUUID();
  await env.DB.prepare(
    `INSERT INTO devices (id, company_id, connector_id, name, model, ip_address, port, comm_key, group_id)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind(id, auth.companyId, connectorId, name, model, ip, port, commKey, groupId).run();

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
  await expireStaleJobs(env, { companyId: auth.companyId });
  const limit = Math.min(Math.max(Number(new URL(request.url).searchParams.get("limit")) || 20, 1), 100);
  const { results } = await env.DB.prepare(
    `SELECT j.id, j.device_id, d.name AS device_name, j.trigger_type, j.status,
            j.requested_at, j.started_at, j.finished_at, j.records_fetched, j.records_inserted, j.records_skipped, j.error_message,
            j.progress_stage, j.progress_pct, j.progress_msg
       FROM sync_jobs j JOIN devices d ON d.id = j.device_id
      WHERE j.company_id = ?
      ORDER BY j.requested_at DESC
      LIMIT ?`,
  ).bind(auth.companyId, limit).all();
  return json({ jobs: results ?? [] });
}

/** POST /api/devices/sync-all - queue a manual sync for every active device that has an active connector. */
export async function syncAll(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  const { results } = await env.DB.prepare(
    `SELECT d.id,
            (SELECT 1 FROM sync_jobs j WHERE j.device_id = d.id AND j.status IN ('pending','running') LIMIT 1) AS open
       FROM devices d JOIN connectors c ON c.id = d.connector_id
      WHERE d.company_id = ? AND d.is_active = 1 AND c.is_active = 1`,
  ).bind(auth.companyId).all<{ id: string; open: number | null }>();

  const devices = results ?? [];
  const toQueue = devices.filter((d) => !d.open);
  if (toQueue.length) {
    await env.DB.batch(toQueue.map((d) =>
      env.DB.prepare(
        "INSERT INTO sync_jobs (id, company_id, device_id, trigger_type, status) VALUES (?, ?, ?, 'manual', 'pending')",
      ).bind(crypto.randomUUID(), auth.companyId, d.id)));
  }
  return json({ devices: devices.length, queued: toQueue.length, already_queued: devices.length - toQueue.length });
}

// ------------------------------------------------------------------ delete (clean-up of unused items)

/**
 * DELETE /api/devices/:id   { move_to?: deviceId, delete_punches?: true }
 * Only deactivated machines. If it has punches, the caller must either move them
 * to another machine of the company or explicitly delete them.
 */
export async function deleteDevice(request: Request, env: Env, id: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  const body = await readJson<{ move_to?: unknown; delete_punches?: unknown }>(request);

  const device = await env.DB.prepare("SELECT id, name, is_active FROM devices WHERE id = ? AND company_id = ?")
    .bind(id, auth.companyId).first<{ id: string; name: string; is_active: number }>();
  if (!device) throw new HttpError(404, "Machine not found");
  if (device.is_active === 1) throw new HttpError(409, "Deactivate the machine before deleting it");

  const count = (await env.DB.prepare("SELECT COUNT(*) AS n FROM attendance_logs WHERE device_id = ?")
    .bind(id).first<{ n: number }>())?.n ?? 0;

  const statements: D1PreparedStatement[] = [];
  let moved = 0;
  if (count > 0) {
    if (typeof body.move_to === "string" && body.move_to) {
      if (body.move_to === id) throw new HttpError(400, "Choose a different machine to move the punches to");
      const target = await env.DB.prepare("SELECT id FROM devices WHERE id = ? AND company_id = ?")
        .bind(body.move_to, auth.companyId).first();
      if (!target) throw new HttpError(400, "The machine to move the punches to was not found");
      // Punches the target already has (same person, same time) are dropped as duplicates.
      statements.push(
        env.DB.prepare("UPDATE OR IGNORE attendance_logs SET device_id = ?, sync_job_id = NULL WHERE device_id = ?")
          .bind(body.move_to, id),
        // Its employees (names, departments) move too, unless the target already has that user ID.
        env.DB.prepare("UPDATE OR IGNORE employees SET device_id = ? WHERE device_id = ?").bind(body.move_to, id),
      );
      moved = count;
    } else if (body.delete_punches !== true) {
      throw new HttpError(409, `This machine has ${count} punches. Move them to another machine or confirm deleting them.`);
    }
  }
  statements.push(
    env.DB.prepare("DELETE FROM attendance_logs WHERE device_id = ?").bind(id),
    env.DB.prepare("DELETE FROM employees WHERE device_id = ?").bind(id),
    env.DB.prepare("DELETE FROM sync_jobs WHERE device_id = ?").bind(id),
    env.DB.prepare("DELETE FROM devices WHERE id = ? AND company_id = ?").bind(id, auth.companyId),
  );
  const results = await env.DB.batch(statements);
  const movedRows = moved ? (results[0].meta.changes ?? 0) : 0;

  return json({ ok: true, punches: count, moved: movedRows, deleted_punches: count - movedRows });
}

/**
 * DELETE /api/connectors/:id
 * Allowed for revoked connectors, and for connectors that never connected and have no machines.
 */
export async function deleteConnector(request: Request, env: Env, id: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);

  const c = await env.DB.prepare(
    `SELECT c.id, c.is_active, c.last_seen_at,
            (SELECT COUNT(*) FROM devices d WHERE d.connector_id = c.id AND d.is_active = 1) AS devices
       FROM connectors c WHERE c.id = ? AND c.company_id = ?`,
  ).bind(id, auth.companyId).first<{ id: string; is_active: number; last_seen_at: string | null; devices: number }>();
  if (!c) throw new HttpError(404, "Connector not found");
  if (c.is_active === 1 && (c.last_seen_at || c.devices > 0)) {
    throw new HttpError(409, c.devices > 0
      ? "This connector still reads a machine. Revoke it (or move the machine to another connector) first."
      : "This connector has been used. Revoke it first, then delete it.");
  }

  await env.DB.batch([
    env.DB.prepare("UPDATE devices SET connector_id = NULL WHERE connector_id = ? AND company_id = ?").bind(id, auth.companyId),
    env.DB.prepare("DELETE FROM connectors WHERE id = ? AND company_id = ?").bind(id, auth.companyId),
  ]);
  return json({ ok: true });
}

/** POST /api/sync-jobs/:id/cancel - stop a waiting or running sync. The connector stops at its next step. */
export async function cancelJob(request: Request, env: Env, id: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  const now = new Date().toISOString();
  const res = await env.DB.prepare(
    `UPDATE sync_jobs SET status = 'failed', finished_at = ?, progress_stage = NULL, progress_pct = NULL, progress_msg = NULL,
            error_message = ?
      WHERE id = ? AND company_id = ? AND status IN ('pending','running')`,
  ).bind(now, `Stopped by ${auth.fullName}`, id, auth.companyId).run();
  if (!res.meta.changes) throw new HttpError(409, "This sync has already finished");
  return json({ ok: true });
}
'@

# ---------------------------------------------------------------- worker/src/routes/reports.ts
Write-File "worker/src/routes/reports.ts" @'
// Attendance report API (browser session). Any role may view and download.
import type { Env } from "../env";
import { HttpError, json } from "../lib/http";
import { requireAuth, type AuthContext } from "../lib/auth";
import { daysBetween, isDate, localNow, nextPeriod } from "../lib/dates";
import { buildAttendanceReport, reportFilename, xlsxResponse } from "../report";
import { loadScopes } from "../lib/scopes";

const MAX_EXPORT_DAYS = 62;

export async function schedule(env: Env, auth: AuthContext) {
  const c = await env.DB.prepare("SELECT report_every_days, report_hour FROM companies WHERE id = ?")
    .bind(auth.companyId).first<{ report_every_days: number; report_hour: number }>();
  const everyDays = c?.report_every_days ?? 2;
  const hour = c?.report_hour ?? 1;
  const last = await env.DB.prepare(
    "SELECT period_end FROM reports WHERE company_id = ? ORDER BY period_end DESC LIMIT 1",
  ).bind(auth.companyId).first<{ period_end: string }>();
  const today = localNow(new Date(), auth.companyTimezone).date;
  const next = nextPeriod(last?.period_end ?? null, today, everyDays);
  return { every_days: everyDays, hour, timezone: auth.companyTimezone, next_start: next.start, next_end: next.end, next_due: next.dueDate };
}

/** GET /api/reports */
export async function listReports(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  const { results } = await env.DB.prepare(
    `SELECT id, period_start, period_end, status, devices_total, devices_synced,
            punch_count, employee_count, note, created_at, ready_at
       FROM reports
      WHERE company_id = ?
      ORDER BY period_end DESC
      LIMIT 30`,
  ).bind(auth.companyId).all();
  return json({ reports: results ?? [], schedule: await schedule(env, auth) });
}

/** GET /api/reports/:id/download */
export async function downloadReport(request: Request, env: Env, id: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  const report = await env.DB.prepare(
    "SELECT period_start, period_end, status, devices_total, devices_synced, note FROM reports WHERE id = ? AND company_id = ?",
  ).bind(id, auth.companyId).first<{
    period_start: string; period_end: string; status: string; devices_total: number; devices_synced: number; note: string | null;
  }>();
  if (!report) throw new HttpError(404, "Report not found");

  const notes = [`Scheduled report: ${report.devices_synced}/${report.devices_total} machine(s) synced for this period.`];
  if (report.status !== "ready") notes.push("This report was still collecting data when downloaded.");
  if (report.note) notes.push(report.note);

  const { bytes } = await buildAttendanceReport(
    env,
    { companyId: auth.companyId, companyName: auth.companyName, timezone: auth.companyTimezone, notes },
    report.period_start,
    report.period_end,
  );
  return xlsxResponse(bytes, reportFilename(auth.companyName, report.period_start, report.period_end));
}

/** GET /api/export.xlsx?from=YYYY-MM-DD&to=YYYY-MM-DD[&scope=<group or machine id>] */
export async function exportRange(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  const params = new URL(request.url).searchParams;
  const from = params.get("from");
  const to = params.get("to");
  if (!isDate(from) || !isDate(to)) throw new HttpError(400, "from and to must be dates (YYYY-MM-DD)");
  if (to < from) throw new HttpError(400, "'to' must be on or after 'from'");
  if (daysBetween(from, to) + 1 > MAX_EXPORT_DAYS) throw new HttpError(400, `Export at most ${MAX_EXPORT_DAYS} days at a time`);

  let scopeId: string | undefined;
  let scopeName: string | undefined;
  const scope = params.get("scope");
  if (scope) {
    const { byId } = await loadScopes(env, auth.companyId);
    const found = byId.get(scope);
    if (!found) throw new HttpError(404, "Machine or group not found");
    scopeId = found.id;
    scopeName = found.name;
  }

  const { bytes } = await buildAttendanceReport(
    env,
    { companyId: auth.companyId, companyName: auth.companyName, timezone: auth.companyTimezone, notes: ["Manual export."], scopeId },
    from,
    to,
  );
  return xlsxResponse(bytes, reportFilename(scopeName ? `${auth.companyName} ${scopeName}` : auth.companyName, from, to));
}
'@

# ---------------------------------------------------------------- worker/src/routes/health.ts
Write-File "worker/src/routes/health.ts" @'
import { EXPECTED_MIGRATIONS, VERSION, type Env } from "../env";
import { json } from "../lib/http";

const REQUIRED_TABLES = [
  "companies", "users", "sessions", "connectors",
  "devices", "employees", "sync_jobs", "attendance_logs", "machine_groups",
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

# ---------------------------------------------------------------- worker/src/report.ts
Write-File "worker/src/report.ts" @'
// Builds the attendance Excel workbook for a date range (inclusive, company local dates).
import type { Env } from "./env";
import { STYLE, buildXlsx, colName, type CellValue, type SheetSpec } from "./lib/xlsx";
import { addDays, excelDate, excelTime } from "./lib/dates";
import { byUserId, loadPeople, loadScopes, personKey, type Scope } from "./lib/scopes";

const STATES: Record<number, string> = { 0: "Check-in", 1: "Check-out", 2: "Break-out", 3: "Break-in", 4: "OT-in", 5: "OT-out" };
const VERIFY: Record<number, string> = { 0: "Password", 1: "Fingerprint", 2: "Card", 15: "Face" };

interface PunchRow {
  device_id: string;
  device_user_id: string;
  punch_time: string;
  punch_state: number | null;
  verify_mode: number | null;
  device_name: string;
}

export interface ReportContext {
  companyId: string;
  companyName: string;
  timezone: string;
  /** Sync notes (e.g. machines that did not sync). Kept for callers; not printed in the HR format. */
  notes?: string[];
  /** Only this group or ungrouped machine (default: all, one sheet each). */
  scopeId?: string;
}

export interface ReportStats {
  punches: number;
  employees: number;
}

/** Numeric machine IDs go into Excel as numbers (no "number stored as text" warnings). */
function userCell(id: string): CellValue {
  return /^[1-9]\d{0,8}$/.test(id) ? Number(id) : id;
}

/** Employees = distinct user IDs per machine, or per group for grouped machines. */
export async function attendanceStats(env: Env, companyId: string, from: string, to: string): Promise<ReportStats> {
  const row = await env.DB.prepare(
    `SELECT COUNT(*) AS punches,
            COUNT(DISTINCT COALESCE(d.group_id, d.id) || '|' || l.device_user_id) AS employees
       FROM attendance_logs l JOIN devices d ON d.id = l.device_id
      WHERE l.company_id = ? AND l.punch_time >= ? AND l.punch_time < ?`,
  ).bind(companyId, `${from} 00:00:00`, `${addDays(to, 1)} 00:00:00`).first<{ punches: number; employees: number }>();
  return { punches: row?.punches ?? 0, employees: row?.employees ?? 0 };
}

const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

function weekday(date: string): string {
  return WEEKDAYS[new Date(`${date}T00:00:00Z`).getUTCDay()];
}

/** Excel time for "HH:MM:SS", cut to whole minutes so Hours Worked matches the times shown. */
function minuteTime(time: string): number {
  return excelTime(`${time.slice(0, 5)}:00`);
}

/** Excel sheet names: max 31 characters, no []:*?/\\, unique (case-insensitive). */
function sheetNamer(reserved: string[]) {
  const used = new Set(reserved.map((n) => n.toLowerCase()));
  return (wanted: string) => {
    const base = wanted.replace(/[\[\]:*?/\\]/g, " ").replace(/^'+|'+$/g, "").trim().slice(0, 31) || "Machine";
    let name = base;
    for (let i = 2; used.has(name.toLowerCase()); i++) name = `${base.slice(0, 31 - ` (${i})`.length)} (${i})`;
    used.add(name.toLowerCase());
    return name;
  };
}

type Day = { first: string; last: string; count: number };

/** One sheet in the HR layout for a group or a single machine. */
function attendanceSheet(name: string, dates: string[], rows: Array<{ label: string; days: Map<string, Day> }>): SheetSpec {
  const S = STYLE;
  const row1: CellValue[] = [{ v: "Employee", s: S.gridCorner }];
  const row2: CellValue[] = [{ s: S.gridCorner }];
  const row3: CellValue[] = [{ s: S.gridCorner }];
  const merges = ["A1:A3"];
  dates.forEach((date, i) => {
    const c0 = 1 + i * 3;
    row1.push({ v: excelDate(date), s: S.gridDate }, { s: S.gridDate }, { s: S.gridDate });
    row2.push({ v: weekday(date), s: S.gridDay }, { s: S.gridDay }, { s: S.gridDay });
    row3.push({ v: "Time In", s: S.gridHead }, { v: "Time Out", s: S.gridHead }, { v: "Hours Worked", s: S.gridHeadC });
    merges.push(`${colName(c0)}1:${colName(c0 + 2)}1`, `${colName(c0)}2:${colName(c0 + 2)}2`);
  });

  const grid: CellValue[][] = [row1, row2, row3];
  for (const person of rows) {
    const excelRow = grid.length + 1;
    const row: CellValue[] = [{ v: person.label, s: S.gridName }];
    dates.forEach((date, i) => {
      const inCol = `${colName(1 + i * 3)}${excelRow}`;
      const outCol = `${colName(2 + i * 3)}${excelRow}`;
      const d = person.days.get(date);
      const tin = d ? minuteTime(d.first) : null;
      const tout = d && d.count > 1 ? minuteTime(d.last) : null;
      row.push(
        { v: tin, s: S.gridTime },
        { v: tout, s: S.gridTime },
        {
          f: `IF(OR(${inCol}="",${outCol}=""),"",${outCol}-${inCol})`,
          v: tin !== null && tout !== null ? Math.round((tout - tin) * 1e8) / 1e8 : "",
          s: S.gridHours,
        },
      );
    });
    grid.push(row);
  }

  const widths = [Math.max(17.33, ...rows.map((r) => Math.min(40, r.label.length + 3)))];
  for (let i = 0; i < dates.length; i++) widths.push(9.5, 9.5, 12.5);
  return { name, widths, rows: grid, merges, freeze: { cols: 1, rows: 3 } };
}

/**
 * Workbook layout (matches the HR format):
 *   One sheet per machine group, and one per machine that is not in a group.
 *   A1:A3 "Employee"; for every date a 3-column block with the date (d-mmm) and
 *   weekday merged on top, then Time In / Time Out / Hours Worked. One row per employee.
 *   User ID 2 on two separate machines is two rows on two sheets; on two machines of
 *   the same group it is one row (first punch of the day on any of them, last punch on any).
 *   Sheet "All Punches": every punch, for checking.
 */
export async function buildAttendanceReport(env: Env, ctx: ReportContext, from: string, to: string) {
  const { scopes, byId, scopeOfDevice } = await loadScopes(env, ctx.companyId);
  if (ctx.scopeId && !byId.has(ctx.scopeId)) throw new Error("Unknown machine or group");

  const { results } = await env.DB.prepare(
    `SELECT l.device_id, l.device_user_id, l.punch_time, l.punch_state, l.verify_mode, d.name AS device_name
       FROM attendance_logs l
       JOIN devices d ON d.id = l.device_id
      WHERE l.company_id = ? AND l.punch_time >= ? AND l.punch_time < ?
      ORDER BY l.punch_time, l.device_user_id`,
  ).bind(ctx.companyId, `${from} 00:00:00`, `${addDays(to, 1)} 00:00:00`).all<PunchRow>();
  const inScope = (deviceId: string) => !ctx.scopeId || scopeOfDevice.get(deviceId)?.id === ctx.scopeId;
  const punches = (results ?? []).filter((p) => inScope(p.device_id));

  const people = await loadPeople(env, ctx.companyId, scopeOfDevice);
  const label = (scopeId: string, userId: string) => people.get(personKey(scopeId, userId))?.name || `ID ${userId}`;

  // First and last punch per person per day
  const days = new Map<string, Map<string, Day>>();
  const punchedIn = new Map<string, Set<string>>(); // scope -> user IDs with punches in the period
  for (const p of punches) {
    const scope = scopeOfDevice.get(p.device_id);
    if (!scope) continue;
    const key = personKey(scope.id, p.device_user_id);
    const date = p.punch_time.slice(0, 10);
    const time = p.punch_time.slice(11, 19);
    let perDay = days.get(key);
    if (!perDay) days.set(key, (perDay = new Map()));
    const d = perDay.get(date);
    if (!d) perDay.set(date, { first: time, last: time, count: 1 });
    else {
      if (time < d.first) d.first = time;
      if (time > d.last) d.last = time;
      d.count++;
    }
    let set = punchedIn.get(scope.id);
    if (!set) punchedIn.set(scope.id, (set = new Set()));
    set.add(p.device_user_id);
  }

  const dates: string[] = [];
  for (let d = from; d <= to; d = addDays(d, 1)) dates.push(d);

  // Which sheets: the requested one, or every active machine/group plus any with punches in the period.
  const wanted: Scope[] = ctx.scopeId
    ? [byId.get(ctx.scopeId)!]
    : scopes.filter((s) => s.active || punchedIn.has(s.id));

  const nameSheet = sheetNamer(["All Punches"]);
  const sheets: SheetSpec[] = [];
  for (const scope of wanted) {
    const ids = new Set(punchedIn.get(scope.id) ?? []);
    if (scope.active) {
      for (const p of people.values()) if (p.scopeId === scope.id && p.active) ids.add(p.userId);
    }
    const rows = [...ids].sort(byUserId).map((userId) => ({
      label: label(scope.id, userId),
      days: days.get(personKey(scope.id, userId)) ?? new Map<string, Day>(),
    }));
    sheets.push(attendanceSheet(nameSheet(scope.name), dates, rows));
  }
  if (!sheets.length) sheets.push(attendanceSheet(nameSheet("Attendance"), dates, []));

  // ---- All punches (for checking)
  const showGroup = scopes.some((s) => s.kind === "group");
  const punchRows: CellValue[][] = [[
    "Date", "Time", "User ID", "Name", "Type", "Verified By", "Machine", ...(showGroup ? ["Group"] : []),
  ]];
  for (const p of punches) {
    const scope = scopeOfDevice.get(p.device_id);
    punchRows.push([
      { v: excelDate(p.punch_time.slice(0, 10)), s: STYLE.date },
      { v: excelTime(p.punch_time.slice(11, 19)), s: STYLE.time },
      userCell(p.device_user_id),
      scope ? people.get(personKey(scope.id, p.device_user_id))?.name ?? "" : "",
      p.punch_state === null ? "" : STATES[p.punch_state] ?? `State ${p.punch_state}`,
      p.verify_mode === null ? "" : VERIFY[p.verify_mode] ?? `Mode ${p.verify_mode}`,
      p.device_name,
      ...(showGroup ? [scope?.kind === "group" ? scope.name : ""] : []),
    ]);
  }
  sheets.push({
    name: "All Punches",
    widths: [13, 10, 10, 24, 12, 13, 18, ...(showGroup ? [18] : [])],
    rows: punchRows,
    header: true,
  });

  const bytes = buildXlsx(sheets);
  const employees = new Set(punches.map((p) => personKey(scopeOfDevice.get(p.device_id)?.id ?? p.device_id, p.device_user_id))).size;
  return { bytes, stats: { punches: punches.length, employees } };
}

export function reportFilename(companyName: string, from: string, to: string): string {
  const slug = companyName.replace(/[^A-Za-z0-9]+/g, "_").replace(/^_+|_+$/g, "").slice(0, 60) || "Company";
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

# ---------------------------------------------------------------- worker/src/index.ts
Write-File "worker/src/index.ts" @'
import type { Env } from "./env";
import { HttpError, html, json, redirect } from "./lib/http";
import { getAuth } from "./lib/auth";
import { health } from "./routes/health";
import { login, logout, me, signup } from "./routes/auth";
import {
  createConnector, createDevice, deactivateDevice, listConnectors,
  listDevices, listSyncJobs, queueSync, revokeConnector, syncAll, deleteDevice, deleteConnector, cancelJob,
} from "./routes/manage";
import { downloadConnector } from "./routes/download";
import { status } from "./routes/status";
import { overview } from "./routes/overview";
import { claimJob, completeJob, connectorConfig, jobProgress, uploadLogs, uploadUsers } from "./routes/connector";
import { listEmployees, saveEmployee } from "./routes/employees";
import { createGroup, deleteGroup, listGroups, renameGroup, setDeviceGroup } from "./routes/groups";
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
const R_EMPLOYEE = new RegExp(`^/api/employees/${ID}/([^/]{1,100})$`);
const R_GROUP = new RegExp(`^/api/groups/${ID}$`);
const R_DEVICE_GROUP = new RegExp(`^/api/devices/${ID}/group$`);
const R_CONNECTOR_PACKAGE = new RegExp(`^/api/connectors/${ID}/package$`);
const R_DEVICE = new RegExp(`^/api/devices/${ID}$`);
const R_CONNECTOR = new RegExp(`^/api/connectors/${ID}$`);
const R_JOB_CANCEL = new RegExp(`^/api/sync-jobs/${ID}/cancel$`);
const R_JOB_PROGRESS = new RegExp(`^/api/connector/jobs/${ID}/progress$`);

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
  if (method === "POST" && (m = R_CONNECTOR_PACKAGE.exec(pathname))) return downloadConnector(request, env, m[1]);
  if (method === "DELETE" && (m = R_CONNECTOR.exec(pathname))) return deleteConnector(request, env, m[1]);
  if (method === "DELETE" && (m = R_DEVICE.exec(pathname))) return deleteDevice(request, env, m[1]);
  if (pathname === "/api/devices" && method === "GET") return listDevices(request, env);
  if (pathname === "/api/devices" && method === "POST") return createDevice(request, env);
  if (pathname === "/api/devices/sync-all" && method === "POST") return syncAll(request, env);
  if (method === "POST" && (m = R_DEVICE_DEACTIVATE.exec(pathname))) return deactivateDevice(request, env, m[1]);
  if (method === "POST" && (m = R_DEVICE_SYNC.exec(pathname))) return queueSync(request, env, m[1]);
  if (pathname === "/api/sync-jobs" && method === "GET") return listSyncJobs(request, env);
  if (method === "POST" && (m = R_JOB_CANCEL.exec(pathname))) return cancelJob(request, env, m[1]);
  if (pathname === "/api/status" && method === "GET") return status(request, env);
  if (pathname === "/api/overview" && method === "GET") return overview(request, env);
  if (pathname === "/api/reports" && method === "GET") return listReports(request, env);
  if (method === "GET" && (m = R_REPORT_DOWNLOAD.exec(pathname))) return downloadReport(request, env, m[1]);
  if (pathname === "/api/export.xlsx" && method === "GET") return exportRange(request, env);
  if (pathname === "/api/employees" && method === "GET") return listEmployees(request, env);
  if (method === "PUT" && (m = R_EMPLOYEE.exec(pathname))) return saveEmployee(request, env, m[1], safeDecode(m[2]));
  if (pathname === "/api/groups" && method === "GET") return listGroups(request, env);
  if (pathname === "/api/groups" && method === "POST") return createGroup(request, env);
  if (method === "PUT" && (m = R_GROUP.exec(pathname))) return renameGroup(request, env, m[1]);
  if (method === "DELETE" && (m = R_GROUP.exec(pathname))) return deleteGroup(request, env, m[1]);
  if (method === "PUT" && (m = R_DEVICE_GROUP.exec(pathname))) return setDeviceGroup(request, env, m[1]);

  // ---- ZKT Connector API (Bearer token)
  if (pathname === "/api/connector/config" && method === "GET") return connectorConfig(request, env);
  if (pathname === "/api/connector/jobs/claim" && method === "POST") return claimJob(request, env);
  if (method === "POST" && (m = R_JOB_LOGS.exec(pathname))) return uploadLogs(request, env, m[1]);
  if (method === "POST" && (m = R_JOB_USERS.exec(pathname))) return uploadUsers(request, env, m[1]);
  if (method === "POST" && (m = R_JOB_PROGRESS.exec(pathname))) return jobProgress(request, env, m[1]);
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

# ---------------------------------------------------------------- worker/src/pages.ts
Write-File "worker/src/pages.ts" @'
import { VERSION } from "./env";
import type { AuthContext } from "./lib/auth";
import { escapeHtml } from "./lib/http";

// ------------------------------------------------------------------ design tokens + components
const STYLE = String.raw`
:root {
  --canvas:#EEF2F0; --surface:#FFFFFF; --surface-2:#F5F8F6; --ink:#17302B; --ink-2:#3A4F4A; --muted:#62746F;
  --line:#D6DFDB; --line-2:#E5ECE9;
  --side:#17302B; --side-ink:#E4EEEA; --side-muted:#93ABA4; --side-hover:rgba(255,255,255,.07);
  --accent:#126B4E; --accent-hover:#0E5A41; --accent-ink:#FFFFFF; --accent-soft:#E0F0E8;
  --amber:#9A5A05; --amber-soft:#FBF0DC; --red:#B42318; --red-soft:#FDECEA;
  --radius:8px; --radius-lg:12px;
  color-scheme: light;
}
@media (prefers-color-scheme: dark) {
  :root {
    --canvas:#0E1614; --surface:#15201D; --surface-2:#1A2724; --ink:#E3ECE8; --ink-2:#C3D1CC; --muted:#8EA29C;
    --line:#293834; --line-2:#21302C;
    --side:#0A110F; --side-ink:#E3ECE8; --side-muted:#80958F; --side-hover:rgba(255,255,255,.06);
    --accent:#3DB389; --accent-hover:#52C49A; --accent-ink:#06201A; --accent-soft:#163A2F;
    --amber:#E3A94F; --amber-soft:#36290F; --red:#F27A6D; --red-soft:#3A1916;
    color-scheme: dark;
  }
}
* { box-sizing:border-box; }
[hidden] { display:none !important; }
html, body { margin:0; }
body {
  background:var(--canvas); color:var(--ink);
  font-family:"IBM Plex Sans", system-ui, -apple-system, "Segoe UI", sans-serif;
  font-size:14px; line-height:1.5; -webkit-font-smoothing:antialiased;
}
h1, h2, h3 { margin:0; font-weight:600; letter-spacing:-0.01em; }
h1 { font-size:26px; line-height:1.2; }
h2 { font-size:16px; }
p { margin:0; }
a { color:var(--accent); }
.num, td.num, .tnum { font-variant-numeric:tabular-nums; }
:focus-visible { outline:2px solid var(--accent); outline-offset:2px; }
@media (prefers-reduced-motion: reduce) { * { transition:none !important; animation:none !important; } }

/* ---------- buttons + inputs */
.btn {
  display:inline-flex; align-items:center; justify-content:center; gap:6px;
  height:36px; padding:0 14px; border-radius:var(--radius); border:1px solid transparent;
  font:inherit; font-weight:500; font-size:14px; cursor:pointer; text-decoration:none; white-space:nowrap;
  transition:background .12s, border-color .12s, color .12s;
}
.btn-primary { background:var(--accent); color:var(--accent-ink); }
.btn-primary:hover { background:var(--accent-hover); }
.btn-ghost { background:var(--surface); color:var(--ink); border-color:var(--line); }
.btn-ghost:hover { border-color:var(--muted); }
.btn-quiet { background:transparent; color:var(--muted); padding:0 8px; }
.btn-quiet:hover { color:var(--ink); }
.btn-danger { background:transparent; color:var(--red); padding:0 8px; }
.btn-danger:hover { background:var(--red-soft); }
.btn-sm { height:30px; padding:0 11px; font-size:13px; }
.btn:disabled, .btn[aria-disabled="true"] { opacity:.45; cursor:default; }
.btn-block { width:100%; height:40px; }

.field { display:flex; flex-direction:column; gap:6px; min-width:0; }
.field label { font-size:13px; font-weight:500; color:var(--ink-2); }
.input, select.input {
  height:38px; padding:0 12px; width:100%; border-radius:var(--radius); border:1px solid var(--line);
  background:var(--surface); color:var(--ink); font:inherit; font-size:14px;
  transition:border-color .12s, box-shadow .12s;
}
.input::placeholder { color:var(--muted); opacity:.8; }
.input:focus { outline:none; border-color:var(--accent); box-shadow:0 0 0 3px var(--accent-soft); }
.input-sm { height:32px; font-size:13px; padding:0 10px; }
.hint { font-size:12.5px; color:var(--muted); }
.error-text { color:var(--red); font-size:13px; min-height:18px; }
.ok-text { color:var(--accent); font-size:13px; min-height:18px; }
.panel-body .error-text:empty, .page > .error-text:empty { display:none; }

/* ---------- app shell */
.shell { display:grid; grid-template-columns:236px minmax(0, 1fr); min-height:100vh; }
.side, .main { min-width:0; }
.side {
  background:var(--side); color:var(--side-ink); padding:20px 14px 16px;
  position:sticky; top:0; height:100vh; display:flex; flex-direction:column; gap:22px;
}
.brand { display:flex; align-items:center; gap:10px; padding:2px 8px; color:var(--side-ink); text-decoration:none; }
.brand svg { flex:none; }
.brand-name { font-weight:600; font-size:15px; line-height:1.2; }
.brand-co { font-size:12.5px; color:var(--side-muted); line-height:1.3; }
.nav { display:flex; flex-direction:column; gap:2px; }
.nav a {
  display:flex; align-items:center; gap:10px; padding:8px 10px; border-radius:var(--radius);
  color:var(--side-muted); text-decoration:none; font-weight:500; position:relative;
}
.nav a:hover { color:var(--side-ink); background:var(--side-hover); }
.nav a[aria-current="page"] { color:var(--side-ink); background:var(--side-hover); }
.nav a[aria-current="page"]::before {
  content:""; position:absolute; left:-14px; top:8px; bottom:8px; width:3px; border-radius:0 3px 3px 0; background:var(--accent);
}
.nav svg { width:18px; height:18px; flex:none; }
.nav .count { margin-left:auto; font-size:12px; color:var(--side-muted); }
.side-foot { margin-top:auto; border-top:1px solid rgba(255,255,255,.08); padding:14px 8px 0; font-size:13px; }
.side-foot .who { color:var(--side-ink); font-weight:500; }
.side-foot .role { color:var(--side-muted); text-transform:capitalize; }
.side-foot .btn { margin-top:10px; color:var(--side-muted); padding:0; height:auto; }
.side-foot .btn:hover { color:var(--side-ink); }
.side-foot .ver { margin-top:12px; font-size:11.5px; color:var(--side-muted); opacity:.7; }

.main { padding:30px 40px 60px; max-width:1180px; width:100%; }
.page[hidden] { display:none; }
.page-head { display:flex; align-items:flex-end; justify-content:space-between; gap:16px; margin-bottom:22px; flex-wrap:wrap; }
.page-head p { color:var(--muted); margin-top:6px; max-width:70ch; }
.page-actions { display:flex; gap:8px; flex-wrap:wrap; align-items:center; }
.stack > * + * { margin-top:18px; }

/* ---------- panels + tables */
.panel { background:var(--surface); border:1px solid var(--line); border-radius:var(--radius-lg); }
.panel-head { display:flex; align-items:flex-start; justify-content:space-between; gap:16px; padding:18px 20px 0; flex-wrap:wrap; }
.panel-head p { color:var(--muted); margin-top:4px; font-size:13.5px; max-width:75ch; }
.panel-body { padding:16px 20px 20px; }
.table-wrap { overflow-x:auto; margin-top:14px; border-top:1px solid var(--line-2); }
table { width:100%; border-collapse:collapse; }
th {
  text-align:left; font-size:12.5px; font-weight:500; color:var(--muted); background:var(--surface-2);
  padding:9px 14px; border-bottom:1px solid var(--line-2); white-space:nowrap;
}
td { padding:11px 14px; border-bottom:1px solid var(--line-2); white-space:nowrap; vertical-align:middle; }
tr:last-child td { border-bottom:0; }
tbody tr:hover td, tr.editing td { background:var(--surface-2); }
td .input-sm { min-width:160px; }
th.num, td.num { text-align:right; }
td.wrap { white-space:normal; min-width:220px; }
td.muted, .muted { color:var(--muted); }
td.actions { text-align:right; }
td.actions .btn + .btn { margin-left:6px; }
td.empty { color:var(--muted); padding:28px 14px; text-align:center; white-space:normal; }
.sub-id { display:block; color:var(--muted); font-size:12.5px; }

.pill { display:inline-flex; align-items:center; gap:6px; font-size:13px; font-weight:500; white-space:nowrap; }
.pill::before { content:""; width:7px; height:7px; border-radius:50%; background:currentColor; }
.pill.ok { color:var(--accent); } .pill.warn { color:var(--amber); } .pill.bad { color:var(--red); } .pill.idle { color:var(--muted); }
.t-warn { color:var(--amber); } .t-bad { color:var(--red); }

/* ---------- notices */
.notices { display:flex; flex-direction:column; gap:8px; margin-bottom:18px; }
.nav .count[data-dot="1"]::after { content:""; display:inline-block; width:7px; height:7px; border-radius:50%; background:var(--amber); margin-left:6px; vertical-align:1px; }
.notice {
  display:flex; gap:12px; align-items:flex-start; padding:11px 14px; border-radius:var(--radius);
  border:1px solid var(--line); border-left-width:3px; background:var(--surface); font-size:13.5px;
}
.notice.error { border-left-color:var(--red); background:var(--red-soft); border-color:transparent; border-left-color:var(--red); }
.notice.warning { border-left-color:var(--amber); background:var(--amber-soft); border-color:transparent; border-left-color:var(--amber); }
.notice.info { border-left-color:var(--accent); }
.notice strong { font-weight:600; }

/* ---------- overview: summary strip */
.summary { display:grid; grid-template-columns:repeat(4, minmax(0, 1fr)); }
.summary > div { padding:16px 20px; border-left:1px solid var(--line-2); min-width:0; }
.summary > div:first-child { border-left:0; }
.summary .k { font-size:12.5px; color:var(--muted); }
.summary .v { font-size:22px; font-weight:600; margin-top:2px; font-variant-numeric:tabular-nums; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.summary .v small { font-size:14px; font-weight:500; color:var(--muted); }
.summary .d { font-size:12.5px; color:var(--muted); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }

/* ---------- overview: day timeline (the signature element) */
.day-nav { display:flex; align-items:center; gap:6px; }
.day-nav .day-label { font-weight:600; min-width:150px; text-align:center; font-variant-numeric:tabular-nums; }
.tl { padding:6px 20px 18px; }
.tl-row { display:grid; grid-template-columns:200px minmax(0, 1fr) 92px; align-items:center; gap:14px; min-height:40px; }
.tl-row + .tl-row { border-top:1px solid var(--line-2); }
.tl-axis { min-height:30px; border-top:0 !important; }
.tl-who { min-width:0; }
.tl-who .n { font-weight:500; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.tl-who .i { font-size:12px; color:var(--muted); }
.tl-track { position:relative; height:26px; }
.tl-grid { position:absolute; top:0; bottom:0; width:1px; background:var(--line-2); }
.tl-hour { position:absolute; top:6px; transform:translateX(-50%); font-size:11.5px; color:var(--muted); font-variant-numeric:tabular-nums; }
.tl-bar { position:absolute; top:9px; height:8px; border-radius:4px; background:var(--accent-soft); border:1px solid var(--accent); }
.tl-tick { position:absolute; top:4px; width:2px; height:18px; margin-left:-1px; border-radius:1px; background:var(--accent); }
.tl-tick.single { background:var(--amber); width:3px; }
.tl-sum { text-align:right; font-variant-numeric:tabular-nums; font-weight:500; }
.tl-sum.t-warn { font-weight:400; font-size:12.5px; }
.tl-now { position:absolute; top:-2px; bottom:-2px; width:0; border-left:1px dashed var(--red); }
.tl-empty { padding:36px 20px; text-align:center; color:var(--muted); }
.absent { padding:14px 20px 18px; border-top:1px solid var(--line-2); display:flex; gap:8px; flex-wrap:wrap; align-items:center; }
.absent .k { color:var(--muted); font-size:13px; margin-right:4px; }
.chip { display:inline-flex; align-items:center; height:26px; padding:0 10px; border-radius:13px; background:var(--surface-2); border:1px solid var(--line-2); font-size:13px; color:var(--ink-2); }

/* ---------- forms in panels */
.form-row { display:grid; gap:12px; align-items:end; }
.form-row.cols-2 { grid-template-columns:minmax(0, 1fr) auto; }
.form-row.cols-dev { grid-template-columns:1.3fr 1.1fr 90px 100px 1.2fr auto; }
.form-row.cols-exp { grid-template-columns:180px 180px minmax(180px, 260px) auto; justify-content:start; }
.setup {
  margin-top:16px; padding:16px 18px; border-radius:var(--radius); background:var(--accent-soft);
  border:1px solid color-mix(in srgb, var(--accent) 30%, transparent);
}
.setup h3 { font-size:15px; }
.setup ol { margin:8px 0 14px; padding-left:20px; line-height:1.7; }
.setup details { margin-top:12px; font-size:13px; color:var(--ink-2); }
.setup summary { cursor:pointer; }
.setup code { display:block; margin:8px 0; padding:8px 10px; border-radius:6px; background:var(--surface); word-break:break-all; font-size:12.5px; }
.search { max-width:260px; }

/* ---------- live sync progress */
.prog { display:flex; flex-direction:column; gap:5px; min-width:200px; max-width:300px; white-space:normal; }
.prog-text { font-size:13px; color:var(--ink-2); line-height:1.35; }
.prog-bar { height:6px; border-radius:3px; background:var(--line-2); overflow:hidden; position:relative; }
.prog-bar > span { display:block; height:100%; background:var(--accent); border-radius:3px; transition:width .4s ease; }
.prog-bar.busy > span { width:35% !important; position:absolute; animation:prog-slide 1.3s ease-in-out infinite; }
@keyframes prog-slide { from { left:-35%; } to { left:100%; } }
.prog-meta { font-size:12px; color:var(--muted); }
.fail-text { display:block; margin-top:4px; font-size:12.5px; color:var(--red); white-space:normal; min-width:220px; max-width:320px; line-height:1.35; }
tr.syncing td { background:color-mix(in srgb, var(--accent-soft) 45%, transparent); }

/* ---------- dialog */
dialog.dlg {
  border:1px solid var(--line); border-radius:var(--radius-lg); padding:0; width:min(460px, calc(100vw - 32px));
  background:var(--surface); color:var(--ink); box-shadow:0 20px 50px rgba(0,0,0,.25);
}
dialog.dlg::backdrop { background:rgba(10, 20, 18, .45); }
.dlg-body { padding:22px 22px 6px; }
.dlg-body h3 { font-size:17px; }
.dlg-body p { color:var(--ink-2); margin-top:8px; }
.dlg-opts { margin-top:14px; display:flex; flex-direction:column; gap:10px; }
.dlg-opt { display:flex; gap:10px; align-items:flex-start; padding:10px 12px; border:1px solid var(--line); border-radius:var(--radius); cursor:pointer; }
.dlg-opt:has(input:checked) { border-color:var(--accent); background:var(--accent-soft); }
.dlg-opt input[type=radio] { margin-top:3px; accent-color:var(--accent); }
.dlg-opt select { margin-top:8px; }
.dlg-foot { display:flex; justify-content:flex-end; gap:8px; padding:16px 22px 20px; }
.btn-danger-solid { background:var(--red); color:#fff; }
.btn-danger-solid:hover { filter:brightness(1.08); }

/* ---------- toast */
.toast {
  position:fixed; left:50%; bottom:24px; transform:translateX(-50%) translateY(20px); opacity:0;
  background:var(--ink); color:var(--canvas); padding:10px 16px; border-radius:var(--radius); font-size:13.5px;
  transition:opacity .18s, transform .18s; pointer-events:none; max-width:min(560px, calc(100vw - 32px)); z-index:10;
}
.toast.show { opacity:1; transform:translateX(-50%) translateY(0); }

/* ---------- responsive */
@media (max-width: 1000px) {
  .form-row.cols-dev { grid-template-columns:1fr 1fr; }
  .summary { grid-template-columns:repeat(2, minmax(0, 1fr)); }
  .summary > div:nth-child(3) { border-left:0; }
  .summary > div:nth-child(n+3) { border-top:1px solid var(--line-2); }
}
@media (max-width: 860px) {
  .shell { grid-template-columns:minmax(0, 1fr); }
  .side { position:sticky; height:auto; z-index:5; flex-direction:row; flex-wrap:wrap; align-items:center; gap:10px 16px; padding:12px 16px; }
  .nav { flex-direction:row; overflow-x:auto; width:100%; order:3; gap:4px; margin:0 -4px; }
  .nav a { padding:7px 10px; white-space:nowrap; }
  .nav a[aria-current="page"]::before { display:none; }
  .nav .count { display:none; }
  .side-foot { margin:0 0 0 auto; border:0; padding:0; display:flex; align-items:center; gap:12px; }
  .side-foot .who, .side-foot .role, .side-foot .ver { display:none; }
  .side-foot .btn { margin:0; }
  .main { padding:22px 16px 48px; }
  h1 { font-size:22px; }
  .tl-row { grid-template-columns:110px minmax(0, 1fr) 64px; gap:8px; }
  .tl { padding:6px 12px 14px; }
  .form-row.cols-2, .form-row.cols-dev, .form-row.cols-exp { grid-template-columns:1fr; }
}
@media (max-width: 520px) {
  .summary { grid-template-columns:1fr 1fr; }
  .summary > div { padding:12px 14px; }
  .summary .v { font-size:18px; }
}

/* ---------- sign-in pages */
.auth { display:grid; grid-template-columns:minmax(0, 1.05fr) minmax(0, 1fr); min-height:100vh; }
.auth-side { background:var(--side); color:var(--side-ink); padding:44px 52px; display:flex; flex-direction:column; justify-content:space-between; gap:40px; }
.auth-side h1 { font-size:34px; line-height:1.15; max-width:16ch; margin-top:56px; }
.auth-side p { color:var(--side-muted); margin-top:14px; max-width:44ch; font-size:15px; }
.demo { border-top:1px solid rgba(255,255,255,.1); padding-top:20px; max-width:520px; }
.demo-row { display:grid; grid-template-columns:96px 1fr; align-items:center; gap:12px; height:30px; font-size:13px; color:var(--side-muted); }
.demo-track { position:relative; height:8px; border-radius:4px; background:rgba(255,255,255,.06); }
.demo-bar { position:absolute; top:0; bottom:0; border-radius:4px; background:rgba(61,179,137,.35); border:1px solid #3DB389; }
.demo-bar.single { width:4px !important; background:#E3A94F; border-color:#E3A94F; }
.demo-axis { display:flex; justify-content:space-between; margin:8px 0 0 108px; font-size:11.5px; color:var(--side-muted); font-variant-numeric:tabular-nums; }
.auth-form { display:flex; align-items:center; justify-content:center; padding:40px 24px; }
.auth-card { width:100%; max-width:380px; }
.auth-card h2 { font-size:22px; }
.auth-card .lead { color:var(--muted); margin:6px 0 26px; }
.auth-card form { display:flex; flex-direction:column; gap:16px; }
.auth-card .alt { margin-top:22px; color:var(--muted); font-size:13.5px; }
.auth-foot { font-size:12px; color:var(--side-muted); opacity:.8; }
@media (max-width: 860px) {
  .auth { grid-template-columns:1fr; }
  .auth-side { padding:24px 20px; gap:16px; }
  .auth-side h1 { margin-top:18px; font-size:24px; }
  .demo, .auth-foot { display:none; }
}
`;

const FONT = `<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600&display=swap" rel="stylesheet">`;

/** Brand mark: a 24-hour dial with the working hours highlighted. */
const LOGO = `<svg width="30" height="30" viewBox="0 0 32 32" aria-hidden="true">
  <circle cx="16" cy="16" r="13" fill="none" stroke="currentColor" stroke-opacity=".28" stroke-width="2.5"/>
  <path d="M16 3 A13 13 0 0 1 28.4 20" fill="none" stroke="#3DB389" stroke-width="2.5" stroke-linecap="round"/>
  <path d="M16 9 V16 L20.5 18.5" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>
</svg>`;

function layout(title: string, body: string): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title} - HR Attendance</title>
<link rel="icon" href="data:image/svg+xml,${encodeURIComponent(LOGO.replace("currentColor", "#17302B").replace("currentColor", "#17302B"))}">
${FONT}
<style>${STYLE}</style>
</head>
<body>${body}</body>
</html>`;
}

// ------------------------------------------------------------------ sign in / sign up
const AUTH_SCRIPT = String.raw`<script>
document.getElementById("f").addEventListener("submit", async function (e) {
  e.preventDefault();
  var btn = this.querySelector("button[type=submit]");
  var msg = document.getElementById("msg");
  msg.textContent = "";
  btn.disabled = true;
  try {
    var res = await fetch(this.dataset.endpoint, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(Object.fromEntries(new FormData(this)))
    });
    var out = await res.json().catch(function () { return {}; });
    if (res.ok) { location.href = out.redirect || "/app"; return; }
    msg.textContent = out.error || "Something went wrong. Try again.";
  } catch (err) {
    msg.textContent = "Can't reach the server. Check your internet connection and try again.";
  }
  btn.disabled = false;
});
</script>`;

function authSide(): string {
  const rows: Array<[string, number, number]> = [
    ["Hilal Khan", 37, 71], ["Ayesha S.", 34, 76], ["Bilal J.", 40, 88], ["Awais Butt", 46, 0], ["Huda Ijaz", 35, 74],
  ];
  const demo = rows.map(([n, a, b]) =>
    `<div class="demo-row"><span>${n}</span><div class="demo-track"><div class="demo-bar${b ? "" : " single"}" style="left:${a}%;width:${b ? b - a : 0}%"></div></div></div>`).join("");
  return `<aside class="auth-side">
  <div>
    <div class="brand">${LOGO}<div><div class="brand-name">HR Attendance</div></div></div>
    <h1>Your time machine's punches, ready as Excel every two days.</h1>
    <p>The connector reads your ZKTeco machine in the office. Reports, names and missing check-outs are all here, without touching the machine.</p>
  </div>
  <div class="demo" aria-hidden="true">
    ${demo}
    <div class="demo-axis"><span>06:00</span><span>09:00</span><span>12:00</span><span>15:00</span><span>18:00</span><span>21:00</span></div>
  </div>
  <div class="auth-foot">${VERSION}</div>
</aside>`;
}

export function loginPage(): string {
  return layout("Sign in", `
<div class="auth">
  ${authSide()}
  <main class="auth-form"><div class="auth-card">
    <h2>Sign in</h2>
    <p class="lead">Use the email you registered your company with.</p>
    <form id="f" data-endpoint="/api/auth/login">
      <div class="field"><label for="email">Email</label><input class="input" id="email" name="email" type="email" autocomplete="email" required></div>
      <div class="field"><label for="password">Password</label><input class="input" id="password" name="password" type="password" autocomplete="current-password" required></div>
      <div class="error-text" id="msg" role="alert"></div>
      <button class="btn btn-primary btn-block" type="submit">Sign in</button>
    </form>
    <p class="alt">New company? <a href="/signup">Create an account</a></p>
  </div></main>
</div>
${AUTH_SCRIPT}`);
}

export function signupPage(requireCode: boolean): string {
  const codeField = requireCode
    ? `<div class="field"><label for="signup_code">Sign-up code</label><input class="input" id="signup_code" name="signup_code" type="text" autocomplete="off" required><span class="hint">Ask your administrator for this code.</span></div>`
    : "";
  return layout("Create account", `
<div class="auth">
  ${authSide()}
  <main class="auth-form"><div class="auth-card">
    <h2>Create your company account</h2>
    <p class="lead">You'll be the owner of this workspace and can add machines right after.</p>
    <form id="f" data-endpoint="/api/auth/signup">
      <div class="field"><label for="company_name">Company name</label><input class="input" id="company_name" name="company_name" type="text" autocomplete="organization" required></div>
      <div class="field"><label for="full_name">Your full name</label><input class="input" id="full_name" name="full_name" type="text" autocomplete="name" required></div>
      <div class="field"><label for="email">Work email</label><input class="input" id="email" name="email" type="email" autocomplete="email" required></div>
      <div class="field"><label for="password">Password</label><input class="input" id="password" name="password" type="password" autocomplete="new-password" minlength="8" required><span class="hint">At least 8 characters.</span></div>
      ${codeField}
      <div class="error-text" id="msg" role="alert"></div>
      <button class="btn btn-primary btn-block" type="submit">Create account</button>
    </form>
    <p class="alt">Already have an account? <a href="/login">Sign in</a></p>
  </div></main>
</div>
${AUTH_SCRIPT}`);
}

// ------------------------------------------------------------------ dashboard
const ICONS: Record<string, string> = {
  overview: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M4 7h16M4 12h10M4 17h13"/><circle cx="18" cy="12" r="1.6" fill="currentColor" stroke="none"/></svg>`,
  reports: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><path d="M6 3h8l4 4v14H6z"/><path d="M14 3v4h4M9 12h6M9 16h6"/></svg>`,
  employees: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="9" cy="8" r="3.2"/><path d="M3.5 19c.8-3 3-4.6 5.5-4.6s4.7 1.6 5.5 4.6"/><path d="M16 5.2a3 3 0 0 1 0 5.6M18 14.6c1.3.6 2.2 1.9 2.6 4.4"/></svg>`,
  machines: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><rect x="6" y="3" width="12" height="18" rx="2"/><rect x="9" y="6" width="6" height="4" rx="1"/><path d="M12 13.5c-1.5 0-2.5 1.2-2.5 2.6v1.4M14.5 17.5v-1.4c0-.6-.2-1.2-.5-1.6" stroke-linecap="round"/></svg>`,
  history: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 12a8 8 0 1 0 2.4-5.7L4 8.5"/><path d="M4 4v4.5h4.5M12 8v4.5l3 1.8"/></svg>`,
};

const NAV: Array<[string, string]> = [
  ["overview", "Overview"], ["reports", "Reports"], ["employees", "Employees"], ["machines", "Machines"], ["history", "Sync history"],
];

export function appPage(auth: AuthContext): string {
  const e = escapeHtml;
  const canManage = auth.role === "owner" || auth.role === "admin";
  const manageOnly = canManage ? "" : " hidden";
  const nav = NAV.map(([id, label]) =>
    `<a href="#${id}" data-page="${id}">${ICONS[id]}<span>${label}</span><span class="count" id="count_${id}"></span></a>`).join("");

  return layout("Dashboard", `
<div class="shell">
  <aside class="side">
    <a class="brand" href="#overview">${LOGO}<div><div class="brand-name">HR Attendance</div><div class="brand-co">${e(auth.companyName)}</div></div></a>
    <nav class="nav" aria-label="Main">${nav}</nav>
    <div class="side-foot">
      <div class="who">${e(auth.fullName)}</div>
      <div class="role">${e(auth.role)}</div>
      <button class="btn btn-quiet" id="logout" type="button">Sign out</button>
      <div class="ver">${VERSION}</div>
    </div>
  </aside>

  <main class="main" id="main">
    <!-- ============================== Overview -->
    <section class="page" id="page-overview">
      <div class="page-head">
        <div><h1>Overview</h1><p id="ov_sub">Who came in, when, and whether the machine is syncing.</p></div>
        <div class="page-actions"><button class="btn btn-ghost" id="sync_all_ov" type="button"${manageOnly}>Sync all machines now</button></div>
      </div>
      <div class="notices" data-alerts aria-live="polite"></div>
      <div class="stack">
        <div class="panel"><div class="summary" id="summary">
          <div><div class="k">Came in</div><div class="v" id="s_in">&nbsp;</div><div class="d" id="s_in_d">&nbsp;</div></div>
          <div><div class="k">Punches</div><div class="v" id="s_punches">&nbsp;</div><div class="d" id="s_punches_d">&nbsp;</div></div>
          <div><div class="k">Last sync</div><div class="v" id="s_sync">&nbsp;</div><div class="d" id="s_sync_d">&nbsp;</div></div>
          <div><div class="k">Next Excel report</div><div class="v" id="s_next">&nbsp;</div><div class="d" id="s_next_d">&nbsp;</div></div>
        </div></div>

        <div class="panel">
          <div class="panel-head">
            <div><h2>Attendance timeline</h2><p>Bars run from first punch to last punch. An amber mark means only one punch, so the check-out is missing.</p></div>
            <div class="day-nav">
              <button class="btn btn-ghost btn-sm" id="day_prev" type="button" aria-label="Previous day">&#8249;</button>
              <span class="day-label" id="day_label"></span>
              <button class="btn btn-ghost btn-sm" id="day_next" type="button" aria-label="Next day">&#8250;</button>
              <button class="btn btn-quiet btn-sm" id="day_today" type="button">Today</button>
            </div>
          </div>
          <div class="tl" id="timeline"></div>
          <div class="absent" id="absent" hidden></div>
        </div>
      </div>
    </section>

    <!-- ============================== Reports -->
    <section class="page" id="page-reports" hidden>
      <div class="page-head">
        <div><h1>Reports</h1><p id="r_sched">An Excel report of the previous two days is prepared automatically every two days.</p></div>
        <div class="page-actions"><button class="btn btn-ghost" id="sync_all" type="button"${manageOnly}>Sync all machines now</button></div>
      </div>
      <div class="stack">
        <div class="panel">
          <div class="panel-head"><div><h2>Scheduled reports</h2><p>Each file has one sheet per machine group, and one per machine that is not in a group (Time In, Time Out, Hours Worked), plus every punch. It's built when you download it, so late punches are included.</p></div></div>
          <div class="table-wrap"><table>
            <thead><tr><th>Period</th><th>Status</th><th class="num">Machines synced</th><th class="num">Employees</th><th class="num">Punches</th><th>Ready</th><th>Note</th><th></th></tr></thead>
            <tbody id="r_rows"></tbody>
          </table></div>
        </div>
        <div class="panel">
          <div class="panel-head"><div><h2>Export any dates</h2><p>Up to 62 days in one file.</p></div></div>
          <div class="panel-body">
            <div class="form-row cols-exp">
              <div class="field"><label for="x_from">From</label><input class="input" id="x_from" type="date"></div>
              <div class="field"><label for="x_to">To</label><input class="input" id="x_to" type="date"></div>
              <div class="field"><label for="x_scope">Machines</label><select class="input" id="x_scope"><option value="">All (one sheet each)</option></select></div>
              <button class="btn btn-primary" id="x_go" type="button">Download Excel</button>
            </div>
            <div class="error-text" id="x_msg" style="margin-top:8px"></div>
          </div>
        </div>
      </div>
    </section>

    <!-- ============================== Employees -->
    <section class="page" id="page-employees" hidden>
      <div class="page-head">
        <div><h1>Employees</h1><p id="e_sub">Names are read from the machine on every sync.</p></div>
        <div class="page-actions"><input class="input search" id="e_search" type="search" placeholder="Search name, ID or department" aria-label="Search employees"></div>
      </div>
      <div class="panel">
        <div class="table-wrap" style="margin-top:0;border-top:0;border-radius:12px">
          <table>
            <thead><tr><th class="num">User ID</th><th>Name</th><th>Department</th><th>Machine or group</th><th>Name from</th><th>Last punch</th><th></th></tr></thead>
            <tbody id="e_rows"></tbody>
          </table>
        </div>
      </div>
      <div class="error-text" id="e_msg" style="margin-top:10px"></div>
    </section>

    <!-- ============================== Machines -->
    <section class="page" id="page-machines" hidden>
      <div class="page-head">
        <div><h1>Machines</h1><p>The connector is a small program on an office PC that reads the attendance machine and sends the punches here. It only reads: nothing on the machine is changed or cleared.</p></div>
      </div>
      <div class="notices" data-alerts aria-live="polite"></div>
      <div class="stack">
        <div class="panel">
          <div class="panel-head"><div><h2>Connectors</h2><p>One per office PC. Download the installer, extract it on a Windows PC on the machine's network and double-click Install.cmd.</p></div></div>
          <div class="panel-body"${manageOnly}>
            <div class="form-row cols-2">
              <div class="field"><label for="c_name">New connector name</label><input class="input" id="c_name" placeholder="e.g. Reception PC"></div>
              <button class="btn btn-primary" id="c_add" type="button">Create connector</button>
            </div>
            <div class="error-text" id="c_msg" style="margin-top:8px"></div>
            <div id="c_token"></div>
          </div>
          <div class="table-wrap"><table>
            <thead><tr><th>Name</th><th>Status</th><th>Version</th><th>Last seen</th><th class="num">Machines</th><th>Token</th><th></th></tr></thead>
            <tbody id="c_rows"></tbody>
          </table></div>
        </div>

        <div class="panel">
          <div class="panel-head"><div><h2>Attendance machines</h2><p>Find the IP and comm key on the machine under Menu, then COMM. The default port is 4370.</p></div></div>
          <div class="panel-body"${manageOnly}>
            <div class="form-row cols-dev">
              <div class="field"><label for="d_name">Machine name</label><input class="input" id="d_name" placeholder="e.g. Main entrance"></div>
              <div class="field"><label for="d_ip">IP address</label><input class="input" id="d_ip" placeholder="192.168.10.21" inputmode="decimal"></div>
              <div class="field"><label for="d_port">Port</label><input class="input" id="d_port" value="4370" inputmode="numeric"></div>
              <div class="field"><label for="d_key">Comm key</label><input class="input" id="d_key" value="0" inputmode="numeric"></div>
              <div class="field"><label for="d_conn">Read by connector</label><select class="input" id="d_conn"></select></div>
              <button class="btn btn-primary" id="d_add" type="button">Add machine</button>
            </div>
            <div class="error-text" id="d_msg" style="margin-top:8px"></div>
          </div>
          <div class="table-wrap"><table>
            <thead><tr><th>Machine</th><th>Last sync</th><th>Clock</th><th class="num">Punches</th><th>Connector</th><th>Group</th><th></th></tr></thead>
            <tbody id="d_rows"></tbody>
          </table></div>
        </div>

        <div class="panel">
          <div class="panel-head"><div><h2>Machine groups</h2><p>Group machines that the same people use with the same user IDs, for example two machines in one office. A group is one sheet in the Excel report. A machine without a group has its own sheet, and ID 2 on it is a different person from ID 2 on any other machine.</p></div></div>
          <div class="panel-body"${manageOnly}>
            <div class="form-row cols-2">
              <div class="field"><label for="g_name">New group name</label><input class="input" id="g_name" placeholder="e.g. PIA Office" maxlength="40"></div>
              <button class="btn btn-primary" id="g_add" type="button">Create group</button>
            </div>
            <div class="error-text" id="g_msg" style="margin-top:8px"></div>
          </div>
          <div class="table-wrap"><table>
            <thead><tr><th>Group</th><th>Machines</th><th></th></tr></thead>
            <tbody id="g_rows"></tbody>
          </table></div>
        </div>
      </div>
    </section>

    <!-- ============================== Sync history -->
    <section class="page" id="page-history" hidden>
      <div class="page-head">
        <div><h1>Sync history</h1><p>Every time the connector read a machine. Read counts every punch on the machine; New counts the ones imported for the first time.</p></div>
      </div>
      <div class="panel">
        <div class="table-wrap" style="margin-top:0;border-top:0;border-radius:12px"><table>
          <thead><tr><th>Requested</th><th>Machine</th><th>Started by</th><th>Status</th><th class="num">Read</th><th class="num">New</th><th class="num">Skipped</th><th>Finished</th><th>Details</th><th></th></tr></thead>
          <tbody id="j_rows"></tbody>
        </table></div>
      </div>
    </section>
  </main>
</div>
<div class="toast" id="toast" role="status" aria-live="polite"></div>
<dialog class="dlg" id="dlg" aria-labelledby="dlg_title">
  <form method="dialog">
    <div class="dlg-body"><h3 id="dlg_title"></h3><div id="dlg_content"></div><div class="error-text" id="dlg_msg" style="margin-top:10px"></div></div>
    <div class="dlg-foot"><button class="btn btn-ghost" value="cancel" type="submit">Cancel</button><button class="btn btn-danger-solid" id="dlg_ok" value="ok" type="submit"></button></div>
  </form>
</dialog>
<script>var CAN_MANAGE = ${canManage ? "true" : "false"};</script>
${DASH_SCRIPT}`);
}

// Client script. Written with String.raw: no template substitutions or backticks inside.
const DASH_SCRIPT = String.raw`<script>
var DASH = "\u2014";
var MONTHS = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
var DAYS = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];

/* ---------- helpers */
async function api(method, path, body) {
  var opts = { method: method, headers: {} };
  if (body !== undefined) { opts.headers["content-type"] = "application/json"; opts.body = JSON.stringify(body); }
  var res = await fetch(path, opts);
  var data = await res.json().catch(function () { return {}; });
  if (res.status === 401) { location.href = "/login"; throw new Error("Signed out"); }
  if (!res.ok) throw new Error(data.error || ("Request failed (" + res.status + ")"));
  return data;
}
function el(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text !== undefined && text !== null) e.textContent = text; return e; }
function td(text, cls) { return el("td", cls, (text === null || text === undefined || text === "") ? DASH : String(text)); }
function pill(text, kind) { var c = el("td"); c.appendChild(el("span", "pill " + kind, text)); return c; }
function btn(label, kind, onClick) { var b = el("button", "btn btn-sm " + kind, label); b.type = "button"; b.addEventListener("click", onClick); return b; }
function emptyRow(tbody, cols, text) { var tr = el("tr"); var c = el("td", "empty", text); c.colSpan = cols; tr.appendChild(c); tbody.appendChild(tr); }
function setText(id, text) { document.getElementById(id).textContent = text || ""; }
var toastTimer;
function toast(text) { var t = document.getElementById("toast"); t.textContent = text; t.classList.add("show"); clearTimeout(toastTimer); toastTimer = setTimeout(function () { t.classList.remove("show"); }, 3500); }

function pad(n) { return String(n).padStart(2, "0"); }
function isoDay(d) { return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()); }
function parseDay(s) { var p = s.split("-"); return new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2])); }
function addDays(s, n) { var d = parseDay(s); d.setDate(d.getDate() + n); return isoDay(d); }
function fmtDay(s) { var d = parseDay(s); return d.getDate() + " " + MONTHS[d.getMonth()] + " " + d.getFullYear(); }
function fmtDayShort(s) { var d = parseDay(s); return DAYS[d.getDay()] + " " + d.getDate() + " " + MONTHS[d.getMonth()]; }
function period(a, b) { return a === b ? fmtDay(a) : (parseDay(a).getDate() + " " + MONTHS[parseDay(a).getMonth()] + " \u2013 " + fmtDay(b)); }
function shortPeriod(a, b) {
  var x = parseDay(a), y = parseDay(b);
  if (a === b) return y.getDate() + " " + MONTHS[y.getMonth()];
  return x.getMonth() === y.getMonth() ? x.getDate() + "\u2013" + y.getDate() + " " + MONTHS[y.getMonth()]
    : x.getDate() + " " + MONTHS[x.getMonth()] + " \u2013 " + y.getDate() + " " + MONTHS[y.getMonth()];
}
function when(iso) {
  if (!iso) return DASH;
  var d = new Date(iso);
  return d.getDate() + " " + MONTHS[d.getMonth()] + ", " + pad(d.getHours()) + ":" + pad(d.getMinutes());
}
function ago(iso) {
  if (!iso) return "Never";
  var m = Math.round((Date.now() - new Date(iso).getTime()) / 60000);
  if (m < 1) return "Just now";
  if (m < 60) return m + " min ago";
  if (m < 48 * 60) return Math.round(m / 60) + " h ago";
  return Math.round(m / 1440) + " days ago";
}
function punchTime(s) { return s ? s.slice(0, 16).replace(" ", ", ") : DASH; }
function minutes(t) { var p = t.split(":"); return Number(p[0]) * 60 + Number(p[1]); }
function dur(mins) { return Math.floor(mins / 60) + "h " + pad(mins % 60) + "m"; }

/* ---------- confirm dialog: onConfirm may throw to keep the dialog open with the error */
function confirmDialog(title, content, okLabel, onConfirm) {
  var dlg = document.getElementById("dlg");
  setText("dlg_title", title);
  var box = document.getElementById("dlg_content"); box.textContent = "";
  (Array.isArray(content) ? content : [content]).forEach(function (n) { box.appendChild(typeof n === "string" ? el("p", null, n) : n); });
  setText("dlg_msg", "");
  var ok = document.getElementById("dlg_ok"); ok.textContent = okLabel; ok.disabled = false;
  ok.onclick = async function (ev) {
    ev.preventDefault();
    ok.disabled = true;
    try { await onConfirm(); dlg.close(); }
    catch (err) { setText("dlg_msg", err.message); ok.disabled = false; }
  };
  dlg.showModal();
}

/* ---------- navigation */
var PAGES = ["overview", "reports", "employees", "machines", "history"];
function showPage() {
  var id = (location.hash || "#overview").slice(1);
  if (PAGES.indexOf(id) < 0) id = "overview";
  PAGES.forEach(function (p) {
    document.getElementById("page-" + p).hidden = p !== id;
    var a = document.querySelector('.nav a[data-page="' + p + '"]');
    if (p === id) a.setAttribute("aria-current", "page"); else a.removeAttribute("aria-current");
  });
  document.title = document.querySelector('.nav a[data-page="' + id + '"] span').textContent + " - HR Attendance";
  window.scrollTo(0, 0);
}
window.addEventListener("hashchange", showPage);

/* ---------- status notices */
async function loadStatus() {
  var data = await api("GET", "/api/status");
  document.querySelectorAll(".notices[data-alerts]").forEach(function (box) {
    box.textContent = "";
    box.hidden = !data.alerts.length;
    data.alerts.forEach(function (a) { box.appendChild(el("div", "notice " + a.level, a.text)); });
  });
  var urgent = data.alerts.filter(function (a) { return a.level !== "info"; }).length;
  document.getElementById("count_machines").dataset.dot = urgent ? "1" : "";
}

/* ---------- overview */
var ovDate = null;
var ovToday = null;
async function loadOverview() {
  var data = await api("GET", "/api/overview" + (ovDate ? "?date=" + ovDate : ""));
  ovDate = data.date; ovToday = data.today;
  var isToday = data.date === data.today;
  document.getElementById("day_label").textContent = isToday ? "Today, " + fmtDayShort(data.date) : fmtDayShort(data.date) + " " + parseDay(data.date).getFullYear();
  document.getElementById("day_next").disabled = isToday;
  document.getElementById("day_today").hidden = isToday;

  var total = data.present.length + data.absent.length;
  var s_in = document.getElementById("s_in"); s_in.textContent = data.present.length + " ";
  s_in.appendChild(el("small", null, "of " + total));
  var singles = data.present.filter(function (p) { return p.punches.length === 1; }).length;
  setText("s_in_d", singles ? singles + " without check-out" : (data.present.length ? "All with check-out" : (isToday ? "No punches yet today" : "No punches")));
  setText("s_punches", data.punches);
  setText("s_punches_d", isToday ? "So far today" : fmtDay(data.date));
  setText("s_sync", data.machines ? ago(data.last_sync) : "No machine");
  setText("s_sync_d", data.machines ? (data.machines + " machine" + (data.machines > 1 ? "s" : "")) : "Add one under Machines");
  var sc = data.schedule;
  setText("s_next", fmtDayShort(sc.next_due));
  setText("s_next_d", "After " + pad(sc.hour) + ":00, for " + shortPeriod(sc.next_start, sc.next_end));
  renderTimeline(data, isToday);
}

function renderTimeline(data, isToday) {
  var box = document.getElementById("timeline");
  box.textContent = "";
  var absentBox = document.getElementById("absent");
  absentBox.textContent = "";
  absentBox.hidden = !data.absent.length || !data.present.length;

  if (!data.present.length) {
    box.appendChild(el("div", "tl-empty", isToday
      ? "No one has punched in yet today. Punches appear here after the next sync."
      : "No punches on this day."));
    return;
  }

  // Axis: whole hours around the earliest and latest punch, at least 06:00 - 20:00.
  var first = 24 * 60, last = 0;
  data.present.forEach(function (p) { first = Math.min(first, minutes(p.punches[0])); last = Math.max(last, minutes(p.punches[p.punches.length - 1])); });
  var startH = Math.max(0, Math.min(6, Math.floor(first / 60) - 1));
  var endH = Math.min(24, Math.max(20, Math.ceil(last / 60) + 1));
  var span = (endH - startH) * 60;
  function pos(m) { return ((m - startH * 60) / span * 100) + "%"; }
  // Keep hour labels at least ~48px apart, whatever the screen width.
  var trackPx = Math.max(120, box.clientWidth - (window.innerWidth <= 860 ? 200 : 340));
  var step = [1, 2, 3, 4, 6, 12].find(function (h) { return trackPx / (endH - startH) * h >= 48; }) || 12;

  function gridInto(track, withLabels) {
    for (var h = startH; h <= endH; h++) {
      if ((h - startH) % step !== 0) continue;
      var g = el(withLabels ? "span" : "div", withLabels ? "tl-hour" : "tl-grid", withLabels ? pad(h) + ":00" : null);
      g.style.left = pos(h * 60);
      track.appendChild(g);
    }
  }

  var axis = el("div", "tl-row tl-axis");
  axis.appendChild(el("div"));
  var axisTrack = el("div", "tl-track"); gridInto(axisTrack, true); axis.appendChild(axisTrack);
  axis.appendChild(el("div", "tl-sum muted", "Hours"));
  box.appendChild(axis);

  var nowMin = null;
  if (isToday) { var n = new Date(); nowMin = n.getHours() * 60 + n.getMinutes(); }

  data.present.forEach(function (p) {
    var row = el("div", "tl-row");
    var who = el("div", "tl-who");
    who.appendChild(el("div", "n", p.name || ("User " + p.user_id)));
    who.appendChild(el("div", "i", "ID " + p.user_id + (p.where ? " \u00b7 " + p.where : "") + (p.department ? " \u00b7 " + p.department : "")));
    row.appendChild(who);

    var track = el("div", "tl-track");
    gridInto(track, false);
    var a = minutes(p.punches[0]), b = minutes(p.punches[p.punches.length - 1]);
    var single = p.punches.length === 1;
    if (!single) {
      var bar = el("div", "tl-bar"); bar.style.left = pos(a); bar.style.width = ((b - a) / span * 100) + "%";
      track.appendChild(bar);
    }
    p.punches.forEach(function (t) {
      var tick = el("div", "tl-tick" + (single ? " single" : ""));
      tick.style.left = pos(minutes(t));
      tick.title = t;
      track.appendChild(tick);
    });
    if (nowMin !== null && nowMin >= startH * 60 && nowMin <= endH * 60) {
      var now = el("div", "tl-now"); now.style.left = pos(nowMin); now.title = "Now"; track.appendChild(now);
    }
    var label = p.punches.join(", ");
    track.setAttribute("role", "img");
    track.setAttribute("aria-label", (p.name || "User " + p.user_id) + ": punches at " + label);
    track.title = label;
    row.appendChild(track);

    row.appendChild(single
      ? el("div", "tl-sum t-warn", "In " + p.punches[0])
      : el("div", "tl-sum", dur(b - a)));
    box.appendChild(row);
  });

  if (!absentBox.hidden) {
    absentBox.appendChild(el("span", "k", "No punch (" + data.absent.length + "):"));
    data.absent.forEach(function (x) { absentBox.appendChild(el("span", "chip", (x.name || ("ID " + x.user_id)) + (x.where ? " \u00b7 " + x.where : ""))); });
  }
}

document.getElementById("day_prev").addEventListener("click", function () { ovDate = addDays(ovDate, -1); loadOverview().catch(function (e) { toast(e.message); }); });
document.getElementById("day_next").addEventListener("click", function () { if (ovDate < ovToday) { ovDate = addDays(ovDate, 1); loadOverview().catch(function (e) { toast(e.message); }); } });
document.getElementById("day_today").addEventListener("click", function () { ovDate = null; loadOverview().catch(function (e) { toast(e.message); }); });

/* ---------- reports */
async function loadReports() {
  var data = await api("GET", "/api/reports");
  var s = data.schedule;
  setText("r_sched", "Every " + s.every_days + " days, an Excel report of the previous " + s.every_days + " days is prepared after " +
    pad(s.hour) + ":00 (" + s.timezone + "). Next: " + period(s.next_start, s.next_end) + ", ready on " + fmtDay(s.next_due) + ".");
  var tbody = document.getElementById("r_rows");
  tbody.textContent = "";
  document.getElementById("count_reports").textContent = data.reports.length ? data.reports.length : "";
  if (!data.reports.length) emptyRow(tbody, 8, "No reports yet. The first one appears at the next scheduled time, or use Export any dates below.");
  data.reports.forEach(function (r) {
    var tr = el("tr");
    tr.appendChild(td(period(r.period_start, r.period_end)));
    tr.appendChild(r.status === "ready" ? pill("Ready", "ok") : pill("Collecting", "warn"));
    tr.appendChild(td(r.devices_synced + " of " + r.devices_total, "num"));
    tr.appendChild(td(r.status === "ready" ? r.employee_count : "", "num"));
    tr.appendChild(td(r.status === "ready" ? r.punch_count : "", "num"));
    tr.appendChild(td(r.ready_at ? when(r.ready_at) : ""));
    tr.appendChild(td(r.note, r.note ? "wrap t-warn" : "muted"));
    var actions = el("td", "actions");
    var a = el("a", "btn btn-sm " + (r.status === "ready" ? "btn-primary" : "btn-ghost"), "Download Excel");
    a.href = "/api/reports/" + r.id + "/download";
    actions.appendChild(a);
    tr.appendChild(actions);
    tbody.appendChild(tr);
  });
}

document.getElementById("x_from").value = isoDay(new Date(Date.now() - 2 * 86400000));
document.getElementById("x_to").value = isoDay(new Date(Date.now() - 86400000));
document.getElementById("x_go").addEventListener("click", function () {
  var from = document.getElementById("x_from").value;
  var to = document.getElementById("x_to").value;
  if (!from || !to) { setText("x_msg", "Choose both dates."); return; }
  if (to < from) { setText("x_msg", "The end date must be on or after the start date."); return; }
  setText("x_msg", "");
  var scope = document.getElementById("x_scope").value;
  location.href = "/api/export.xlsx?from=" + encodeURIComponent(from) + "&to=" + encodeURIComponent(to) +
    (scope ? "&scope=" + encodeURIComponent(scope) : "");
});

/* ---------- employees */
var empEditing = false;
var empData = [];
function cellInput(value, placeholder, maxLength, label) {
  var i = el("input", "input input-sm");
  i.value = value || ""; i.placeholder = placeholder || ""; i.maxLength = maxLength; i.setAttribute("aria-label", label);
  return i;
}
async function loadEmployees() {
  if (empEditing) return; // never wipe what someone is typing
  var data = await api("GET", "/api/employees");
  empData = data.employees;
  document.getElementById("count_employees").textContent = data.total || "";
  setText("e_sub", data.total + " employee" + (data.total === 1 ? "" : "s") +
    (data.unnamed ? ", " + data.unnamed + " without a name" : "") +
    ". Names are read from the machine on every sync." +
    (CAN_MANAGE ? " Type a name to override it; clear it to use the machine's name again." : ""));
  renderEmployees();
}
var empEditingId = null;
function empKey(e) { return e.scope_id + "|" + e.user_id; }
function scopeCell(e) {
  var c = el("td", "muted");
  c.appendChild(document.createTextNode(e.scope_name));
  if (e.scope_kind === "group") c.appendChild(el("span", "sub-id", "Group"));
  return c;
}
function renderEmployees() {
  var q = document.getElementById("e_search").value.trim().toLowerCase();
  var tbody = document.getElementById("e_rows");
  tbody.textContent = "";
  var list = empData.filter(function (e) {
    return !q || (e.user_id + " " + e.name + " " + (e.machine_name || "") + " " + e.department + " " + e.scope_name).toLowerCase().indexOf(q) >= 0;
  });
  if (!empData.length) { emptyRow(tbody, 7, "No employees yet. They appear after the first sync."); return; }
  if (!list.length) { emptyRow(tbody, 7, "No employee matches \u201c" + q + "\u201d."); return; }
  list.forEach(function (e) { tbody.appendChild(empKey(e) === empEditingId ? editRow(e) : viewRow(e)); });
}
function viewRow(e) {
  var tr = el("tr");
  tr.appendChild(td(e.user_id, "num"));
  var name = el("td");
  if (e.name) name.appendChild(el("span", null, e.name)); else name.appendChild(el("span", "pill warn", "Needs a name"));
  tr.appendChild(name);
  tr.appendChild(td(e.department, e.department ? "" : "muted"));
  tr.appendChild(scopeCell(e));
  tr.appendChild(td(e.name_edited ? "Edited here" : (e.machine_name ? "Machine" : ""), "muted"));
  tr.appendChild(td(punchTime(e.last_punch), "muted"));
  var actions = el("td", "actions");
  if (CAN_MANAGE) actions.appendChild(btn("Edit", "btn-ghost", function () {
    empEditingId = empKey(e); empEditing = true; renderEmployees();
    var f = document.querySelector("#e_rows input"); if (f) f.focus();
  }));
  tr.appendChild(actions);
  return tr;
}
function editRow(e) {
  var tr = el("tr", "editing");
  tr.appendChild(td(e.user_id, "num"));
  var nameIn = cellInput(e.name, e.machine_name || "Enter a name", 80, "Name for user " + e.user_id);
  var deptIn = cellInput(e.department, "Add department", 60, "Department for user " + e.user_id);
  var c1 = el("td"); c1.appendChild(nameIn);
  if (e.machine_name) c1.appendChild(el("span", "sub-id", "On the machine: " + e.machine_name));
  tr.appendChild(c1);
  var c2 = el("td"); c2.appendChild(deptIn); tr.appendChild(c2);
  tr.appendChild(scopeCell(e));
  tr.appendChild(td(e.name_edited ? "Edited here" : (e.machine_name ? "Machine" : ""), "muted"));
  tr.appendChild(td(punchTime(e.last_punch), "muted"));
  function done() { empEditingId = null; empEditing = false; }
  var save = btn("Save", "btn-primary", async function () {
    save.disabled = true;
    var name = nameIn.value.trim();
    // Same as the machine's name (or empty): keep following the machine.
    if (e.machine_name && name === e.machine_name) name = "";
    try {
      await api("PUT", "/api/employees/" + e.scope_id + "/" + encodeURIComponent(e.user_id), { name: name, department: deptIn.value });
      setText("e_msg", "");
      done();
      toast("Saved " + (name || e.machine_name || "user " + e.user_id));
      await loadEmployees();
    } catch (err) { setText("e_msg", err.message); save.disabled = false; }
  });
  var cancel = btn("Cancel", "btn-quiet", function () { done(); setText("e_msg", ""); renderEmployees(); });
  [nameIn, deptIn].forEach(function (x) {
    x.addEventListener("keydown", function (ev) { if (ev.key === "Enter") save.click(); if (ev.key === "Escape") cancel.click(); });
  });
  var c3 = el("td", "actions"); c3.appendChild(cancel); c3.appendChild(save); tr.appendChild(c3);
  return tr;
}
document.getElementById("e_search").addEventListener("input", function () { if (!empEditing) renderEmployees(); });

/* ---------- machines: connectors */
async function downloadInstaller(connectorId, token) {
  var res = await fetch("/api/connectors/" + connectorId + "/package", {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(token ? { token: token } : {})
  });
  if (res.status === 401) { location.href = "/login"; throw new Error("Signed out"); }
  if (!res.ok) { var d = await res.json().catch(function () { return {}; }); throw new Error(d.error || ("Download failed (" + res.status + ")")); }
  var blob = await res.blob();
  var m = /filename="([^"]+)"/.exec(res.headers.get("content-disposition") || "");
  var a = el("a"); a.href = URL.createObjectURL(blob); a.download = m ? m[1] : "ZKT-Connector.zip";
  document.body.appendChild(a); a.click();
  setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 2000);
}

var connectorsData = [];
var devicesData = [];
async function loadConnectors() {
  var data = await api("GET", "/api/connectors");
  var tbody = document.getElementById("c_rows");
  var select = document.getElementById("d_conn");
  tbody.textContent = ""; select.textContent = "";
  var active = data.connectors.filter(function (c) { return c.is_active; });
  connectorsData = data.connectors;
  if (!active.length) { var o0 = el("option", null, "Create a connector first"); o0.value = ""; select.appendChild(o0); }
  if (!data.connectors.length) emptyRow(tbody, 7, "No connectors yet. Create one above, then download its installer.");
  data.connectors.forEach(function (c) {
    var tr = el("tr");
    tr.appendChild(td(c.name));
    var online = c.last_seen_at && (Date.now() - new Date(c.last_seen_at).getTime()) < 2 * 60000;
    tr.appendChild(!c.is_active ? pill("Revoked", "idle") : !c.last_seen_at ? pill("Not installed", "warn") : online ? pill("Online", "ok") : pill("Offline", "bad"));
    tr.appendChild(td(c.version, "muted"));
    tr.appendChild(td(c.last_seen_at ? ago(c.last_seen_at) : "", "muted"));
    tr.appendChild(td(c.device_count, "num"));
    tr.appendChild(td(c.token_hint ? "\u2026" + c.token_hint : "", "muted"));
    var actions = el("td", "actions");
    var deletable = !c.is_active || (!c.last_seen_at && !c.device_count);
    if (CAN_MANAGE && deletable) {
      actions.appendChild(btn("Delete", "btn-danger", function () {
        confirmDialog("Delete " + c.name + "?",
          [c.is_active ? "This connector was never installed. Deleting it removes it from this list." :
            "This connector is revoked and can no longer sync. Deleting it removes it from this list. Attendance already imported is kept."],
          "Delete connector",
          async function () { await api("DELETE", "/api/connectors/" + c.id); toast("Deleted " + c.name); await refreshMachines(); });
      }));
    }
    if (CAN_MANAGE && c.is_active) {
      actions.appendChild(btn("Download installer", "btn-ghost", async function () {
        if (c.last_seen_at && !confirm("Download a new installer for " + c.name + "?\n\nThis creates a new token. The PC that runs this connector now stops syncing until you run Install.cmd from the new download on it.")) return;
        try { await downloadInstaller(c.id, null); toast("Installer downloaded. Extract it on the office PC and run Install.cmd."); await refreshMachines(); }
        catch (err) { setText("c_msg", err.message); }
      }));
      actions.appendChild(btn("Revoke", "btn-danger", async function () {
        if (!confirm("Revoke " + c.name + "? It stops syncing immediately.")) return;
        try { await api("POST", "/api/connectors/" + c.id + "/revoke", {}); toast("Revoked " + c.name); await refreshMachines(); } catch (err) { setText("c_msg", err.message); }
      }));
    }
    tr.appendChild(actions);
    tbody.appendChild(tr);
  });
  active.forEach(function (c) { var o = el("option", null, c.name); o.value = c.id; select.appendChild(o); });
}

document.getElementById("c_add").addEventListener("click", async function () {
  setText("c_msg", "");
  var box = document.getElementById("c_token"); box.textContent = "";
  try {
    var r = await api("POST", "/api/connectors", { name: document.getElementById("c_name").value });
    var wrap = el("div", "setup");
    wrap.appendChild(el("h3", null, "Install " + r.connector.name + " on the office PC"));
    var steps = el("ol");
    ["Download the installer. It's already set up for your company.",
     "Copy the ZIP to a Windows PC on the same network as the machine.",
     "Right-click the ZIP, choose Extract All, then double-click Install.cmd and click Yes."].forEach(function (t) { steps.appendChild(el("li", null, t)); });
    wrap.appendChild(steps);
    var dl = btn("Download installer", "btn-primary", async function () {
      dl.disabled = true;
      try { await downloadInstaller(r.connector.id, r.token); dl.textContent = "Downloaded"; toast("Installer downloaded"); }
      catch (err) { setText("c_msg", err.message); dl.disabled = false; }
    });
    dl.classList.remove("btn-sm");
    wrap.appendChild(dl);
    var adv = el("details");
    adv.appendChild(el("summary", null, "Show the token for manual setup"));
    adv.appendChild(el("code", null, r.token));
    var copy = btn("Copy token", "btn-ghost", function () { navigator.clipboard.writeText(r.token); copy.textContent = "Copied"; });
    adv.appendChild(copy);
    wrap.appendChild(adv);
    box.appendChild(wrap);
    document.getElementById("c_name").value = "";
    await refreshMachines();
  } catch (err) { setText("c_msg", err.message); }
});

/* ---------- machines: devices */
function clockText(sec) {
  if (sec === null || sec === undefined) return null;
  var a = Math.abs(sec);
  if (a <= 60) return { t: "Correct", k: "ok" };
  var t = a < 5400 ? Math.round(a / 60) + " min" : a < 172800 ? Math.round(a / 3600) + " h" : Math.round(a / 86400) + " days";
  return { t: t + (sec < 0 ? " slow" : " fast"), k: "warn" };
}
var devicesTimer = null;
function syncCell(d, active) {
  var c = el("td");
  var st = d.last_job_status;
  if (!d.is_active) { c.appendChild(el("span", "pill idle", "Inactive")); return c; }
  if (active) {
    var box = el("div", "prog");
    var waitingFor = st === "pending" ? Math.round((Date.now() - new Date(d.job_requested_at).getTime()) / 1000) : 0;
    var connectorLive = d.connector_seen && Date.now() - new Date(d.connector_seen).getTime() < 60000;
    var text = st !== "pending" ? (d.job_msg || "Syncing\u2026")
      : waitingFor < 20 && connectorLive ? "Starting\u2026 the connector picks this up in a few seconds"
      : connectorLive ? "The connector has not picked this up yet. On the office PC open Start menu > ZKT Connector > ZKT Connector status."
      : "Waiting for the connector, but it is not running. On the office PC open Start menu > ZKT Connector > Start ZKT Connector.";
    box.appendChild(el("div", "prog-text", text));
    var bar = el("div", "prog-bar" + (d.job_pct === null || d.job_pct === undefined || st === "pending" || d.job_stage === "retrying" ? " busy" : ""));
    var fill = el("span"); fill.style.width = (d.job_pct || 0) + "%"; bar.appendChild(fill);
    box.appendChild(bar);
    if (st === "pending" && waitingFor > 20) box.appendChild(el("div", "prog-meta", "Waiting " + waitingFor + " s. It stops by itself after 10 minutes."));
    c.appendChild(box);
    return c;
  }
  if (st === "failed") {
    c.appendChild(el("span", "pill bad", "Failed " + (d.job_finished_at ? ago(d.job_finished_at).toLowerCase() : "")));
    if (d.job_error) { var f = el("span", "fail-text", d.job_error); f.title = d.job_error; c.appendChild(f); }
    return c;
  }
  c.appendChild(el("span", "pill " + (st === "success" ? "ok" : "idle"), d.last_sync_at ? ago(d.last_sync_at) : "Never"));
  if (st === "success" && d.job_new !== null && d.job_new !== undefined) c.appendChild(el("span", "sub-id", d.job_new + " new punches"));
  return c;
}

var groupsData = [];
async function loadDevices() {
  var anyActive = false;
  var both = await Promise.all([api("GET", "/api/devices"), api("GET", "/api/groups")]);
  var data = both[0];
  groupsData = both[1].groups;
  renderGroups();
  renderExportScopes(data.devices);
  var tbody = document.getElementById("d_rows");
  tbody.textContent = "";
  devicesData = data.devices;
  document.getElementById("count_machines").textContent = data.devices.filter(function (d) { return d.is_active; }).length || "";
  if (!data.devices.length) emptyRow(tbody, 7, "No machines yet. Add your attendance machine above.");
  data.devices.forEach(function (d) {
    var tr = el("tr");
    var name = el("td"); name.appendChild(document.createTextNode(d.name));
    name.appendChild(el("span", "sub-id", d.ip_address + ":" + d.port + (d.is_active ? "" : " \u00b7 deactivated")));
    if (d.serial_number) name.appendChild(el("span", "sub-id", "Serial " + d.serial_number));
    tr.appendChild(name);
    var st = d.last_job_status;
    var active = d.is_active && (st === "pending" || st === "running");
    if (active) { anyActive = true; tr.className = "syncing"; }
    tr.appendChild(syncCell(d, active));
    var ck = clockText(d.clock_offset_seconds);
    tr.appendChild(ck ? pill(ck.t, ck.k) : td(""));
    tr.appendChild(td(d.log_count, "num"));
    tr.appendChild(td(d.connector_name, "muted"));
    tr.appendChild(groupCell(d));
    var actions = el("td", "actions");
    if (CAN_MANAGE && active) {
      actions.appendChild(btn("Stop", "btn-danger", async function () {
        try { await api("POST", "/api/sync-jobs/" + d.job_id + "/cancel", {}); toast("Stopped the sync of " + d.name); await refreshMachines(); }
        catch (err) { toast(err.message); await refreshMachines(); }
      }));
    } else if (CAN_MANAGE && d.is_active) {
      actions.appendChild(btn("Sync now", "btn-ghost", async function () {
        try {
          var r = await api("POST", "/api/devices/" + d.id + "/sync", {});
          toast(r.already_queued ? "A sync for " + d.name + " is already running." : "Sync started. Progress is shown here.");
          await refreshMachines();
        } catch (err) { setText("d_msg", err.message); }
      }));
      actions.appendChild(btn("Deactivate", "btn-danger", async function () {
        if (!confirm("Deactivate " + d.name + "? Its attendance data is kept.")) return;
        try { await api("POST", "/api/devices/" + d.id + "/deactivate", {}); toast("Deactivated " + d.name); await refreshMachines(); } catch (err) { setText("d_msg", err.message); }
      }));
    }
    if (CAN_MANAGE && !d.is_active) actions.appendChild(btn("Delete", "btn-danger", function () { deleteMachine(d); }));
    tr.appendChild(actions);
    tbody.appendChild(tr);
  });
  // While a sync runs, refresh every 1.5 s to show live progress; then refresh the rest once.
  clearTimeout(devicesTimer);
  if (anyActive) {
    devicesTimer = setTimeout(function () { quiet(loadDevices()); }, 1500);
    wasActive = true;
  } else if (wasActive) {
    wasActive = false;
    quiet(loadJobs()); quiet(loadStatus()); quiet(loadEmployees()); if (ovDate === ovToday) quiet(loadOverview());
  }
}
var wasActive = false;

/* ---------- machines: groups */
function groupCell(d) {
  if (!CAN_MANAGE || (!groupsData.length && !d.group_id)) return td(d.group_name, "muted");
  var c = el("td");
  var sel = el("select", "input input-sm");
  sel.setAttribute("aria-label", "Group for " + d.name);
  var none = el("option", null, "No group"); none.value = ""; sel.appendChild(none);
  groupsData.forEach(function (g) { var o = el("option", null, g.name); o.value = g.id; sel.appendChild(o); });
  sel.value = d.group_id || "";
  sel.addEventListener("change", async function () {
    sel.disabled = true;
    try {
      await api("PUT", "/api/devices/" + d.id + "/group", { group_id: sel.value || null });
      var g = groupsData.find(function (x) { return x.id === sel.value; });
      toast(g ? d.name + " is now in " + g.name : d.name + " is no longer in a group");
      await refreshAfterGrouping();
    } catch (err) { setText("d_msg", err.message); sel.value = d.group_id || ""; sel.disabled = false; }
  });
  c.appendChild(sel);
  return c;
}
function refreshAfterGrouping() {
  return Promise.all([quiet(loadDevices()), quiet(loadEmployees()), quiet(loadOverview())]);
}
function renderGroups() {
  var tbody = document.getElementById("g_rows");
  tbody.textContent = "";
  if (!groupsData.length) { emptyRow(tbody, 3, "No groups. Every machine is reported on its own sheet."); return; }
  groupsData.forEach(function (g) {
    var tr = el("tr");
    tr.appendChild(td(g.name));
    tr.appendChild(td(g.machines ? g.machine_names : "No machines yet. Choose this group in the Group column above.", g.machines ? "" : "muted"));
    var actions = el("td", "actions");
    if (CAN_MANAGE) {
      actions.appendChild(btn("Rename", "btn-ghost", async function () {
        var name = prompt("New name for the group " + g.name, g.name);
        if (name === null || name.trim() === g.name) return;
        try { await api("PUT", "/api/groups/" + g.id, { name: name }); toast("Renamed to " + name.trim()); await refreshAfterGrouping(); }
        catch (err) { setText("g_msg", err.message); }
      }));
      actions.appendChild(btn("Delete", "btn-danger", function () {
        confirmDialog("Delete the group " + g.name + "?",
          [g.machines ? "Its machines (" + g.machine_names + ") stay, without a group. Each one gets its own sheet in the Excel report again." : "It has no machines.",
           "No attendance or employee names are deleted."],
          "Delete group",
          async function () { await api("DELETE", "/api/groups/" + g.id); toast("Deleted the group " + g.name); await refreshAfterGrouping(); });
      }));
    }
    tr.appendChild(actions);
    tbody.appendChild(tr);
  });
}
function renderExportScopes(devices) {
  var sel = document.getElementById("x_scope");
  var keep = sel.value;
  while (sel.options.length > 1) sel.remove(1);
  groupsData.filter(function (g) { return g.machines > 0; }).forEach(function (g) {
    var o = el("option", null, g.name + " (group)"); o.value = g.id; sel.appendChild(o);
  });
  devices.filter(function (d) { return !d.group_id; }).forEach(function (d) {
    var o = el("option", null, d.name + (d.is_active ? "" : " (deactivated)")); o.value = d.id; sel.appendChild(o);
  });
  sel.value = keep;
  if (sel.value !== keep) sel.value = "";
}
document.getElementById("g_add").addEventListener("click", async function () {
  var input = document.getElementById("g_name");
  try {
    var r = await api("POST", "/api/groups", { name: input.value });
    input.value = ""; setText("g_msg", "");
    toast("Created " + r.group.name + ". Now choose it in the Group column of each machine.");
    await loadDevices();
  } catch (err) { setText("g_msg", err.message); }
});
document.getElementById("g_name").addEventListener("keydown", function (ev) { if (ev.key === "Enter") document.getElementById("g_add").click(); });

function deleteMachine(d) {
  var punches = Number(d.log_count) || 0;
  if (!punches) {
    confirmDialog("Delete " + d.name + "?", ["This machine is deactivated and has no punches. Deleting it removes it from this list."], "Delete machine",
      async function () { await api("DELETE", "/api/devices/" + d.id, {}); toast("Deleted " + d.name); await refreshAll(); });
    return;
  }
  var targets = devicesData.filter(function (x) { return x.id !== d.id && x.is_active; });
  var opts = el("div", "dlg-opts");
  var moveSel = null;
  function option(value, title, hint, checked) {
    var lab = el("label", "dlg-opt");
    var r = el("input"); r.type = "radio"; r.name = "dlg_choice"; r.value = value; r.checked = checked;
    var txt = el("div"); txt.appendChild(el("div", null, title)); if (hint) txt.appendChild(el("div", "hint", hint));
    lab.appendChild(r); lab.appendChild(txt); opts.appendChild(lab);
    return txt;
  }
  if (targets.length) {
    var t = option("move", "Move the punches to another machine", "Keeps them in reports. Use this when the same machine was added again.", true);
    moveSel = el("select", "input input-sm");
    targets.forEach(function (x) { var o = el("option", null, x.name + " (" + x.ip_address + ")"); o.value = x.id; if (x.ip_address === d.ip_address) o.selected = true; moveSel.appendChild(o); });
    t.appendChild(moveSel);
  }
  option("delete", "Delete the punches too", "They disappear from all reports and Excel files. This can't be undone.", !targets.length);
  confirmDialog("Delete " + d.name + "?",
    ["This machine is deactivated but holds " + punches + " punches.", opts],
    "Delete machine",
    async function () {
      var choice = (document.querySelector('input[name="dlg_choice"]:checked') || {}).value;
      var body = choice === "move" ? { move_to: moveSel.value } : { delete_punches: true };
      var r = await api("DELETE", "/api/devices/" + d.id, body);
      var target = choice === "move" ? moveSel.options[moveSel.selectedIndex].textContent.replace(/ \(.*\)$/, "") : "";
      toast(choice !== "move" ? "Deleted " + d.name + " and its " + r.punches + " punches"
        : r.moved === r.punches ? "Deleted " + d.name + ". Moved " + r.moved + " punches to " + target + "."
        : "Deleted " + d.name + ". " + target + " already had " + (r.punches - r.moved) + " of its punches" + (r.moved ? "; moved the other " + r.moved + "." : ", so nothing was lost."));
      await refreshAll();
    });
}
document.getElementById("d_add").addEventListener("click", async function () {
  setText("d_msg", "");
  try {
    await api("POST", "/api/devices", {
      name: document.getElementById("d_name").value,
      ip_address: document.getElementById("d_ip").value,
      port: document.getElementById("d_port").value,
      comm_key: document.getElementById("d_key").value,
      connector_id: document.getElementById("d_conn").value
    });
    toast("Added " + document.getElementById("d_name").value);
    document.getElementById("d_name").value = "";
    document.getElementById("d_ip").value = "";
    await refreshMachines();
  } catch (err) { setText("d_msg", err.message); }
});

/* ---------- sync history */
async function loadJobs() {
  var data = await api("GET", "/api/sync-jobs?limit=30");
  var tbody = document.getElementById("j_rows");
  tbody.textContent = "";
  if (!data.jobs.length) emptyRow(tbody, 10, "No syncs yet. Click Sync now on a machine, or wait for the scheduled sync.");
  var anyActive = false;
  var LABEL = { success: ["Done", "ok"], failed: ["Failed", "bad"], pending: ["Waiting", "warn"], running: ["Syncing", "warn"] };
  data.jobs.forEach(function (j) {
    var tr = el("tr");
    tr.appendChild(td(when(j.requested_at)));
    tr.appendChild(td(j.device_name));
    tr.appendChild(td(j.trigger_type === "scheduled" ? "Schedule" : "Manual", "muted"));
    var l = LABEL[j.status] || [j.status, "idle"];
    tr.appendChild(pill(l[0], l[1]));
    tr.appendChild(td(j.status === "success" ? j.records_fetched + (j.records_skipped || 0) : "", "num"));
    tr.appendChild(td(j.status === "success" ? j.records_inserted : "", "num"));
    tr.appendChild(td(j.records_skipped || "", j.records_skipped ? "num t-warn" : "num muted"));
    tr.appendChild(td(j.finished_at ? when(j.finished_at) : ""));
    var isActive = j.status === "pending" || j.status === "running";
    if (isActive) anyActive = true;
    tr.appendChild(td(isActive ? (j.progress_msg || (j.status === "pending" ? "Waiting for the connector" : "Syncing")) + (j.progress_pct !== null && j.progress_pct !== undefined && j.status === "running" ? " (" + j.progress_pct + "%)" : "") : j.error_message,
      isActive ? "wrap muted" : j.error_message ? "wrap t-bad" : "muted"));
    var act = el("td", "actions");
    if (CAN_MANAGE && isActive) act.appendChild(btn("Stop", "btn-danger", async function () {
      try { await api("POST", "/api/sync-jobs/" + j.id + "/cancel", {}); toast("Sync stopped"); } catch (err) { toast(err.message); }
      quiet(loadJobs()); quiet(loadDevices());
    }));
    tr.appendChild(act);
    tbody.appendChild(tr);
  });
  clearTimeout(jobsTimer);
  if (anyActive) jobsTimer = setTimeout(function () { quiet(loadJobs()); }, 2000);
}
var jobsTimer = null;

/* ---------- sync all */
async function syncAllNow(b) {
  b.disabled = true;
  try {
    var r = await api("POST", "/api/devices/sync-all", {});
    toast(r.devices ? (r.queued ? "Sync started for " + r.queued + " machine" + (r.queued > 1 ? "s" : "") + ". Progress is shown under Machines." : "Already syncing.") : "No machine has an active connector yet.");
    await refreshAll();
  } catch (err) { toast(err.message); }
  b.disabled = false;
}
document.getElementById("sync_all").addEventListener("click", function () { syncAllNow(this); });
document.getElementById("sync_all_ov").addEventListener("click", function () { syncAllNow(this); });

document.getElementById("logout").addEventListener("click", async function () {
  await fetch("/api/auth/logout", { method: "POST", headers: { "content-type": "application/json" }, body: "{}" });
  location.href = "/login";
});

/* ---------- refresh */
function quiet(p) { return p.catch(function (e) { if (e.message !== "Signed out") console.warn(e); }); }
function refreshMachines() { return Promise.all([quiet(loadConnectors()), quiet(loadDevices()), quiet(loadStatus())]); }
function refreshAll() {
  return Promise.all([quiet(loadStatus()), quiet(loadOverview()), quiet(loadReports()), quiet(loadEmployees()),
    quiet(loadConnectors()), quiet(loadDevices()), quiet(loadJobs())]);
}
showPage();
refreshAll();
setInterval(function () {
  if (document.hidden) return;
  quiet(loadStatus()); quiet(loadJobs()); quiet(loadReports()); quiet(loadDevices()); quiet(loadConnectors());
  if (ovDate === ovToday) quiet(loadOverview());
}, 20000);
</script>`;
'@

# ---------------------------------------------------------------- worker/src/env.ts
Write-File "worker/src/env.ts" @'
export interface Env {
  DB: D1Database;
  /** Optional. When set, sign-up requires this code (set with: wrangler secret put SIGNUP_CODE). */
  SIGNUP_CODE?: string;
}

export const VERSION = "0.13.0-phase13";

/** Number of files in worker/migrations. The health check reports "degraded" until all are applied. */
export const EXPECTED_MIGRATIONS = 7;
'@

# ---------------------------------------------------------------- worker/package.json
Write-File "worker/package.json" @'
{
  "name": "hr-attendance-worker",
  "version": "0.13.0",
  "private": true,
  "scripts": {
    "bundle-connector": "node scripts/bundle-connector.mjs",
    "dev": "npm run bundle-connector && wrangler dev",
    "deploy": "npm run bundle-connector && wrangler deploy",
    "typecheck": "npm run bundle-connector && tsc --noEmit"
  },
  "devDependencies": {
    "@cloudflare/workers-types": "^5.20261001.1",
    "typescript": "^5.6.0",
    "wrangler": "^4.0.0"
  }
}
'@

Write-Host ""
Write-Host "Phase 13 files written." -ForegroundColor Cyan
Write-Host "Next: cd worker; npx wrangler d1 migrations apply DB --remote; npm run deploy" -ForegroundColor Cyan
