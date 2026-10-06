// Attendance report API (browser session). Any role may view and download.
import type { Env } from "../env";
import { HttpError, json } from "../lib/http";
import { requireAuth, type AuthContext } from "../lib/auth";
import { daysBetween, isDate, localNow, nextPeriod } from "../lib/dates";
import { buildAttendanceReport, reportFilename, xlsxResponse } from "../report";

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

/** GET /api/export.xlsx?from=YYYY-MM-DD&to=YYYY-MM-DD */
export async function exportRange(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  const params = new URL(request.url).searchParams;
  const from = params.get("from");
  const to = params.get("to");
  if (!isDate(from) || !isDate(to)) throw new HttpError(400, "from and to must be dates (YYYY-MM-DD)");
  if (to < from) throw new HttpError(400, "'to' must be on or after 'from'");
  if (daysBetween(from, to) + 1 > MAX_EXPORT_DAYS) throw new HttpError(400, `Export at most ${MAX_EXPORT_DAYS} days at a time`);

  const { bytes } = await buildAttendanceReport(
    env,
    { companyId: auth.companyId, companyName: auth.companyName, timezone: auth.companyTimezone, notes: ["Manual export."] },
    from,
    to,
  );
  return xlsxResponse(bytes, reportFilename(auth.companyName, from, to));
}