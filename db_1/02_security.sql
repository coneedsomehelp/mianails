-- ============================================================
-- Salon Timekeeper — 02_security.sql
-- Bucket 5.1: row-level security. Run SECOND.
--
-- Model:
--   · Employees are ANONYMOUS clients. They get ZERO direct table
--     access; every employee action goes through server-side RPC
--     functions (Bucket 5.2) that validate tokens and login codes.
--     RLS enabled + no anon policy = deny by default.
--   · Managers sign in via Supabase Auth. A row in `managers`
--     is what grants access — an authenticated stranger with no
--     managers row sees nothing.
-- ============================================================

-- helper: is the current authenticated user a registered manager?
create or replace function is_manager() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from managers where user_id = auth.uid());
$$;

-- ---------- enable RLS everywhere ----------
alter table config        enable row level security;
alter table shops         enable row level security;
alter table employees     enable row level security;
alter table devices       enable row level security;
alter table poster_tokens enable row level security;
alter table sessions      enable row level security;
alter table punches       enable row level security;
alter table corrections   enable row level security;
alter table leave         enable row level security;
alter table managers      enable row level security;

-- ---------- manager read access ----------
create policy mgr_read_config      on config        for select to authenticated using (is_manager());
create policy mgr_read_shops       on shops         for select to authenticated using (is_manager());
create policy mgr_read_employees   on employees     for select to authenticated using (is_manager());
create policy mgr_read_devices     on devices       for select to authenticated using (is_manager());
create policy mgr_read_sessions    on sessions      for select to authenticated using (is_manager());
create policy mgr_read_punches     on punches       for select to authenticated using (is_manager());
create policy mgr_read_corrections on corrections   for select to authenticated using (is_manager());
create policy mgr_read_leave       on leave         for select to authenticated using (is_manager());
create policy mgr_read_managers    on managers      for select to authenticated using (is_manager());

-- ---------- manager write access ----------
-- roster management
create policy mgr_ins_employees on employees for insert to authenticated
  with check (is_manager());
create policy mgr_upd_employees on employees for update to authenticated
  using (is_manager()) with check (is_manager());

-- corrections: append-only, and attribution must be YOURSELF
create policy mgr_ins_corrections on corrections for insert to authenticated
  with check (is_manager() and manager_id = auth.uid());

-- leave: managers can create day-off assignments and manager-entered leave...
create policy mgr_ins_leave on leave for insert to authenticated
  with check (is_manager() and created_by = 'manager');
-- ...decide pending requests (decision must be attributed to yourself)...
create policy mgr_upd_leave on leave for update to authenticated
  using (is_manager())
  with check (is_manager() and (decided_by is null or decided_by = auth.uid()));
-- ...and remove day-off assignments (the roster toggle). PTO records are never deleted.
create policy mgr_del_dayoff on leave for delete to authenticated
  using (is_manager() and type = 'dayoff');

-- config: only the owner changes policy constants
create policy owner_upd_config on config for update to authenticated
  using (exists (select 1 from managers where user_id = auth.uid() and role = 'owner'))
  with check (exists (select 1 from managers where user_id = auth.uid() and role = 'owner'));

-- NOTE deliberately absent:
--   · no anon policies at all (employee RPCs in 5.2 are SECURITY DEFINER)
--   · no update/delete policies on punches or corrections
--     (blocked twice: no policy AND the append-only triggers)
--   · no insert policy on punches for managers — even managers add time
--     via corrections, never by minting raw punches; keeps the ledger honest
