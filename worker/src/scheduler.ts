// Runs every hour (Cloudflare cron). For each company:
//  1. A "collecting" report becomes "ready" once its sync jobs have finished (or after 3 hours).
//  2. When a report period has ended (default: every 2 days, after 01:00 local time),
//     create the report and a scheduled sync job for every active machine.
import type { Env } from "./env";
import { localNow, nextPeriod } from "./lib/dates";
import { attendanceStats } from "./report";

const MAX_COLLECT_MINUTES = 180;

interface CompanyRow {
  id: string;
  timezone: string;
  report_every_days: number;
  report_hour: number;
}

interface ReportRow {
  id: string;
  company_id: string;
  period_start: string;
  period_end: string;
  created_at: string;
}

export async function runScheduler(env: Env, now = new Date()): Promise<void> {
  const { results } = await env.DB.prepare(
    "SELECT id, timezone, report_every_days, report_hour FROM companies WHERE status = 'active'",
  ).all<CompanyRow>();

  for (const company of results ?? []) {
    try {
      await finishCollecting(env, company, now);
      await startDuePeriod(env, company, now);
    } catch (err) {
      console.error(`scheduler: company ${company.id}: ${String(err)}`);
    }
  }
}

async function finishCollecting(env: Env, company: CompanyRow, now: Date): Promise<void> {
  const { results } = await env.DB.prepare(
    "SELECT id FROM reports WHERE company_id = ? AND status = 'collecting'",
  ).bind(company.id).all<{ id: string }>();
  for (const r of results ?? []) await finalizeReportIfDone(env, r.id, now);
}

/**
 * Marks a collecting report "ready" when none of its sync jobs are still open,
 * or when it has waited MAX_COLLECT_MINUTES. Called hourly and whenever a linked job completes.
 */
export async function finalizeReportIfDone(env: Env, reportId: string, now = new Date()): Promise<boolean> {
  const report = await env.DB.prepare(
    "SELECT id, company_id, period_start, period_end, created_at FROM reports WHERE id = ? AND status = 'collecting'",
  ).bind(reportId).first<ReportRow>();
  if (!report) return false;

  const jobs = await env.DB.prepare(
    `SELECT SUM(CASE WHEN status IN ('pending','running') THEN 1 ELSE 0 END) AS open,
            SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END) AS ok,
            SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) AS failed
       FROM sync_jobs WHERE report_id = ?`,
  ).bind(report.id).first<{ open: number | null; ok: number | null; failed: number | null }>();

  const open = jobs?.open ?? 0;
  const minutes = (now.getTime() - Date.parse(report.created_at)) / 60000;
  if (open > 0 && minutes < MAX_COLLECT_MINUTES) return false;

  const notes: string[] = [];
  if (jobs?.failed) notes.push(`${jobs.failed} machine sync(s) failed`);
  if (open > 0) notes.push(`${open} machine(s) had not synced after ${MAX_COLLECT_MINUTES / 60} hours - is the connector PC on?`);
  const stats = await attendanceStats(env, report.company_id, report.period_start, report.period_end);

  const res = await env.DB.prepare(
    `UPDATE reports
        SET status = 'ready', ready_at = ?, devices_synced = ?, punch_count = ?, employee_count = ?, note = ?
      WHERE id = ? AND status = 'collecting'`,
  ).bind(now.toISOString(), jobs?.ok ?? 0, stats.punches, stats.employees, notes.join("; ") || null, report.id).run();
  return (res.meta.changes ?? 0) > 0;
}

async function startDuePeriod(env: Env, company: CompanyRow, now: Date): Promise<void> {
  // Only one report collects at a time.
  const collecting = await env.DB.prepare(
    "SELECT 1 FROM reports WHERE company_id = ? AND status = 'collecting' LIMIT 1",
  ).bind(company.id).first();
  if (collecting) return;

  const local = localNow(now, company.timezone);
  const last = await env.DB.prepare(
    "SELECT period_end FROM reports WHERE company_id = ? ORDER BY period_end DESC LIMIT 1",
  ).bind(company.id).first<{ period_end: string }>();
  const period = nextPeriod(last?.period_end ?? null, local.date, company.report_every_days);

  // Due once the period's last day is over and it's past the report hour.
  if (local.date < period.dueDate) return;
  if (local.date === period.dueDate && local.hour < company.report_hour) return;

  const reportId = crypto.randomUUID();
  const inserted = await env.DB.prepare(
    "INSERT OR IGNORE INTO reports (id, company_id, period_start, period_end, created_at) VALUES (?, ?, ?, ?, ?)",
  ).bind(reportId, company.id, period.start, period.end, now.toISOString()).run();
  if (!inserted.meta.changes) return;

  const { results: devices } = await env.DB.prepare(
    `SELECT d.id FROM devices d JOIN connectors c ON c.id = d.connector_id
      WHERE d.company_id = ? AND d.is_active = 1 AND c.is_active = 1`,
  ).bind(company.id).all<{ id: string }>();

  const statements: D1PreparedStatement[] = [
    env.DB.prepare("UPDATE reports SET devices_total = ? WHERE id = ?").bind(devices?.length ?? 0, reportId),
  ];
  for (const d of devices ?? []) {
    const open = await env.DB.prepare(
      "SELECT id FROM sync_jobs WHERE device_id = ? AND status IN ('pending','running') LIMIT 1",
    ).bind(d.id).first<{ id: string }>();
    if (open) {
      statements.push(env.DB.prepare("UPDATE sync_jobs SET report_id = ? WHERE id = ?").bind(reportId, open.id));
    } else {
      statements.push(
        env.DB.prepare(
          `INSERT INTO sync_jobs (id, company_id, device_id, trigger_type, status, report_id, requested_at)
           VALUES (?, ?, ?, 'scheduled', 'pending', ?, ?)`,
        ).bind(crypto.randomUUID(), company.id, d.id, reportId, now.toISOString()),
      );
    }
  }
  await env.DB.batch(statements);

  // No machines: nothing to wait for.
  if (!devices?.length) await finalizeReportIfDone(env, reportId, now);
}