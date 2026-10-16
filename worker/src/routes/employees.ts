// Employees (dashboard). A user ID belongs to its machine, or to the machine's group:
// "ID 2" on two separate machines is two people; on two machines of one group it is one person.
import type { Env } from "../env";
import { HttpError, json, readJson } from "../lib/http";
import { requireAuth, requireRole } from "../lib/auth";
import { byUserId, loadPeople, loadScopes, personKey } from "../lib/scopes";

export const USER_ID_RE = /^[A-Za-z0-9_.-]{1,32}$/;

function cleanOptional(value: unknown, field: string, max: number): string {
  if (value === undefined || value === null) return "";
  if (typeof value !== "string") throw new HttpError(400, `${field} must be text`);
  const v = value.trim().replace(/\s+/g, " ");
  if (v.length > max) throw new HttpError(400, `${field} is too long (max ${max})`);
  return v;
}

/** GET /api/employees */
export async function listEmployees(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  const { scopes, byId, scopeOfDevice } = await loadScopes(env, auth.companyId);
  const people = await loadPeople(env, auth.companyId, scopeOfDevice);

  // Anyone who punched but is not on the machine's user list yet, and their last punch.
  const { results: seen } = await env.DB.prepare(
    `SELECT device_id, device_user_id, MAX(punch_time) AS last_punch
       FROM attendance_logs WHERE company_id = ? GROUP BY device_id, device_user_id`,
  ).bind(auth.companyId).all<{ device_id: string; device_user_id: string; last_punch: string }>();

  const lastPunch = new Map<string, string>();
  for (const r of seen ?? []) {
    const scope = scopeOfDevice.get(r.device_id);
    if (!scope) continue;
    const key = personKey(scope.id, r.device_user_id);
    if (!people.has(key)) {
      people.set(key, {
        scopeId: scope.id, userId: r.device_user_id, name: "", machineName: null,
        department: "", edited: false, active: true,
      });
    }
    if ((lastPunch.get(key) ?? "") < r.last_punch) lastPunch.set(key, r.last_punch);
  }

  const order = new Map(scopes.map((s, i) => [s.id, i]));
  const employees = [...people.values()]
    .sort((a, b) => (order.get(a.scopeId)! - order.get(b.scopeId)!) || byUserId(a.userId, b.userId))
    .map((p) => {
      const scope = byId.get(p.scopeId)!;
      return {
        scope_id: p.scopeId,
        scope_kind: scope.kind,
        scope_name: scope.name,
        user_id: p.userId,
        name: p.name,
        machine_name: p.machineName,
        department: p.department,
        name_edited: p.edited ? 1 : 0,
        last_punch: lastPunch.get(personKey(p.scopeId, p.userId)) ?? null,
      };
    });

  const unnamed = employees.filter((e) => !e.name).length;
  return json({
    employees,
    total: employees.length,
    unnamed,
    scopes: scopes.map((s) => ({ id: s.id, kind: s.kind, name: s.name })),
  });
}

/**
 * PUT /api/employees/:scopeId/:userId  { name?, department? }
 * scopeId is a group id, or a machine id for a machine without a group.
 * The change is saved on every machine of the scope, so the person keeps it
 * even if the group is changed later. An empty name means "use the machine's name again".
 */
export async function saveEmployee(request: Request, env: Env, scopeId: string, userId: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  if (!USER_ID_RE.test(userId)) throw new HttpError(400, "Invalid user ID");

  const { byId } = await loadScopes(env, auth.companyId);
  const scope = byId.get(scopeId);
  if (!scope) throw new HttpError(404, "Machine or group not found");

  const body = await readJson<Record<string, unknown>>(request);
  const name = cleanOptional(body.name, "Name", 80);
  const department = cleanOptional(body.department, "Department", 60);
  const now = new Date().toISOString();

  // Machines of the scope that know this user ID; if none do, all of them.
  const placeholders = scope.deviceIds.map(() => "?").join(",");
  const { results: known } = await env.DB.prepare(
    `SELECT device_id FROM employees WHERE company_id = ? AND device_user_id = ? AND device_id IN (${placeholders})
     UNION
     SELECT DISTINCT device_id FROM attendance_logs WHERE company_id = ? AND device_user_id = ? AND device_id IN (${placeholders})`,
  ).bind(auth.companyId, userId, ...scope.deviceIds, auth.companyId, userId, ...scope.deviceIds)
    .all<{ device_id: string }>();
  const targets = known?.length ? known.map((k) => k.device_id) : scope.deviceIds;

  await env.DB.batch(targets.map((deviceId) => env.DB.prepare(
    `INSERT INTO employees (id, company_id, device_id, device_user_id, full_name, department, name_edited, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, NULLIF(?6, ''), ?7, ?8)
     ON CONFLICT (company_id, device_id, device_user_id) DO UPDATE SET
       full_name   = CASE WHEN ?7 = 1 THEN ?5 ELSE COALESCE(employees.machine_name, '') END,
       name_edited = ?7,
       department  = NULLIF(?6, ''),
       updated_at  = ?8`,
  ).bind(crypto.randomUUID(), auth.companyId, deviceId, userId, name, department, name ? 1 : 0, now)));

  return json({ ok: true, scope_id: scopeId, user_id: userId, machines: targets.length });
}