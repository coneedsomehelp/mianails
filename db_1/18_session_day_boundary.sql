-- ============================================================
-- Salon Timekeeper — 18_session_day_boundary.sql
--
-- BUG FIXED (found 22/07/2026, live data):
--   A check-in with no check-out stayed "open" and paired with a
--   LATER DAY's check-out. Real example: NGUYEN Thanh Tung, in
--   18/07 09:55 + out 21/07 19:52 = one 81h56 session charged to
--   18/07, leaving 20/07 and 21/07 showing "Vắng". Manager add-out
--   fixes were only consulted for the LAST open punch, so a fix
--   that worked on Monday silently stopped working on Tuesday.
--
-- THE RULE (implements config auto_close = credit 0 minutes):
--   A work session must start AND end on the same Paris day.
--   An unresolved check-in counts 0h for its day and raises a
--   missing-out alert — it can never reach into the next day.
--
-- TWO HALVES — both required:
--   • SERVER (this file): my_summary() = the EMPLOYEE's own screen.
--     Same bug, opposite symptom: it DROPPED days after an unclosed
--     check-in, so staff under-saw their hours while managers
--     over-saw them.
--   • CLIENT (index.html >= v2026.07.22-01): buildSessions() = the
--     manager dashboard + payroll CSV. Deploy both together.
--
-- Verified after applying: server and client agree to the minute
-- (Tung 19h28, Tam 28h17, Thao 28h08).
-- Idempotent: safe to re-run.
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
