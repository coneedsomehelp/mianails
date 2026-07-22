-- ============================================================
-- Salon Timekeeper — 00_full_rebuild.sql
-- Generated 2026-07-11 from db_1/ files: 01, 02, 03, 04, 07, 08, 10, 11, 12, 13, 14, 15
--
-- WHAT THIS IS
--   The single, canonical, ALWAYS-SAFE-TO-RE-RUN definition of the
--   entire database logic layer: tables, security policies (RLS),
--   functions, triggers, cron schedules, default settings, holidays.
--   Run order is baked in — the old "11 must run after 08" rule and
--   every duplicate-object error are handled internally.
--
-- WHAT THIS IS *NOT*
--   Not a backup. It never restores punches, leave, employees or
--   managers data. It never DELETES anything, and it never
--   OVERWRITES existing config values (it only adds missing
--   defaults) — your Telegram token and live settings are safe.
--
-- WHEN TO RUN
--   • Any doubt ("did I miss a file?" / a partial run errored out)
--   • Setting up a fresh Supabase project (disaster recovery) —
--     then restore data separately from a backup, and re-add
--     config values telegram_bot_token, telegram_chat_ids, site_url
--   • After folding in any future SQL change (rule: every new
--     numbered file 17+ must ALSO be appended here)
--
-- The SQL editor still stops at the first error. If it errors:
-- read the message, send it to Claude, do not re-run blindly.
-- ============================================================

-- ╔══════════════════ 01_schema.sql ══════════════════╗
-- ============================================================
-- Salon Timekeeper — 01_schema.sql
-- Bucket 5.1: tables, constraints, indexes, immutability.
-- Run FIRST in the Supabase SQL Editor.
-- ============================================================

create extension if not exists pgcrypto;

-- ---------- policy constants live in data, not code ----------
create table if not exists config (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

-- ---------- locations ----------
create table if not exists shops (
  id         smallint primary key,
  name       text not null,
  -- secret embedded in each door tablet's kiosk URL; rotating it kills a stolen tablet's access
  kiosk_key  uuid not null default gen_random_uuid(),
  created_at timestamptz not null default now()
);

-- ---------- shared roster across all shops ----------
create table if not exists employees (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  -- last 6 digits of the employee's phone number; identifier, not a secret
  login_code      text not null unique check (login_code ~ '^[0-9]{6}$'),
  pto_opening     numeric(6,2) not null default 0,
  pto_start_month date not null default (date_trunc('month', now() at time zone 'Europe/Paris'))::date,
  active          boolean not null default true,   -- deactivate leavers; NEVER delete (history must survive)
  created_at      timestamptz not null default now()
);

-- ---------- device fingerprint registry ----------
create table if not exists devices (
  device_uuid uuid primary key,
  first_seen  timestamptz not null default now(),
  last_seen   timestamptz not null default now()
);

-- ---------- token layer 1: shared, time-rotated poster QR (one per shop) ----------
create table if not exists poster_tokens (
  shop_id    smallint primary key references shops(id),
  code       text not null,
  expires_at timestamptz not null
);

-- ---------- token layer 2: single-use per-scan sessions ----------
create table if not exists sessions (
  id          uuid primary key default gen_random_uuid(),
  shop_id     smallint not null references shops(id),
  device_uuid uuid not null,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  used_at     timestamptz,                    -- set exactly once at punch redemption
  employee_id uuid references employees(id)   -- set at redemption
);
create index if not exists sessions_expiry on sessions (expires_at);

-- ---------- the ledger: immutable punch events ----------
create table if not exists punches (
  id          uuid primary key default gen_random_uuid(),
  employee_id uuid not null references employees(id),
  shop_id     smallint not null references shops(id),
  type        text not null check (type in ('in','out')),
  ts          timestamptz not null default now(),   -- SERVER-assigned; clients never supply times
  session_id  uuid references sessions(id),
  device_uuid uuid,
  ip          inet,
  created_at  timestamptz not null default now()
);
create index if not exists punches_emp_ts on punches (employee_id, ts);
create index if not exists punches_ts     on punches (ts);

-- ---------- append-only corrections layered on the ledger ----------
create table if not exists corrections (
  id            uuid primary key default gen_random_uuid(),
  kind          text not null check (kind in ('edit','void','add-in','add-out','ack')),
  punch_id      uuid references punches(id),        -- target punch (null for no-show acks)
  employee_id   uuid not null references employees(id),
  old_ts        timestamptz,
  new_ts        timestamptz,
  synthetic_ref text,                               -- e.g. 'noshow-<employee_id>-<YYYY-MM-DD>'
  note          text,
  manager_id    uuid not null references auth.users(id),  -- NAMED attribution, per owner decision
  created_at    timestamptz not null default now()
);
create index if not exists corrections_emp on corrections (employee_id);

-- ---------- leave: weekly day-offs + PTO requests ----------
create table if not exists leave (
  id           uuid primary key default gen_random_uuid(),
  type         text not null check (type in ('dayoff','pto')),
  employee_id  uuid not null references employees(id),
  date         date,                               -- dayoff only
  start_date   date,                               -- pto only
  end_date     date,
  half         text check (half in ('am','pm')),   -- null = full day(s)
  days         numeric(4,1),                       -- 0.5 for half-days
  note         text,
  status       text not null default 'approved'
               check (status in ('pending','approved','rejected','cancelled')),
  requested_at timestamptz not null default now(),
  decided_by   uuid references auth.users(id),
  decided_at   timestamptz,
  created_by   text not null default 'employee' check (created_by in ('employee','manager')),
  constraint leave_shape check (
    (type = 'dayoff' and date is not null)
    or
    (type = 'pto' and start_date is not null and end_date is not null
       and end_date >= start_date and days is not null)
  )
);
create index if not exists leave_emp on leave (employee_id);

-- ---------- manager identity (linked to Supabase Auth) ----------
create table if not exists managers (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  name       text not null,
  shop_id    smallint references shops(id),  -- null = owner (all shops); per-store scoping activates at scale
  role       text not null default 'manager' check (role in ('owner','manager')),
  created_at timestamptz not null default now()
);

-- ============================================================
-- Immutability: punches and corrections are APPEND-ONLY.
-- Any attempt to update or delete a row fails loudly.
-- ============================================================
create or replace function forbid_change() returns trigger
language plpgsql as $$
begin
  raise exception 'This table is append-only: rows are never edited or deleted. Add a correction instead.';
end $$;

drop trigger if exists punches_immutable on punches;
create trigger punches_immutable
  before update or delete on punches
  for each row execute function forbid_change();

drop trigger if exists corrections_immutable on corrections;
create trigger corrections_immutable
  before update or delete on corrections
  for each row execute function forbid_change();

-- ╔══════════════════ 02_security.sql ══════════════════╗
-- ============================================================
-- Salon Timekeeper — 02_security.sql
-- Bucket 5.1: row-level security. Run SECOND.
--
-- Model:
--   · Employees are ANONYMOUS clients. They get ZERO direct table
--     access; every employee action goes through server-side RPC
--     functions (Bucket 5.2) that validate tokens and login codes.
--     RLS enabled + no anon policy = deny by default.
--   · Managers sign in via Supabase Auth. A row in `managers`
--     is what grants access — an authenticated stranger with no
--     managers row sees nothing.
-- ============================================================

-- helper: is the current authenticated user a registered manager?
create or replace function is_manager() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from managers where user_id = auth.uid());
$$;

-- ---------- enable RLS everywhere ----------
alter table config        enable row level security;
alter table shops         enable row level security;
alter table employees     enable row level security;
alter table devices       enable row level security;
alter table poster_tokens enable row level security;
alter table sessions      enable row level security;
alter table punches       enable row level security;
alter table corrections   enable row level security;
alter table leave         enable row level security;
alter table managers      enable row level security;

-- ---------- manager read access ----------
drop policy if exists mgr_read_config on config;
create policy mgr_read_config on config        for select to authenticated using (is_manager());
drop policy if exists mgr_read_shops on shops;
create policy mgr_read_shops on shops         for select to authenticated using (is_manager());
drop policy if exists mgr_read_employees on employees;
create policy mgr_read_employees on employees     for select to authenticated using (is_manager());
drop policy if exists mgr_read_devices on devices;
create policy mgr_read_devices on devices       for select to authenticated using (is_manager());
drop policy if exists mgr_read_sessions on sessions;
create policy mgr_read_sessions on sessions      for select to authenticated using (is_manager());
drop policy if exists mgr_read_punches on punches;
create policy mgr_read_punches on punches       for select to authenticated using (is_manager());
drop policy if exists mgr_read_corrections on corrections;
create policy mgr_read_corrections on corrections   for select to authenticated using (is_manager());
drop policy if exists mgr_read_leave on leave;
create policy mgr_read_leave on leave         for select to authenticated using (is_manager());
drop policy if exists mgr_read_managers on managers;
create policy mgr_read_managers on managers      for select to authenticated using (is_manager());

-- ---------- manager write access ----------
-- roster management
drop policy if exists mgr_ins_employees on employees;
create policy mgr_ins_employees on employees for insert to authenticated
  with check (is_manager());
drop policy if exists mgr_upd_employees on employees;
create policy mgr_upd_employees on employees for update to authenticated
  using (is_manager()) with check (is_manager());

-- corrections: append-only, and attribution must be YOURSELF
drop policy if exists mgr_ins_corrections on corrections;
create policy mgr_ins_corrections on corrections for insert to authenticated
  with check (is_manager() and manager_id = auth.uid());

-- leave: managers can create day-off assignments and manager-entered leave...
drop policy if exists mgr_ins_leave on leave;
create policy mgr_ins_leave on leave for insert to authenticated
  with check (is_manager() and created_by = 'manager');
-- ...decide pending requests (decision must be attributed to yourself)...
drop policy if exists mgr_upd_leave on leave;
create policy mgr_upd_leave on leave for update to authenticated
  using (is_manager())
  with check (is_manager() and (decided_by is null or decided_by = auth.uid()));
-- ...and remove day-off assignments (the roster toggle). PTO records are never deleted.
drop policy if exists mgr_del_dayoff on leave;
create policy mgr_del_dayoff on leave for delete to authenticated
  using (is_manager() and type = 'dayoff');

-- config: only the owner changes policy constants
drop policy if exists owner_upd_config on config;
create policy owner_upd_config on config for update to authenticated
  using (exists (select 1 from managers where user_id = auth.uid() and role = 'owner'))
  with check (exists (select 1 from managers where user_id = auth.uid() and role = 'owner'));

-- NOTE deliberately absent:
--   · no anon policies at all (employee RPCs in 5.2 are SECURITY DEFINER)
--   · no update/delete policies on punches or corrections
--     (blocked twice: no policy AND the append-only triggers)
--   · no insert policy on punches for managers — even managers add time
--     via corrections, never by minting raw punches; keeps the ledger honest

-- ╔══════════════════ 03_config_seed.sql ══════════════════╗
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
  ('timezone',              '"Europe/Paris"')
on conflict (key) do nothing;

-- ---------- shops — EDIT the names to the salons' real names ----------
insert into shops (id, name) values
  (1, 'Tiệm 1'),
  (2, 'Tiệm 2')
on conflict (id) do nothing;

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

-- ╔══════════════════ 04_functions.sql ══════════════════╗
-- ============================================================
-- Salon Timekeeper — 04_functions.sql
-- Bucket 5.2: server-side functions. Run FOURTH.
--
-- Design: anonymous clients (employee phones, door tablets) can
-- execute ONLY these functions. Each validates its own inputs,
-- runs with elevated rights (SECURITY DEFINER), and returns the
-- minimum needed. Timestamps are always server-assigned.
-- ============================================================

-- ---------- helpers ----------
create or replace function paris_date(p timestamptz) returns date
language sql immutable as $$
  select (p at time zone 'Europe/Paris')::date
$$;

create or replace function cfg_int(p_key text) returns int
language sql stable security definer set search_path = public as $$
  select (value #>> '{}')::int from config where key = p_key
$$;

-- client IP as seen by the API gateway (best-effort)
create or replace function req_ip() returns inet
language plpgsql stable as $$
declare v text;
begin
  v := split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1);
  return nullif(trim(v), '')::inet;
exception when others then
  return null;
end $$;

-- ============================================================
-- 1) KIOSK: rotate the poster code (door tablet calls this ~60s)
--    Authenticated by the shop's secret kiosk_key from its URL.
-- ============================================================
create or replace function kiosk_rotate(p_shop_id smallint, p_kiosk_key uuid)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_ttl int; v_grace int; v_code text;
begin
  if not exists (select 1 from shops where id = p_shop_id and kiosk_key = p_kiosk_key) then
    raise exception 'invalid kiosk credentials';
  end if;
  v_ttl := cfg_int('poster_ttl_seconds');
  v_grace := cfg_int('poster_grace_seconds');
  -- 6 chars from an unambiguous alphabet (no I, L, O, 0, 1)
  select string_agg(substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789', 1 + floor(random()*31)::int, 1), '')
    into v_code from generate_series(1, 6);
  insert into poster_tokens (shop_id, code, expires_at)
  values (p_shop_id, v_code, now() + make_interval(secs => v_ttl + v_grace))
  on conflict (shop_id) do update set code = excluded.code, expires_at = excluded.expires_at;
  return json_build_object('code', v_code, 'ttl', v_ttl);
end $$;

-- ============================================================
-- 2) SCAN: validate the poster code, register the device,
--    mint a single-use session (the employee's 5-minute window)
-- ============================================================
create or replace function scan_start(p_shop_id smallint, p_code text, p_device_uuid uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v_sid uuid;
begin
  if not exists (
    select 1 from poster_tokens
    where shop_id = p_shop_id and code = upper(trim(p_code)) and expires_at > now()
  ) then
    return json_build_object('ok', false, 'error', 'code_invalid');
  end if;
  insert into devices (device_uuid) values (p_device_uuid)
    on conflict (device_uuid) do update set last_seen = now();
  insert into sessions (shop_id, device_uuid, expires_at)
  values (p_shop_id, p_device_uuid, now() + make_interval(secs => cfg_int('session_ttl_seconds')))
  returning id into v_sid;
  return json_build_object('ok', true, 'session_id', v_sid);
end $$;

-- ---------- shared: resolve a live session + employee, or explain why not ----------
create or replace function _resolve(p_session_id uuid, p_login_code text,
                                    out o_err text, out o_emp employees, out o_shop smallint)
language plpgsql security definer set search_path = public as $$
declare v_sess sessions;
begin
  select * into v_sess from sessions where id = p_session_id;
  if v_sess.id is null or v_sess.expires_at < now() then o_err := 'session_expired'; return; end if;
  if v_sess.used_at is not null then o_err := 'session_used'; return; end if;
  select * into o_emp from employees where login_code = p_login_code and active;
  if o_emp.id is null then o_err := 'employee_not_found'; return; end if;
  o_shop := v_sess.shop_id;
  o_err := null;
end $$;

-- ---------- shared: today's state for one employee, corrections applied ----------
create or replace function _today_state(p_emp uuid)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_today date := paris_date(now());
  v_in int; v_out int; v_mins numeric; v_prior_open boolean;
begin
  -- today's punch counts, voided punches excluded
  select
    count(*) filter (where p.type = 'in'),
    count(*) filter (where p.type = 'out')
  into v_in, v_out
  from punches p
  where p.employee_id = p_emp and paris_date(p.ts) = v_today
    and not exists (select 1 from corrections c where c.kind = 'void' and c.punch_id = p.id);

  -- unresolved open 'in' from a previous day (the missing-out banner)
  select exists (
    select 1 from punches pi
    where pi.employee_id = p_emp and pi.type = 'in' and paris_date(pi.ts) < v_today
      and not exists (select 1 from corrections c where c.kind = 'void' and c.punch_id = pi.id)
      and not exists (select 1 from corrections c where c.kind = 'add-out' and c.punch_id = pi.id)
      and not exists (
        select 1 from punches po
        where po.employee_id = p_emp and po.type = 'out' and po.ts > pi.ts
          and not exists (select 1 from corrections c2 where c2.kind = 'void' and c2.punch_id = po.id)
      )
  ) into v_prior_open;

  -- minutes today: pair today's punches in order (voids excluded, edits applied)
  with eff as (
    select p.id, p.type, coalesce(ce.new_ts, p.ts) as ts
    from punches p
    left join lateral (
      select new_ts from corrections c
      where c.kind = 'edit' and c.punch_id = p.id
      order by c.created_at desc limit 1
    ) ce on true
    where p.employee_id = p_emp
      and not exists (select 1 from corrections c where c.kind = 'void' and c.punch_id = p.id)
  ), today_eff as (
    select *, row_number() over (order by ts) rn from eff where paris_date(ts) = v_today
  )
  select coalesce(sum(
    extract(epoch from coalesce(o.ts, now()) - i.ts) / 60.0
  ), 0)
  into v_mins
  from today_eff i
  left join lateral (
    select ts from today_eff o where o.type = 'out' and o.rn > i.rn
      and not exists (select 1 from today_eff x where x.type = 'in' and x.rn > i.rn and x.rn < o.rn)
    order by o.rn limit 1
  ) o on true
  where i.type = 'in'
    and not exists (  -- skip 'in' rows already consumed by an earlier pairing
      select 1 from today_eff prev
      where prev.type = 'in' and prev.rn < i.rn
        and not exists (select 1 from today_eff po where po.type = 'out' and po.rn > prev.rn and po.rn < i.rn)
    );

  return json_build_object(
    'checked_in',      v_in > v_out,
    'minutes_today',   round(v_mins),
    'full_day',        v_mins >= cfg_int('full_day_min'),
    'prior_open_flag', v_prior_open,
    'next_dayoff', (select min(l.date) from leave l
                    where l.type = 'dayoff' and l.employee_id = p_emp and l.date >= v_today)
  );
end $$;

-- ============================================================
-- 3) WHOAMI: after typing the 6 digits — who is this, and their
--    live status for the punch screen. Does NOT consume the session.
-- ============================================================
create or replace function whoami(p_session_id uuid, p_login_code text)
returns json language plpgsql security definer set search_path = public as $$
declare r record;
begin
  select * into r from _resolve(p_session_id, p_login_code);
  if r.o_err is not null then return json_build_object('ok', false, 'error', r.o_err); end if;
  return json_build_object('ok', true, 'name', (r.o_emp).name, 'state', _today_state((r.o_emp).id));
end $$;

-- ============================================================
-- 4) PUNCH: redeem the session (atomically, exactly once),
--    record the punch with SERVER time, device, and IP.
--    The server decides in/out from current state.
-- ============================================================
create or replace function punch(p_session_id uuid, p_login_code text)
returns json language plpgsql security definer set search_path = public as $$
declare
  r record; v_state json; v_type text; v_dev uuid;
begin
  select * into r from _resolve(p_session_id, p_login_code);
  if r.o_err is not null then return json_build_object('ok', false, 'error', r.o_err); end if;

  -- single-use redemption: the conditional UPDATE is the atomic lock —
  -- of two simultaneous punches on one session, exactly one row-updates
  update sessions set used_at = now(), employee_id = (r.o_emp).id
  where id = p_session_id and used_at is null
  returning device_uuid into v_dev;
  if v_dev is null then return json_build_object('ok', false, 'error', 'session_used'); end if;

  v_state := _today_state((r.o_emp).id);
  v_type := case when (v_state ->> 'checked_in')::boolean then 'out' else 'in' end;

  insert into punches (employee_id, shop_id, type, session_id, device_uuid, ip)
  values ((r.o_emp).id, r.o_shop, v_type, p_session_id, v_dev, req_ip());

  return json_build_object('ok', true, 'name', (r.o_emp).name, 'type', v_type,
                           'ts', now(), 'state', _today_state((r.o_emp).id));
end $$;

-- ============================================================
-- 5) LEAVE: no door code needed (requesting from home is fine);
--    gated by the login code alone, per the accepted identity model.
-- ============================================================
create or replace function leave_get(p_login_code text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_emp employees; v_today date := paris_date(now());
  v_months int; v_accrued numeric; v_used numeric;
begin
  select * into v_emp from employees where login_code = p_login_code and active;
  if v_emp.id is null then return json_build_object('ok', false, 'error', 'employee_not_found'); end if;

  v_months := greatest(1,
    (extract(year from v_today)::int - extract(year from v_emp.pto_start_month)::int) * 12
    + (extract(month from v_today)::int - extract(month from v_emp.pto_start_month)::int) + 1);
  v_accrued := (select (value #>> '{}')::numeric from config where key = 'pto_rate_per_month') * v_months;
  select coalesce(sum(days), 0) into v_used
    from leave where type = 'pto' and employee_id = v_emp.id and status = 'approved';

  return json_build_object('ok', true, 'name', v_emp.name,
    'balance', v_emp.pto_opening + v_accrued - v_used,
    'upcoming_dayoffs', (select coalesce(json_agg(l.date order by l.date), '[]'::json)
        from leave l where l.type = 'dayoff' and l.employee_id = v_emp.id
          and l.date between v_today and v_today + 30),
    'approved', (select coalesce(json_agg(json_build_object(
          'start', l.start_date, 'end', l.end_date, 'half', l.half, 'days', l.days) order by l.start_date), '[]'::json)
        from leave l where l.type = 'pto' and l.employee_id = v_emp.id
          and l.status = 'approved' and l.end_date >= v_today),
    'pending', (select coalesce(json_agg(json_build_object(
          'id', l.id, 'start', l.start_date, 'end', l.end_date, 'half', l.half, 'days', l.days) order by l.start_date), '[]'::json)
        from leave l where l.type = 'pto' and l.employee_id = v_emp.id and l.status = 'pending'));
end $$;

create or replace function leave_request(p_login_code text, p_start date, p_end date,
                                         p_half text, p_note text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_emp employees; v_today date := paris_date(now());
  v_end date := coalesce(p_end, p_start); v_days numeric;
begin
  select * into v_emp from employees where login_code = p_login_code and active;
  if v_emp.id is null then return json_build_object('ok', false, 'error', 'employee_not_found'); end if;
  if p_start is null or p_start < v_today then return json_build_object('ok', false, 'error', 'past_date'); end if;
  if v_end < p_start then return json_build_object('ok', false, 'error', 'end_before_start'); end if;
  if p_half is not null and (p_half not in ('am','pm') or v_end <> p_start) then
    return json_build_object('ok', false, 'error', 'half_single_day_only');
  end if;
  -- overlap check; the opposite half of the same single day may coexist
  if exists (
    select 1 from leave l
    where l.type = 'pto' and l.employee_id = v_emp.id and l.status in ('pending','approved')
      and not (l.end_date < p_start or l.start_date > v_end)
      and not (p_start = v_end and l.start_date = p_start and l.end_date = v_end
               and l.half is not null and p_half is not null and l.half <> p_half)
  ) then
    return json_build_object('ok', false, 'error', 'overlap');
  end if;
  v_days := case when p_half is not null then 0.5 else (v_end - p_start + 1) end;
  insert into leave (type, employee_id, start_date, end_date, half, days, note, status, created_by)
  values ('pto', v_emp.id, p_start, v_end, p_half, v_days, nullif(trim(p_note), ''), 'pending', 'employee');
  return json_build_object('ok', true, 'days', v_days);
end $$;

create or replace function leave_cancel(p_login_code text, p_leave_id uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v_emp uuid;
begin
  select id into v_emp from employees where login_code = p_login_code and active;
  if v_emp is null then return json_build_object('ok', false, 'error', 'employee_not_found'); end if;
  update leave set status = 'cancelled', decided_at = now()
  where id = p_leave_id and employee_id = v_emp and status = 'pending';
  if not found then return json_build_object('ok', false, 'error', 'not_cancellable'); end if;
  return json_build_object('ok', true);
end $$;

-- ============================================================
-- Grants: anonymous clients may execute ONLY these entry points.
-- The internal helpers are locked down.
-- ============================================================
revoke all on function kiosk_rotate(smallint, uuid)                    from public;
revoke all on function scan_start(smallint, text, uuid)                from public;
revoke all on function whoami(uuid, text)                              from public;
revoke all on function punch(uuid, text)                               from public;
revoke all on function leave_get(text)                                 from public;
revoke all on function leave_request(text, date, date, text, text)     from public;
revoke all on function leave_cancel(text, uuid)                        from public;
revoke all on function _resolve(uuid, text)                            from public;
revoke all on function _today_state(uuid)                              from public;

grant execute on function kiosk_rotate(smallint, uuid)                 to anon, authenticated;
grant execute on function scan_start(smallint, text, uuid)             to anon, authenticated;
grant execute on function whoami(uuid, text)                           to anon, authenticated;
grant execute on function punch(uuid, text)                            to anon, authenticated;
grant execute on function leave_get(text)                              to anon, authenticated;
grant execute on function leave_request(text, date, date, text, text)  to anon, authenticated;
grant execute on function leave_cancel(text, uuid)                     to anon, authenticated;

-- ╔══════════════════ 07_correction_guards.sql ══════════════════╗
-- ============================================================
-- Salon Timekeeper — 07_correction_guards.sql
-- Correction integrity, enforced by the DATABASE so it holds
-- against any client, not just the UI. Run in the SQL Editor.
--
-- Owner decision: managers may set times freely, INCLUDING the
-- future (soft-confirmed in the UI). The hard rules are:
--   · a correction must target a real punch of the same employee
--   · add-out must be AFTER the check-in it closes
--   · add-in  must be BEFORE the check-out it opens
-- ============================================================

create or replace function validate_correction() returns trigger
language plpgsql as $$
declare v_punch punches;
begin
  if new.kind in ('edit','void','add-out','add-in') then
    if new.punch_id is null then
      raise exception 'This correction kind must target a punch';
    end if;
    select * into v_punch from punches where id = new.punch_id;
    if v_punch.id is null then
      raise exception 'Correction targets a punch that does not exist';
    end if;
    if v_punch.employee_id <> new.employee_id then
      raise exception 'Correction employee does not match the punch employee';
    end if;
    if new.kind = 'add-out' and (new.new_ts is null or new.new_ts <= v_punch.ts) then
      raise exception 'Check-out time must be after the check-in it closes';
    end if;
    if new.kind = 'add-in' and (new.new_ts is null or new.new_ts >= v_punch.ts) then
      raise exception 'Check-in time must be before the check-out it opens';
    end if;
    if new.kind = 'edit' and new.new_ts is null then
      raise exception 'Edit requires a new time';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists corrections_validate on corrections;
drop trigger if exists corrections_validate on corrections;
create trigger corrections_validate
  before insert on corrections
  for each row execute function validate_correction();

-- verification (both must FAIL):
-- insert a correction with a random punch_id      → 'does not exist'
-- add-out with new_ts earlier than the punch's ts → 'must be after'

-- ╔══════════════════ 08_notifications_RERUN.sql ══════════════════╗
-- ============================================================
-- Salon Timekeeper — 08_notifications_RERUN.sql
-- Safe clean re-run. The credential section is REMOVED on
-- purpose — your telegram_bot_token and telegram_chat_ids are
-- already in the config table and must not be overwritten.
-- Everything here is idempotent: run the whole file at once.
-- ============================================================

-- ---------- 1. extensions (no-ops if already enabled) ----------
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- ---------- 2. send log (THE TABLE THAT WAS MISSING) ----------
create table if not exists notif_log (
  id      bigint generated always as identity primary key,
  kind    text not null,
  ref     text not null,
  sent_at timestamptz not null default now(),
  unique (kind, ref)
);
alter table notif_log enable row level security;

-- managers may read it (harmless if already present)
drop policy if exists mgr_read_notif on notif_log;
create policy mgr_read_notif on notif_log
  for select to authenticated using (is_manager());

-- ---------- 3. sender ----------
create or replace function tg_send(p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare v_token text; v_chat text;
begin
  select value #>> '{}' into v_token from config where key = 'telegram_bot_token';
  if v_token is null or v_token = 'PASTE_ME_BOT_TOKEN' then return; end if;
  for v_chat in
    select jsonb_array_elements_text(value) from config where key = 'telegram_chat_ids'
  loop
    perform net.http_post(
      url     := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
      body    := jsonb_build_object('chat_id', v_chat, 'text', p_text),
      headers := '{"Content-Type":"application/json"}'::jsonb
    );
  end loop;
end $$;

-- ---------- 4. new pending leave → alert (runs every 5 min) ----------
create or replace function notify_pending_leave() returns void
language plpgsql security definer set search_path = public as $$
declare r record; v_msg text;
begin
  for r in
    select l.id, l.start_date, l.end_date, l.days, l.half, l.note, e.name
    from leave l join employees e on e.id = l.employee_id
    where l.type = 'pto' and l.status = 'pending'
      and not exists (select 1 from notif_log n where n.kind = 'leave' and n.ref = l.id::text)
    order by l.requested_at
  loop
    v_msg := '🌴 Đơn xin nghỉ mới: ' || r.name || ' — '
          || to_char(r.start_date, 'DD/MM') || ' → ' || to_char(r.end_date, 'DD/MM')
          || ' (' || r.days || ' ngày'
          || case when r.half = 'am' then ', buổi sáng'
                  when r.half = 'pm' then ', buổi chiều' else '' end
          || ')'
          || coalesce(E'\nLý do: ' || nullif(trim(r.note), ''), '')
          || E'\n→ Duyệt trong trang Quản lý → Nghỉ phép.';
    perform tg_send(v_msg);
    insert into notif_log (kind, ref) values ('leave', r.id::text)
      on conflict do nothing;
  end loop;
end $$;

-- ---------- 5. morning digest: yesterday's forgotten punches ----------
create or replace function notify_morning_digest() returns void
language plpgsql security definer set search_path = public as $$
declare
  v_y date := paris_date(now()) - 1;
  v_lines text := ''; v_pend int; r record;
begin
  if exists (select 1 from notif_log where kind = 'digest' and ref = v_y::text) then
    return;
  end if;

  for r in
    select e.name, pi.ts
    from punches pi join employees e on e.id = pi.employee_id
    where pi.type = 'in' and paris_date(pi.ts) = v_y and e.active
      and not exists (select 1 from corrections c where c.kind = 'void'    and c.punch_id = pi.id)
      and not exists (select 1 from corrections c where c.kind = 'add-out' and c.punch_id = pi.id)
      and not exists (
        select 1 from punches po
        where po.employee_id = pi.employee_id and po.type = 'out' and po.ts > pi.ts
          and not exists (select 1 from corrections c2 where c2.kind = 'void' and c2.punch_id = po.id))
  loop
    v_lines := v_lines || E'\n• ' || r.name || ' — quên chấm RA (vào lúc '
            || to_char(r.ts at time zone 'Europe/Paris', 'HH24:MI') || ')';
  end loop;

  for r in
    select e.name, po.ts
    from punches po join employees e on e.id = po.employee_id
    where po.type = 'out' and paris_date(po.ts) = v_y and e.active
      and not exists (select 1 from corrections c where c.kind = 'void'   and c.punch_id = po.id)
      and not exists (select 1 from corrections c where c.kind = 'add-in' and c.punch_id = po.id)
      and not exists (
        select 1 from punches pi
        where pi.employee_id = po.employee_id and pi.type = 'in'
          and paris_date(pi.ts) = v_y and pi.ts < po.ts
          and not exists (select 1 from corrections c2 where c2.kind = 'void' and c2.punch_id = pi.id))
  loop
    v_lines := v_lines || E'\n• ' || r.name || ' — quên chấm VÀO (ra lúc '
            || to_char(r.ts at time zone 'Europe/Paris', 'HH24:MI') || ')';
  end loop;

  select count(*) into v_pend from leave where type = 'pto' and status = 'pending';

  if v_lines <> '' or v_pend > 0 then
    perform tg_send(
      '☀️ Tổng kết ngày ' || to_char(v_y, 'DD/MM') || ':'
      || case when v_lines <> '' then v_lines
              else E'\n• Không có cảnh báo chấm công 🎉' end
      || case when v_pend > 0 then E'\n🌴 Còn ' || v_pend || ' đơn nghỉ phép chờ duyệt' else '' end
      || E'\n→ Xử lý trong trang Quản lý.');
  end if;

  insert into notif_log (kind, ref) values ('digest', v_y::text)
    on conflict do nothing;
end $$;

-- ---------- 6. schedules (unschedule-then-schedule = safe re-run) ----------
do $$ begin perform cron.unschedule('notify-pending-leave'); exception when others then null; end $$;
do $$ begin perform cron.unschedule('morning-digest');       exception when others then null; end $$;
select cron.schedule('notify-pending-leave', '*/5 * * * *', $$select notify_pending_leave()$$);
select cron.schedule('morning-digest',       '15 7 * * *',  $$select notify_morning_digest()$$);

-- ---------- 7. verify ----------
-- select count(*) from notif_log;        -- a number, NOT an error = table exists
-- select notify_pending_leave();         -- your pending PTO should hit Telegram now
-- select jobname, schedule from cron.job; -- expect the 2 jobs

-- ╔══════════════════ 10_my_summary.sql ══════════════════╗
-- ============================================================
-- Salon Timekeeper — 10_my_summary.sql
-- UI-B: employee self-service dashboard. One read-only RPC:
-- an employee's OWN month hours + today, by login code —
-- the same identity model already accepted for leave_get.
-- Corrections-aware: voids excluded, edits applied, manager
-- add-out fixes counted (so the app agrees with payroll).
-- ============================================================

create or replace function my_summary(p_login_code text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_emp employees;
  v_t date := paris_date(now());
  v_m date := date_trunc('month', v_t)::date;
  v_month json;
begin
  select * into v_emp from employees where login_code = p_login_code and active;
  if v_emp.id is null then
    return json_build_object('ok', false, 'error', 'employee_not_found');
  end if;

  with eff as (
    select p.id, p.type, coalesce(ce.new_ts, p.ts) as ts
    from punches p
    left join lateral (
      select new_ts from corrections c
      where c.kind = 'edit' and c.punch_id = p.id
      order by c.created_at desc limit 1
    ) ce on true
    where p.employee_id = v_emp.id
      and not exists (select 1 from corrections c where c.kind = 'void' and c.punch_id = p.id)
  ), month_eff as (
    select *, row_number() over (order by ts) rn
    from eff where paris_date(ts) >= v_m and paris_date(ts) <= v_t
  ), pairs as (
    select paris_date(i.ts) as d,
      extract(epoch from
        coalesce(
          o.ts,                                            -- matched check-out
          ao.new_ts,                                       -- manager add-out fix
          case when paris_date(i.ts) = v_t then now()      -- today, still in
               else i.ts end                               -- unresolved: 0 until fixed
        ) - i.ts) / 60.0 as mins
    from month_eff i
    left join lateral (
      select ts from month_eff o
      where o.type = 'out' and o.rn > i.rn
        and not exists (select 1 from month_eff x where x.type = 'in' and x.rn > i.rn and x.rn < o.rn)
      order by o.rn limit 1
    ) o on true
    left join lateral (
      select new_ts from corrections c
      where c.kind = 'add-out' and c.punch_id = i.id
      order by c.created_at desc limit 1
    ) ao on true
    where i.type = 'in'
      and not exists (
        select 1 from month_eff prev
        where prev.type = 'in' and prev.rn < i.rn
          and not exists (select 1 from month_eff po where po.type = 'out' and po.rn > prev.rn and po.rn < i.rn)
      )
  ), daily as (
    select d, sum(mins) as m from pairs group by d
  )
  select json_build_object(
    'total_min',  coalesce(round(sum(m)), 0),
    'days',       count(*) filter (where m > 0),
    'full_days',  count(*) filter (where m >= cfg_int('full_day_min'))
  ) into v_month from daily;

  return json_build_object(
    'ok', true,
    'name', v_emp.name,
    'month', coalesce(v_month, json_build_object('total_min',0,'days',0,'full_days',0)),
    'today', _today_state(v_emp.id)
  );
end $$;

revoke all on function my_summary(text) from public;
grant execute on function my_summary(text) to anon, authenticated;

-- verification:
-- select my_summary('<a real login code>');
--   → ok:true with month totals matching the admin's month view
-- select my_summary('999999');
--   → {"ok":false,"error":"employee_not_found"}

-- ╔══════════════════ 11_manager_conveniences.sql ══════════════════╗
-- ============================================================
-- Salon Timekeeper — 11_manager_conveniences.sql
-- (1) Kiosk key rotation from the admin UI (managers only)
-- (2) Telegram messages gain a button that opens the admin
--     directly on the right tab (?open=leave)
-- Run AFTER 08 and 09. Requires site_url set in config (09).
-- ============================================================

-- ---------- 1. rotate a shop's kiosk key (kills a lost tablet) ----------
create or replace function rotate_kiosk_key(p_shop_id smallint)
returns json language plpgsql security definer set search_path = public as $$
declare v_new uuid;
begin
  if not is_manager() then
    raise exception 'managers only';
  end if;
  update shops set kiosk_key = gen_random_uuid()
  where id = p_shop_id
  returning kiosk_key into v_new;
  if v_new is null then
    return json_build_object('ok', false, 'error', 'shop_not_found');
  end if;
  return json_build_object('ok', true, 'kiosk_key', v_new);
end $$;

revoke all on function rotate_kiosk_key(smallint) from public;
grant execute on function rotate_kiosk_key(smallint) to authenticated;

-- ---------- 2. tg_send with an optional URL button ----------
-- (drop the old single-arg version first to avoid an ambiguous overload)
drop function if exists tg_send(text);

create or replace function tg_send(p_text text, p_btn_label text default null, p_btn_url text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_token text; v_chat text; v_body jsonb;
begin
  select value #>> '{}' into v_token from config where key = 'telegram_bot_token';
  if v_token is null or v_token = 'PASTE_ME_BOT_TOKEN' then return; end if;
  for v_chat in
    select jsonb_array_elements_text(value) from config where key = 'telegram_chat_ids'
  loop
    v_body := jsonb_build_object('chat_id', v_chat, 'text', p_text);
    if p_btn_label is not null and p_btn_url is not null and p_btn_url not like '%YOUR-%' then
      v_body := v_body || jsonb_build_object('reply_markup', jsonb_build_object(
        'inline_keyboard', jsonb_build_array(jsonb_build_array(
          jsonb_build_object('text', p_btn_label, 'url', p_btn_url)))));
    end if;
    perform net.http_post(
      url     := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
      body    := v_body,
      headers := '{"Content-Type":"application/json"}'::jsonb
    );
  end loop;
end $$;

-- ---------- 3. notifications now carry the button ----------
create or replace function notify_pending_leave() returns void
language plpgsql security definer set search_path = public as $$
declare r record; v_msg text; v_url text;
begin
  select value #>> '{}' into v_url from config where key = 'site_url';
  for r in
    select l.id, l.start_date, l.end_date, l.days, l.half, l.note, e.name
    from leave l join employees e on e.id = l.employee_id
    where l.type = 'pto' and l.status = 'pending'
      and not exists (select 1 from notif_log n where n.kind = 'leave' and n.ref = l.id::text)
    order by l.requested_at
  loop
    v_msg := '🌴 Đơn xin nghỉ mới: ' || r.name || ' — '
          || to_char(r.start_date, 'DD/MM') || ' → ' || to_char(r.end_date, 'DD/MM')
          || ' (' || r.days || ' ngày'
          || case when r.half = 'am' then ', buổi sáng'
                  when r.half = 'pm' then ', buổi chiều' else '' end
          || ')'
          || coalesce(E'\nLý do: ' || nullif(trim(r.note), ''), '');
    perform tg_send(v_msg, 'Duyệt ngay · Approuver', v_url || '?open=leave');
    insert into notif_log (kind, ref) values ('leave', r.id::text)
      on conflict do nothing;
  end loop;
end $$;

-- morning digest: same body as 09, button added
create or replace function notify_morning_digest() returns void
language plpgsql security definer set search_path = public as $$
declare
  v_t   date := paris_date(now());
  v_m   date := date_trunc('month', v_t)::date;
  v_url text; v_dow text; v_off text := ''; v_pend text := '';
  r record; v_msg text;
begin
  if exists (select 1 from notif_log where kind = 'digest' and ref = v_t::text) then
    return;
  end if;
  select value #>> '{}' into v_url from config where key = 'site_url';
  v_dow := case extract(dow from v_t)::int
    when 0 then 'Chủ Nhật' when 1 then 'Thứ Hai' when 2 then 'Thứ Ba'
    when 3 then 'Thứ Tư'  when 4 then 'Thứ Năm' when 5 then 'Thứ Sáu'
    else 'Thứ Bảy' end;

  for r in
    select * from (
      select e.name, 'weekly' as k, null::text as half
      from leave l join employees e on e.id = l.employee_id
      where l.type = 'dayoff' and l.date = v_t and e.active
      union all
      select e.name, 'pto', l.half
      from leave l join employees e on e.id = l.employee_id
      where l.type = 'pto' and l.status = 'approved'
        and l.start_date <= v_t and l.end_date >= v_t and e.active
    ) q order by name
  loop
    v_off := v_off || E'\n• ' || r.name || ' → '
          || case when r.k = 'weekly' then 'Nghỉ tuần'
                  else 'Nghỉ phép'
                    || case when r.half = 'am' then ' (nửa ngày — sáng)'
                            when r.half = 'pm' then ' (nửa ngày — chiều)'
                            else '' end
             end;
  end loop;
  if v_off = '' then v_off := E'\n• Không ai nghỉ — đủ đội hình 💪'; end if;

  for r in
    select * from (
      select e.name, 1 as ord, paris_date(pi.ts) as d1, null::date as d2, 'mout' as k
      from punches pi join employees e on e.id = pi.employee_id
      where pi.type = 'in' and paris_date(pi.ts) >= v_m and paris_date(pi.ts) < v_t and e.active
        and not exists (select 1 from corrections c where c.kind = 'void'    and c.punch_id = pi.id)
        and not exists (select 1 from corrections c where c.kind = 'add-out' and c.punch_id = pi.id)
        and not exists (
          select 1 from punches po
          where po.employee_id = pi.employee_id and po.type = 'out' and po.ts > pi.ts
            and not exists (select 1 from corrections c2 where c2.kind = 'void' and c2.punch_id = po.id))
      union all
      select e.name, 1, paris_date(po.ts), null, 'min'
      from punches po join employees e on e.id = po.employee_id
      where po.type = 'out' and paris_date(po.ts) >= v_m and paris_date(po.ts) < v_t and e.active
        and not exists (select 1 from corrections c where c.kind = 'void'   and c.punch_id = po.id)
        and not exists (select 1 from corrections c where c.kind = 'add-in' and c.punch_id = po.id)
        and not exists (
          select 1 from punches pi
          where pi.employee_id = po.employee_id and pi.type = 'in'
            and paris_date(pi.ts) = paris_date(po.ts) and pi.ts < po.ts
            and not exists (select 1 from corrections c2 where c2.kind = 'void' and c2.punch_id = pi.id))
      union all
      select e.name, 2, l.start_date, l.end_date, 'pto'
      from leave l join employees e on e.id = l.employee_id
      where l.type = 'pto' and l.status = 'pending'
    ) q order by ord, d1
  loop
    v_pend := v_pend || E'\n• ' || r.name || ' → '
           || case r.k
                when 'mout' then 'Quên chấm RA ('  || to_char(r.d1, 'DD/MM') || ')'
                when 'min'  then 'Quên chấm VÀO (' || to_char(r.d1, 'DD/MM') || ')'
                else 'Đơn xin nghỉ (' || to_char(r.d1, 'DD/MM') || ' → ' || to_char(r.d2, 'DD/MM') || ')'
              end;
  end loop;
  if v_pend = '' then v_pend := E'\n• Không có gì chờ xử lý 🎉'; end if;

  v_msg := '☀️ Báo cáo ngày (' || v_dow || ', ' || to_char(v_t, 'DD/MM') || ')'
        || E'\n\nHôm nay nghỉ:'          || v_off
        || E'\n\nChờ xử lý (tháng này):' || v_pend;
  perform tg_send(v_msg, 'Mở trang quản lý · Ouvrir', v_url || '?open=today');
  insert into notif_log (kind, ref) values ('digest', v_t::text)
    on conflict do nothing;
end $$;

-- ---------- verification ----------
-- select tg_send('✅ Test nút bấm', 'Mở trang quản lý', (select value #>> '{}' from config where key='site_url') || '?open=leave');
--   → message arrives WITH a button; tapping it opens the admin on Nghỉ phép.
-- select rotate_kiosk_key(1::smallint);   -- run signed in? SQL editor is admin:
--   NOTE: from the SQL editor is_manager() is false → 'managers only' error is the
--   expected PASS there. Test the button in the admin UI instead.

-- ╔══════════════════ 12_notification_health.sql ══════════════════╗
-- ============================================================
-- Salon Timekeeper — 12_notification_health.sql
-- Managers can verify Telegram delivery from the admin UI
-- (Hệ thống tab) instead of trusting silence. Run AFTER 11.
-- ============================================================

-- managers may read the send log
drop policy if exists mgr_read_notif on notif_log;
create policy mgr_read_notif on notif_log
  for select to authenticated using (is_manager());

-- last delivery attempts, with Telegram's actual answers.
-- NOTE: pg_net auto-deletes its response log after a few hours,
-- so this shows RECENT health, which is exactly what a check needs.
create or replace function tg_health(p_limit int default 10)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_manager() then raise exception 'managers only'; end if;
  return coalesce((
    select json_agg(row_to_json(t)) from (
      select id, status_code, timed_out, error_msg,
             left(coalesce(content::text, ''), 160) as content_snippet,
             created
      from net._http_response
      order by id desc
      limit greatest(1, least(p_limit, 50))
    ) t
  ), '[]'::json);
end $$;

revoke all on function tg_health(int) from public;
grant execute on function tg_health(int) to authenticated;

-- one-tap test message from the admin
create or replace function tg_test()
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_manager() then raise exception 'managers only'; end if;
  perform tg_send('✅ Tin nhắn thử từ trang Quản lý — hệ thống thông báo hoạt động ('
    || to_char(now() at time zone 'Europe/Paris', 'HH24:MI') || ' Paris).');
  return json_build_object('ok', true);
end $$;

revoke all on function tg_test() from public;
grant execute on function tg_test() to authenticated;

-- ============================================================
-- CHANGING THE DAILY REPORT TIME (the recipe, for the manual)
-- Cron runs in UTC. Paris is UTC+2 in summer, UTC+1 in winter.
--   9:00 Paris summer  → '0 7 * * *'
--   9:00 Paris winter  → '0 8 * * *'
-- Pick one; it drifts 1h across the DST change (harmless), or
-- re-run this twice a year for exact 9:00.
--
-- select cron.unschedule('morning-digest');
-- select cron.schedule('morning-digest', '0 7 * * *', $$select notify_morning_digest()$$);
--
-- Leave-alert frequency (default every 5 min) works the same way:
-- select cron.unschedule('notify-pending-leave');
-- select cron.schedule('notify-pending-leave', '*/10 * * * *', $$select notify_pending_leave()$$);
--
-- See what's scheduled right now:
-- select jobname, schedule from cron.job;
-- ============================================================

-- ╔══════════════════ 13_holidays.sql ══════════════════╗
-- ============================================================
-- Salon Timekeeper — 13_holidays.sql
-- French public holidays reference table. The month export
-- splits worked hours into normal / Sunday / holiday so the
-- accountant can apply differential rates. The app categorizes
-- HOURS only — pay computation stays with the accountant.
--
-- MAINTENANCE: seed the new year each January (Easter-linked
-- dates move). The owner's manual has the recipe.
-- ============================================================

create table if not exists holidays (
  date date primary key,
  name text not null
);

alter table holidays enable row level security;

drop policy if exists mgr_read_holidays on holidays;
create policy mgr_read_holidays on holidays
  for select to authenticated using (is_manager());

-- managers may maintain the list from SQL; no anon access at all.

-- ---------- seed: jours fériés 2026 ----------
insert into holidays (date, name) values
  ('2026-01-01', 'Jour de l''an'),
  ('2026-04-06', 'Lundi de Pâques'),
  ('2026-05-01', 'Fête du Travail'),          -- legally special: double pay if worked
  ('2026-05-08', 'Victoire 1945'),
  ('2026-05-14', 'Ascension'),
  ('2026-05-25', 'Lundi de Pentecôte'),
  ('2026-07-14', 'Fête nationale'),
  ('2026-08-15', 'Assomption'),
  ('2026-11-01', 'Toussaint'),
  ('2026-11-11', 'Armistice 1918'),
  ('2026-12-25', 'Noël')
on conflict (date) do nothing;

-- ---------- seed: jours fériés 2027 ----------
insert into holidays (date, name) values
  ('2027-01-01', 'Jour de l''an'),
  ('2027-03-29', 'Lundi de Pâques'),
  ('2027-05-01', 'Fête du Travail'),
  ('2027-05-06', 'Ascension'),
  ('2027-05-08', 'Victoire 1945'),
  ('2027-05-17', 'Lundi de Pentecôte'),
  ('2027-07-14', 'Fête nationale'),
  ('2027-08-15', 'Assomption'),
  ('2027-11-01', 'Toussaint'),
  ('2027-11-11', 'Armistice 1918'),
  ('2027-12-25', 'Noël')
on conflict (date) do nothing;

-- Salon-specific closed/special days can be added the same way:
-- insert into holidays (date, name) values ('2026-12-26', 'Lendemain de Noël (salon)') on conflict do nothing;

-- ---------- verify ----------
-- select * from holidays order by date;   -- expect 22 rows

-- ╔══════════════════ 14_leave_decisions.sql ══════════════════╗
-- ============================================================
-- Salon Timekeeper — 14_leave_decisions.sql
-- Employees see the outcome of their leave requests (approved
-- or rejected) on their own dashboard. Additive: a NEW function,
-- nothing existing is modified. Run any time after 04.
-- ============================================================

create or replace function leave_recent(p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare v_emp uuid;
begin
  select id into v_emp from employees
  where login_code = p_code and active;
  if v_emp is null then
    return '[]'::json;
  end if;

  return coalesce((
    select json_agg(row_to_json(t)) from (
      select start_date, end_date, days, half, status, decided_at
      from leave
      where type = 'pto'
        and employee_id = v_emp
        and status in ('approved', 'rejected')
        and decided_at >= now() - interval '45 days'
      order by decided_at desc
      limit 5
    ) t
  ), '[]'::json);
end $$;

revoke all on function leave_recent(text) from public;
grant execute on function leave_recent(text) to anon, authenticated;

-- ---------- verify ----------
-- select leave_recent('000001');
--   → JSON list of that employee's recent decisions (or [] if none)

-- ╔══════════════════ 15_leave_notes.sql ══════════════════╗
-- ============================================================
-- Salon Timekeeper — 15_leave_notes.sql
-- (1) PTO requests REQUIRE a reason (enforced server-side)
-- (2) Managers can attach a rejection note the employee reads
-- Run AFTER 14.
-- ============================================================

-- ---------- 1. rejection note column ----------
alter table leave add column if not exists decision_note text;

-- ---------- 2. server-side: reason is mandatory on new requests ----------
-- Applies only to employee-created pending PTO. Weekly dayoffs and
-- manager actions are untouched.
create or replace function enforce_pto_note() returns trigger
language plpgsql as $$
begin
  if new.type = 'pto' and new.status = 'pending'
     and (new.note is null or length(trim(new.note)) = 0) then
    raise exception 'note_required';
  end if;
  return new;
end $$;

drop trigger if exists trg_pto_note on leave;
drop trigger if exists trg_pto_note on leave;
create trigger trg_pto_note
  before insert on leave
  for each row execute function enforce_pto_note();

-- ---------- 3. leave_recent now returns the rejection note ----------
create or replace function leave_recent(p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare v_emp uuid;
begin
  select id into v_emp from employees
  where login_code = p_code and active;
  if v_emp is null then
    return '[]'::json;
  end if;

  return coalesce((
    select json_agg(row_to_json(t)) from (
      select start_date, end_date, days, half, status, decided_at, decision_note
      from leave
      where type = 'pto'
        and employee_id = v_emp
        and status in ('approved', 'rejected')
        and decided_at >= now() - interval '45 days'
      order by decided_at desc
      limit 5
    ) t
  ), '[]'::json);
end $$;

revoke all on function leave_recent(text) from public;
grant execute on function leave_recent(text) to anon, authenticated;

-- ---------- verify ----------
-- insert into leave (type, employee_id, status, start_date, end_date, days)
--   select 'pto', id, 'pending', current_date+7, current_date+7, 1 from employees limit 1;
--   → must FAIL with 'note_required'  (then it worked; nothing was inserted)
-- select leave_recent('000001');  → decisions now include decision_note

-- ╔══════════════════ final verification ══════════════════╗
select 'tables' k, count(*)::text v from information_schema.tables where table_schema='public'
union all select 'functions', count(*)::text from information_schema.routines where routine_schema='public'
union all select 'policies', count(*)::text from pg_policies where schemaname='public'
union all select 'cron jobs', count(*)::text from cron.job
union all select 'config keys', count(*)::text from config;
-- expect roughly: tables 13, functions 24+, policies 19+, cron 2, config 12

-- ╔══════════════════ 17_login_code_length.sql ══════════════════╗
alter table employees drop constraint if exists employees_login_code_check;
alter table employees add constraint employees_login_code_check
  check (login_code ~ '^[0-9]{2,6}$');
update employees set login_code = right(login_code, 2)
 where login_code ~ '^0000[0-9]{2}$';

-- ╔══════════════════ 18_session_day_boundary.sql ══════════════════╗
create or replace function my_summary(p_login_code text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_emp employees;
  v_t date := paris_date(now());
  v_m date := date_trunc('month', v_t)::date;
  v_month json;
begin
  select * into v_emp from employees where login_code = p_login_code and active;
  if v_emp.id is null then
    return json_build_object('ok', false, 'error', 'employee_not_found');
  end if;

  with eff as (
    select p.id, p.type, coalesce(ce.new_ts, p.ts) as ts
    from punches p
    left join lateral (
      select new_ts from corrections c
      where c.kind = 'edit' and c.punch_id = p.id
      order by c.created_at desc limit 1
    ) ce on true
    where p.employee_id = v_emp.id
      and not exists (select 1 from corrections c where c.kind = 'void' and c.punch_id = p.id)
  ), month_eff as (
    select *, row_number() over (order by ts) rn
    from eff where paris_date(ts) >= v_m and paris_date(ts) <= v_t
  ), pairs as (
    select paris_date(i.ts) as d,
      extract(epoch from
        coalesce(
          o.ts,                                            -- matched check-out
          ao.new_ts,                                       -- manager add-out fix
          case when paris_date(i.ts) = v_t then now()      -- today, still in
               else i.ts end                               -- unresolved: 0 until fixed
        ) - i.ts) / 60.0 as mins
    from month_eff i
    left join lateral (
      select ts from month_eff o
      where o.type = 'out' and o.rn > i.rn
        and paris_date(o.ts) = paris_date(i.ts)   -- SAME-DAY ONLY (the fix)
        and not exists (select 1 from month_eff x where x.type = 'in' and x.rn > i.rn and x.rn < o.rn)
      order by o.rn limit 1
    ) o on true
    left join lateral (
      select new_ts from corrections c
      where c.kind = 'add-out' and c.punch_id = i.id
      order by c.created_at desc limit 1
    ) ao on true
    where i.type = 'in'
      and not exists (
        select 1 from month_eff prev
        where prev.type = 'in' and prev.rn < i.rn
          and paris_date(prev.ts) = paris_date(i.ts)   -- SAME-DAY ONLY (the fix)
          and not exists (select 1 from month_eff po where po.type = 'out' and po.rn > prev.rn and po.rn < i.rn)
      )
  ), daily as (
    select d, sum(mins) as m from pairs group by d
  )
  select json_build_object(
    'total_min',  coalesce(round(sum(m)), 0),
    'days',       count(*) filter (where m > 0),
    'full_days',  count(*) filter (where m >= cfg_int('full_day_min'))
  ) into v_month from daily;

  return json_build_object(
    'ok', true,
    'name', v_emp.name,
    'month', coalesce(v_month, json_build_object('total_min',0,'days',0,'full_days',0)),
    'today', _today_state(v_emp.id)
  );
end $$;

revoke all on function my_summary(text) from public;
grant execute on function my_summary(text) to anon, authenticated;

-- verification:
-- select my_summary('<a real login code>');
--   → ok:true with month totals matching the admin's month view
-- select my_summary('999999');
--   → {"ok":false,"error":"employee_not_found"}
