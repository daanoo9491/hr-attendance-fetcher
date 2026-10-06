-- =============================================================
-- Phase 7 - employee names
-- employees.full_name = name shown in reports ('' = not known yet).
-- It follows the machine's name until someone edits it in the
-- dashboard (name_edited = 1); after that the machine never overwrites it.
-- =============================================================
ALTER TABLE employees ADD COLUMN machine_name TEXT;
ALTER TABLE employees ADD COLUMN name_edited INTEGER NOT NULL DEFAULT 0;
ALTER TABLE employees ADD COLUMN updated_at TEXT;