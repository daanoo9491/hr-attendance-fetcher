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