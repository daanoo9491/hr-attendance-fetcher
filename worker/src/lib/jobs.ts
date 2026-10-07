// Sync-job housekeeping: a sync never stays "Waiting" or "Syncing" forever.
import type { Env } from "../env";

/** A manual sync not picked up within this time fails (connector PC is probably off). */
export const PENDING_MANUAL_MINUTES = 10;
/** Scheduled syncs (for the 2-day report) wait as long as the report does. */
export const PENDING_SCHEDULED_MINUTES = 180;
/** A running sync whose connector has not reported for this long fails. */
export const SILENT_RUNNING_MINUTES = 3;

function minutesAgo(now: Date, m: number): string {
  return new Date(now.getTime() - m * 60_000).toISOString();
}

/** Marks stuck jobs as failed with a clear reason. Optional scope: one company or one connector. */
export async function expireStaleJobs(env: Env, scope: { companyId?: string; connectorId?: string } = {}, now = new Date()) {
  const ts = now.toISOString();
  const where = scope.connectorId
    ? " AND device_id IN (SELECT id FROM devices WHERE connector_id = ?)"
    : scope.companyId ? " AND company_id = ?" : "";
  const extra = scope.connectorId ?? scope.companyId;
  const bind = (...v: unknown[]) => (extra ? [...v, extra] : v);

  await env.DB.batch([
    env.DB.prepare(
      `UPDATE sync_jobs SET status = 'failed', finished_at = ?, progress_msg = NULL,
              error_message = 'The connector did not start this sync within ${PENDING_MANUAL_MINUTES} minutes. Check that the connector PC is on and connected to the internet.'
        WHERE status = 'pending' AND trigger_type = 'manual' AND requested_at < ?${where}`,
    ).bind(...bind(ts, minutesAgo(now, PENDING_MANUAL_MINUTES))),
    env.DB.prepare(
      `UPDATE sync_jobs SET status = 'failed', finished_at = ?, progress_msg = NULL,
              error_message = 'The connector did not start this scheduled sync within ${PENDING_SCHEDULED_MINUTES / 60} hours. Check that the connector PC is on.'
        WHERE status = 'pending' AND trigger_type = 'scheduled' AND requested_at < ?${where}`,
    ).bind(...bind(ts, minutesAgo(now, PENDING_SCHEDULED_MINUTES))),
    env.DB.prepare(
      `UPDATE sync_jobs SET status = 'failed', finished_at = ?, progress_msg = NULL,
              error_message = 'The connector stopped responding during this sync (no update for ${SILENT_RUNNING_MINUTES} minutes). It may have been closed or lost its internet connection.'
        WHERE status = 'running' AND COALESCE(heartbeat_at, started_at) < ?${where}`,
    ).bind(...bind(ts, minutesAgo(now, SILENT_RUNNING_MINUTES))),
  ]);
}