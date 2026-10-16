// Machine groups. Machines in one group share their employees by user ID
// (ID 2 on any machine of the group is the same person) and get one sheet in the Excel report.
import type { Env } from "../env";
import { HttpError, json, readJson } from "../lib/http";
import { requireAuth, requireRole } from "../lib/auth";

function cleanName(value: unknown): string {
  const v = typeof value === "string" ? value.trim().replace(/\s+/g, " ") : "";
  if (v.length < 2) throw new HttpError(400, "Group name is required (at least 2 characters)");
  if (v.length > 40) throw new HttpError(400, "Group name is too long (max 40)");
  return v;
}

/** Returns the group id when it belongs to the company (null = "no group"). */
export async function checkGroup(env: Env, companyId: string, groupId: unknown): Promise<string | null> {
  if (groupId === undefined || groupId === null || groupId === "") return null;
  if (typeof groupId !== "string") throw new HttpError(400, "group_id must be text");
  const ok = await env.DB.prepare("SELECT 1 FROM machine_groups WHERE id = ? AND company_id = ?")
    .bind(groupId, companyId).first();
  if (!ok) throw new HttpError(400, "Group not found");
  return groupId;
}

function duplicate(err: unknown): boolean {
  return err instanceof Error && /UNIQUE/i.test(err.message);
}

/** GET /api/groups */
export async function listGroups(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  const { results } = await env.DB.prepare(
    `SELECT g.id, g.name, g.created_at,
            (SELECT COUNT(*) FROM devices d WHERE d.group_id = g.id) AS machines,
            (SELECT group_concat(d.name, ', ') FROM devices d WHERE d.group_id = g.id) AS machine_names
       FROM machine_groups g WHERE g.company_id = ? ORDER BY g.name`,
  ).bind(auth.companyId).all();
  return json({ groups: results ?? [] });
}

/** POST /api/groups  { name } */
export async function createGroup(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  const body = await readJson<{ name?: unknown }>(request);
  const name = cleanName(body.name);
  const id = crypto.randomUUID();
  try {
    await env.DB.prepare("INSERT INTO machine_groups (id, company_id, name) VALUES (?, ?, ?)")
      .bind(id, auth.companyId, name).run();
  } catch (err) {
    if (duplicate(err)) throw new HttpError(409, `A group called "${name}" already exists`);
    throw err;
  }
  return json({ group: { id, name } }, 201);
}

/** PUT /api/groups/:id  { name } */
export async function renameGroup(request: Request, env: Env, id: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  const body = await readJson<{ name?: unknown }>(request);
  const name = cleanName(body.name);
  let changes = 0;
  try {
    const r = await env.DB.prepare("UPDATE machine_groups SET name = ? WHERE id = ? AND company_id = ?")
      .bind(name, id, auth.companyId).run();
    changes = r.meta.changes ?? 0;
  } catch (err) {
    if (duplicate(err)) throw new HttpError(409, `A group called "${name}" already exists`);
    throw err;
  }
  if (!changes) throw new HttpError(404, "Group not found");
  return json({ group: { id, name } });
}

/** DELETE /api/groups/:id - its machines become ungrouped; no attendance is deleted. */
export async function deleteGroup(request: Request, env: Env, id: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  const results = await env.DB.batch([
    env.DB.prepare("UPDATE devices SET group_id = NULL WHERE group_id = ? AND company_id = ?").bind(id, auth.companyId),
    env.DB.prepare("DELETE FROM machine_groups WHERE id = ? AND company_id = ?").bind(id, auth.companyId),
  ]);
  if (!(results[1].meta.changes ?? 0)) throw new HttpError(404, "Group not found");
  return json({ ok: true, machines_ungrouped: results[0].meta.changes ?? 0 });
}

/** PUT /api/devices/:id/group  { group_id: string | null } */
export async function setDeviceGroup(request: Request, env: Env, deviceId: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  const body = await readJson<{ group_id?: unknown }>(request);
  const groupId = await checkGroup(env, auth.companyId, body.group_id);
  const r = await env.DB.prepare("UPDATE devices SET group_id = ? WHERE id = ? AND company_id = ?")
    .bind(groupId, deviceId, auth.companyId).run();
  if (!(r.meta.changes ?? 0)) throw new HttpError(404, "Machine not found");
  return json({ ok: true, group_id: groupId });
}