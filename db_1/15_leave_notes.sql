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
