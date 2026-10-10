// Builds the attendance Excel workbook for a date range (inclusive, company local dates).
import type { Env } from "./env";
import { STYLE, buildXlsx, colName, type CellValue } from "./lib/xlsx";
import { addDays, excelDate, excelTime } from "./lib/dates";

const STATES: Record<number, string> = { 0: "Check-in", 1: "Check-out", 2: "Break-out", 3: "Break-in", 4: "OT-in", 5: "OT-out" };
const VERIFY: Record<number, string> = { 0: "Password", 1: "Fingerprint", 2: "Card", 15: "Face" };

interface PunchRow {
  device_user_id: string;
  punch_time: string;
  punch_state: number | null;
  verify_mode: number | null;
  device_name: string;
  full_name: string | null;
  department: string | null;
}

export interface ReportContext {
  companyId: string;
  companyName: string;
  timezone: string;
  /** Sync notes (e.g. machines that did not sync). Kept for callers; not printed in the HR format. */
  notes?: string[];
}

export interface ReportStats {
  punches: number;
  employees: number;
}

/** Numeric machine IDs go into Excel as numbers (no "number stored as text" warnings). */
function userCell(id: string): CellValue {
  return /^[1-9]\d{0,8}$/.test(id) ? Number(id) : id;
}

function byUserId(a: string, b: string): number {
  const na = Number(a);
  const nb = Number(b);
  if (Number.isFinite(na) && Number.isFinite(nb) && na !== nb) return na - nb;
  return a.localeCompare(b);
}

export async function attendanceStats(env: Env, companyId: string, from: string, to: string): Promise<ReportStats> {
  const row = await env.DB.prepare(
    `SELECT COUNT(*) AS punches, COUNT(DISTINCT device_user_id) AS employees
       FROM attendance_logs
      WHERE company_id = ? AND punch_time >= ? AND punch_time < ?`,
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

/**
 * Workbook layout (matches the HR format):
 *   Sheet "Attendance": A1:A3 "Employee"; for every date a 3-column block with
 *   the date (d-mmm) and weekday merged on top, then Time In / Time Out / Hours Worked.
 *   One row per employee. Hours Worked is a formula (Time Out - Time In), so it
 *   updates if HR corrects a time by hand.
 *   Sheet "All Punches": every punch, for checking.
 */
export async function buildAttendanceReport(env: Env, ctx: ReportContext, from: string, to: string) {
  const { results } = await env.DB.prepare(
    `SELECT l.device_user_id, l.punch_time, l.punch_state, l.verify_mode,
            d.name AS device_name, NULLIF(e.full_name, '') AS full_name, NULLIF(e.department, '') AS department
       FROM attendance_logs l
       JOIN devices d ON d.id = l.device_id
       LEFT JOIN employees e ON e.company_id = l.company_id AND e.device_user_id = l.device_user_id
      WHERE l.company_id = ? AND l.punch_time >= ? AND l.punch_time < ?
      ORDER BY l.punch_time, l.device_user_id`,
  ).bind(ctx.companyId, `${from} 00:00:00`, `${addDays(to, 1)} 00:00:00`).all<PunchRow>();
  const punches = results ?? [];

  // Everyone active on the Employees page gets a row (blank when absent), plus anyone who punched.
  const { results: staff } = await env.DB.prepare(
    `SELECT device_user_id, NULLIF(full_name, '') AS full_name
       FROM employees WHERE company_id = ? AND is_active = 1`,
  ).bind(ctx.companyId).all<{ device_user_id: string; full_name: string | null }>();

  const names = new Map<string, string>();
  for (const e of staff ?? []) names.set(e.device_user_id, e.full_name ?? "");
  for (const p of punches) {
    if (!names.get(p.device_user_id)) names.set(p.device_user_id, p.full_name ?? "");
  }
  const userIds = [...names.keys()].sort(byUserId);

  // First and last punch per person per day
  type Day = { first: string; last: string; count: number };
  const days = new Map<string, Day>();
  for (const p of punches) {
    const key = `${p.device_user_id}|${p.punch_time.slice(0, 10)}`;
    const time = p.punch_time.slice(11, 19);
    const d = days.get(key);
    if (!d) days.set(key, { first: time, last: time, count: 1 });
    else {
      if (time < d.first) d.first = time;
      if (time > d.last) d.last = time;
      d.count++;
    }
  }

  const dates: string[] = [];
  for (let d = from; d <= to; d = addDays(d, 1)) dates.push(d);

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
  userIds.forEach((id) => {
    const excelRow = grid.length + 1;
    const row: CellValue[] = [{ v: names.get(id) || `ID ${id}`, s: S.gridName }];
    dates.forEach((date, i) => {
      const inCol = `${colName(1 + i * 3)}${excelRow}`;
      const outCol = `${colName(2 + i * 3)}${excelRow}`;
      const d = days.get(`${id}|${date}`);
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
  });

  const widths = [Math.max(17.33, ...userIds.map((id) => Math.min(40, (names.get(id) || `ID ${id}`).length + 3)))];
  for (let i = 0; i < dates.length; i++) widths.push(9.5, 9.5, 12.5);

  // ---- All punches (for checking)
  const punchRows: CellValue[][] = [["Date", "Time", "User ID", "Name", "Type", "Verified By", "Device"]];
  for (const p of punches) {
    punchRows.push([
      { v: excelDate(p.punch_time.slice(0, 10)), s: STYLE.date },
      { v: excelTime(p.punch_time.slice(11, 19)), s: STYLE.time },
      userCell(p.device_user_id),
      p.full_name ?? "",
      p.punch_state === null ? "" : STATES[p.punch_state] ?? `State ${p.punch_state}`,
      p.verify_mode === null ? "" : VERIFY[p.verify_mode] ?? `Mode ${p.verify_mode}`,
      p.device_name,
    ]);
  }

  const bytes = buildXlsx([
    { name: "Attendance", widths, rows: grid, merges, freeze: { cols: 1, rows: 3 } },
    { name: "All Punches", widths: [13, 10, 10, 24, 12, 13, 18], rows: punchRows, header: true },
  ]);

  const employees = new Set(punches.map((p) => p.device_user_id)).size;
  return { bytes, stats: { punches: punches.length, employees } };
}

export function reportFilename(companyName: string, from: string, to: string): string {
  const slug = companyName.replace(/[^A-Za-z0-9]+/g, "_").replace(/^_+|_+$/g, "").slice(0, 40) || "Company";
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