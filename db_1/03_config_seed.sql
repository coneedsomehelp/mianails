-- ============================================================
-- Salon Timekeeper — 03_config_seed.sql
-- Bucket 5.1: policy constants + shops + roster template.
-- Run THIRD. Edit the marked sections before running.
-- ============================================================

-- ---------- policy constants (every value = a decision from the design phase) ----------
insert into config (key, value) values
  ('full_day_min',          '570'),                                   -- 9h30 incl. 30min break
  ('pto_rate_per_month',    '2.5'),                                   -- French congés payés standard
  ('poster_ttl_seconds',    '60'),                                    -- QR rotation
  ('poster_grace_seconds',  '30'),
  ('session_ttl_seconds',   '300'),                                   -- 5-minute punch window after scan
  ('auto_close',            '{"at": "midnight_paris", "credit_minutes": 0}'),
  ('flags',                 '{"missing_out": true, "missing_in": true, "no_show": true,
                              "double_in": false, "long_session": false,
                              "long_session_min": 720,
                              "same_device_multi_identity": true, "device_changed": true}'),
  ('roster_warn_fraction',  '0.3334'),                                -- amber when > 1/3 off same day
  ('timezone',              '"Europe/Paris"');

-- ---------- shops — EDIT the names to the salons' real names ----------
insert into shops (id, name) values
  (1, 'Tiệm 1'),
  (2, 'Tiệm 2');

-- ---------- employees — TEMPLATE ----------
-- Register the real 17 here. login_code = last 6 digits of each person's
-- phone. pto_opening = current balance from the accountant's records.
-- Uncomment and fill in:
--
-- insert into employees (name, login_code, pto_opening) values
--   ('Chị Hoa',  '123456', 4.5),
--   ('Chị Lan',  '234567', 2.0),
--   ('Anh Minh', '345678', 0.0);
--
-- If two people share a phone number (family members), give one of them
-- a different memorable 6-digit code and note it in their record.

-- ---------- managers — run AFTER creating auth users (see runbook step 4) ----------
-- Replace the UUIDs with the ones shown in Authentication → Users:
--
-- insert into managers (user_id, name, role, shop_id) values
--   ('<uuid-from-auth-users>', 'Your name',        'owner',   null),  -- null shop = all shops
--   ('<uuid-from-auth-users>', 'Manager, Salon 1', 'manager', 1),
--   ('<uuid-from-auth-users>', 'Manager, Salon 2', 'manager', 2);

-- ---------- verification (run after everything above) ----------
-- A. Data landed:
-- select count(*) from config;    -- expect 9
-- select * from shops;            -- expect your 2 shops with kiosk_key values
-- select count(*) from employees; -- expect your roster size
--
-- B. RLS is enabled:
-- select relname, relrowsecurity from pg_class
--   where relname in ('punches','corrections','leave','employees');  -- all true
--
-- C. RLS actually filters. NOTE: the SQL Editor runs as an admin role
--    that BYPASSES RLS, so impersonate the anon role in a transaction:
-- begin;
-- set local role anon;
-- select count(*) from employees;  -- expect 0, even though rows exist
-- rollback;
--
-- D. Append-only holds. INSERTS ARE ALLOWED (that is how punches get
--    recorded) — it's UPDATE and DELETE that MUST FAIL:
-- insert into punches (employee_id, shop_id, type)
--   select id, 1, 'in' from employees limit 1;   -- succeeds (expected)
-- update punches set type = 'out';               -- MUST FAIL: append-only
-- delete from punches;                           -- MUST FAIL: append-only
--
-- E. Clean up the test punch from D. The admin role can bypass the
--    trigger — deliberate: append-only protects against app bugs and
--    tampering through the app, not against the database owner:
-- alter table punches disable trigger punches_immutable;
-- delete from punches;
-- alter table punches enable trigger punches_immutable;
