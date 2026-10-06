// Builds the attendance Excel workbook for a date range (inclusive, company local dates).
import type { Env } from "./env";
import { STYLE, buildXlsx, type CellValue } from "./lib/xlsx";
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
  /** Extra lines for the "Report Info" sheet (e.g. sync status of a scheduled report). */
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

export async function buildAttendanceReport(env: Env, ctx: ReportContext, from: string, to: string) {
  const { results } = await env.DB.prepare(
    `SELECT l.device_user_id, l.punch_time, l.punch_state, l.verify_mode,
            d.name AS device_name, e.full_name, e.department
       FROM attendance_logs l
       JOIN devices d ON d.id = l.device_id
       LEFT JOIN employees e ON e.company_id = l.company_id AND e.device_user_id = l.device_user_id
      WHERE l.company_id = ? AND l.punch_time >= ? AND l.punch_time < ?
      ORDER BY l.punch_time, l.device_user_id`,
  ).bind(ctx.companyId, `${from} 00:00:00`, `${addDays(to, 1)} 00:00:00`).all<PunchRow>();
  const punches = results ?? [];

  // ---- Daily summary: one row per person per day
  type Day = { date: string; userId: string; name: string; dept: string; first: string; last: string; count: number };
  const days = new Map<string, Day>();
  for (const p of punches) {
    const date = p.punch_time.slice(0, 10);
    const time = p.punch_time.slice(11, 19);
    const key = `${date}|${p.device_user_id}`;
    const d = days.get(key);
    if (!d) {
      days.set(key, { date, userId: p.device_user_id, name: p.full_name ?? "", dept: p.department ?? "", first: time, last: time, count: 1 });
    } else {
      if (time < d.first) d.first = time;
      if (time > d.last) d.last = time;
      d.count++;
    }
  }
  const summary = [...days.values()].sort((a, b) => a.date.localeCompare(b.date) || byUserId(a.userId, b.userId));

  const summaryRows: CellValue[][] = [
    ["Date", "User ID", "Name", "Department", "First In", "Last Out", "Hours", "Punches", "Note"],
  ];
  for (const d of summary) {
    const single = d.count === 1;
    summaryRows.push([
      { v: excelDate(d.date), s: STYLE.date },
      userCell(d.userId),
      d.name,
      d.dept,
      { v: excelTime(d.first), s: STYLE.time },
      single ? null : { v: excelTime(d.last), s: STYLE.time },
      single ? null : { v: excelTime(d.last) - excelTime(d.first), s: STYLE.duration },
      d.count,
      single ? "Only one punch - check-out missing" : "",
    ]);
  }

  // ---- All punches
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

  // ---- Info
  const employees = new Set(punches.map((p) => p.device_user_id)).size;
  const bold = (s: string) => ({ v: s, s: STYLE.bold });
  const infoRows: CellValue[][] = [
    [bold("Attendance Report"), ""],
    ["", ""],
    [bold("Company"), ctx.companyName],
    [bold("Period"), from === to ? from : `${from} to ${to}`],
    [bold("Generated"), `${new Date().toISOString().replace("T", " ").slice(0, 16)} UTC`],
    [bold("Time zone"), `${ctx.timezone} (times are as recorded by the machine)`],
    [bold("Employees with punches"), employees],
    [bold("Total punches"), punches.length],
    ["", ""],
    [bold("Notes"), "A day runs 00:00-23:59. Hours = Last Out - First In (breaks are not deducted)."],
    ["", "Names and departments appear once employees are mapped to machine user IDs."],
    ...(ctx.notes ?? []).map((n) => ["", n] as CellValue[]),
  ];

  const bytes = buildXlsx([
    { name: "Daily Summary", widths: [13, 10, 24, 18, 10, 10, 8, 9, 34], rows: summaryRows, header: true },
    { name: "All Punches", widths: [13, 10, 10, 24, 12, 13, 18], rows: punchRows, header: true },
    { name: "Report Info", widths: [24, 70], rows: infoRows },
  ]);

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