// Who is who: an employee is a user ID inside a "scope".
//   - A machine that is not in a group is its own scope.
//   - A group of machines is one scope: user ID 2 on any machine of the group is the same person.
// So "ID 2" on two ungrouped machines is two different people.
import type { Env } from "../env";

export interface Scope {
  id: string;               // group id, or the machine id when the machine has no group
  kind: "group" | "machine";
  name: string;
  deviceIds: string[];
  active: boolean;          // at least one active machine
}

export interface Person {
  scopeId: string;
  userId: string;
  name: string;             // "" when unknown
  machineName: string | null;
  department: string;
  edited: boolean;
  active: boolean;
}

interface DeviceRow { id: string; name: string; is_active: number; group_id: string | null; group_name: string | null }

export async function loadScopes(env: Env, companyId: string) {
  const { results } = await env.DB.prepare(
    `SELECT d.id, d.name, d.is_active, d.group_id, g.name AS group_name
       FROM devices d LEFT JOIN machine_groups g ON g.id = d.group_id
      WHERE d.company_id = ?`,
  ).bind(companyId).all<DeviceRow>();

  const byId = new Map<string, Scope>();
  const scopeOfDevice = new Map<string, Scope>();
  for (const d of results ?? []) {
    const id = d.group_id ?? d.id;
    let s = byId.get(id);
    if (!s) {
      s = { id, kind: d.group_id ? "group" : "machine", name: d.group_name ?? d.name, deviceIds: [], active: false };
      byId.set(id, s);
    }
    s.deviceIds.push(d.id);
    if (d.is_active) s.active = true;
    scopeOfDevice.set(d.id, s);
  }
  const scopes = [...byId.values()].sort((a, b) =>
    (a.kind === b.kind ? 0 : a.kind === "group" ? -1 : 1) || a.name.localeCompare(b.name));
  return { scopes, byId, scopeOfDevice };
}

export const personKey = (scopeId: string, userId: string) => `${scopeId}|${userId}`;

/**
 * Employees merged per scope. Inside a group, a name typed in the dashboard wins,
 * then any name read from one of its machines.
 */
export async function loadPeople(env: Env, companyId: string, scopeOfDevice: Map<string, Scope>) {
  const { results } = await env.DB.prepare(
    `SELECT device_id, device_user_id, full_name, machine_name, COALESCE(department, '') AS department,
            name_edited, is_active
       FROM employees WHERE company_id = ?`,
  ).bind(companyId).all<{
    device_id: string; device_user_id: string; full_name: string; machine_name: string | null;
    department: string; name_edited: number; is_active: number;
  }>();

  const people = new Map<string, Person>();
  for (const e of results ?? []) {
    const scope = scopeOfDevice.get(e.device_id);
    if (!scope) continue;
    const key = personKey(scope.id, e.device_user_id);
    const p = people.get(key);
    if (!p) {
      people.set(key, {
        scopeId: scope.id, userId: e.device_user_id, name: e.full_name, machineName: e.machine_name,
        department: e.department, edited: e.name_edited === 1, active: e.is_active === 1,
      });
      continue;
    }
    const edited = e.name_edited === 1;
    if ((edited && !p.edited) || (!p.edited && !p.name && e.full_name)) {
      p.name = e.full_name;
      p.edited = edited;
    }
    if (!p.machineName && e.machine_name) p.machineName = e.machine_name;
    if (!p.department && e.department) p.department = e.department;
    if (e.is_active === 1) p.active = true;
  }
  return people;
}

/** Sorts user IDs numerically when they are numbers. */
export function byUserId(a: string, b: string): number {
  const na = Number(a);
  const nb = Number(b);
  if (Number.isFinite(na) && Number.isFinite(nb) && na !== nb) return na - nb;
  return a.localeCompare(b);
}