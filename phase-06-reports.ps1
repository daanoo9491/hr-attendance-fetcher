# =====================================================================
# HR Auto Attendance Fetcher - PHASE 6 : 2-day schedule + Excel reports
#                                         + connector starts with Windows
# Run from the ROOT of the repo (hr-attendance-fetcher):
#   powershell -ExecutionPolicy Bypass -File .\phase-06-reports.ps1
# =====================================================================
$ErrorActionPreference = "Stop"

function Write-File([string]$Path, [string]$Content) {
    $full = Join-Path (Get-Location) $Path
    $dir  = Split-Path $full -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($full, $Content.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  wrote $Path" -ForegroundColor Green
}

if (-not (Test-Path "connector/src/sync.js")) {
    throw "Run this from the repo root, after Phase 5 (connector/src/sync.js not found)."
}

Write-Host "Phase 6: writing scheduler, Excel reports and autostart..." -ForegroundColor Cyan

# ---------------------------------------------------------------- worker/wrangler.toml (append cron, keep your database_id)
$tomlPath = Join-Path (Get-Location) "worker/wrangler.toml"
$toml = [System.IO.File]::ReadAllText($tomlPath)
if ($toml -match '(?m)^\s*\[triggers\]') {
    Write-Host "  worker/wrangler.toml already has [triggers] - left unchanged" -ForegroundColor Yellow
} else {
    $add = "`n`n# Phase 6: hourly scheduler (2-day attendance reports)`n[triggers]`ncrons = [""5 * * * *""]`n"
    [System.IO.File]::WriteAllText($tomlPath, $toml.TrimEnd() + $add, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  updated worker/wrangler.toml (added hourly cron)" -ForegroundColor Green
}

# ---------------------------------------------------------------- .gitignore
Write-File ".gitignore" @'
node_modules/
.wrangler/
.dev.vars
.env
dist/
*.log
*.log.old
output/
logs/
run-connector.cmd
'@

# ---------------------------------------------------------------- worker/migrations/0004_reports.sql
Write-File "worker/migrations/0004_reports.sql" @'
-- =============================================================
-- Phase 6 - scheduled 2-day attendance reports
-- =============================================================

-- Report schedule per company: every N days, generated after this local hour.
ALTER TABLE companies ADD COLUMN report_every_days INTEGER NOT NULL DEFAULT 2;
ALTER TABLE companies ADD COLUMN report_hour INTEGER NOT NULL DEFAULT 1;

-- One row per scheduled report period. The Excel file itself is built on
-- download from attendance_logs, so it always includes the latest punches.
CREATE TABLE reports (
  id              TEXT PRIMARY KEY,
  company_id      TEXT NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  period_start    TEXT NOT NULL,   -- YYYY-MM-DD, inclusive (company local date)
  period_end      TEXT NOT NULL,   -- YYYY-MM-DD, inclusive
  status          TEXT NOT NULL DEFAULT 'collecting' CHECK (status IN ('collecting','ready')),
  devices_total   INTEGER NOT NULL DEFAULT 0,
  devices_synced  INTEGER NOT NULL DEFAULT 0,
  punch_count     INTEGER NOT NULL DEFAULT 0,
  employee_count  INTEGER NOT NULL DEFAULT 0,
  note            TEXT,
  created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  ready_at        TEXT,
  UNIQUE (company_id, period_start)
);
CREATE INDEX idx_reports_company ON reports(company_id, period_end);

-- Scheduled sync jobs are linked to the report they collect data for.
ALTER TABLE sync_jobs ADD COLUMN report_id TEXT REFERENCES reports(id) ON DELETE SET NULL;
CREATE INDEX idx_sync_jobs_report ON sync_jobs(report_id);
'@

# ---------------------------------------------------------------- worker/src/env.ts
Write-File "worker/src/env.ts" @'
export interface Env {
  DB: D1Database;
  /** Optional. When set, sign-up requires this code (set with: wrangler secret put SIGNUP_CODE). */
  SIGNUP_CODE?: string;
}

export const VERSION = "0.6.0-phase6";

/** Number of files in worker/migrations. The health check reports "degraded" until all are applied. */
export const EXPECTED_MIGRATIONS = 4;
'@

# ---------------------------------------------------------------- worker/src/lib/xlsx.ts
Write-File "worker/src/lib/xlsx.ts" @'
// Minimal, dependency-free .xlsx writer for Workers.
// Produces a standard Office Open XML workbook (stored zip, inline strings).

export const STYLE = {
  normal: 0,
  header: 1,   // bold on light blue
  date: 2,     // dd-mmm-yyyy
  time: 3,     // hh:mm
  duration: 4, // [h]:mm
  bold: 5,
} as const;

export type CellValue = string | number | null | undefined | { v: string | number; s: number };

export interface SheetSpec {
  name: string;
  widths: number[];
  rows: CellValue[][];
  /** First row is a header: bold, frozen, with filter buttons. */
  header?: boolean;
}

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

function colName(index: number): string {
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
  let value: string | number;
  let style = defaultStyle;
  if (typeof cell === "object") {
    value = cell.v;
    style = cell.s;
  } else {
    value = cell;
  }
  const s = style ? ` s="${style}"` : "";
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
  if (sheet.header) {
    parts.push(`<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>`);
  } else {
    parts.push(`<sheetViews><sheetView workbookViewId="0"/></sheetViews>`);
  }
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
  parts.push(`</worksheet>`);
  return parts.join("");
}

const STYLES_XML = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<numFmts count="3"><numFmt numFmtId="164" formatCode="dd\\-mmm\\-yyyy"/><numFmt numFmtId="165" formatCode="hh:mm"/><numFmt numFmtId="166" formatCode="[h]:mm"/></numFmts>
<fonts count="2"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font><font><b/><sz val="11"/><name val="Calibri"/><family val="2"/></font></fonts>
<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFDCE6F1"/><bgColor indexed="64"/></patternFill></fill></fills>
<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="6">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>
<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="166" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
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
    `</sheets>` + (definedNames ? `<definedNames>${definedNames}</definedNames>` : "") + `</workbook>`]);

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

// ---------------------------------------------------------------- zip (store, no compression)

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(data: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < data.length; i++) c = CRC_TABLE[(c ^ data[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function zipStore(entries: Array<{ name: string; data: Uint8Array }>): Uint8Array {
  const now = new Date();
  const dosTime = (now.getUTCHours() << 11) | (now.getUTCMinutes() << 5) | Math.floor(now.getUTCSeconds() / 2);
  const dosDate = ((now.getUTCFullYear() - 1980) << 9) | ((now.getUTCMonth() + 1) << 5) | now.getUTCDate();

  const chunks: Uint8Array[] = [];
  const central: Uint8Array[] = [];
  let offset = 0;

  for (const e of entries) {
    const name = enc.encode(e.name);
    const crc = crc32(e.data);

    const local = new DataView(new ArrayBuffer(30));
    local.setUint32(0, 0x04034b50, true);
    local.setUint16(4, 20, true);
    local.setUint16(6, 0x0800, true); // UTF-8 names
    local.setUint16(8, 0, true);      // stored
    local.setUint16(10, dosTime, true);
    local.setUint16(12, dosDate, true);
    local.setUint32(14, crc, true);
    local.setUint32(18, e.data.length, true);
    local.setUint32(22, e.data.length, true);
    local.setUint16(26, name.length, true);
    local.setUint16(28, 0, true);
    chunks.push(new Uint8Array(local.buffer), name, e.data);

    const cd = new DataView(new ArrayBuffer(46));
    cd.setUint32(0, 0x02014b50, true);
    cd.setUint16(4, 20, true);
    cd.setUint16(6, 20, true);
    cd.setUint16(8, 0x0800, true);
    cd.setUint16(10, 0, true);
    cd.setUint16(12, dosTime, true);
    cd.setUint16(14, dosDate, true);
    cd.setUint32(16, crc, true);
    cd.setUint32(20, e.data.length, true);
    cd.setUint32(24, e.data.length, true);
    cd.setUint16(28, name.length, true);
    cd.setUint16(30, 0, true);
    cd.setUint16(32, 0, true);
    cd.setUint16(34, 0, true);
    cd.setUint16(36, 0, true);
    cd.setUint32(38, 0, true);
    cd.setUint32(42, offset, true);
    central.push(new Uint8Array(cd.buffer), name);

    offset += 30 + name.length + e.data.length;
  }

  const cdSize = central.reduce((n, c) => n + c.length, 0);
  const end = new DataView(new ArrayBuffer(22));
  end.setUint32(0, 0x06054b50, true);
  end.setUint16(8, entries.length, true);
  end.setUint16(10, entries.length, true);
  end.setUint32(12, cdSize, true);
  end.setUint32(16, offset, true);

  const all = [...chunks, ...central, new Uint8Array(end.buffer)];
  const out = new Uint8Array(all.reduce((n, c) => n + c.length, 0));
  let p = 0;
  for (const c of all) { out.set(c, p); p += c.length; }
  return out;
}
'@

# ---------------------------------------------------------------- worker/src/lib/dates.ts
Write-File "worker/src/lib/dates.ts" @'
// Date helpers. Report dates are calendar dates in the company's time zone
// (the same local time the attendance machine records).

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

export function isDate(s: unknown): s is string {
  if (typeof s !== "string" || !DATE_RE.test(s)) return false;
  const d = new Date(`${s}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === s;
}

export function addDays(date: string, n: number): string {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

export function daysBetween(from: string, to: string): number {
  return Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86400000);
}

/** Current date and hour in a time zone, e.g. { date: "2026-10-05", hour: 21 } */
export function localNow(now: Date, timeZone: string): { date: string; hour: number } {
  let tz = timeZone;
  try {
    new Intl.DateTimeFormat("en-CA", { timeZone: tz });
  } catch {
    tz = "Asia/Karachi";
  }
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-CA", {
      timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", hourCycle: "h23",
    }).formatToParts(now).map((p) => [p.type, p.value]),
  );
  return { date: `${parts.year}-${parts.month}-${parts.day}`, hour: Number(parts.hour) };
}

/**
 * The next report period after `lastEnd` (or, for the first report, the
 * `everyDays` full days before today). `dueDate` is the first day it can be
 * generated: the day after the period ends.
 */
export function nextPeriod(lastEnd: string | null, today: string, everyDays: number) {
  const days = Math.max(1, everyDays);
  const start = lastEnd ? addDays(lastEnd, 1) : addDays(today, -days);
  const end = addDays(start, days - 1);
  return { start, end, dueDate: addDays(end, 1) };
}

/** Excel serial date (days since 1899-12-30) for "YYYY-MM-DD". */
export function excelDate(date: string): number {
  return Math.round((Date.parse(`${date}T00:00:00Z`) - Date.UTC(1899, 11, 30)) / 86400000);
}

/** Fraction of a day for "HH:MM:SS". */
export function excelTime(time: string): number {
  const [h, m, s] = time.split(":").map(Number);
  return (h * 3600 + m * 60 + (s || 0)) / 86400;
}
'@

# ---------------------------------------------------------------- worker/src/report.ts
Write-File "worker/src/report.ts" @'
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
'@

# ---------------------------------------------------------------- worker/src/scheduler.ts
Write-File "worker/src/scheduler.ts" @'
// Runs every hour (Cloudflare cron). For each company:
//  1. A "collecting" report becomes "ready" once its sync jobs have finished (or after 3 hours).
//  2. When a report period has ended (default: every 2 days, after 01:00 local time),
//     create the report and a scheduled sync job for every active machine.
import type { Env } from "./env";
import { localNow, nextPeriod } from "./lib/dates";
import { attendanceStats } from "./report";

const MAX_COLLECT_MINUTES = 180;

interface CompanyRow {
  id: string;
  timezone: string;
  report_every_days: number;
  report_hour: number;
}

interface ReportRow {
  id: string;
  company_id: string;
  period_start: string;
  period_end: string;
  created_at: string;
}

export async function runScheduler(env: Env, now = new Date()): Promise<void> {
  const { results } = await env.DB.prepare(
    "SELECT id, timezone, report_every_days, report_hour FROM companies WHERE status = 'active'",
  ).all<CompanyRow>();

  for (const company of results ?? []) {
    try {
      await finishCollecting(env, company, now);
      await startDuePeriod(env, company, now);
    } catch (err) {
      console.error(`scheduler: company ${company.id}: ${String(err)}`);
    }
  }
}

async function finishCollecting(env: Env, company: CompanyRow, now: Date): Promise<void> {
  const { results } = await env.DB.prepare(
    "SELECT id FROM reports WHERE company_id = ? AND status = 'collecting'",
  ).bind(company.id).all<{ id: string }>();
  for (const r of results ?? []) await finalizeReportIfDone(env, r.id, now);
}

/**
 * Marks a collecting report "ready" when none of its sync jobs are still open,
 * or when it has waited MAX_COLLECT_MINUTES. Called hourly and whenever a linked job completes.
 */
export async function finalizeReportIfDone(env: Env, reportId: string, now = new Date()): Promise<boolean> {
  const report = await env.DB.prepare(
    "SELECT id, company_id, period_start, period_end, created_at FROM reports WHERE id = ? AND status = 'collecting'",
  ).bind(reportId).first<ReportRow>();
  if (!report) return false;

  const jobs = await env.DB.prepare(
    `SELECT SUM(CASE WHEN status IN ('pending','running') THEN 1 ELSE 0 END) AS open,
            SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END) AS ok,
            SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) AS failed
       FROM sync_jobs WHERE report_id = ?`,
  ).bind(report.id).first<{ open: number | null; ok: number | null; failed: number | null }>();

  const open = jobs?.open ?? 0;
  const minutes = (now.getTime() - Date.parse(report.created_at)) / 60000;
  if (open > 0 && minutes < MAX_COLLECT_MINUTES) return false;

  const notes: string[] = [];
  if (jobs?.failed) notes.push(`${jobs.failed} machine sync(s) failed`);
  if (open > 0) notes.push(`${open} machine(s) had not synced after ${MAX_COLLECT_MINUTES / 60} hours - is the connector PC on?`);
  const stats = await attendanceStats(env, report.company_id, report.period_start, report.period_end);

  const res = await env.DB.prepare(
    `UPDATE reports
        SET status = 'ready', ready_at = ?, devices_synced = ?, punch_count = ?, employee_count = ?, note = ?
      WHERE id = ? AND status = 'collecting'`,
  ).bind(now.toISOString(), jobs?.ok ?? 0, stats.punches, stats.employees, notes.join("; ") || null, report.id).run();
  return (res.meta.changes ?? 0) > 0;
}

async function startDuePeriod(env: Env, company: CompanyRow, now: Date): Promise<void> {
  // Only one report collects at a time.
  const collecting = await env.DB.prepare(
    "SELECT 1 FROM reports WHERE company_id = ? AND status = 'collecting' LIMIT 1",
  ).bind(company.id).first();
  if (collecting) return;

  const local = localNow(now, company.timezone);
  const last = await env.DB.prepare(
    "SELECT period_end FROM reports WHERE company_id = ? ORDER BY period_end DESC LIMIT 1",
  ).bind(company.id).first<{ period_end: string }>();
  const period = nextPeriod(last?.period_end ?? null, local.date, company.report_every_days);

  // Due once the period's last day is over and it's past the report hour.
  if (local.date < period.dueDate) return;
  if (local.date === period.dueDate && local.hour < company.report_hour) return;

  const reportId = crypto.randomUUID();
  const inserted = await env.DB.prepare(
    "INSERT OR IGNORE INTO reports (id, company_id, period_start, period_end, created_at) VALUES (?, ?, ?, ?, ?)",
  ).bind(reportId, company.id, period.start, period.end, now.toISOString()).run();
  if (!inserted.meta.changes) return;

  const { results: devices } = await env.DB.prepare(
    `SELECT d.id FROM devices d JOIN connectors c ON c.id = d.connector_id
      WHERE d.company_id = ? AND d.is_active = 1 AND c.is_active = 1`,
  ).bind(company.id).all<{ id: string }>();

  const statements: D1PreparedStatement[] = [
    env.DB.prepare("UPDATE reports SET devices_total = ? WHERE id = ?").bind(devices?.length ?? 0, reportId),
  ];
  for (const d of devices ?? []) {
    const open = await env.DB.prepare(
      "SELECT id FROM sync_jobs WHERE device_id = ? AND status IN ('pending','running') LIMIT 1",
    ).bind(d.id).first<{ id: string }>();
    if (open) {
      statements.push(env.DB.prepare("UPDATE sync_jobs SET report_id = ? WHERE id = ?").bind(reportId, open.id));
    } else {
      statements.push(
        env.DB.prepare(
          `INSERT INTO sync_jobs (id, company_id, device_id, trigger_type, status, report_id, requested_at)
           VALUES (?, ?, ?, 'scheduled', 'pending', ?, ?)`,
        ).bind(crypto.randomUUID(), company.id, d.id, reportId, now.toISOString()),
      );
    }
  }
  await env.DB.batch(statements);

  // No machines: nothing to wait for.
  if (!devices?.length) await finalizeReportIfDone(env, reportId, now);
}
'@

# ---------------------------------------------------------------- worker/src/routes/reports.ts
Write-File "worker/src/routes/reports.ts" @'
// Attendance report API (browser session). Any role may view and download.
import type { Env } from "../env";
import { HttpError, json } from "../lib/http";
import { requireAuth, type AuthContext } from "../lib/auth";
import { daysBetween, isDate, localNow, nextPeriod } from "../lib/dates";
import { buildAttendanceReport, reportFilename, xlsxResponse } from "../report";

const MAX_EXPORT_DAYS = 62;

async function schedule(env: Env, auth: AuthContext) {
  const c = await env.DB.prepare("SELECT report_every_days, report_hour FROM companies WHERE id = ?")
    .bind(auth.companyId).first<{ report_every_days: number; report_hour: number }>();
  const everyDays = c?.report_every_days ?? 2;
  const hour = c?.report_hour ?? 1;
  const last = await env.DB.prepare(
    "SELECT period_end FROM reports WHERE company_id = ? ORDER BY period_end DESC LIMIT 1",
  ).bind(auth.companyId).first<{ period_end: string }>();
  const today = localNow(new Date(), auth.companyTimezone).date;
  const next = nextPeriod(last?.period_end ?? null, today, everyDays);
  return { every_days: everyDays, hour, timezone: auth.companyTimezone, next_start: next.start, next_end: next.end, next_due: next.dueDate };
}

/** GET /api/reports */
export async function listReports(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  const { results } = await env.DB.prepare(
    `SELECT id, period_start, period_end, status, devices_total, devices_synced,
            punch_count, employee_count, note, created_at, ready_at
       FROM reports
      WHERE company_id = ?
      ORDER BY period_end DESC
      LIMIT 30`,
  ).bind(auth.companyId).all();
  return json({ reports: results ?? [], schedule: await schedule(env, auth) });
}

/** GET /api/reports/:id/download */
export async function downloadReport(request: Request, env: Env, id: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  const report = await env.DB.prepare(
    "SELECT period_start, period_end, status, devices_total, devices_synced, note FROM reports WHERE id = ? AND company_id = ?",
  ).bind(id, auth.companyId).first<{
    period_start: string; period_end: string; status: string; devices_total: number; devices_synced: number; note: string | null;
  }>();
  if (!report) throw new HttpError(404, "Report not found");

  const notes = [`Scheduled report: ${report.devices_synced}/${report.devices_total} machine(s) synced for this period.`];
  if (report.status !== "ready") notes.push("This report was still collecting data when downloaded.");
  if (report.note) notes.push(report.note);

  const { bytes } = await buildAttendanceReport(
    env,
    { companyId: auth.companyId, companyName: auth.companyName, timezone: auth.companyTimezone, notes },
    report.period_start,
    report.period_end,
  );
  return xlsxResponse(bytes, reportFilename(auth.companyName, report.period_start, report.period_end));
}

/** GET /api/export.xlsx?from=YYYY-MM-DD&to=YYYY-MM-DD */
export async function exportRange(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  const params = new URL(request.url).searchParams;
  const from = params.get("from");
  const to = params.get("to");
  if (!isDate(from) || !isDate(to)) throw new HttpError(400, "from and to must be dates (YYYY-MM-DD)");
  if (to < from) throw new HttpError(400, "'to' must be on or after 'from'");
  if (daysBetween(from, to) + 1 > MAX_EXPORT_DAYS) throw new HttpError(400, `Export at most ${MAX_EXPORT_DAYS} days at a time`);

  const { bytes } = await buildAttendanceReport(
    env,
    { companyId: auth.companyId, companyName: auth.companyName, timezone: auth.companyTimezone, notes: ["Manual export."] },
    from,
    to,
  );
  return xlsxResponse(bytes, reportFilename(auth.companyName, from, to));
}
'@

# ---------------------------------------------------------------- worker/src/routes/connector.ts
Write-File "worker/src/routes/connector.ts" @'
// ZKT Connector API. Authenticated with "Authorization: Bearer zkc_..." (not a browser session).
// A connector can only see devices assigned to it, and jobs of those devices.
import type { Env } from "../env";
import { HttpError, json, readJson } from "../lib/http";
import { sha256Hex } from "../lib/crypto";
import { finalizeReportIfDone } from "../scheduler";

const MAX_RECORDS_PER_UPLOAD = 1000;
const STALE_JOB_MINUTES = 30;
const TOKEN_RE = /^Bearer\s+(zkc_[A-Za-z0-9_-]{20,})$/;
const TIMESTAMP_RE = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})$/;

interface ConnectorContext {
  connectorId: string;
  connectorName: string;
  companyId: string;
  companyTimezone: string;
}

async function requireConnector(request: Request, env: Env): Promise<ConnectorContext> {
  const match = TOKEN_RE.exec(request.headers.get("authorization") ?? "");
  if (!match) throw new HttpError(401, "Missing or invalid connector token");

  const row = await env.DB.prepare(
    `SELECT c.id, c.name, c.company_id, co.timezone
       FROM connectors c JOIN companies co ON co.id = c.company_id
      WHERE c.token_hash = ? AND c.is_active = 1 AND co.status = 'active'`,
  ).bind(await sha256Hex(match[1])).first<{ id: string; name: string; company_id: string; timezone: string }>();
  if (!row) throw new HttpError(401, "Connector token is not valid or has been revoked");

  const version = (request.headers.get("x-connector-version") ?? "").trim().slice(0, 40) || null;
  await env.DB.prepare("UPDATE connectors SET last_seen_at = ?, version = COALESCE(?, version) WHERE id = ?")
    .bind(new Date().toISOString(), version, row.id).run();

  return { connectorId: row.id, connectorName: row.name, companyId: row.company_id, companyTimezone: row.timezone };
}

/** Loads a job only if it belongs to one of this connector's devices. */
async function loadOwnJob(env: Env, ctx: ConnectorContext, jobId: string) {
  const job = await env.DB.prepare(
    `SELECT j.id, j.status, j.device_id, j.company_id, j.report_id
       FROM sync_jobs j JOIN devices d ON d.id = j.device_id
      WHERE j.id = ? AND j.company_id = ? AND d.connector_id = ?`,
  ).bind(jobId, ctx.companyId, ctx.connectorId)
    .first<{ id: string; status: string; device_id: string; company_id: string; report_id: string | null }>();
  if (!job) throw new HttpError(404, "Job not found");
  return job;
}

// ------------------------------------------------------------------ GET /api/connector/config
export async function connectorConfig(request: Request, env: Env): Promise<Response> {
  const ctx = await requireConnector(request, env);
  const { results } = await env.DB.prepare(
    `SELECT id, name, model, ip_address, port, comm_key, serial_number, last_sync_at
       FROM devices
      WHERE connector_id = ? AND company_id = ? AND is_active = 1
      ORDER BY name`,
  ).bind(ctx.connectorId, ctx.companyId).all();

  return json({
    connector: { id: ctx.connectorId, name: ctx.connectorName },
    company: { timezone: ctx.companyTimezone },
    devices: results ?? [],
    server_time: new Date().toISOString(),
  });
}

// ------------------------------------------------------------------ POST /api/connector/jobs/claim
export async function claimJob(request: Request, env: Env): Promise<Response> {
  const ctx = await requireConnector(request, env);
  const now = new Date();
  const staleBefore = new Date(now.getTime() - STALE_JOB_MINUTES * 60_000).toISOString();

  // 1) Jobs this connector started but never finished are marked failed.
  await env.DB.prepare(
    `UPDATE sync_jobs
        SET status = 'failed', finished_at = ?, error_message = 'Timed out: connector did not report completion'
      WHERE status = 'running' AND started_at < ?
        AND device_id IN (SELECT id FROM devices WHERE connector_id = ?)`,
  ).bind(now.toISOString(), staleBefore, ctx.connectorId).run();

  // 2) Atomically take the oldest pending job for this connector's devices.
  const job = await env.DB.prepare(
    `UPDATE sync_jobs
        SET status = 'running', started_at = ?
      WHERE status = 'pending'
        AND id = (
          SELECT j.id FROM sync_jobs j JOIN devices d ON d.id = j.device_id
           WHERE j.status = 'pending' AND j.company_id = ? AND d.connector_id = ? AND d.is_active = 1
           ORDER BY j.requested_at
           LIMIT 1)
      RETURNING id, device_id, trigger_type, requested_at, started_at`,
  ).bind(now.toISOString(), ctx.companyId, ctx.connectorId)
    .first<{ id: string; device_id: string; trigger_type: string; requested_at: string; started_at: string }>();

  if (!job) return json({ job: null });

  const device = await env.DB.prepare(
    "SELECT id, name, model, ip_address, port, comm_key, last_sync_at FROM devices WHERE id = ?",
  ).bind(job.device_id).first();

  return json({ job: { ...job, device } });
}

// ------------------------------------------------------------------ POST /api/connector/jobs/:id/logs
interface CleanRecord { u: string; t: string; s: number | null; v: number | null }

function cleanRecord(raw: unknown): CleanRecord | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;

  const userId = String(r.user_id ?? "").trim();
  if (!userId || userId.length > 32) return null;

  const m = TIMESTAMP_RE.exec(typeof r.timestamp === "string" ? r.timestamp.trim() : "");
  if (!m) return null;
  const [mo, d, h, mi, s] = [m[2], m[3], m[4], m[5], m[6]].map(Number);
  if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || s > 59) return null;

  const state = Number.isInteger(r.state) ? (r.state as number) : null;
  const verify = Number.isInteger(r.verify_mode) ? (r.verify_mode as number) : null;
  return { u: userId, t: `${m[1]}-${m[2]}-${m[3]} ${m[4]}:${m[5]}:${m[6]}`, s: state, v: verify };
}

export async function uploadLogs(request: Request, env: Env, jobId: string): Promise<Response> {
  const ctx = await requireConnector(request, env);
  const job = await loadOwnJob(env, ctx, jobId);
  if (job.status !== "running") throw new HttpError(409, `Job is ${job.status}, not running`);

  const body = await readJson<{ records?: unknown }>(request);
  if (!Array.isArray(body.records)) throw new HttpError(400, "Body must be { records: [...] }");
  if (body.records.length > MAX_RECORDS_PER_UPLOAD) {
    throw new HttpError(413, `Send at most ${MAX_RECORDS_PER_UPLOAD} records per request`);
  }

  const clean = body.records.map(cleanRecord).filter((r): r is CleanRecord => r !== null);
  const rejected = body.records.length - clean.length;

  let inserted = 0;
  if (clean.length > 0) {
    // One statement for the whole chunk; duplicates are skipped by the UNIQUE key.
    const res = await env.DB.prepare(
      `INSERT OR IGNORE INTO attendance_logs
         (company_id, device_id, device_user_id, punch_time, punch_state, verify_mode, sync_job_id)
       SELECT ?1, ?2,
              json_extract(value, '$.u'), json_extract(value, '$.t'),
              json_extract(value, '$.s'), json_extract(value, '$.v'), ?3
         FROM json_each(?4)`,
    ).bind(job.company_id, job.device_id, job.id, JSON.stringify(clean)).run();
    inserted = res.meta.changes ?? 0;
  }

  await env.DB.prepare(
    "UPDATE sync_jobs SET records_fetched = records_fetched + ?, records_inserted = records_inserted + ? WHERE id = ?",
  ).bind(clean.length, inserted, job.id).run();

  return json({
    received: body.records.length,
    accepted: clean.length,
    rejected,
    inserted,
    duplicates: clean.length - inserted,
  });
}

// ------------------------------------------------------------------ POST /api/connector/jobs/:id/complete
export async function completeJob(request: Request, env: Env, jobId: string): Promise<Response> {
  const ctx = await requireConnector(request, env);
  const job = await loadOwnJob(env, ctx, jobId);
  if (job.status !== "running") throw new HttpError(409, `Job is ${job.status}, not running`);

  const body = await readJson<Record<string, unknown>>(request);
  const status = body.status;
  if (status !== "success" && status !== "failed") throw new HttpError(400, "status must be 'success' or 'failed'");
  const errorMessage = status === "failed"
    ? (typeof body.error_message === "string" && body.error_message.trim() ? body.error_message.trim().slice(0, 500) : "Unknown error")
    : null;
  const serial = typeof body.device_serial === "string" && body.device_serial.trim()
    ? body.device_serial.trim().slice(0, 64)
    : null;
  const skipped = Number.isInteger(body.records_skipped) && (body.records_skipped as number) >= 0
    ? (body.records_skipped as number)
    : 0;
  const clockOffset = Number.isInteger(body.clock_offset_seconds) && Math.abs(body.clock_offset_seconds as number) < 20 * 365 * 86400
    ? (body.clock_offset_seconds as number)
    : null;

  const now = new Date().toISOString();
  const statements = [
    env.DB.prepare("UPDATE sync_jobs SET status = ?, finished_at = ?, error_message = ?, records_skipped = ? WHERE id = ?")
      .bind(status, now, errorMessage, skipped, job.id),
  ];
  if (status === "success") {
    statements.push(
      env.DB.prepare(
        `UPDATE devices
            SET last_sync_at = ?, serial_number = COALESCE(?, serial_number),
                clock_offset_seconds = COALESCE(?, clock_offset_seconds),
                clock_checked_at = CASE WHEN ? IS NULL THEN clock_checked_at ELSE ? END
          WHERE id = ?`,
      ).bind(now, serial, clockOffset, clockOffset, now, job.device_id),
    );
  }
  await env.DB.batch(statements);

  // If this was the last machine for a scheduled report, the report is ready now.
  if (job.report_id) await finalizeReportIfDone(env, job.report_id);

  const summary = await env.DB.prepare(
    `SELECT id, status, records_fetched, records_inserted, records_skipped, finished_at, error_message
       FROM sync_jobs WHERE id = ?`,
  ).bind(job.id).first();
  return json({ job: summary });
}
'@

# ---------------------------------------------------------------- worker/src/pages.ts
Write-File "worker/src/pages.ts" @'
import { VERSION } from "./env";
import type { AuthContext } from "./lib/auth";
import { escapeHtml } from "./lib/http";

const STYLE = `
:root { --bg:#f5f6f8; --card:#ffffff; --text:#1c2330; --muted:#667085; --border:#d9dde3; --accent:#1f6feb; --error:#c62828; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#0f1318; --card:#171c23; --text:#e6e9ee; --muted:#98a2b3; --border:#2a313b; --accent:#4c8dff; --error:#ff6b6b; }
}
* { box-sizing:border-box; }
body { margin:0; font-family:system-ui,-apple-system,"Segoe UI",sans-serif; background:var(--bg); color:var(--text); }
.wrap { max-width:420px; margin:8vh auto; padding:0 16px; }
.wide { max-width:860px; }
.card { background:var(--card); border:1px solid var(--border); border-radius:12px; padding:28px; }
h1 { font-size:20px; margin:0 0 4px; }
p.sub { color:var(--muted); margin:0 0 20px; font-size:14px; }
label { display:block; font-size:13px; margin:14px 0 6px; color:var(--muted); }
input { width:100%; padding:10px 12px; border:1px solid var(--border); border-radius:8px; background:var(--bg); color:var(--text); font-size:15px; }
button { margin-top:20px; width:100%; padding:11px; border:0; border-radius:8px; background:var(--accent); color:#fff; font-size:15px; cursor:pointer; }
button:disabled { opacity:.6; cursor:default; }
.msg { color:var(--error); font-size:14px; min-height:20px; margin-top:12px; }
.alt { text-align:center; font-size:14px; margin-top:16px; color:var(--muted); }
a { color:var(--accent); }
.top { display:flex; justify-content:space-between; align-items:center; margin-bottom:20px; }
.top button { width:auto; margin:0; padding:8px 14px; background:transparent; color:var(--text); border:1px solid var(--border); }
dl { display:grid; grid-template-columns:140px 1fr; gap:10px 16px; margin:0; font-size:15px; }
dt { color:var(--muted); }
dd { margin:0; word-break:break-word; }
.foot { color:var(--muted); font-size:12px; text-align:center; margin-top:16px; }
.dash { max-width:1100px; margin:24px auto; padding:0 16px; }
.dash .card { margin-bottom:20px; padding:20px; }
.dash h2 { font-size:16px; margin:0 0 4px; }
.dash p.sub { margin-bottom:14px; }
.row { display:flex; flex-wrap:wrap; gap:10px; align-items:flex-end; }
.row .f { display:flex; flex-direction:column; flex:1 1 140px; }
.row .f label { margin:0 0 4px; }
.row input, .row select { padding:8px 10px; border:1px solid var(--border); border-radius:8px; background:var(--bg); color:var(--text); font-size:14px; width:100%; }
.row button, .sm { width:auto; margin:0; padding:9px 14px; font-size:14px; }
.sm { padding:5px 10px; font-size:13px; margin-left:4px; background:transparent; color:var(--text); border:1px solid var(--border); }
.sm.primary { background:var(--accent); color:#fff; border-color:var(--accent); }
.tbl { overflow-x:auto; margin-top:14px; }
table { width:100%; border-collapse:collapse; font-size:13px; }
th, td { text-align:left; padding:8px 6px; border-bottom:1px solid var(--border); white-space:nowrap; }
th { color:var(--muted); font-weight:500; }
td.err { white-space:normal; color:var(--error); max-width:280px; }
td.warn { color:#b26b00; }
.badge { display:inline-block; padding:2px 8px; border-radius:999px; font-size:12px; border:1px solid var(--border); }
.b-success, .b-active, .b-ready { color:#1a7f37; border-color:#1a7f37; }
.b-collecting { color:#b26b00; border-color:#b26b00; }
a.dl { display:inline-block; text-decoration:none; border-radius:8px; }
.b-failed, .b-revoked, .b-inactive { color:var(--error); border-color:var(--error); }
.b-running, .b-pending { color:#b26b00; border-color:#b26b00; }
.token { margin-top:14px; padding:12px; border:1px dashed var(--accent); border-radius:8px; font-size:13px; }
.token code { display:block; margin:8px 0; padding:8px; background:var(--bg); border-radius:6px; word-break:break-all; font-size:13px; }
.empty { color:var(--muted); font-size:13px; padding:10px 0; }
.dash .msg { margin-top:8px; min-height:0; }
`;

function layout(title: string, body: string): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title}</title>
<style>${STYLE}</style>
</head>
<body>${body}</body>
</html>`;
}

/** Shared client script: posts the form as JSON and follows the redirect. */
function formScript(endpoint: string): string {
  return `<script>
document.getElementById("f").addEventListener("submit", async function (e) {
  e.preventDefault();
  var btn = this.querySelector("button");
  var msg = document.getElementById("msg");
  msg.textContent = "";
  btn.disabled = true;
  try {
    var data = Object.fromEntries(new FormData(this));
    var res = await fetch("${endpoint}", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(data)
    });
    var out = await res.json().catch(function () { return {}; });
    if (res.ok) { location.href = out.redirect || "/app"; return; }
    msg.textContent = out.error || "Something went wrong";
  } catch (err) {
    msg.textContent = "Network error, please try again";
  }
  btn.disabled = false;
});
</script>`;
}

export function loginPage(): string {
  return layout("Sign in", `
<div class="wrap"><div class="card">
  <h1>HR Attendance</h1>
  <p class="sub">Sign in to your company account</p>
  <form id="f">
    <label for="email">Email</label>
    <input id="email" name="email" type="email" autocomplete="email" required>
    <label for="password">Password</label>
    <input id="password" name="password" type="password" autocomplete="current-password" required>
    <button type="submit">Sign in</button>
    <div class="msg" id="msg"></div>
  </form>
  <div class="alt">New company? <a href="/signup">Create an account</a></div>
</div><div class="foot">${VERSION}</div></div>
${formScript("/api/auth/login")}`);
}

export function signupPage(requireCode: boolean): string {
  const codeField = requireCode
    ? `<label for="signup_code">Sign-up code</label>
    <input id="signup_code" name="signup_code" type="text" autocomplete="off" required>`
    : "";
  return layout("Create account", `
<div class="wrap"><div class="card">
  <h1>Create your company account</h1>
  <p class="sub">You will be the owner of this company workspace</p>
  <form id="f">
    <label for="company_name">Company name</label>
    <input id="company_name" name="company_name" type="text" required>
    <label for="full_name">Your full name</label>
    <input id="full_name" name="full_name" type="text" autocomplete="name" required>
    <label for="email">Email</label>
    <input id="email" name="email" type="email" autocomplete="email" required>
    <label for="password">Password (min 8 characters)</label>
    <input id="password" name="password" type="password" autocomplete="new-password" minlength="8" required>
    ${codeField}
    <button type="submit">Create account</button>
    <div class="msg" id="msg"></div>
  </form>
  <div class="alt">Already have an account? <a href="/login">Sign in</a></div>
</div><div class="foot">${VERSION}</div></div>
${formScript("/api/auth/signup")}`);
}

export function appPage(auth: AuthContext): string {
  const e = escapeHtml;
  const canManage = auth.role === "owner" || auth.role === "admin";
  const hide = canManage ? "" : ` style="display:none"`;
  return layout("Dashboard", `
<div class="dash">
  <div class="top">
    <div>
      <h1>${e(auth.companyName)}</h1>
      <p class="sub" style="margin:0">${e(auth.fullName)} &middot; ${e(auth.role)}</p>
    </div>
    <button id="logout" type="button">Sign out</button>
  </div>

  <div class="card">
    <h2>Attendance reports</h2>
    <p class="sub" id="r_sched">Every 2 days an Excel report of the previous 2 days is prepared automatically.</p>
    <div class="tbl"><table>
      <thead><tr><th>Period</th><th>Status</th><th>Machines synced</th><th>Employees</th><th>Punches</th><th>Ready at</th><th>Note</th><th></th></tr></thead>
      <tbody id="r_rows"></tbody>
    </table></div>
    <div class="row" style="margin-top:16px">
      <div class="f" style="flex:0 1 170px"><label for="x_from">Custom export from</label><input id="x_from" type="date"></div>
      <div class="f" style="flex:0 1 170px"><label for="x_to">to</label><input id="x_to" type="date"></div>
      <button id="x_go" type="button">Download Excel</button>
    </div>
    <div class="msg" id="x_msg"></div>
  </div>

  <div class="card">
    <h2>1. Connectors</h2>
    <p class="sub">A connector is the ZKT Connector app on an office PC that can reach the machine. Its token goes into connector/.env.</p>
    <div class="row"${hide}>
      <div class="f"><label for="c_name">Connector name</label><input id="c_name" placeholder="Office PC - Lahore"></div>
      <button id="c_add" type="button">Create connector</button>
    </div>
    <div class="msg" id="c_msg"></div>
    <div id="c_token"></div>
    <div class="tbl"><table>
      <thead><tr><th>Name</th><th>Token</th><th>Status</th><th>Version</th><th>Last seen</th><th>Devices</th><th></th></tr></thead>
      <tbody id="c_rows"></tbody>
    </table></div>
  </div>

  <div class="card">
    <h2>2. Devices</h2>
    <p class="sub">Attendance machines on your LAN, each assigned to the connector that reads it.</p>
    <div class="row"${hide}>
      <div class="f"><label for="d_name">Device name</label><input id="d_name" placeholder="Main entrance K50"></div>
      <div class="f"><label for="d_ip">IP address</label><input id="d_ip" placeholder="192.168.10.21"></div>
      <div class="f" style="flex:0 1 90px"><label for="d_port">Port</label><input id="d_port" value="4370"></div>
      <div class="f" style="flex:0 1 90px"><label for="d_key">Comm key</label><input id="d_key" value="0"></div>
      <div class="f"><label for="d_conn">Connector</label><select id="d_conn"></select></div>
      <button id="d_add" type="button">Add device</button>
    </div>
    <div class="msg" id="d_msg"></div>
    <div class="tbl"><table>
      <thead><tr><th>Name</th><th>Address</th><th>Connector</th><th>Serial</th><th>Clock</th><th>Last sync</th><th>Logs</th><th>Last job</th><th></th></tr></thead>
      <tbody id="d_rows"></tbody>
    </table></div>
  </div>

  <div class="card">
    <h2>3. Sync jobs</h2>
    <p class="sub">Each import run. The connector picks up pending jobs and uploads the machine's attendance logs.</p>
    <div class="tbl"><table>
      <thead><tr><th>Requested</th><th>Device</th><th>Trigger</th><th>Status</th><th>Read</th><th>New</th><th>Skipped</th><th>Finished</th><th>Error</th></tr></thead>
      <tbody id="j_rows"></tbody>
    </table></div>
  </div>

  <div class="foot">${VERSION}</div>
</div>
<script>
var CAN_MANAGE = ${canManage ? "true" : "false"};

async function api(method, path, body) {
  var opts = { method: method, headers: {} };
  if (body !== undefined) { opts.headers["content-type"] = "application/json"; opts.body = JSON.stringify(body); }
  var res = await fetch(path, opts);
  var data = await res.json().catch(function () { return {}; });
  if (res.status === 401) { location.href = "/login"; throw new Error("Signed out"); }
  if (!res.ok) throw new Error(data.error || ("Request failed (" + res.status + ")"));
  return data;
}

function when(v) { return v ? new Date(v).toLocaleString() : "\\u2014"; }
function td(text, cls) { var c = document.createElement("td"); c.textContent = (text === null || text === undefined || text === "") ? "\\u2014" : String(text); if (cls) c.className = cls; return c; }
function badge(text) { var c = document.createElement("td"); if (!text) { c.textContent = "\\u2014"; return c; } var s = document.createElement("span"); s.className = "badge b-" + text; s.textContent = text; c.appendChild(s); return c; }
function btn(label, primary, onClick) { var b = document.createElement("button"); b.type = "button"; b.className = primary ? "sm primary" : "sm"; b.textContent = label; b.addEventListener("click", onClick); return b; }
function clockCell(sec) {
  var c = document.createElement("td");
  if (sec === null || sec === undefined) { c.textContent = "\\u2014"; return c; }
  var a = Math.abs(sec);
  var txt = a < 60 ? a + " s" : a < 3600 ? Math.round(a / 60) + " min" : a < 86400 ? (a / 3600).toFixed(1) + " h" : Math.round(a / 86400) + " days";
  c.textContent = a <= 60 ? "OK" : (sec < 0 ? txt + " slow" : txt + " fast");
  if (a > 60) { c.className = "warn"; c.title = "The machine clock is off. Correct the time on the machine so punches are recorded at the right time."; }
  return c;
}
function emptyRow(tbody, cols, text) { var tr = document.createElement("tr"); var c = document.createElement("td"); c.colSpan = cols; c.className = "empty"; c.textContent = text; tr.appendChild(c); tbody.appendChild(tr); }
function showMsg(id, text) { document.getElementById(id).textContent = text || ""; }

function fmtDate(d) { var p = d.split("-"); var m = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"][Number(p[1]) - 1]; return p[2] + " " + m + " " + p[0]; }
function period(a, b) { return a === b ? fmtDate(a) : fmtDate(a) + " \\u2013 " + fmtDate(b); }
function isoLocal(offsetDays) { var d = new Date(); d.setDate(d.getDate() + offsetDays); var p = function (n) { return String(n).padStart(2, "0"); }; return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate()); }

async function loadReports() {
  var data = await api("GET", "/api/reports");
  var s = data.schedule;
  document.getElementById("r_sched").textContent =
    "Every " + s.every_days + " days an Excel report of the previous " + s.every_days + " days is prepared automatically. Next: " +
    period(s.next_start, s.next_end) + ", ready on " + fmtDate(s.next_due) + " after " + String(s.hour).padStart(2, "0") + ":00 (" + s.timezone + ").";
  var tbody = document.getElementById("r_rows");
  tbody.textContent = "";
  if (!data.reports.length) emptyRow(tbody, 8, "No reports yet. The first one is created at the next scheduled time.");
  data.reports.forEach(function (r) {
    var tr = document.createElement("tr");
    tr.appendChild(td(period(r.period_start, r.period_end)));
    tr.appendChild(badge(r.status === "ready" ? "ready" : "collecting"));
    tr.appendChild(td(r.devices_synced + " / " + r.devices_total));
    tr.appendChild(td(r.status === "ready" ? r.employee_count : ""));
    tr.appendChild(td(r.status === "ready" ? r.punch_count : ""));
    tr.appendChild(td(when(r.ready_at)));
    tr.appendChild(td(r.note, r.note ? "warn" : ""));
    var actions = document.createElement("td");
    var a = document.createElement("a");
    a.href = "/api/reports/" + r.id + "/download";
    a.className = "sm primary dl";
    a.textContent = "Download Excel";
    actions.appendChild(a);
    tr.appendChild(actions);
    tbody.appendChild(tr);
  });
}

async function loadConnectors() {
  var data = await api("GET", "/api/connectors");
  var tbody = document.getElementById("c_rows");
  var select = document.getElementById("d_conn");
  tbody.textContent = ""; select.textContent = "";
  var none = document.createElement("option"); none.value = ""; none.textContent = "(none yet)"; select.appendChild(none);
  if (!data.connectors.length) emptyRow(tbody, 7, "No connectors yet. Create one first.");
  data.connectors.forEach(function (c) {
    var tr = document.createElement("tr");
    tr.appendChild(td(c.name));
    tr.appendChild(td(c.token_hint ? "zkc_\\u2026" + c.token_hint : ""));
    tr.appendChild(badge(c.is_active ? "active" : "revoked"));
    tr.appendChild(td(c.version));
    tr.appendChild(td(when(c.last_seen_at)));
    tr.appendChild(td(c.device_count));
    var actions = document.createElement("td");
    if (CAN_MANAGE && c.is_active) {
      actions.appendChild(btn("Revoke", false, async function () {
        if (!confirm("Revoke connector '" + c.name + "'? It will stop working immediately.")) return;
        try { await api("POST", "/api/connectors/" + c.id + "/revoke", {}); await refresh(); } catch (err) { alert(err.message); }
      }));
    }
    tr.appendChild(actions);
    tbody.appendChild(tr);
    if (c.is_active) { var o = document.createElement("option"); o.value = c.id; o.textContent = c.name; select.appendChild(o); }
  });
  if (select.options.length > 1) select.selectedIndex = 1;
}

async function loadDevices() {
  var data = await api("GET", "/api/devices");
  var tbody = document.getElementById("d_rows");
  tbody.textContent = "";
  if (!data.devices.length) emptyRow(tbody, 9, "No devices yet.");
  data.devices.forEach(function (d) {
    var tr = document.createElement("tr");
    tr.appendChild(td(d.name + (d.is_active ? "" : " (inactive)")));
    tr.appendChild(td(d.ip_address + ":" + d.port));
    tr.appendChild(td(d.connector_name));
    tr.appendChild(td(d.serial_number));
    tr.appendChild(clockCell(d.clock_offset_seconds));
    tr.appendChild(td(when(d.last_sync_at)));
    tr.appendChild(td(d.log_count));
    tr.appendChild(badge(d.last_job_status));
    var actions = document.createElement("td");
    if (CAN_MANAGE && d.is_active) {
      actions.appendChild(btn("Sync now", true, async function () {
        try {
          var r = await api("POST", "/api/devices/" + d.id + "/sync", {});
          showMsg("d_msg", r.already_queued ? "A sync for this device is already " + r.job.status + "." : "");
          await refresh();
        } catch (err) { alert(err.message); }
      }));
      actions.appendChild(btn("Deactivate", false, async function () {
        if (!confirm("Deactivate device '" + d.name + "'? Its attendance data is kept.")) return;
        try { await api("POST", "/api/devices/" + d.id + "/deactivate", {}); await refresh(); } catch (err) { alert(err.message); }
      }));
    }
    tr.appendChild(actions);
    tbody.appendChild(tr);
  });
}

async function loadJobs() {
  var data = await api("GET", "/api/sync-jobs?limit=20");
  var tbody = document.getElementById("j_rows");
  tbody.textContent = "";
  if (!data.jobs.length) emptyRow(tbody, 9, "No sync jobs yet.");
  data.jobs.forEach(function (j) {
    var tr = document.createElement("tr");
    tr.appendChild(td(when(j.requested_at)));
    tr.appendChild(td(j.device_name));
    tr.appendChild(td(j.trigger_type));
    tr.appendChild(badge(j.status));
    tr.appendChild(td(j.records_fetched + (j.records_skipped || 0)));
    tr.appendChild(td(j.records_inserted));
    tr.appendChild(td(j.records_skipped, j.records_skipped ? "warn" : ""));
    tr.appendChild(td(when(j.finished_at)));
    tr.appendChild(td(j.error_message, j.error_message ? "err" : ""));
    tbody.appendChild(tr);
  });
}

async function refresh() {
  try { await Promise.all([loadReports(), loadConnectors(), loadDevices(), loadJobs()]); }
  catch (err) { showMsg("d_msg", err.message); }
}

document.getElementById("c_add").addEventListener("click", async function () {
  showMsg("c_msg", "");
  var box = document.getElementById("c_token"); box.textContent = "";
  try {
    var r = await api("POST", "/api/connectors", { name: document.getElementById("c_name").value });
    var wrap = document.createElement("div"); wrap.className = "token";
    var title = document.createElement("strong"); title.textContent = "Connector token for '" + r.connector.name + "'";
    var code = document.createElement("code"); code.textContent = r.token;
    var note = document.createElement("div"); note.textContent = r.note;
    var copy = btn("Copy token", true, function () { navigator.clipboard.writeText(r.token); copy.textContent = "Copied"; });
    wrap.appendChild(title); wrap.appendChild(code); wrap.appendChild(note); wrap.appendChild(copy);
    box.appendChild(wrap);
    document.getElementById("c_name").value = "";
    await refresh();
  } catch (err) { showMsg("c_msg", err.message); }
});

document.getElementById("d_add").addEventListener("click", async function () {
  showMsg("d_msg", "");
  try {
    await api("POST", "/api/devices", {
      name: document.getElementById("d_name").value,
      ip_address: document.getElementById("d_ip").value,
      port: document.getElementById("d_port").value,
      comm_key: document.getElementById("d_key").value,
      connector_id: document.getElementById("d_conn").value
    });
    document.getElementById("d_name").value = "";
    document.getElementById("d_ip").value = "";
    await refresh();
  } catch (err) { showMsg("d_msg", err.message); }
});

document.getElementById("x_from").value = isoLocal(-2);
document.getElementById("x_to").value = isoLocal(-1);
document.getElementById("x_go").addEventListener("click", function () {
  var from = document.getElementById("x_from").value;
  var to = document.getElementById("x_to").value;
  if (!from || !to) { showMsg("x_msg", "Choose both dates."); return; }
  if (to < from) { showMsg("x_msg", "'to' must be on or after 'from'."); return; }
  showMsg("x_msg", "");
  location.href = "/api/export.xlsx?from=" + encodeURIComponent(from) + "&to=" + encodeURIComponent(to);
});

document.getElementById("logout").addEventListener("click", async function () {
  await fetch("/api/auth/logout", { method: "POST", headers: { "content-type": "application/json" }, body: "{}" });
  location.href = "/login";
});

refresh();
setInterval(function () { loadJobs(); loadReports(); }, 15000);
</script>`);
}
'@

# ---------------------------------------------------------------- worker/src/index.ts
Write-File "worker/src/index.ts" @'
import type { Env } from "./env";
import { HttpError, html, json, redirect } from "./lib/http";
import { getAuth } from "./lib/auth";
import { health } from "./routes/health";
import { login, logout, me, signup } from "./routes/auth";
import {
  createConnector, createDevice, deactivateDevice, listConnectors,
  listDevices, listSyncJobs, queueSync, revokeConnector,
} from "./routes/manage";
import { claimJob, completeJob, connectorConfig, uploadLogs } from "./routes/connector";
import { downloadReport, exportRange, listReports } from "./routes/reports";
import { runScheduler } from "./scheduler";
import { appPage, loginPage, signupPage } from "./pages";

export type { Env };

const ID = "([0-9a-f-]{36})";
const R_CONNECTOR_REVOKE = new RegExp(`^/api/connectors/${ID}/revoke$`);
const R_DEVICE_DEACTIVATE = new RegExp(`^/api/devices/${ID}/deactivate$`);
const R_DEVICE_SYNC = new RegExp(`^/api/devices/${ID}/sync$`);
const R_JOB_LOGS = new RegExp(`^/api/connector/jobs/${ID}/logs$`);
const R_JOB_COMPLETE = new RegExp(`^/api/connector/jobs/${ID}/complete$`);
const R_REPORT_DOWNLOAD = new RegExp(`^/api/reports/${ID}/download$`);

async function route(request: Request, env: Env): Promise<Response> {
  const { pathname } = new URL(request.url);
  const method = request.method;
  let m: RegExpExecArray | null;

  // ---- Public / auth
  if (pathname === "/api/health" && method === "GET") return health(env);
  if (pathname === "/api/auth/signup" && method === "POST") return signup(request, env);
  if (pathname === "/api/auth/login" && method === "POST") return login(request, env);
  if (pathname === "/api/auth/logout" && method === "POST") return logout(request, env);
  if (pathname === "/api/auth/me" && method === "GET") return me(request, env);

  // ---- Dashboard API (browser session)
  if (pathname === "/api/connectors" && method === "GET") return listConnectors(request, env);
  if (pathname === "/api/connectors" && method === "POST") return createConnector(request, env);
  if (method === "POST" && (m = R_CONNECTOR_REVOKE.exec(pathname))) return revokeConnector(request, env, m[1]);
  if (pathname === "/api/devices" && method === "GET") return listDevices(request, env);
  if (pathname === "/api/devices" && method === "POST") return createDevice(request, env);
  if (method === "POST" && (m = R_DEVICE_DEACTIVATE.exec(pathname))) return deactivateDevice(request, env, m[1]);
  if (method === "POST" && (m = R_DEVICE_SYNC.exec(pathname))) return queueSync(request, env, m[1]);
  if (pathname === "/api/sync-jobs" && method === "GET") return listSyncJobs(request, env);
  if (pathname === "/api/reports" && method === "GET") return listReports(request, env);
  if (method === "GET" && (m = R_REPORT_DOWNLOAD.exec(pathname))) return downloadReport(request, env, m[1]);
  if (pathname === "/api/export.xlsx" && method === "GET") return exportRange(request, env);

  // ---- ZKT Connector API (Bearer token)
  if (pathname === "/api/connector/config" && method === "GET") return connectorConfig(request, env);
  if (pathname === "/api/connector/jobs/claim" && method === "POST") return claimJob(request, env);
  if (method === "POST" && (m = R_JOB_LOGS.exec(pathname))) return uploadLogs(request, env, m[1]);
  if (method === "POST" && (m = R_JOB_COMPLETE.exec(pathname))) return completeJob(request, env, m[1]);

  if (pathname.startsWith("/api/")) return json({ error: "Not found" }, 404);

  // ---- Pages
  if (method === "GET") {
    if (pathname === "/") {
      return redirect((await getAuth(request, env)) ? "/app" : "/login");
    }
    if (pathname === "/login") {
      return (await getAuth(request, env)) ? redirect("/app") : html(loginPage());
    }
    if (pathname === "/signup") {
      return (await getAuth(request, env)) ? redirect("/app") : html(signupPage(Boolean(env.SIGNUP_CODE)));
    }
    if (pathname === "/app") {
      const auth = await getAuth(request, env);
      return auth ? html(appPage(auth)) : redirect("/login");
    }
  }

  return json({ error: "Not found" }, 404);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await route(request, env);
    } catch (err) {
      if (err instanceof HttpError) return json({ error: err.message }, err.status);
      console.error(err);
      return json({ error: "Internal server error" }, 500);
    }
  },

  // Cloudflare cron (see [triggers] in wrangler.toml): runs every hour.
  async scheduled(controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(runScheduler(env, new Date(controller.scheduledTime)));
  },
};
'@

# ---------------------------------------------------------------- connector/package.json
Write-File "connector/package.json" @'
{
  "name": "zkt-connector",
  "version": "0.6.0",
  "private": true,
  "type": "module",
  "scripts": {
    "start": "node src/index.js",
    "api-test": "node src/api-test.js",
    "read-device": "node src/read-device.js",
    "mock-device": "node test/mock-device.js",
    "test": "node --test test/zk.test.js test/sync.test.js"
  },
  "dependencies": {
    "dotenv": "^16.4.5"
  }
}
'@

# ---------------------------------------------------------------- connector/src/api.js
Write-File "connector/src/api.js" @'
// HTTP client for the Attendance Fetcher Worker (connector side).
export const CONNECTOR_VERSION = "0.6.0";

export class ApiClient {
  constructor(baseUrl, token) {
    this.baseUrl = baseUrl.replace(/\/+$/, "");
    this.token = token;
  }

  async request(method, path, body) {
    const res = await fetch(this.baseUrl + path, {
      method,
      headers: {
        authorization: `Bearer ${this.token}`,
        "content-type": "application/json",
        "x-connector-version": CONNECTOR_VERSION,
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });

    const text = await res.text();
    let data;
    try {
      data = text ? JSON.parse(text) : {};
    } catch {
      data = { error: text.slice(0, 200) };
    }

    if (!res.ok) {
      const err = new Error(`${method} ${path} -> ${res.status}: ${data.error ?? "request failed"}`);
      err.status = res.status;
      throw err;
    }
    return data;
  }

  getConfig() {
    return this.request("GET", "/api/connector/config");
  }

  claimJob() {
    return this.request("POST", "/api/connector/jobs/claim", {});
  }

  /** records: [{ user_id, timestamp: "YYYY-MM-DD HH:MM:SS", state, verify_mode }] (max 1000 per call) */
  uploadLogs(jobId, records) {
    return this.request("POST", `/api/connector/jobs/${encodeURIComponent(jobId)}/logs`, { records });
  }

  /** payload: { status: "success" | "failed", error_message?, device_serial? } */
  completeJob(jobId, payload) {
    return this.request("POST", `/api/connector/jobs/${encodeURIComponent(jobId)}/complete`, payload);
  }
}

export function clientFromEnv() {
  const base = process.env.API_BASE_URL;
  const token = process.env.CONNECTOR_TOKEN;
  if (!base) throw new Error("API_BASE_URL is not set in .env");
  if (!token || !token.startsWith("zkc_")) {
    throw new Error("CONNECTOR_TOKEN is not set in .env (create a connector in the dashboard and paste its token)");
  }
  return new ApiClient(base, token);
}
'@

# ---------------------------------------------------------------- connector/src/index.js
Write-File "connector/src/index.js" @'
// ZKT Connector main loop.
//   npm start                 -> runs continuously: picks up sync jobs and imports attendance
//   npm start -- --once       -> processes at most one pending job, then exits
import "dotenv/config";
import { CONNECTOR_VERSION, clientFromEnv } from "./api.js";
import { processJob } from "./sync.js";
import { log } from "./log.js";

const once = process.argv.includes("--once");
const pollSeconds = Math.min(Math.max(Number(process.env.POLL_INTERVAL_SECONDS) || 60, 15), 3600);
const timeoutMs = Number(process.env.DEVICE_TIMEOUT_MS) || 10000;

let stopping = false;
process.on("SIGINT", () => {
  if (stopping) process.exit(1);
  stopping = true;
  log.info("Stopping after the current step (press Ctrl+C again to force)...");
});
process.on("SIGTERM", () => { stopping = true; });

async function sleepUnlessStopping(seconds) {
  for (let i = 0; i < seconds && !stopping; i++) await new Promise((r) => setTimeout(r, 1000));
}

async function main() {
  log.info(`ZKT Connector ${CONNECTOR_VERSION} starting${once ? " (single run)" : ""}`);
  const api = clientFromEnv();

  // At Windows start-up the network may not be ready yet: keep trying (except for a bad token).
  let config;
  for (;;) {
    try {
      config = await api.getConfig();
      break;
    } catch (err) {
      if (err.status === 401 || once) throw err;
      log.warn(`Server not reachable yet (${err.message}). Retrying in 30 s`);
      await sleepUnlessStopping(30);
      if (stopping) return;
    }
  }
  log.info(`Connected to ${api.baseUrl} as connector "${config.connector.name}"`);
  if (!config.devices.length) log.warn("No devices assigned to this connector yet (add one in the dashboard).");
  for (const d of config.devices) log.info(`Device "${d.name}" at ${d.ip_address}:${d.port}`);
  if (!once) log.info(`Checking for sync jobs every ${pollSeconds} s. Press Ctrl+C to stop.`);

  while (!stopping) {
    try {
      const { job } = await api.claimJob();
      if (job) {
        await processJob(api, job, { timeoutMs });
        if (once) break;
        continue; // another job may be waiting (e.g. several devices)
      }
      if (once) {
        log.info("No pending sync job. Click 'Sync now' in the dashboard, then run again.");
        break;
      }
    } catch (err) {
      if (err.status === 401) {
        log.error(`${err.message}. Create a new connector token in the dashboard and update .env.`);
        process.exitCode = 1;
        return;
      }
      log.error(`Could not reach the server: ${err.message}`);
      if (once) { process.exitCode = 1; return; }
    }
    await sleepUnlessStopping(pollSeconds);
  }
  log.info("Connector stopped.");
}

main().catch((err) => {
  log.error(err.message);
  process.exitCode = 1;
});
'@

# ---------------------------------------------------------------- connector/scripts/install-autostart.ps1
Write-File "connector/scripts/install-autostart.ps1" @'
# =====================================================================
# ZKT Connector - start automatically with Windows (no login needed).
# Creates a Windows Scheduled Task "ZKT Connector" that runs as SYSTEM at
# start-up and restarts the connector if it ever stops.
#
# Run in PowerShell opened with "Run as administrator", from the connector folder:
#   powershell -ExecutionPolicy Bypass -File .\scripts\install-autostart.ps1
# =====================================================================
$ErrorActionPreference = "Stop"
$TaskName = "ZKT Connector"

$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Please open PowerShell with 'Run as administrator' and run this again."
}

$dir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if (-not (Test-Path (Join-Path $dir ".env")))         { throw ".env not found in $dir - create it first (see .env.example)." }
if (-not (Test-Path (Join-Path $dir "node_modules"))) { throw "Run 'npm install' in $dir first." }
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { throw "Node.js was not found in PATH." }

$logs    = Join-Path $dir "logs"
$logFile = Join-Path $logs "connector.log"
$script  = Join-Path $dir "src\index.js"
$cmdPath = Join-Path $dir "run-connector.cmd"
New-Item -ItemType Directory -Force -Path $logs | Out-Null

# Stop an older copy started by this task, if any.
Get-CimInstance Win32_Process |
    Where-Object { $_.CommandLine -and ($_.CommandLine -like "*$script*" -or $_.CommandLine -like "*$cmdPath*") } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# Wrapper: runs the connector, appends output to logs\connector.log,
# keeps the log under ~5 MB, and restarts after 60 s if node exits.
$cmd = @"
@echo off
rem Generated by scripts\install-autostart.ps1 - do not edit, run the installer again instead.
cd /d "$dir"
:loop
for %%F in ("$logFile") do if %%~zF GTR 5000000 move /y "$logFile" "$logFile.old" >nul
echo ===== %date% %time% starting connector >> "$logFile"
"$node" "$script" >> "$logFile" 2>&1
ping -n 61 127.0.0.1 >nul
goto loop
"@
# cmd.exe needs Windows (CRLF) line endings for labels/goto to work.
[System.IO.File]::WriteAllText($cmdPath, ($cmd -replace "`r?`n", "`r`n"), [System.Text.Encoding]::ASCII)

$action    = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$cmdPath`"" -WorkingDirectory $dir
$trigger   = New-ScheduledTaskTrigger -AtStartup
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
               -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
               -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description "Imports attendance from the ZKTeco machine into HR Attendance Fetcher ($dir)" -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Host "Scheduled task '$TaskName' installed and started." -ForegroundColor Green
Write-Host "Waiting 10 seconds for the first log lines..."
Start-Sleep -Seconds 10
if (Test-Path $logFile) { Get-Content $logFile -Tail 12 } else { Write-Host "No log yet: $logFile" -ForegroundColor Yellow }
Write-Host ""
Write-Host "Log file : $logFile"
Write-Host "Status   : Get-ScheduledTask '$TaskName' | Get-ScheduledTaskInfo"
Write-Host "Remove   : powershell -ExecutionPolicy Bypass -File .\scripts\uninstall-autostart.ps1"
'@

# ---------------------------------------------------------------- connector/scripts/uninstall-autostart.ps1
Write-File "connector/scripts/uninstall-autostart.ps1" @'
# Removes the "ZKT Connector" start-up task and stops the running connector.
# Run in PowerShell opened with "Run as administrator", from the connector folder:
#   powershell -ExecutionPolicy Bypass -File .\scripts\uninstall-autostart.ps1
$ErrorActionPreference = "Stop"
$TaskName = "ZKT Connector"
$dir     = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script  = Join-Path $dir "src\index.js"
$cmdPath = Join-Path $dir "run-connector.cmd"

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Scheduled task '$TaskName' removed." -ForegroundColor Green
} else {
    Write-Host "Scheduled task '$TaskName' was not installed."
}

Get-CimInstance Win32_Process |
    Where-Object { $_.CommandLine -and ($_.CommandLine -like "*$script*" -or $_.CommandLine -like "*$cmdPath*") } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host "Stopped process $($_.ProcessId)" }

if (Test-Path $cmdPath) { Remove-Item $cmdPath -Force }
Write-Host "Done. Logs are kept in $(Join-Path $dir 'logs')."
'@

Write-Host ""
Write-Host "Phase 6 files written. Next steps are listed in the chat." -ForegroundColor Cyan
