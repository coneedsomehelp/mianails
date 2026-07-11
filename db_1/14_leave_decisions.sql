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
