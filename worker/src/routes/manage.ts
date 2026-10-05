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