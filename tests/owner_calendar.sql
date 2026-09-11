-- Run in a transaction after the migration, then ROLLBACK. Synthetic employee
-- only; temporary owner-role change is never committed or visible to clients.
do $$
declare
  v_owner uuid; v_employee uuid:=gen_random_uuid(); v_shop smallint; v_date date;
  v_get jsonb; v_saved jsonb; v_request uuid; v_count int; v_blocked boolean;
  v_payload jsonb; v_balance numeric; v_range uuid; v_code text; v_id uuid;
begin
  select user_id into v_owner from public.managers where role='owner' limit 1;
  assert v_owner is not null,'An existing owner is required for rollback-only checks';
  select id into v_shop from public.shops order by id limit 1;
  assert v_shop is not null,'A salon is required';
  v_date:=(now() at time zone 'Europe/Paris')::date;
  loop
    v_code:=lpad((floor(random()*1000000))::int::text,6,'0');
    exit when not exists(select 1 from public.employees where login_code=v_code);
  end loop;
  insert into public.employees(id,name,login_code,pto_opening) values(v_employee,'CALENDAR ROLLBACK TEST',v_code,10);
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  assert not has_function_privilege('anon','public.owner_calendar_save(uuid,date,text,uuid,text,jsonb,text)','execute');
  assert not has_function_privilege('anon','public.owner_calendar_get(uuid,date)','execute');
  assert not has_function_privilege('authenticated','salon_private.day_snapshot(uuid,date)','execute');

  -- Owner can create a completely forgotten day; optional reason remains null.
  execute 'set local role authenticated';
  v_get:=public.owner_calendar_get(v_employee,v_date);
  v_request:=gen_random_uuid();
  v_payload:=jsonb_build_array(jsonb_build_object('in','10:00','out','19:30','shop',v_shop));
  v_saved:=public.owner_calendar_save(v_employee,v_date,v_get->>'version',v_request,'work',v_payload,null);
  assert (v_saved->>'ok')::boolean;
  assert (v_saved->>'total_minutes')::numeric=570;
  assert (public.my_summary(v_code)->'month'->>'total_min')::numeric=570;
  select count(*) into v_count from public.punches where employee_id=v_employee;
  assert v_count=2;
  assert (select count(*)=1 from public.corrections where employee_id=v_employee and kind='day-edit' and note is null);
  -- Same request retried after lost response produces exactly one adjustment.
  v_saved:=public.owner_calendar_save(v_employee,v_date,v_get->>'version',v_request,'work',v_payload,null);
  assert (v_saved->>'replayed')::boolean;
  assert (select count(*)=2 from public.punches where employee_id=v_employee);
  v_blocked:=false;
  begin
    perform public.owner_calendar_save(v_employee,v_date,v_get->>'version',gen_random_uuid(),'clear','[]',null);
  exception when serialization_failure then v_blocked:=true; end;
  assert v_blocked,'Stale popup must fail';

  -- Validation rejects reversed times and overlapping periods atomically.
  v_get:=public.owner_calendar_get(v_employee,v_date);
  v_blocked:=false;
  begin
    perform public.owner_calendar_save(v_employee,v_date,v_get->>'version',gen_random_uuid(),'work',
      jsonb_build_array(jsonb_build_object('in','19:30','out','10:00','shop',v_shop)),null);
  exception when raise_exception then v_blocked:=sqlerrm='checkout_before_checkin'; end;
  assert v_blocked;
  v_blocked:=false;
  begin
    perform public.owner_calendar_save(v_employee,v_date,v_get->>'version',gen_random_uuid(),'work',
      v_payload||jsonb_build_array(jsonb_build_object('in','12:00','out','14:00','shop',v_shop)),null);
  exception when raise_exception then v_blocked:=sqlerrm='overlapping_sessions'; end;
  assert v_blocked;
  assert (select count(*)=2 from public.punches where employee_id=v_employee);

  -- Split visits retain the break and produce identical employee totals.
  v_payload:=jsonb_build_array(jsonb_build_object('in','10:00','out','13:00','shop',v_shop),
    jsonb_build_object('in','14:00','out','19:30','shop',v_shop));
  v_saved:=public.owner_calendar_save(v_employee,v_date,v_get->>'version',gen_random_uuid(),'work',v_payload,null);
  assert (v_saved->>'total_minutes')::numeric=510;
  assert (public.my_summary(v_code)->'month'->>'total_min')::numeric=510;
  assert (select count(*)=6 from public.punches where employee_id=v_employee),'Original punches must remain';
  -- Half-day PTO plus work.
  v_get:=public.owner_calendar_get(v_employee,v_date);
  v_balance:=(public.leave_get(v_code)->>'balance')::numeric;
  v_saved:=public.owner_calendar_save(v_employee,v_date,v_get->>'version',gen_random_uuid(),'am',
    jsonb_build_array(jsonb_build_object('in','14:00','out','18:45','shop',v_shop)),null);
  assert (public.my_summary(v_code)->'month'->>'total_min')::numeric=285;
  assert (public.leave_get(v_code)->>'balance')::numeric=v_balance-0.5;
  -- Full PTO removes work from totals; changing to weekly off restores balance.
  v_get:=public.owner_calendar_get(v_employee,v_date);
  perform public.owner_calendar_save(v_employee,v_date,v_get->>'version',gen_random_uuid(),'pto','[]',null);
  assert (public.my_summary(v_code)->'month'->>'total_min')::numeric=0;
  assert (public.leave_get(v_code)->>'balance')::numeric=v_balance-1;
  v_get:=public.owner_calendar_get(v_employee,v_date);
  perform public.owner_calendar_save(v_employee,v_date,v_get->>'version',gen_random_uuid(),'dayoff','[]',null);
  assert (public.leave_get(v_code)->>'balance')::numeric=v_balance;
  assert (select count(*)=1 from public.leave where employee_id=v_employee and type='dayoff' and date=v_date);
  -- Clear means no working time or active weekly/PTO leave on the selected day.
  v_get:=public.owner_calendar_get(v_employee,v_date);
  perform public.owner_calendar_save(v_employee,v_date,v_get->>'version',gen_random_uuid(),'clear','[]',null);
  assert not exists(select 1 from public.leave where employee_id=v_employee and
    (type='dayoff' and date=v_date or type='pto' and status in ('approved','pending') and start_date<=v_date and end_date>=v_date));
  assert (select count(*)=8 from public.punches where employee_id=v_employee);
  -- RLS forbids manufacturing audit summaries directly, even for an owner.
  v_blocked:=false;
  begin
    insert into public.corrections(kind,employee_id,manager_id,day_date,owner_request_id,details)
      values('day-edit',v_employee,v_owner,v_date,gen_random_uuid(),'{}');
  exception when insufficient_privilege then v_blocked:=true; end;
  assert v_blocked;
  execute 'reset role';

  -- Immutable triggers still block the database owner (not only client RLS).
  v_blocked:=false;
  begin delete from public.punches where employee_id=v_employee;
  exception when raise_exception then v_blocked:=position('append-only' in sqlerrm)>0; end;
  assert v_blocked;
  v_blocked:=false;
  begin update public.corrections set note='tampered' where employee_id=v_employee;
  exception when raise_exception then v_blocked:=position('append-only' in sqlerrm)>0; end;
  assert v_blocked;

  -- Removing the middle of approved leave preserves its other four days.
  insert into public.leave(type,employee_id,start_date,end_date,days,status,created_by)
    values('pto',v_employee,v_date-2,v_date+2,5,'approved','manager') returning id into v_range;
  v_get:=public.owner_calendar_get(v_employee,v_date);
  perform public.owner_calendar_save(v_employee,v_date,v_get->>'version',gen_random_uuid(),'clear','[]',null);
  assert (select status='cancelled' from public.leave where id=v_range);
  assert (select sum(days)=4 from public.leave where employee_id=v_employee and type='pto' and status='approved');
  assert not exists(select 1 from public.leave where employee_id=v_employee and type='pto' and status='approved' and start_date<=v_date and end_date>=v_date);
  -- Pending multi-day requests also keep both unaffected portions.
  insert into public.leave(type,employee_id,start_date,end_date,days,status,created_by,note)
    values('pto',v_employee,v_date+5,v_date+9,5,'pending','employee','sample request');
  v_get:=public.owner_calendar_get(v_employee,v_date+7);
  perform public.owner_calendar_save(v_employee,v_date+7,v_get->>'version',gen_random_uuid(),'clear','[]',null);
  assert (select sum(days)=4 from public.leave where employee_id=v_employee and status='pending');
  -- Old dates and real midnight are accepted. Nonexistent spring DST hour is not.
  v_get:=public.owner_calendar_get(v_employee,date '2024-01-01');
  v_saved:=public.owner_calendar_save(v_employee,date '2024-01-01',v_get->>'version',gen_random_uuid(),'work',
    jsonb_build_array(jsonb_build_object('in','00:00','out','01:00','shop',v_shop)),null);
  assert (v_saved->>'total_minutes')::numeric=60;
  v_get:=public.owner_calendar_get(v_employee,date '2026-03-29');
  v_blocked:=false;
  begin
    perform public.owner_calendar_save(v_employee,date '2026-03-29',v_get->>'version',gen_random_uuid(),'work',
      jsonb_build_array(jsonb_build_object('in','02:30','out','04:00','shop',v_shop)),null);
  exception when raise_exception then v_blocked:=sqlerrm='invalid_dst_time'; end;
  assert v_blocked;
  -- Adjacent sessions at the exact same time are not double-counted.
  v_get:=public.owner_calendar_get(v_employee,v_date);
  v_saved:=public.owner_calendar_save(v_employee,v_date,v_get->>'version',gen_random_uuid(),'work',
    jsonb_build_array(jsonb_build_object('in','10:00','out','13:00','shop',v_shop),
      jsonb_build_object('in','13:00','out','19:30','shop',v_shop)),null);
  assert (v_saved->>'total_minutes')::numeric=570;
  assert (public.my_summary(v_code)->'month'->>'total_min')::numeric=570;
  assert (public.my_summary(v_code)->'today'->>'minutes_today')::numeric=570;
  -- Registered manager cannot use either endpoint, despite authentication.
  update public.managers set role='manager' where user_id=v_owner;
  execute 'set local role authenticated';
  v_blocked:=false;
  begin perform public.owner_calendar_get(v_employee,v_date);
  exception when insufficient_privilege then v_blocked:=true; end;
  assert v_blocked;
  v_blocked:=false;
  begin perform public.owner_calendar_save(v_employee,v_date,'x',gen_random_uuid(),'clear','[]',null);
  exception when insufficient_privilege then v_blocked:=true; end;
  assert v_blocked;
  execute 'reset role';
  update public.managers set role='owner' where user_id=v_owner;
  assert (select bool_and(details?'before' and details?'after' and details?'request')
    from public.corrections where employee_id=v_employee and kind='day-edit');
end $$;
