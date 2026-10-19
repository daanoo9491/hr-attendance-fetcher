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

  // A person = user ID on one machine. Same roster as the Employees page and the report.
  const { machines } = await loadScopes(env, auth.companyId);
  const people = await loadPeople(env, auth.companyId, machines);
  const showWhere = [...machines.values()].filter((m) => m.active).length > 1;
  const where = (deviceId: string) => (showWhere ? machines.get(deviceId)?.name ?? null : null);

  const sync = await env.DB.prepare(
    "SELECT MAX(last_sync_at) AS last_sync, COUNT(*) AS machines FROM devices WHERE company_id = ? AND is_active = 1",
  ).bind(auth.companyId).first<{ last_sync: string | null; machines: number }>();

  const byPerson = new Map<string, { deviceId: string; userId: string; times: string[] }>();
  for (const p of punches ?? []) {
    const key = personKey(p.device_id, p.user_id);
    const entry = byPerson.get(key) ?? { deviceId: p.device_id, userId: p.user_id, times: [] };
    entry.times.push(p.time);
    byPerson.set(key, entry);
  }
  const present = [...byPerson].map(([key, e]) => {
    const info = people.get(key);
    e.times.sort();
    return {
      user_id: e.userId, name: info?.name || null, department: info?.department || null,
      where: where(e.deviceId), punches: e.times,
    };
  });
  present.sort((a, b) => a.punches[0].localeCompare(b.punches[0]) || a.user_id.localeCompare(b.user_id));
  const absent = [...people]
    .filter(([key, p]) => p.inRoster && !byPerson.has(key))
    .map(([, p]) => ({ user_id: p.userId, name: p.name || null, where: where(p.deviceId) }))
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