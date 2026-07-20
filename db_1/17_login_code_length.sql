-- ============================================================
-- Salon Timekeeper — 17_login_code_length.sql
-- Login codes: allow 2-6 digits (was: exactly 6).
-- Rationale: staff found 6 digits slow to type; short codes are
-- valid because punching is secured by the physical rotating QR
-- + single-use session, not by code secrecy. Reverting to longer
-- codes later = just issue new codes; no schema change needed.
-- Applied to production: 2026-07-19 (codes migrated 0000XX -> XX).
-- Idempotent: safe to re-run.
-- ============================================================
alter table employees drop constraint if exists employees_login_code_check;
alter table employees add constraint employees_login_code_check
  check (login_code ~ '^[0-9]{2,6}$');

-- one-time migration (no-op once applied)
update employees set login_code = right(login_code, 2)
 where login_code ~ '^0000[0-9]{2}$';
