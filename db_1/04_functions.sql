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
