-- ============================================================
-- Salon Timekeeper — 01_schema.sql
-- Bucket 5.1: tables, constraints, indexes, immutability.
-- Run FIRST in the Supabase SQL Editor.
-- ============================================================

create extension if not exists pgcrypto;

-- ---------- policy constants live in data, not code ----------
create table config (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

-- ---------- locations ----------
create table shops (
  id         smallint primary key,
  name       text not null,
  -- secret embedded in each door tablet's kiosk URL; rotating it kills a stolen tablet's access
  kiosk_key  uuid not null default gen_random_uuid(),
  created_at timestamptz not null default now()
);

-- ---------- shared roster across all shops ----------
create table employees (
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
create table devices (
  device_uuid uuid primary key,
  first_seen  timestamptz not null default now(),
  last_seen   timestamptz not null default now()
);

-- ---------- token layer 1: shared, time-rotated poster QR (one per shop) ----------
create table poster_tokens (
  shop_id    smallint primary key references shops(id),
  code       text not null,
  expires_at timestamptz not null
);

-- ---------- token layer 2: single-use per-scan sessions ----------
create table sessions (
  id          uuid primary key default gen_random_uuid(),
  shop_id     smallint not null references shops(id),
  device_uuid uuid not null,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  used_at     timestamptz,                    -- set exactly once at punch redemption
  employee_id uuid references employees(id)   -- set at redemption
);
create index sessions_expiry on sessions (expires_at);

-- ---------- the ledger: immutable punch events ----------
create table punches (
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
create index punches_emp_ts on punches (employee_id, ts);
create index punches_ts     on punches (ts);

-- ---------- append-only corrections layered on the ledger ----------
create table corrections (
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
create index corrections_emp on corrections (employee_id);

-- ---------- leave: weekly day-offs + PTO requests ----------
create table leave (
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
create index leave_emp on leave (employee_id);

-- ---------- manager identity (linked to Supabase Auth) ----------
create table managers (
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

create trigger punches_immutable
  before update or delete on punches
  for each row execute function forbid_change();

create trigger corrections_immutable
  before update or delete on corrections
  for each row execute function forbid_change();
