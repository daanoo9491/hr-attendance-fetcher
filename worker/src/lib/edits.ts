// Manual attendance corrections (Attendance Edit page). The machine's punches are never
// changed: an edit replaces the Time In / Time Out of one person on one day in reports.
import type { Env } from "../env";

export const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;

export interface Edit {
  device_id: string;
  device_user_id: string;
  work_date: string;
  time_in: string | null;   // 'HH:MM', or null = blank
  time_out: string | null;
  note: string | null;
  edited_by: string;
  edited_at: string;
}

export const editKey = (deviceId: string, userId: string, date: string) => `${deviceId}|${userId}|${date}`;

/** All edits of a company for dates from..to (inclusive). */
export async function loadEdits(env: Env, companyId: string, from: string, to: string): Promise<Map<string, Edit>> {
  const { results } = await env.DB.prepare(
    `SELECT device_id, device_user_id, work_date, time_in, time_out, note, edited_by, edited_at
       FROM attendance_edits
      WHERE company_id = ? AND work_date >= ? AND work_date <= ?`,
  ).bind(companyId, from, to).all<Edit>();
  const map = new Map<string, Edit>();
  for (const e of results ?? []) map.set(editKey(e.device_id, e.device_user_id, e.work_date), e);
  return map;
}