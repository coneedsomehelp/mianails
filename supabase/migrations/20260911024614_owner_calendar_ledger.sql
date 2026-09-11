-- Owner calendar: atomic day replacement, with immutable before/after bookkeeping.
-- Additive upgrade after db_1/18_session_day_boundary.sql. No historical rows rewritten.
create schema if not exists salon_private;
revoke all on schema salon_private from public, anon;
grant usage on schema salon_private to authenticated;

alter table public.corrections add column if not exists day_date date;
alter table public.corrections add column if not exists owner_request_id uuid;
alter table public.corrections add column if not exists details jsonb;
alter table public.corrections drop constraint if exists corrections_kind_check;
alter table public.corrections add constraint corrections_kind_check
  check (kind in ('edit','void','add-in','add-out','ack','day-edit'));
alter table public.corrections add constraint corrections_day_edit_shape check (
  (kind='day-edit' and punch_id is null and day_date is not null
    and owner_request_id is not null and details is not null and jsonb_typeof(details)='object')
  or (kind<>'day-edit' and day_date is null and owner_request_id is null and details is null)
);
create unique index corrections_owner_request on public.corrections(owner_request_id)
  where owner_request_id is not null;
create index corrections_day_history on public.corrections(employee_id,day_date,created_at);

-- Existing manager correction tools keep their access; calendar audit rows can
-- only be written inside the owner-checked transaction, never via direct inserts.
alter policy mgr_ins_corrections on public.corrections with check (
  public.is_manager() and manager_id=auth.uid()
  and kind in ('edit','void','add-in','add-out','ack')
  and day_date is null and owner_request_id is null and details is null
);

-- Qualify the existing guard so it also works from a hardened empty search path.
create or replace function public.validate_correction() returns trigger
language plpgsql set search_path='' as $$
declare v_punch public.punches;
begin
  if new.kind in ('edit','void','add-out','add-in') then
    if new.punch_id is null then
      raise exception 'This correction kind must target a punch';
    end if;
    select * into v_punch from public.punches where id = new.punch_id;
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

-- Serialize calendar saves with punches, old correction tools and leave actions.
-- Transaction locks release automatically, including on errors/rollback.
create or replace function salon_private.lock_employee_record() returns trigger
language plpgsql set search_path='' as $$
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    (case when tg_op='DELETE' then old.employee_id else new.employee_id end)::text,0));
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;
revoke all on function salon_private.lock_employee_record() from public, anon, authenticated;
create trigger a_calendar_lock before insert on public.punches
  for each row execute function salon_private.lock_employee_record();
create trigger a_calendar_lock before insert on public.corrections
  for each row execute function salon_private.lock_employee_record();
create trigger a_calendar_lock before insert or update or delete on public.leave
  for each row execute function salon_private.lock_employee_record();

-- Snapshot is internal and contains only records relevant to this employee/date.
-- Exclude nested audit payloads to keep successive snapshots bounded in size.
create or replace function salon_private.day_snapshot(p_employee uuid,p_date date)
returns jsonb language sql stable set search_path='' as $$
  with selected as (
    select p.* from public.punches p
    left join lateral (
      select c.new_ts from public.corrections c where c.punch_id=p.id and c.kind='edit'
      order by c.created_at desc,c.id desc limit 1
    ) e on true
    where p.employee_id=p_employee and
      ((p.ts at time zone 'Europe/Paris')::date=p_date
       or (coalesce(e.new_ts,p.ts) at time zone 'Europe/Paris')::date=p_date)
  )
  select jsonb_build_object(
    'punches',coalesce((select jsonb_agg(to_jsonb(p) order by p.ts,p.id) from selected p),'[]'::jsonb),
    'corrections',coalesce((select jsonb_agg((to_jsonb(c)-'details')||case when c.kind='day-edit' then jsonb_build_object('day_type',c.details#>>'{request,type}') else '{}'::jsonb end order by c.created_at,c.id)
      from public.corrections c where c.employee_id=p_employee and
        (c.punch_id in (select id from selected) or c.day_date=p_date
          or c.synthetic_ref='noshow-'||p_employee::text||'-'||p_date::text)),'[]'::jsonb),
    'leave',coalesce((select jsonb_agg(to_jsonb(l) order by l.id) from public.leave l
      where l.employee_id=p_employee and
        ((l.type='dayoff' and l.date=p_date) or
         (l.type='pto' and l.start_date<=p_date and l.end_date>=p_date))),'[]'::jsonb)
  );
$$;
revoke all on function salon_private.day_snapshot(uuid,date) from public, anon, authenticated;

create or replace function salon_private.owner_calendar_get(p_employee uuid,p_date date)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_state jsonb;
begin
  if auth.uid() is null or not exists(select 1 from public.managers where user_id=auth.uid() and role='owner') then
    raise exception using errcode='42501',message='owner_only';
  end if;
  if p_date is null or p_date not between date '1900-01-01' and date '9998-12-31' then
    raise exception 'invalid_date';
  end if;
  if not exists(select 1 from public.employees where id=p_employee) then raise exception 'employee_not_found'; end if;
  v_state:=salon_private.day_snapshot(p_employee,p_date);
  return jsonb_build_object('ok',true,'version',md5(v_state::text),'snapshot',v_state);
end $$;
revoke all on function salon_private.owner_calendar_get(uuid,date) from public,anon,authenticated;
grant execute on function salon_private.owner_calendar_get(uuid,date) to authenticated;

create or replace function public.owner_calendar_get(p_employee uuid,p_date date)
returns jsonb language sql security invoker set search_path='' as $$
  select salon_private.owner_calendar_get(p_employee,p_date);
$$;
revoke all on function public.owner_calendar_get(uuid,date) from public,anon,authenticated;
grant execute on function public.owner_calendar_get(uuid,date) to authenticated;

create or replace function salon_private.owner_calendar_save(
  p_employee uuid,p_date date,p_version text,p_request_id uuid,
  p_type text,p_sessions jsonb,p_note text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_owner uuid:=auth.uid(); v_before jsonb; v_after jsonb; v_request jsonb;
  v_existing public.corrections; v_leave public.leave; v_punch record;
  v_row jsonb; v_in timestamptz; v_out timestamptz; v_shop smallint;
  v_intervals jsonb:='[]'::jsonb; v_added jsonb:='[]'::jsonb;
  v_id uuid; v_audit_id uuid:=gen_random_uuid(); v_minutes numeric:=0;
  v_active boolean;
begin
  if v_owner is null or not exists(select 1 from public.managers where user_id=v_owner and role='owner') then
    raise exception using errcode='42501',message='owner_only';
  end if;
  if p_request_id is null or p_version is null then raise exception 'missing_version_or_request'; end if;
  if p_date is null or p_date not between date '1900-01-01' and date '9998-12-31' then raise exception 'invalid_date'; end if;
  if p_type is null or p_type not in ('work','dayoff','pto','am','pm','clear') then raise exception 'invalid_day_type'; end if;
  if p_sessions is null or jsonb_typeof(p_sessions)<>'array' then raise exception 'invalid_sessions'; end if;
  if jsonb_array_length(p_sessions)>24 then raise exception 'too_many_sessions'; end if;
  if length(coalesce(p_note,''))>2000 then raise exception 'note_too_long'; end if;
  if p_type in ('dayoff','pto','clear') and jsonb_array_length(p_sessions)>0 then raise exception 'leave_cannot_have_hours'; end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_employee::text,0));
  select active into v_active from public.employees where id=p_employee;
  if not found then raise exception 'employee_not_found'; end if;
  v_request:=jsonb_build_object('type',p_type,'sessions',p_sessions,'note',nullif(trim(p_note),''));
  select * into v_existing from public.corrections where owner_request_id=p_request_id;
  if found then
    if v_existing.manager_id<>v_owner or v_existing.employee_id<>p_employee or v_existing.day_date<>p_date
       or v_existing.details->'request' is distinct from v_request then raise exception 'request_id_reused'; end if;
    return jsonb_build_object('ok',true,'audit_id',v_existing.id,'replayed',true);
  end if;
  v_before:=salon_private.day_snapshot(p_employee,p_date);
  if md5(v_before::text)<>p_version then raise exception using errcode='40001',message='day_changed'; end if;

  for v_row in select value from jsonb_array_elements(p_sessions) loop
    if jsonb_typeof(v_row)<>'object' or coalesce(v_row->>'in','') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
       or coalesce(v_row->>'out','') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
       or coalesce(v_row->>'shop','') !~ '^[0-9]{1,5}$' then raise exception 'invalid_session'; end if;
    v_shop:=(v_row->>'shop')::smallint;
    if not exists(select 1 from public.shops where id=v_shop) then raise exception 'invalid_shop'; end if;
    v_in:=(p_date+(v_row->>'in')::time) at time zone 'Europe/Paris';
    v_out:=(p_date+(v_row->>'out')::time) at time zone 'Europe/Paris';
    if to_char(v_in at time zone 'Europe/Paris','HH24:MI')<>v_row->>'in'
       or to_char(v_out at time zone 'Europe/Paris','HH24:MI')<>v_row->>'out' then raise exception 'invalid_dst_time'; end if;
    if v_out<=v_in then raise exception 'checkout_before_checkin'; end if;
    if exists(select 1 from jsonb_array_elements(v_intervals) x
      where v_in<(x->>'end')::timestamptz and v_out>(x->>'start')::timestamptz) then raise exception 'overlapping_sessions'; end if;
    v_intervals:=v_intervals||jsonb_build_array(jsonb_build_object('start',v_in,'end',v_out,'shop',v_shop));
    v_minutes:=v_minutes+extract(epoch from v_out-v_in)/60;
  end loop;

  -- Invalidate effective punches on this date by APPENDING void corrections.
  -- Original punches and every earlier correction remain untouched.
  for v_punch in
    select p.id,p.ts,coalesce(e.new_ts,p.ts) effective_ts from public.punches p
    left join lateral (select c.new_ts from public.corrections c where c.punch_id=p.id and c.kind='edit'
      order by c.created_at desc,c.id desc limit 1) e on true
    where p.employee_id=p_employee and (coalesce(e.new_ts,p.ts) at time zone 'Europe/Paris')::date=p_date
      and not exists(select 1 from public.corrections c where c.punch_id=p.id and c.kind='void')
  loop
    insert into public.corrections(kind,punch_id,employee_id,old_ts,manager_id,note)
      values('void',v_punch.id,p_employee,v_punch.effective_ts,v_owner,nullif(trim(p_note),''));
  end loop;

  -- Weekly leave is a mutable roster projection; its exact original row is in
  -- v_before, recorded below in the immutable corrections ledger.
  delete from public.leave where employee_id=p_employee and type='dayoff' and date=p_date;
  -- Preserve the rest of any multi-day PTO request, including pending requests.
  for v_leave in select * from public.leave where employee_id=p_employee and type='pto'
      and status in ('approved','pending') and start_date<=p_date and end_date>=p_date for update
  loop
    update public.leave set status='cancelled',decided_by=v_owner,decided_at=now() where id=v_leave.id;
    if v_leave.start_date<p_date then
      insert into public.leave(type,employee_id,start_date,end_date,half,days,note,status,requested_at,decided_by,decided_at,created_by,decision_note)
      values('pto',p_employee,v_leave.start_date,p_date-1,null,p_date-v_leave.start_date,v_leave.note,v_leave.status,
        v_leave.requested_at,v_leave.decided_by,v_leave.decided_at,v_leave.created_by,v_leave.decision_note);
    end if;
    if v_leave.end_date>p_date then
      insert into public.leave(type,employee_id,start_date,end_date,half,days,note,status,requested_at,decided_by,decided_at,created_by,decision_note)
      values('pto',p_employee,p_date+1,v_leave.end_date,null,v_leave.end_date-p_date,v_leave.note,v_leave.status,
        v_leave.requested_at,v_leave.decided_by,v_leave.decided_at,v_leave.created_by,v_leave.decision_note);
    end if;
  end loop;
  if p_type='dayoff' then
    insert into public.leave(type,employee_id,date,status,created_by,decided_by,decided_at,note)
      values('dayoff',p_employee,p_date,'approved','manager',v_owner,now(),nullif(trim(p_note),''));
  elsif p_type in ('pto','am','pm') then
    insert into public.leave(type,employee_id,start_date,end_date,half,days,status,created_by,decided_by,decided_at,note)
      values('pto',p_employee,p_date,p_date,case when p_type='pto' then null else p_type end,
        case when p_type='pto' then 1 else 0.5 end,'approved','manager',v_owner,now(),nullif(trim(p_note),''));
  end if;
  -- Owner-generated pairs are appended through this audited transaction only.
  -- Keeping ordinary punch pairs means all existing reports and employee RPCs
  -- use the same calculations without a second competing source of hours.
  for v_row in select value from jsonb_array_elements(v_intervals) loop
    insert into public.punches(employee_id,shop_id,type,ts)
      values(p_employee,(v_row->>'shop')::smallint,'in',(v_row->>'start')::timestamptz) returning id into v_id;
    v_added:=v_added||to_jsonb(v_id);
    insert into public.punches(employee_id,shop_id,type,ts)
      values(p_employee,(v_row->>'shop')::smallint,'out',(v_row->>'end')::timestamptz) returning id into v_id;
    v_added:=v_added||to_jsonb(v_id);
  end loop;
  v_after:=salon_private.day_snapshot(p_employee,p_date);
  insert into public.corrections(id,kind,employee_id,manager_id,day_date,owner_request_id,note,details)
    values(v_audit_id,'day-edit',p_employee,v_owner,p_date,p_request_id,nullif(trim(p_note),''),
      jsonb_build_object('request',v_request,'before',v_before,'after',v_after,
        'added_punch_ids',v_added,'total_minutes',v_minutes));
  return jsonb_build_object('ok',true,'audit_id',v_audit_id,'total_minutes',v_minutes);
end $$;
revoke all on function salon_private.owner_calendar_save(uuid,date,text,uuid,text,jsonb,text) from public,anon,authenticated;
grant execute on function salon_private.owner_calendar_save(uuid,date,text,uuid,text,jsonb,text) to authenticated;

create or replace function public.owner_calendar_save(
  p_employee uuid,p_date date,p_version text,p_request_id uuid,
  p_type text,p_sessions jsonb,p_note text default null)
returns jsonb language sql security invoker set search_path='' as $$
  select salon_private.owner_calendar_save(p_employee,p_date,p_version,p_request_id,p_type,p_sessions,p_note);
$$;
revoke all on function public.owner_calendar_save(uuid,date,text,uuid,text,jsonb,text) from public,anon,authenticated;
grant execute on function public.owner_calendar_save(uuid,date,text,uuid,text,jsonb,text) to authenticated;
-- Adjacent visits may share an endpoint: process checkout before check-in.
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
    select *, row_number() over (order by ts, type desc, id) rn from eff where paris_date(ts) = v_today
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
    select *, row_number() over (order by ts, type desc, id) rn
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


notify pgrst,'reload schema';
