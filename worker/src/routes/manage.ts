// Dashboard (session-authenticated) API: connectors, devices, sync jobs.
// Every query is filtered by auth.companyId, so tenants never see each other's data.
import type { Env } from "../env";
import { HttpError, json, readJson } from "../lib/http";
import { requireAuth, requireRole } from "../lib/auth";
import { randomToken, sha256Hex } from "../lib/crypto";
import { expireStaleJobs } from "../lib/jobs";

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
            d.connector_id, c.name AS connector_name, c.is_active AS connector_active, c.last_seen_at AS connector_seen,
            d.last_sync_at, d.clock_offset_seconds, d.clock_checked_at, d.is_active, d.created_at,
            (SELECT COUNT(*) FROM attendance_logs l WHERE l.device_id = d.id) AS log_count,
            j.id AS job_id, j.status AS last_job_status, j.trigger_type AS job_trigger, j.requested_at AS job_requested_at,
            j.progress_stage AS job_stage, j.progress_pct AS job_pct, j.progress_msg AS job_msg,
            j.error_message AS job_error, j.finished_at AS job_finished_at, j.records_inserted AS job_new
       FROM devices d
       LEFT JOIN connectors c ON c.id = d.connector_id
       LEFT JOIN sync_jobs j ON j.id = (SELECT id FROM sync_jobs WHERE device_id = d.id ORDER BY requested_at DESC LIMIT 1)
      WHERE d.company_id = ?
      ORDER BY d.is_active DESC, d.created_at DESC`,
  ).bind(auth.companyId).all();
  return json({ devices: results ?? [], server_time: new Date().toISOString() });
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
      );
      moved = count;
    } else if (body.delete_punches !== true) {
      throw new HttpError(409, `This machine has ${count} punches. Move them to another machine or confirm deleting them.`);
    }
  }
  statements.push(
    env.DB.prepare("DELETE FROM attendance_logs WHERE device_id = ?").bind(id),
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