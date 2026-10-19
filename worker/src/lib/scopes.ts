// Who is who.
//   An employee is a user ID ON ONE MACHINE. "ID 2" on two machines is always two
//   people; nothing is ever merged or copied between machines.
//   A group only decides which machines share one sheet of the Excel report.
//
// The roster (the people counted on the Employees page and listed in reports) is:
//   everyone on an active machine - from the machine's user list or from its punches -
//   except people a manager has hidden from reports.
// Reports also always include anyone with a punch or a manual edit in the period.
import type { Env } from "../env";

export interface Scope {
  id: string;               // group id, or the machine id when the machine has no group
  kind: "group" | "machine";
  name: string;
  deviceIds: string[];      // sorted by machine name
  active: boolean;          // at least one active machine
}

export interface Machine { id: string; name: string; active: boolean; groupId: string | null; groupName: string | null }

export interface Person {
  deviceId: string;
  userId: string;
  name: string;             // "" when unknown
  machineName: string | null;
  department: string;
  edited: boolean;
  hidden: boolean;          // a manager chose "hide from reports"
  inRoster: boolean;        // active machine and not hidden
  lastPunch: string | null;
}

export const personKey = (deviceId: string, userId: string) => `${deviceId}|${userId}`;

export async function loadScopes(env: Env, companyId: string) {
  const { results } = await env.DB.prepare(
    `SELECT d.id, d.name, d.is_active, d.group_id, g.name AS group_name
       FROM devices d LEFT JOIN machine_groups g ON g.id = d.group_id
      WHERE d.company_id = ?
      ORDER BY d.name`,
  ).bind(companyId).all<{ id: string; name: string; is_active: number; group_id: string | null; group_name: string | null }>();

  const machines = new Map<string, Machine>();
  const byId = new Map<string, Scope>();
  const scopeOfDevice = new Map<string, Scope>();
  for (const d of results ?? []) {
    machines.set(d.id, { id: d.id, name: d.name, active: d.is_active === 1, groupId: d.group_id, groupName: d.group_name });
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
  return { scopes, byId, scopeOfDevice, machines };
}

/** Everyone known on every machine: the machine's user list plus anyone who ever punched on it. */
export async function loadPeople(env: Env, companyId: string, machines: Map<string, Machine>) {
  const [emp, seen] = await Promise.all([
    env.DB.prepare(
      `SELECT device_id, device_user_id, full_name, machine_name, COALESCE(department, '') AS department,
              name_edited, is_active
         FROM employees WHERE company_id = ?`,
    ).bind(companyId).all<{
      device_id: string; device_user_id: string; full_name: string; machine_name: string | null;
      department: string; name_edited: number; is_active: number;
    }>(),
    env.DB.prepare(
      `SELECT device_id, device_user_id, MAX(punch_time) AS last_punch
         FROM attendance_logs WHERE company_id = ? GROUP BY device_id, device_user_id`,
    ).bind(companyId).all<{ device_id: string; device_user_id: string; last_punch: string }>(),
  ]);

  const people = new Map<string, Person>();
  const add = (deviceId: string, userId: string): Person | null => {
    const m = machines.get(deviceId);
    if (!m) return null;
    const key = personKey(deviceId, userId);
    let p = people.get(key);
    if (!p) {
      p = { deviceId, userId, name: "", machineName: null, department: "", edited: false, hidden: false, inRoster: m.active, lastPunch: null };
      people.set(key, p);
    }
    return p;
  };
  for (const e of emp.results ?? []) {
    const p = add(e.device_id, e.device_user_id);
    if (!p) continue;
    p.name = e.full_name;
    p.machineName = e.machine_name;
    p.department = e.department;
    p.edited = e.name_edited === 1;
    p.hidden = e.is_active === 0;
    p.inRoster = p.inRoster && !p.hidden;
  }
  for (const r of seen.results ?? []) {
    const p = add(r.device_id, r.device_user_id);
    if (p) p.lastPunch = r.last_punch;
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

/**
 * Display names that are unique inside one sheet or list. Names are never changed;
 * only when two different people show the same name is something added:
 * the machine if they are on different machines, the ID if they are on the same one.
 */
export function uniqueLabels(people: Person[], machines: Map<string, Machine>): Map<string, string> {
  const groups = new Map<string, Person[]>();
  for (const p of people) {
    const label = (p.name || `ID ${p.userId}`).toLowerCase();
    const list = groups.get(label) ?? [];
    list.push(p);
    groups.set(label, list);
  }
  const out = new Map<string, string>();
  for (const list of groups.values()) {
    const machinesUsed = new Set(list.map((p) => p.deviceId));
    for (const p of list) {
      const base = p.name || `ID ${p.userId}`;
      const machine = machines.get(p.deviceId)?.name ?? "?";
      let label = base;
      if (list.length > 1) {
        if (machinesUsed.size === list.length) label = `${base} (${machine})`;
        else if (machinesUsed.size === 1) label = p.name ? `${base} (ID ${p.userId})` : base;
        else label = p.name ? `${base} (${machine}, ID ${p.userId})` : `${base} (${machine})`;
      }
      out.set(personKey(p.deviceId, p.userId), label);
    }
  }
  return out;
}