-- =============================================================
-- Phase 13 - employee IDs belong to a machine, and machine groups
--
-- Before: one employee per (company, user ID). Two machines that both
-- had "ID 2" shared one row, so the last machine's name overwrote the other.
-- Now:    one employee per (company, machine, user ID).
--
-- Machines can be put in a group (e.g. two machines at the same office
-- where staff are enrolled with the same IDs). Inside a group, the same
-- user ID on any of its machines is the same person, and reports show the
-- group as one sheet.
-- =============================================================

CREATE TABLE machine_groups (
  id          TEXT PRIMARY KEY,
  company_id  TEXT NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  UNIQUE (company_id, name)
);

ALTER TABLE devices ADD COLUMN group_id TEXT REFERENCES machine_groups(id) ON DELETE SET NULL;
CREATE INDEX idx_devices_group ON devices(group_id);

CREATE TABLE employees_new (
  id              TEXT PRIMARY KEY,
  company_id      TEXT NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  device_id       TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  device_user_id  TEXT NOT NULL,
  full_name       TEXT NOT NULL,
  department      TEXT,
  is_active       INTEGER NOT NULL DEFAULT 1,
  created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  machine_name    TEXT,
  name_edited     INTEGER NOT NULL DEFAULT 0,
  updated_at      TEXT,
  UNIQUE (company_id, device_id, device_user_id)
);

-- 1) Everyone who has punches: one copy on each machine they punched on.
--    Names that came from a machine are refreshed per machine on the next sync.
INSERT INTO employees_new (id, company_id, device_id, device_user_id, full_name, department,
                           is_active, created_at, machine_name, name_edited, updated_at)
SELECT lower(hex(randomblob(16))), e.company_id, x.device_id, e.device_user_id, e.full_name, e.department,
       e.is_active, e.created_at, e.machine_name, e.name_edited, e.updated_at
  FROM employees e
  JOIN (SELECT DISTINCT company_id, device_id, device_user_id FROM attendance_logs) x
    ON x.company_id = e.company_id AND x.device_user_id = e.device_user_id;

-- 2) No punches yet, company has exactly one machine: it belongs to that machine.
INSERT OR IGNORE INTO employees_new (id, company_id, device_id, device_user_id, full_name, department,
                                     is_active, created_at, machine_name, name_edited, updated_at)
SELECT lower(hex(randomblob(16))), e.company_id, d.id, e.device_user_id, e.full_name, e.department,
       e.is_active, e.created_at, e.machine_name, e.name_edited, e.updated_at
  FROM employees e
  JOIN devices d ON d.company_id = e.company_id
 WHERE NOT EXISTS (SELECT 1 FROM attendance_logs l WHERE l.company_id = e.company_id AND l.device_user_id = e.device_user_id)
   AND (SELECT COUNT(*) FROM devices d2 WHERE d2.company_id = e.company_id) = 1;

-- (No punches and several machines: we can't tell which machine they are on.
--  The next sync reads each machine's user list and adds them to the right one.)

DROP TABLE employees;
ALTER TABLE employees_new RENAME TO employees;
CREATE INDEX idx_employees_device ON employees(device_id, device_user_id);