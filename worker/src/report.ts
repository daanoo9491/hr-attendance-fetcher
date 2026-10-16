// Builds the attendance Excel workbook for a date range (inclusive, company local dates).
import type { Env } from "./env";
import { STYLE, buildXlsx, colName, type CellValue, type SheetSpec } from "./lib/xlsx";
import { addDays, excelDate, excelTime } from "./lib/dates";
import { byUserId, loadPeople, loadScopes, personKey, type Scope } from "./lib/scopes";

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

/** Employees = distinct user IDs per machine, or per group for grouped machines. */
export async function attendanceStats(env: Env, companyId: string, from: string, to: string): Promise<ReportStats> {
  const row = await env.DB.prepare(
    `SELECT COUNT(*) AS punches,
            COUNT(DISTINCT COALESCE(d.group_id, d.id) || '|' || l.device_user_id) AS employees
       FROM attendance_logs l JOIN devices d ON d.id = l.device_id
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

type Day = { first: string; last: string; count: number };

/** One sheet in the HR layout for a group or a single machine. */
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
      const tin = d ? minuteTime(d.first) : null;
      const tout = d && d.count > 1 ? minuteTime(d.last) : null;
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

  const widths = [Math.max(17.33, ...rows.map((r) => Math.min(40, r.label.length + 3)))];
  for (let i = 0; i < dates.length; i++) widths.push(9.5, 9.5, 12.5);
  return { name, widths, rows: grid, merges, freeze: { cols: 1, rows: 3 } };
}

/**
 * Workbook layout (matches the HR format):
 *   One sheet per machine group, and one per machine that is not in a group.
 *   A1:A3 "Employee"; for every date a 3-column block with the date (d-mmm) and
 *   weekday merged on top, then Time In / Time Out / Hours Worked. One row per employee.
 *   User ID 2 on two separate machines is two rows on two sheets; on two machines of
 *   the same group it is one row (first punch of the day on any of them, last punch on any).
 *   Sheet "All Punches": every punch, for checking.
 */
export async function buildAttendanceReport(env: Env, ctx: ReportContext, from: string, to: string) {
  const { scopes, byId, scopeOfDevice } = await loadScopes(env, ctx.companyId);
  if (ctx.scopeId && !byId.has(ctx.scopeId)) throw new Error("Unknown machine or group");

  const { results } = await env.DB.prepare(
    `SELECT l.device_id, l.device_user_id, l.punch_time, l.punch_state, l.verify_mode, d.name AS device_name
       FROM attendance_logs l
       JOIN devices d ON d.id = l.device_id
      WHERE l.company_id = ? AND l.punch_time >= ? AND l.punch_time < ?
      ORDER BY l.punch_time, l.device_user_id`,
  ).bind(ctx.companyId, `${from} 00:00:00`, `${addDays(to, 1)} 00:00:00`).all<PunchRow>();
  const inScope = (deviceId: string) => !ctx.scopeId || scopeOfDevice.get(deviceId)?.id === ctx.scopeId;
  const punches = (results ?? []).filter((p) => inScope(p.device_id));

  const people = await loadPeople(env, ctx.companyId, scopeOfDevice);
  const label = (scopeId: string, userId: string) => people.get(personKey(scopeId, userId))?.name || `ID ${userId}`;

  // First and last punch per person per day
  const days = new Map<string, Map<string, Day>>();
  const punchedIn = new Map<string, Set<string>>(); // scope -> user IDs with punches in the period
  for (const p of punches) {
    const scope = scopeOfDevice.get(p.device_id);
    if (!scope) continue;
    const key = personKey(scope.id, p.device_user_id);
    const date = p.punch_time.slice(0, 10);
    const time = p.punch_time.slice(11, 19);
    let perDay = days.get(key);
    if (!perDay) days.set(key, (perDay = new Map()));
    const d = perDay.get(date);
    if (!d) perDay.set(date, { first: time, last: time, count: 1 });
    else {
      if (time < d.first) d.first = time;
      if (time > d.last) d.last = time;
      d.count++;
    }
    let set = punchedIn.get(scope.id);
    if (!set) punchedIn.set(scope.id, (set = new Set()));
    set.add(p.device_user_id);
  }

  const dates: string[] = [];
  for (let d = from; d <= to; d = addDays(d, 1)) dates.push(d);

  // Which sheets: the requested one, or every active machine/group plus any with punches in the period.
  const wanted: Scope[] = ctx.scopeId
    ? [byId.get(ctx.scopeId)!]
    : scopes.filter((s) => s.active || punchedIn.has(s.id));

  const nameSheet = sheetNamer(["All Punches"]);
  const sheets: SheetSpec[] = [];
  for (const scope of wanted) {
    const ids = new Set(punchedIn.get(scope.id) ?? []);
    if (scope.active) {
      for (const p of people.values()) if (p.scopeId === scope.id && p.active) ids.add(p.userId);
    }
    const rows = [...ids].sort(byUserId).map((userId) => ({
      label: label(scope.id, userId),
      days: days.get(personKey(scope.id, userId)) ?? new Map<string, Day>(),
    }));
    sheets.push(attendanceSheet(nameSheet(scope.name), dates, rows));
  }
  if (!sheets.length) sheets.push(attendanceSheet(nameSheet("Attendance"), dates, []));

  // ---- All punches (for checking)
  const showGroup = scopes.some((s) => s.kind === "group");
  const punchRows: CellValue[][] = [[
    "Date", "Time", "User ID", "Name", "Type", "Verified By", "Machine", ...(showGroup ? ["Group"] : []),
  ]];
  for (const p of punches) {
    const scope = scopeOfDevice.get(p.device_id);
    punchRows.push([
      { v: excelDate(p.punch_time.slice(0, 10)), s: STYLE.date },
      { v: excelTime(p.punch_time.slice(11, 19)), s: STYLE.time },
      userCell(p.device_user_id),
      scope ? people.get(personKey(scope.id, p.device_user_id))?.name ?? "" : "",
      p.punch_state === null ? "" : STATES[p.punch_state] ?? `State ${p.punch_state}`,
      p.verify_mode === null ? "" : VERIFY[p.verify_mode] ?? `Mode ${p.verify_mode}`,
      p.device_name,
      ...(showGroup ? [scope?.kind === "group" ? scope.name : ""] : []),
    ]);
  }
  sheets.push({
    name: "All Punches",
    widths: [13, 10, 10, 24, 12, 13, 18, ...(showGroup ? [18] : [])],
    rows: punchRows,
    header: true,
  });

  const bytes = buildXlsx(sheets);
  const employees = new Set(punches.map((p) => personKey(scopeOfDevice.get(p.device_id)?.id ?? p.device_id, p.device_user_id))).size;
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