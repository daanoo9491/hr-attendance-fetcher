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