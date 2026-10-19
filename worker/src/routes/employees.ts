// Employees (dashboard). An employee is a user ID on one machine:
// "ID 2" on two machines is two people, also when the machines are in one group.
import type { Env } from "../env";
import { HttpError, json, readJson } from "../lib/http";
import { requireAuth, requireRole } from "../lib/auth";
import { byUserId, loadPeople, loadScopes } from "../lib/scopes";

export const USER_ID_RE = /^[A-Za-z0-9_.-]{1,32}$/;

function cleanOptional(value: unknown, field: string, max: number): string {
  if (value === undefined || value === null) return "";
  if (typeof value !== "string") throw new HttpError(400, `${field} must be text`);
  const v = value.trim().replace(/\s+/g, " ");
  if (v.length > max) throw new HttpError(400, `${field} is too long (max ${max})`);
  return v;
}

/**
 * GET /api/employees
 * Everyone on an active machine. `total` is exactly the number of people the
 * Excel report lists (hidden people are listed here but not counted).
 */
export async function listEmployees(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  const { machines } = await loadScopes(env, auth.companyId);
  const people = await loadPeople(env, auth.companyId, machines);

  const machineOrder = [...machines.values()].map((m) => m.id);
  const all = [...people.values()];
  const listed = all
    .filter((p) => machines.get(p.deviceId)?.active)
    .sort((a, b) => (machineOrder.indexOf(a.deviceId) - machineOrder.indexOf(b.deviceId)) || byUserId(a.userId, b.userId));

  const employees = listed.map((p) => {
    const m = machines.get(p.deviceId)!;
    return {
      device_id: p.deviceId,
      machine: m.name,
      group: m.groupName,
      user_id: p.userId,
      name: p.name,
      machine_name: p.machineName,
      department: p.department,
      name_edited: p.edited ? 1 : 0,
      in_reports: p.hidden ? 0 : 1,
      last_punch: p.lastPunch,
    };
  });

  const counted = employees.filter((e) => e.in_reports);
  return json({
    employees,
    total: counted.length,
    hidden: employees.length - counted.length,
    unnamed: counted.filter((e) => !e.name).length,
    on_deactivated: all.filter((p) => !machines.get(p.deviceId)?.active).length,
    machines: [...machines.values()].filter((m) => m.active).length,
  });
}

/**
 * PUT /api/employees/:deviceId/:userId  { name?, department?, in_reports? }
 * Changes only this machine's employee. An empty name means "use the machine's name again".
 */
export async function saveEmployee(request: Request, env: Env, deviceId: string, userId: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  if (!USER_ID_RE.test(userId)) throw new HttpError(400, "Invalid user ID");
  const device = await env.DB.prepare("SELECT id FROM devices WHERE id = ? AND company_id = ?")
    .bind(deviceId, auth.companyId).first();
  if (!device) throw new HttpError(404, "Machine not found");

  const body = await readJson<Record<string, unknown>>(request);
  const now = new Date().toISOString();
  const statements: D1PreparedStatement[] = [];

  if ("name" in body || "department" in body) {
    const name = cleanOptional(body.name, "Name", 80);
    const department = cleanOptional(body.department, "Department", 60);
    statements.push(env.DB.prepare(
      `INSERT INTO employees (id, company_id, device_id, device_user_id, full_name, department, name_edited, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, NULLIF(?6, ''), ?7, ?8)
       ON CONFLICT (company_id, device_id, device_user_id) DO UPDATE SET
         full_name   = CASE WHEN ?7 = 1 THEN ?5 ELSE COALESCE(employees.machine_name, '') END,
         name_edited = ?7,
         department  = NULLIF(?6, ''),
         updated_at  = ?8`,
    ).bind(crypto.randomUUID(), auth.companyId, deviceId, userId, name, department, name ? 1 : 0, now));
  }

  if ("in_reports" in body) {
    if (typeof body.in_reports !== "boolean") throw new HttpError(400, "in_reports must be true or false");
    statements.push(env.DB.prepare(
      `INSERT INTO employees (id, company_id, device_id, device_user_id, full_name, is_active, updated_at)
       VALUES (?1, ?2, ?3, ?4, '', ?5, ?6)
       ON CONFLICT (company_id, device_id, device_user_id) DO UPDATE SET is_active = ?5, updated_at = ?6`,
    ).bind(crypto.randomUUID(), auth.companyId, deviceId, userId, body.in_reports ? 1 : 0, now));
  }

  if (!statements.length) throw new HttpError(400, "Nothing to change");
  await env.DB.batch(statements);
  return json({ ok: true, device_id: deviceId, user_id: userId });
}