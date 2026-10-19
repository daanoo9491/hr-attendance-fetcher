# =====================================================================
# HR Auto Attendance Fetcher - PHASE 12 : Excel in the HR format
# (Employee rows; per day: date + weekday on top, then
#  Time In / Time Out / Hours Worked). Run from the ROOT of the repo:
#   powershell -ExecutionPolicy Bypass -File .\phase-12-excel-format.ps1
# =====================================================================
$ErrorActionPreference = "Stop"

function Write-File([string]$Path, [string]$Content) {
    $full = Join-Path (Get-Location) $Path
    $dir  = Split-Path $full -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($full, $Content.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  wrote $Path" -ForegroundColor Green
}

if (-not (Test-Path "worker/src/lib/jobs.ts")) {
    throw "Run this from the repo root, after Phase 11 (worker/src/lib/jobs.ts not found)."
}

Write-Host "Phase 12: writing the Excel format..." -ForegroundColor Cyan

# ---------------------------------------------------------------- worker/package.json
Write-File "worker/package.json" @'
{
  "name": "hr-attendance-worker",
  "version": "0.12.0",
  "private": true,
  "scripts": {
    "bundle-connector": "node scripts/bundle-connector.mjs",
    "dev": "npm run bundle-connector && wrangler dev",
    "deploy": "npm run bundle-connector && wrangler deploy",
    "typecheck": "npm run bundle-connector && tsc --noEmit"
  },
  "devDependencies": {
    "@cloudflare/workers-types": "^5.20261001.1",
    "typescript": "^5.6.0",
    "wrangler": "^4.0.0"
  }
}
'@

# ---------------------------------------------------------------- worker/src/env.ts
Write-File "worker/src/env.ts" @'
export interface Env {
  DB: D1Database;
  /** Optional. When set, sign-up requires this code (set with: wrangler secret put SIGNUP_CODE). */
  SIGNUP_CODE?: string;
}

export const VERSION = "0.12.0-phase12";

/** Number of files in worker/migrations. The health check reports "degraded" until all are applied. */
export const EXPECTED_MIGRATIONS = 6;
'@

# ---------------------------------------------------------------- worker/src/lib/xlsx.ts
Write-File "worker/src/lib/xlsx.ts" @'
// Minimal, dependency-free .xlsx writer for Workers.
// Produces a standard Office Open XML workbook (stored zip, inline strings).

export const STYLE = {
  normal: 0,
  header: 1,     // bold on light blue
  date: 2,       // dd-mmm-yyyy
  time: 3,       // hh:mm
  duration: 4,   // [h]:mm
  bold: 5,
  // ---- attendance grid (all with thin borders on every side)
  gridCorner: 6, // bold, centered both ways
  gridDate: 7,   // d-mmm, bold, centered both ways
  gridDay: 8,    // weekday name, bold, centered
  gridHead: 9,   // "Time In" / "Time Out", bold
  gridHeadC: 10, // "Hours Worked", bold, centered
  gridName: 11,  // employee name, bold
  gridTime: 12,  // h:mm AM/PM, centered
  gridHours: 13, // h:mm, centered
  gridCell: 14,  // plain bordered cell
} as const;

/**
 * A cell: a plain value, or { v, s } for a styled value (v may be empty for a styled blank cell),
 * or { f, v, s } for a formula with its cached result.
 */
export type CellValue =
  | string
  | number
  | null
  | undefined
  | { v?: string | number | null; s: number; f?: string };

export interface SheetSpec {
  name: string;
  widths: number[];
  rows: CellValue[][];
  /** First row is a header: bold, frozen, with filter buttons. */
  header?: boolean;
  /** Merged ranges, e.g. ["A1:A3", "B1:D1"]. */
  merges?: string[];
  /** Freeze panes: number of columns on the left and rows on top that stay visible. */
  freeze?: { cols: number; rows: number };
}

import { zipStore } from "./zip";

const enc = new TextEncoder();

function xmlEscape(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    // strip control characters Excel rejects
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, "");
}

export function colName(index: number): string {
  let n = index + 1;
  let s = "";
  while (n > 0) {
    const m = (n - 1) % 26;
    s = String.fromCharCode(65 + m) + s;
    n = Math.floor((n - 1) / 26);
  }
  return s;
}

function safeSheetName(name: string): string {
  return name.replace(/[\[\]:*?/\\]/g, " ").slice(0, 31) || "Sheet";
}

function cellXml(ref: string, cell: CellValue, defaultStyle: number): string {
  if (cell === null || cell === undefined || cell === "") return "";
  let value: string | number | null | undefined;
  let style = defaultStyle;
  let formula: string | undefined;
  if (typeof cell === "object") {
    value = cell.v;
    style = cell.s;
    formula = cell.f;
  } else {
    value = cell;
  }
  const s = style ? ` s="${style}"` : "";
  if (formula) {
    const f = `<f>${xmlEscape(formula)}</f>`;
    if (typeof value === "number" && Number.isFinite(value)) return `<c r="${ref}"${s}>${f}<v>${value}</v></c>`;
    return `<c r="${ref}"${s} t="str">${f}<v>${xmlEscape(String(value ?? ""))}</v></c>`;
  }
  if (value === null || value === undefined || value === "") {
    return style ? `<c r="${ref}"${s}/>` : "";
  }
  if (typeof value === "number" && Number.isFinite(value)) {
    return `<c r="${ref}"${s}><v>${value}</v></c>`;
  }
  return `<c r="${ref}"${s} t="inlineStr"><is><t xml:space="preserve">${xmlEscape(String(value))}</t></is></c>`;
}

function sheetXml(sheet: SheetSpec): string {
  const lastCol = colName(Math.max(sheet.widths.length, 1) - 1);
  const lastRow = Math.max(sheet.rows.length, 1);
  const parts: string[] = [];
  parts.push(`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>`);
  parts.push(`<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">`);
  const freeze = sheet.freeze ?? (sheet.header ? { cols: 0, rows: 1 } : undefined);
  if (freeze && (freeze.cols > 0 || freeze.rows > 0)) {
    const topLeft = `${colName(freeze.cols)}${freeze.rows + 1}`;
    const pane = freeze.cols > 0 && freeze.rows > 0 ? "bottomRight" : freeze.rows > 0 ? "bottomLeft" : "topRight";
    const split = (freeze.cols > 0 ? ` xSplit="${freeze.cols}"` : "") + (freeze.rows > 0 ? ` ySplit="${freeze.rows}"` : "");
    parts.push(`<sheetViews><sheetView workbookViewId="0"><pane${split} topLeftCell="${topLeft}" activePane="${pane}" state="frozen"/><selection pane="${pane}" activeCell="${topLeft}" sqref="${topLeft}"/></sheetView></sheetViews>`);
  } else {
    parts.push(`<sheetViews><sheetView workbookViewId="0"/></sheetViews>`);
  }
  parts.push(`<sheetFormatPr defaultRowHeight="14.4"/>`);
  parts.push(`<cols>`);
  sheet.widths.forEach((w, i) => parts.push(`<col min="${i + 1}" max="${i + 1}" width="${w}" customWidth="1"/>`));
  parts.push(`</cols><sheetData>`);
  sheet.rows.forEach((row, r) => {
    const defaultStyle = sheet.header && r === 0 ? STYLE.header : STYLE.normal;
    const cells = row.map((c, i) => cellXml(`${colName(i)}${r + 1}`, c, defaultStyle)).join("");
    parts.push(`<row r="${r + 1}">${cells}</row>`);
  });
  parts.push(`</sheetData>`);
  if (sheet.header && sheet.rows.length > 0) parts.push(`<autoFilter ref="A1:${lastCol}${lastRow}"/>`);
  if (sheet.merges && sheet.merges.length > 0) {
    parts.push(`<mergeCells count="${sheet.merges.length}">${sheet.merges.map((m) => `<mergeCell ref="${m}"/>`).join("")}</mergeCells>`);
  }
  parts.push(`<pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>`);
  parts.push(`</worksheet>`);
  return parts.join("");
}

const FONT = `<sz val="11"/><name val="Aptos Narrow"/><family val="2"/>`;
const THIN = `<color auto="1"/>`;
const CENTER = `<alignment horizontal="center" vertical="center"/>`;
const H_CENTER = `<alignment horizontal="center"/>`;

const STYLES_XML = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<numFmts count="5"><numFmt numFmtId="164" formatCode="dd\\-mmm\\-yyyy"/><numFmt numFmtId="165" formatCode="hh:mm"/><numFmt numFmtId="166" formatCode="[h]:mm"/><numFmt numFmtId="167" formatCode="h:mm\\ AM/PM"/><numFmt numFmtId="168" formatCode="h:mm;@"/></numFmts>
<fonts count="2"><font>${FONT}</font><font><b/>${FONT}</font></fonts>
<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFDCE6F1"/><bgColor indexed="64"/></patternFill></fill></fills>
<borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border><border><left style="thin">${THIN}</left><right style="thin">${THIN}</right><top style="thin">${THIN}</top><bottom style="thin">${THIN}</bottom><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="15">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>
<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="166" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
<xf numFmtId="0" fontId="1" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1">${CENTER}</xf>
<xf numFmtId="16" fontId="1" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyFont="1" applyBorder="1" applyAlignment="1">${CENTER}</xf>
<xf numFmtId="0" fontId="1" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1">${H_CENTER}</xf>
<xf numFmtId="0" fontId="1" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1"/>
<xf numFmtId="0" fontId="1" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1">${H_CENTER}</xf>
<xf numFmtId="0" fontId="1" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1"/>
<xf numFmtId="167" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1">${CENTER}</xf>
<xf numFmtId="168" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1">${CENTER}</xf>
<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1"/>
</cellXfs>
<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>`;

export function buildXlsx(sheets: SheetSpec[]): Uint8Array {
  const names = sheets.map((s) => safeSheetName(s.name));
  const files: Array<[string, string]> = [];

  files.push(["[Content_Types].xml",
    `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
    `<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">` +
    `<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>` +
    `<Default Extension="xml" ContentType="application/xml"/>` +
    `<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>` +
    `<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>` +
    sheets.map((_, i) => `<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`).join("") +
    `</Types>`]);

  files.push(["_rels/.rels",
    `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
    `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">` +
    `<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>` +
    `</Relationships>`]);

  const definedNames = sheets
    .map((s, i) => (s.header && s.rows.length > 0
      ? `<definedName name="_xlnm._FilterDatabase" localSheetId="${i}" hidden="1">'${xmlEscape(names[i].replace(/'/g, "''"))}'!$A$1:$${colName(Math.max(s.widths.length, 1) - 1)}$${s.rows.length}</definedName>`
      : ""))
    .join("");

  files.push(["xl/workbook.xml",
    `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
    `<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">` +
    `<bookViews><workbookView/></bookViews><sheets>` +
    names.map((n, i) => `<sheet name="${xmlEscape(n)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>`).join("") +
    `</sheets>` + (definedNames ? `<definedNames>${definedNames}</definedNames>` : "") +
    `<calcPr calcId="191029" fullCalcOnLoad="1"/></workbook>`]);

  files.push(["xl/_rels/workbook.xml.rels",
    `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
    `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">` +
    sheets.map((_, i) => `<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>`).join("") +
    `<Relationship Id="rId${sheets.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>` +
    `</Relationships>`]);

  files.push(["xl/styles.xml", STYLES_XML]);
  sheets.forEach((s, i) => files.push([`xl/worksheets/sheet${i + 1}.xml`, sheetXml({ ...s, name: names[i] })]));

  return zipStore(files.map(([name, text]) => ({ name, data: enc.encode(text) })));
}
'@

# ---------------------------------------------------------------- worker/src/report.ts
Write-File "worker/src/report.ts" @'
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
'@

Write-Host ""
Write-Host "Phase 12 files written. Deploy with: cd worker; npm run deploy" -ForegroundColor Cyan
