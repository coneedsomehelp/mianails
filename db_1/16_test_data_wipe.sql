-- ============================================================
-- Salon Timekeeper — 16_test_data_wipe.sql
-- GO-LIVE RESET. Deletes ALL transactional test data.
--
-- KEEPS:   shops, employees, managers, config, holidays
--          and every function, trigger, policy, cron job.
-- DELETES: punches, corrections, sessions, leave, notif_log
--
-- ⚠ RUN ONCE, THE NIGHT BEFORE GO-LIVE. NOT REVERSIBLE.
-- ⚠ AFTER RUNNING: (1) set each employee's opening PTO balance
--   from the accountant (Nhân viên tab → Dư đầu), and
--   (2) re-assign this week's day-offs in Nghỉ phép — the wipe
--   removes roster assignments too (they live in `leave`).
-- ============================================================

-- punches & corrections are protected by immutability triggers;
-- lift them for the wipe, restore immediately after.
alter table corrections disable trigger all;
alter table punches     disable trigger all;

delete from corrections;
delete from punches;
delete from sessions;
delete from leave;
delete from notif_log;

alter table punches     enable trigger all;
alter table corrections enable trigger all;

-- ---------- verify: transactional tables empty, people intact ----------
select 'punches' t, count(*) n from punches
union all select 'corrections', count(*) from corrections
union all select 'sessions',    count(*) from sessions
union all select 'leave',       count(*) from leave
union all select 'notif_log',   count(*) from notif_log
union all select 'employees (kept)', count(*) from employees
union all select 'managers (kept)',  count(*) from managers
union all select 'shops (kept)',     count(*) from shops
union all select 'holidays (kept)',  count(*) from holidays;
-- expect: first five = 0; the kept rows unchanged.
