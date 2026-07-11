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
