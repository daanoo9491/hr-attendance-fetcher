// Attendance Edit page: one day, everyone on the roster, with machine punches and any manual edit.
import type { Env } from "../env";
import { HttpError, json, readJson } from "../lib/http";
import { requireAuth, requireRole } from "../lib/auth";
import { addDays, isDate, localNow } from "../lib/dates";
import { TIME_RE, editKey, loadEdits } from "../lib/edits";
import { byUserId, loadPeople, loadScopes, personKey, uniqueLabels, type Person } from "../lib/scopes";
import { USER_ID_RE } from "./employees";

/** GET /api/attendance?date=YYYY-MM-DD[&scope=<group or machine id>] */
export async function dayAttendance(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  const today = localNow(new Date(), auth.companyTimezone).date;
  const params = new URL(request.url).searchParams;
  const q = params.get("date");
  if (q !== null && !isDate(q)) throw new HttpError(400, "date must be YYYY-MM-DD");
  const date = q ?? addDays(today, -1);

  const { scopes, byId, scopeOfDevice, machines } = await loadScopes(env, auth.companyId);
  const scopeId = params.get("scope") || "";
  if (scopeId && !byId.has(scopeId)) throw new HttpError(404, "Machine or group not found");
  const inScope = (deviceId: string) => !scopeId || scopeOfDevice.get(deviceId)?.id === scopeId;

  const [people, edits, punchRes] = await Promise.all([
    loadPeople(env, auth.companyId, machines),
    loadEdits(env, auth.companyId, date, date),
    env.DB.prepare(
      `SELECT device_id, device_user_id, substr(punch_time, 12, 5) AS time
         FROM attendance_logs
        WHERE company_id = ? AND punch_time >= ? AND punch_time < ?
        ORDER BY punch_time`,
    ).bind(auth.companyId, `${date} 00:00:00`, `${addDays(date, 1)} 00:00:00`)
      .all<{ device_id: string; device_user_id: string; time: string }>(),
  ]);

  const punches = new Map<string, string[]>();
  for (const p of punchRes.results ?? []) {
    const key = personKey(p.device_id, p.device_user_id);
    const list = punches.get(key) ?? [];
    list.push(p.time);
    punches.set(key, list);
  }

  // Roster + anyone with a punch or an edit on this day.
  const rows: Person[] = [];
  for (const [key, p] of people) {
    if (!inScope(p.deviceId)) continue;
    if (p.inRoster || punches.has(key) || edits.has(editKey(p.deviceId, p.userId, date))) rows.push(p);
  }
  const order = [...machines.keys()];
  rows.sort((a, b) => (order.indexOf(a.deviceId) - order.indexOf(b.deviceId)) || byUserId(a.userId, b.userId));
  const labels = uniqueLabels(rows, machines);

  const out = rows.map((p) => {
    const key = personKey(p.deviceId, p.userId);
    const times = punches.get(key) ?? [];
    const machineIn = times[0] ?? null;
    const machineOut = times.length > 1 ? times[times.length - 1] : null;
    const edit = edits.get(editKey(p.deviceId, p.userId, date)) ?? null;
    const timeIn = edit ? edit.time_in : machineIn;
    const timeOut = edit ? edit.time_out : machineOut;
    const status = edit ? "edited" : !times.length ? "absent" : !machineOut ? "missing_out" : "ok";
    const m = machines.get(p.deviceId)!;
    return {
      device_id: p.deviceId, machine: m.name, group: m.groupName, user_id: p.userId,
      name: labels.get(key) ?? p.name, hidden: p.hidden,
      punches: times, machine_in: machineIn, machine_out: machineOut,
      time_in: timeIn, time_out: timeOut, status,
      edit: edit && { time_in: edit.time_in, time_out: edit.time_out, note: edit.note, edited_by: edit.edited_by, edited_at: edit.edited_at },
    };
  });

  return json({
    date,
    today,
    rows: out,
    counts: {
      total: out.length,
      missing_out: out.filter((r) => r.status === "missing_out").length,
      absent: out.filter((r) => r.status === "absent").length,
      edited: out.filter((r) => r.status === "edited").length,
    },
    scopes: scopes.filter((s) => s.active).map((s) => ({ id: s.id, kind: s.kind, name: s.name })),
  });
}

function cleanTime(value: unknown, field: string): string | null {
  if (value === undefined || value === null || value === "") return null;
  if (typeof value !== "string" || !TIME_RE.test(value.trim())) throw new HttpError(400, `${field} must be a time like 09:05`);
  return value.trim();
}

async function checkTarget(env: Env, companyId: string, deviceId: string, userId: string, date: string, today: string) {
  if (!USER_ID_RE.test(userId)) throw new HttpError(400, "Invalid user ID");
  if (!isDate(date)) throw new HttpError(400, "Invalid date");
  if (date > today) throw new HttpError(400, "You can't edit attendance for a future date");
  const device = await env.DB.prepare("SELECT id FROM devices WHERE id = ? AND company_id = ?")
    .bind(deviceId, companyId).first();
  if (!device) throw new HttpError(404, "Machine not found");
}

/** PUT /api/attendance/:deviceId/:userId/:date  { time_in, time_out, note? }  (empty time = blank) */
export async function saveAttendanceEdit(request: Request, env: Env, deviceId: string, userId: string, date: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  await checkTarget(env, auth.companyId, deviceId, userId, date, localNow(new Date(), auth.companyTimezone).date);

  const body = await readJson<Record<string, unknown>>(request);
  const timeIn = cleanTime(body.time_in, "Time In");
  const timeOut = cleanTime(body.time_out, "Time Out");
  if (timeIn && timeOut && timeOut <= timeIn) throw new HttpError(400, "Time Out must be after Time In");
  const note = typeof body.note === "string" ? body.note.trim().replace(/\s+/g, " ").slice(0, 200) : "";
  const now = new Date().toISOString();
  const by = auth.fullName || auth.email;

  await env.DB.prepare(
    `INSERT INTO attendance_edits (id, company_id, device_id, device_user_id, work_date, time_in, time_out, note, edited_by, edited_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, NULLIF(?8, ''), ?9, ?10)
     ON CONFLICT (device_id, device_user_id, work_date) DO UPDATE SET
       time_in = ?6, time_out = ?7, note = NULLIF(?8, ''), edited_by = ?9, edited_at = ?10`,
  ).bind(crypto.randomUUID(), auth.companyId, deviceId, userId, date, timeIn, timeOut, note, by, now).run();

  return json({ ok: true, time_in: timeIn, time_out: timeOut, note: note || null, edited_by: by, edited_at: now });
}

/** DELETE /api/attendance/:deviceId/:userId/:date - back to the machine's punches. */
export async function deleteAttendanceEdit(request: Request, env: Env, deviceId: string, userId: string, date: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  if (!USER_ID_RE.test(userId) || !isDate(date)) throw new HttpError(400, "Invalid user ID or date");
  await env.DB.prepare(
    "DELETE FROM attendance_edits WHERE company_id = ? AND device_id = ? AND device_user_id = ? AND work_date = ?",
  ).bind(auth.companyId, deviceId, userId, date).run();
  return json({ ok: true });
}