-- =============================================================
-- Phase 14 - manual attendance edits, and repair of names that
-- migration 0007 copied between machines.
-- =============================================================

-- A manager's correction for one person on one day. The machine punches
-- are never changed; the report uses these times instead of the first/last punch.
-- time_in / time_out: 'HH:MM', or NULL = blank in the report.
CREATE TABLE attendance_edits (
  id              TEXT PRIMARY KEY,
  company_id      TEXT NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  device_id       TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  device_user_id  TEXT NOT NULL,
  work_date       TEXT NOT NULL,
  time_in         TEXT,
  time_out        TEXT,
  note            TEXT,
  edited_by       TEXT NOT NULL,
  edited_at       TEXT NOT NULL,
  UNIQUE (device_id, device_user_id, work_date)
);
CREATE INDEX idx_edits_company_date ON attendance_edits(company_id, work_date);

-- Repair 1: a name typed in the dashboard that 0007 copied to the same user ID on
-- another machine. We can't tell which machine's person it was meant for, so these
-- go back to the machine's own name; type it again on the right machine.
UPDATE employees
   SET full_name = COALESCE(machine_name, ''), name_edited = 0,
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
 WHERE id IN (
   SELECT e.id FROM employees e
     JOIN employees o ON o.company_id = e.company_id AND o.device_user_id = e.device_user_id
                     AND o.device_id <> e.device_id
    WHERE e.name_edited = 1 AND o.name_edited = 1 AND o.full_name = e.full_name
 );

-- Repair 2: machine names that 0007 copied to the same user ID on another machine
-- (identical name and timestamp). Cleared here; each machine's next sync puts back
-- the name that machine really has.
UPDATE employees
   SET full_name = '', machine_name = NULL
 WHERE id IN (
   SELECT e.id FROM employees e
     JOIN employees o ON o.company_id = e.company_id AND o.device_user_id = e.device_user_id
                     AND o.device_id <> e.device_id
    WHERE e.name_edited = 0 AND o.name_edited = 0
      AND COALESCE(o.machine_name, '') = COALESCE(e.machine_name, '')
      AND COALESCE(o.updated_at, '') = COALESCE(e.updated_at, '')
 );