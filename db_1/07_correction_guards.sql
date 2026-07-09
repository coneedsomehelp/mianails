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
create trigger corrections_validate
  before insert on corrections
  for each row execute function validate_correction();

-- verification (both must FAIL):
-- insert a correction with a random punch_id      → 'does not exist'
-- add-out with new_ts earlier than the punch's ts → 'must be after'
