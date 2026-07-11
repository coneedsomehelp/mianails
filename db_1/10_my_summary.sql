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
