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