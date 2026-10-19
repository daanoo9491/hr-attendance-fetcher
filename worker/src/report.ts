// Builds the attendance Excel workbook for a date range (inclusive, company local dates).
import type { Env } from "./env";
import { STYLE, buildXlsx, colName, type CellValue, type SheetSpec } from "./lib/xlsx";
import { addDays, excelDate, excelTime } from "./lib/dates";
import { byUserId, loadPeople, loadScopes, personKey, uniqueLabels, type Person, type Scope } from "./lib/scopes";
import { editKey, loadEdits } from "./lib/edits";

const STATES: Record<number, string> = { 0: "Check-in", 1: "Check-out", 2: "Break-out", 3: "Break-in", 4: "OT-in", 5: "OT-out" };
const VERIFY: Record<number, string> = { 0: "Password", 1: "Fingerprint", 2: "Card", 15: "Face" };

interface PunchRow {
  device_id: string;
  device_user_id: string;
  punch_time: string;
  punch_state: number | null;
  verify_mode: number | null;
  device_name: string;
}

export interface ReportContext {
  companyId: string;
  companyName: string;
  timezone: string;
  /** Sync notes (e.g. machines that did not sync). Kept for callers; not printed in the HR format. */
  notes?: string[];
  /** Only this group or ungrouped machine (default: all, one sheet each). */
  scopeId?: string;
}

export interface ReportStats {
  punches: number;
  employees: number;
}

/** Numeric machine IDs go into Excel as numbers (no "number stored as text" warnings). */
function userCell(id: string): CellValue {
  return /^[1-9]\d{0,8}$/.test(id) ? Number(id) : id;
}

/** Employees = distinct people (user ID on a machine) with punches in the period. */
export async function attendanceStats(env: Env, companyId: string, from: string, to: string): Promise<ReportStats> {
  const row = await env.DB.prepare(
    `SELECT COUNT(*) AS punches,
            COUNT(DISTINCT l.device_id || '|' || l.device_user_id) AS employees
       FROM attendance_logs l
      WHERE l.company_id = ? AND l.punch_time >= ? AND l.punch_time < ?`,
  ).bind(companyId, `${from} 00:00:00`, `${addDays(to, 1)} 00:00:00`).first<{ punches: number; employees: number }>();
  return { punches: row?.punches ?? 0, employees: row?.employees ?? 0 };
}

const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

function weekday(date: string): string {
  return WEEKDAYS[new Date(`${date}T00:00:00Z`).getUTCDay()];
}

/** Excel time for "HH:MM:SS", cut to whole minutes so Hours Worked matches the times shown. */
function minuteTime(time: string): number {
  return excelTime(`${time.slice(0, 5)}:00`);
}

/** Excel sheet names: max 31 characters, no []:*?/\\, unique (case-insensitive). */
function sheetNamer(reserved: string[]) {
  const used = new Set(reserved.map((n) => n.toLowerCase()));
  return (wanted: string) => {
    const base = wanted.replace(/[\[\]:*?/\\]/g, " ").replace(/^'+|'+$/g, "").trim().slice(0, 31) || "Machine";
    let name = base;
    for (let i = 2; used.has(name.toLowerCase()); i++) name = `${base.slice(0, 31 - ` (${i})`.length)} (${i})`;
    used.add(name.toLowerCase());
    return name;
  };
}

/** Effective Time In / Time Out of one person on one day, as Excel times (null = blank). */
type Day = { tin: number | null; tout: number | null };

/** One sheet in the HR layout. */
function attendanceSheet(name: string, dates: string[], rows: Array<{ label: string; days: Map<string, Day> }>): SheetSpec {
  const S = STYLE;
  const row1: CellValue[] = [{ v: "Employee", s: S.gridCorner }];
  const row2: CellValue[] = [{ s: S.gridCorner }];
  const row3: CellValue[] = [{ s: S.gridCorner }];
  const merges = ["A1:A3"];
  dates.forEach((date, i) => {
    const c0 = 1 + i * 3;
    row1.push({ v: excelDate(date), s: S.gridDate }, { s: S.gridDate }, { s: S.gridDate });
    row2.push({ v: weekday(date), s: S.gridDay }, { s: S.gridDay }, { s: S.gridDay });
    row3.push({ v: "Time In", s: S.gridHead }, { v: "Time Out", s: S.gridHead }, { v: "Hours Worked", s: S.gridHeadC });
    merges.push(`${colName(c0)}1:${colName(c0 + 2)}1`, `${colName(c0)}2:${colName(c0 + 2)}2`);
  });

  const grid: CellValue[][] = [row1, row2, row3];
  for (const person of rows) {
    const excelRow = grid.length + 1;
    const row: CellValue[] = [{ v: person.label, s: S.gridName }];
    dates.forEach((date, i) => {
      const inCol = `${colName(1 + i * 3)}${excelRow}`;
      const outCol = `${colName(2 + i * 3)}${excelRow}`;
      const d = person.days.get(date);
      const tin = d?.tin ?? null;
      const tout = d?.tout ?? null;
      row.push(
        { v: tin, s: S.gridTime },
        { v: tout, s: S.gridTime },
        {
          f: `IF(OR(${inCol}="",${outCol}=""),"",${outCol}-${inCol})`,
          v: tin !== null && tout !== null ? Math.round((tout - tin) * 1e8) / 1e8 : "",
          s: S.gridHours,
        },
      );
    });
    grid.push(row);
  }

  const widths = [Math.max(17.33, ...rows.map((r) => Math.min(48, r.label.length + 3)))];
  for (let i = 0; i < dates.length; i++) widths.push(9.5, 9.5, 12.5);
  return { name, widths, rows: grid, merges, freeze: { cols: 1, rows: 3 } };
}

/**
 * Workbook layout (matches the HR format):
 *   One sheet per machine group, and one per machine that is not in a group.
 *   A group only puts its machines on one sheet: every machine keeps its own people,
 *   so "ID 2" on two machines is two rows and nobody is merged, added or dropped.
 *   Rows = the same roster as the Employees page (everyone on an active machine who is
 *   not hidden from reports), plus anyone with a punch or a manual edit in the period.
 *   Time In / Time Out = first / last punch of the day, or the manager's edit.
 *   Sheets "Manual Edits" (when there are any) and "All Punches" are for checking.
 */
export async function buildAttendanceReport(env: Env, ctx: ReportContext, from: string, to: string) {
  const { scopes, byId, scopeOfDevice, machines } = await loadScopes(env, ctx.companyId);
  if (ctx.scopeId && !byId.has(ctx.scopeId)) throw new Error("Unknown machine or group");
  const inScope = (deviceId: string) => !ctx.scopeId || scopeOfDevice.get(deviceId)?.id === ctx.scopeId;

  const [punchRes, people, edits] = await Promise.all([
    env.DB.prepare(
      `SELECT l.device_id, l.device_user_id, l.punch_time, l.punch_state, l.verify_mode, d.name AS device_name
         FROM attendance_logs l
         JOIN devices d ON d.id = l.device_id
        WHERE l.company_id = ? AND l.punch_time >= ? AND l.punch_time < ?
        ORDER BY l.punch_time, l.device_user_id`,
    ).bind(ctx.companyId, `${from} 00:00:00`, `${addDays(to, 1)} 00:00:00`).all<PunchRow>(),
    loadPeople(env, ctx.companyId, machines),
    loadEdits(env, ctx.companyId, from, to),
  ]);
  const punches = (punchRes.results ?? []).filter((p) => inScope(p.device_id));
  const scopedEdits = [...edits.values()].filter((e) => inScope(e.device_id));

  // First and last punch per person per day (as HH:MM:SS)
  const raw = new Map<string, { first: string; last: string; count: number }>();
  for (const p of punches) {
    const key = editKey(p.device_id, p.device_user_id, p.punch_time.slice(0, 10));
    const time = p.punch_time.slice(11, 19);
    const d = raw.get(key);
    if (!d) raw.set(key, { first: time, last: time, count: 1 });
    else {
      if (time < d.first) d.first = time;
      if (time > d.last) d.last = time;
      d.count++;
    }
  }

  // Who is on the report: the roster, plus anyone with a punch or an edit in the period.
  const included = new Set<string>();
  for (const [key, p] of people) if (p.inRoster && inScope(p.deviceId)) included.add(key);
  for (const p of punches) included.add(personKey(p.device_id, p.device_user_id));
  for (const e of scopedEdits) included.add(personKey(e.device_id, e.device_user_id));

  const dates: string[] = [];
  for (let d = from; d <= to; d = addDays(d, 1)) dates.push(d);

  const dayOf = (deviceId: string, userId: string, date: string): Day | undefined => {
    const k = editKey(deviceId, userId, date);
    const edit = edits.get(k);
    if (edit) {
      return {
        tin: edit.time_in ? excelTime(`${edit.time_in}:00`) : null,
        tout: edit.time_out ? excelTime(`${edit.time_out}:00`) : null,
      };
    }
    const r = raw.get(k);
    if (!r) return undefined;
    return { tin: minuteTime(r.first), tout: r.count > 1 ? minuteTime(r.last) : null };
  };

  const personOf = (key: string): Person => {
    const known = people.get(key);
    if (known) return known;
    const [deviceId, userId] = key.split("|");
    return { deviceId, userId, name: "", machineName: null, department: "", edited: false, hidden: false, inRoster: false, lastPunch: null };
  };

  const machineOrder = [...machines.keys()];
  const wanted: Scope[] = ctx.scopeId ? [byId.get(ctx.scopeId)!] : scopes;
  const nameSheet = sheetNamer(["All Punches", "Manual Edits"]);
  const sheets: SheetSpec[] = [];
  const labelOf = new Map<string, string>();
  for (const scope of wanted) {
    const members = [...included]
      .map(personOf)
      .filter((p) => scope.deviceIds.includes(p.deviceId))
      .sort((a, b) => (machineOrder.indexOf(a.deviceId) - machineOrder.indexOf(b.deviceId)) || byUserId(a.userId, b.userId));
    if (!members.length && !scope.active) continue;
    const labels = uniqueLabels(members, machines);
    for (const [k, v] of labels) labelOf.set(k, v);
    const rows = members.map((p) => {
      const days = new Map<string, Day>();
      for (const date of dates) {
        const d = dayOf(p.deviceId, p.userId, date);
        if (d) days.set(date, d);
      }
      return { label: labels.get(personKey(p.deviceId, p.userId))!, days };
    });
    sheets.push(attendanceSheet(nameSheet(scope.name), dates, rows));
  }
  if (!sheets.length) sheets.push(attendanceSheet(nameSheet("Attendance"), dates, []));

  // ---- Manual edits (audit trail)
  if (scopedEdits.length) {
    const rows: CellValue[][] = [["Date", "Employee", "User ID", "Machine", "Time In", "Time Out", "Machine In", "Machine Out", "Note", "Edited By", "Edited At (UTC)"]];
    scopedEdits.sort((a, b) => a.work_date.localeCompare(b.work_date) || byUserId(a.device_user_id, b.device_user_id));
    for (const e of scopedEdits) {
      const key = personKey(e.device_id, e.device_user_id);
      const r = raw.get(editKey(e.device_id, e.device_user_id, e.work_date));
      rows.push([
        { v: excelDate(e.work_date), s: STYLE.date },
        labelOf.get(key) ?? (personOf(key).name || `ID ${e.device_user_id}`),
        userCell(e.device_user_id),
        machines.get(e.device_id)?.name ?? "",
        e.time_in ? { v: excelTime(`${e.time_in}:00`), s: STYLE.time } : "",
        e.time_out ? { v: excelTime(`${e.time_out}:00`), s: STYLE.time } : "",
        r ? { v: minuteTime(r.first), s: STYLE.time } : "",
        r && r.count > 1 ? { v: minuteTime(r.last), s: STYLE.time } : "",
        e.note ?? "",
        e.edited_by,
        e.edited_at.slice(0, 16).replace("T", " "),
      ]);
    }
    sheets.push({ name: "Manual Edits", widths: [13, 26, 10, 22, 10, 10, 12, 12, 34, 20, 18], rows, header: true });
  }

  // ---- All punches (for checking)
  const showGroup = scopes.some((s) => s.kind === "group");
  const punchRows: CellValue[][] = [[
    "Date", "Time", "User ID", "Name", "Type", "Verified By", "Machine", ...(showGroup ? ["Group"] : []),
  ]];
  for (const p of punches) {
    const key = personKey(p.device_id, p.device_user_id);
    const group = machines.get(p.device_id)?.groupName ?? "";
    punchRows.push([
      { v: excelDate(p.punch_time.slice(0, 10)), s: STYLE.date },
      { v: excelTime(p.punch_time.slice(11, 19)), s: STYLE.time },
      userCell(p.device_user_id),
      people.get(key)?.name ?? "",
      p.punch_state === null ? "" : STATES[p.punch_state] ?? `State ${p.punch_state}`,
      p.verify_mode === null ? "" : VERIFY[p.verify_mode] ?? `Mode ${p.verify_mode}`,
      p.device_name,
      ...(showGroup ? [group] : []),
    ]);
  }
  sheets.push({
    name: "All Punches",
    widths: [13, 10, 10, 24, 12, 13, 22, ...(showGroup ? [18] : [])],
    rows: punchRows,
    header: true,
  });

  const bytes = buildXlsx(sheets);
  const employees = new Set(punches.map((p) => personKey(p.device_id, p.device_user_id))).size;
  return { bytes, stats: { punches: punches.length, employees } };
}

export function reportFilename(companyName: string, from: string, to: string): string {
  const slug = companyName.replace(/[^A-Za-z0-9]+/g, "_").replace(/^_+|_+$/g, "").slice(0, 60) || "Company";
  return from === to ? `Attendance_${slug}_${from}.xlsx` : `Attendance_${slug}_${from}_to_${to}.xlsx`;
}

export function xlsxResponse(bytes: Uint8Array, filename: string): Response {
  return new Response(bytes, {
    headers: {
      "content-type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      "content-disposition": `attachment; filename="${filename}"`,
      "cache-control": "no-store",
    },
  });
}