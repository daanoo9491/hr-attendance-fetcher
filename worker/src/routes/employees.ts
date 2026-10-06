// Employees (dashboard). Lists every user ID known from the machine's user list
// or from attendance, and lets owners/admins set the name and department.
import type { Env } from "../env";
import { HttpError, json, readJson } from "../lib/http";
import { requireAuth, requireRole } from "../lib/auth";

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
  const { results } = await env.DB.prepare(
    `WITH ids AS (
       SELECT device_user_id FROM employees WHERE company_id = ?1
       UNION
       SELECT DISTINCT device_user_id FROM attendance_logs WHERE company_id = ?1
     )
     SELECT ids.device_user_id AS user_id,
            COALESCE(e.full_name, '') AS name,
            e.machine_name, COALESCE(e.department, '') AS department,
            COALESCE(e.name_edited, 0) AS name_edited,
            (SELECT MAX(l.punch_time) FROM attendance_logs l
              WHERE l.company_id = ?1 AND l.device_user_id = ids.device_user_id) AS last_punch
       FROM ids
       LEFT JOIN employees e ON e.company_id = ?1 AND e.device_user_id = ids.device_user_id
      ORDER BY CASE WHEN ids.device_user_id GLOB '[0-9]*' AND ids.device_user_id NOT GLOB '*[^0-9]*'
                    THEN CAST(ids.device_user_id AS INTEGER) END,
               ids.device_user_id`,
  ).bind(auth.companyId).all();

  const employees = results ?? [];
  const unnamed = employees.filter((e) => !(e as { name: string }).name).length;
  return json({ employees, total: employees.length, unnamed });
}

/**
 * PUT /api/employees/:userId  { name?, department? }
 * An empty name means "use the name from the machine again".
 */
export async function saveEmployee(request: Request, env: Env, userId: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  if (!USER_ID_RE.test(userId)) throw new HttpError(400, "Invalid user ID");

  const body = await readJson<Record<string, unknown>>(request);
  const name = cleanOptional(body.name, "Name", 80);
  const department = cleanOptional(body.department, "Department", 60);
  const now = new Date().toISOString();

  await env.DB.prepare(
    `INSERT INTO employees (id, company_id, device_user_id, full_name, department, name_edited, updated_at)
     VALUES (?1, ?2, ?3, ?4, NULLIF(?5, ''), ?6, ?7)
     ON CONFLICT (company_id, device_user_id) DO UPDATE SET
       full_name   = CASE WHEN ?6 = 1 THEN ?4 ELSE COALESCE(employees.machine_name, '') END,
       name_edited = ?6,
       department  = NULLIF(?5, ''),
       updated_at  = ?7`,
  ).bind(crypto.randomUUID(), auth.companyId, userId, name, department, name ? 1 : 0, now).run();

  const row = await env.DB.prepare(
    `SELECT device_user_id AS user_id, full_name AS name, machine_name,
            COALESCE(department, '') AS department, name_edited
       FROM employees WHERE company_id = ? AND device_user_id = ?`,
  ).bind(auth.companyId, userId).first();
  return json({ employee: row });
}