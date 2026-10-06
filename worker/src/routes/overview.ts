// GET /api/overview?date=YYYY-MM-DD - one day of attendance for the dashboard timeline.
import type { Env } from "../env";
import { HttpError, json } from "../lib/http";
import { requireAuth } from "../lib/auth";
import { addDays, isDate, localNow } from "../lib/dates";
import { schedule } from "./reports";

export async function overview(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  const today = localNow(new Date(), auth.companyTimezone).date;
  const q = new URL(request.url).searchParams.get("date");
  if (q !== null && !isDate(q)) throw new HttpError(400, "date must be YYYY-MM-DD");
  const date = q ?? today;

  const { results: punches } = await env.DB.prepare(
    `SELECT l.device_user_id AS user_id, substr(l.punch_time, 12, 5) AS time
       FROM attendance_logs l
      WHERE l.company_id = ? AND l.punch_time >= ? AND l.punch_time < ?
      ORDER BY l.punch_time`,
  ).bind(auth.companyId, `${date} 00:00:00`, `${addDays(date, 1)} 00:00:00`).all<{ user_id: string; time: string }>();

  // Everyone the company knows: employees table + anyone who ever punched.
  const { results: people } = await env.DB.prepare(
    `WITH ids AS (
       SELECT device_user_id FROM employees WHERE company_id = ?1 AND is_active = 1
       UNION SELECT DISTINCT device_user_id FROM attendance_logs WHERE company_id = ?1
     )
     SELECT ids.device_user_id AS user_id, NULLIF(e.full_name, '') AS name, e.department
       FROM ids LEFT JOIN employees e ON e.company_id = ?1 AND e.device_user_id = ids.device_user_id`,
  ).bind(auth.companyId).all<{ user_id: string; name: string | null; department: string | null }>();

  const sync = await env.DB.prepare(
    "SELECT MAX(last_sync_at) AS last_sync, COUNT(*) AS machines FROM devices WHERE company_id = ? AND is_active = 1",
  ).bind(auth.companyId).first<{ last_sync: string | null; machines: number }>();

  const byUser = new Map<string, string[]>();
  for (const p of punches ?? []) {
    const list = byUser.get(p.user_id) ?? [];
    list.push(p.time);
    byUser.set(p.user_id, list);
  }
  const info = new Map((people ?? []).map((p) => [p.user_id, p]));
  const present = [...byUser].map(([user_id, times]) => ({
    user_id, name: info.get(user_id)?.name ?? null, department: info.get(user_id)?.department ?? null, punches: times,
  }));
  present.sort((a, b) => a.punches[0].localeCompare(b.punches[0]) || a.user_id.localeCompare(b.user_id));
  const absent = (people ?? [])
    .filter((p) => !byUser.has(p.user_id))
    .map((p) => ({ user_id: p.user_id, name: p.name }))
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