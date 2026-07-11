-- ============================================================
-- Salon Timekeeper — 08_notifications_RERUN.sql
-- Safe clean re-run. The credential section is REMOVED on
-- purpose — your telegram_bot_token and telegram_chat_ids are
-- already in the config table and must not be overwritten.
-- Everything here is idempotent: run the whole file at once.
-- ============================================================

-- ---------- 1. extensions (no-ops if already enabled) ----------
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- ---------- 2. send log (THE TABLE THAT WAS MISSING) ----------
create table if not exists notif_log (
  id      bigint generated always as identity primary key,
  kind    text not null,
  ref     text not null,
  sent_at timestamptz not null default now(),
  unique (kind, ref)
);
alter table notif_log enable row level security;

-- managers may read it (harmless if already present)
drop policy if exists mgr_read_notif on notif_log;
create policy mgr_read_notif on notif_log
  for select to authenticated using (is_manager());

-- ---------- 3. sender ----------
create or replace function tg_send(p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare v_token text; v_chat text;
begin
  select value #>> '{}' into v_token from config where key = 'telegram_bot_token';
  if v_token is null or v_token = 'PASTE_ME_BOT_TOKEN' then return; end if;
  for v_chat in
    select jsonb_array_elements_text(value) from config where key = 'telegram_chat_ids'
  loop
    perform net.http_post(
      url     := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
      body    := jsonb_build_object('chat_id', v_chat, 'text', p_text),
      headers := '{"Content-Type":"application/json"}'::jsonb
    );
  end loop;
end $$;

-- ---------- 4. new pending leave → alert (runs every 5 min) ----------
create or replace function notify_pending_leave() returns void
language plpgsql security definer set search_path = public as $$
declare r record; v_msg text;
begin
  for r in
    select l.id, l.start_date, l.end_date, l.days, l.half, l.note, e.name
    from leave l join employees e on e.id = l.employee_id
    where l.type = 'pto' and l.status = 'pending'
      and not exists (select 1 from notif_log n where n.kind = 'leave' and n.ref = l.id::text)
    order by l.requested_at
  loop
    v_msg := '🌴 Đơn xin nghỉ mới: ' || r.name || ' — '
          || to_char(r.start_date, 'DD/MM') || ' → ' || to_char(r.end_date, 'DD/MM')
          || ' (' || r.days || ' ngày'
          || case when r.half = 'am' then ', buổi sáng'
                  when r.half = 'pm' then ', buổi chiều' else '' end
          || ')'
          || coalesce(E'\nLý do: ' || nullif(trim(r.note), ''), '')
          || E'\n→ Duyệt trong trang Quản lý → Nghỉ phép.';
    perform tg_send(v_msg);
    insert into notif_log (kind, ref) values ('leave', r.id::text)
      on conflict do nothing;
  end loop;
end $$;

-- ---------- 5. morning digest: yesterday's forgotten punches ----------
create or replace function notify_morning_digest() returns void
language plpgsql security definer set search_path = public as $$
declare
  v_y date := paris_date(now()) - 1;
  v_lines text := ''; v_pend int; r record;
begin
  if exists (select 1 from notif_log where kind = 'digest' and ref = v_y::text) then
    return;
  end if;

  for r in
    select e.name, pi.ts
    from punches pi join employees e on e.id = pi.employee_id
    where pi.type = 'in' and paris_date(pi.ts) = v_y and e.active
      and not exists (select 1 from corrections c where c.kind = 'void'    and c.punch_id = pi.id)
      and not exists (select 1 from corrections c where c.kind = 'add-out' and c.punch_id = pi.id)
      and not exists (
        select 1 from punches po
        where po.employee_id = pi.employee_id and po.type = 'out' and po.ts > pi.ts
          and not exists (select 1 from corrections c2 where c2.kind = 'void' and c2.punch_id = po.id))
  loop
    v_lines := v_lines || E'\n• ' || r.name || ' — quên chấm RA (vào lúc '
            || to_char(r.ts at time zone 'Europe/Paris', 'HH24:MI') || ')';
  end loop;

  for r in
    select e.name, po.ts
    from punches po join employees e on e.id = po.employee_id
    where po.type = 'out' and paris_date(po.ts) = v_y and e.active
      and not exists (select 1 from corrections c where c.kind = 'void'   and c.punch_id = po.id)
      and not exists (select 1 from corrections c where c.kind = 'add-in' and c.punch_id = po.id)
      and not exists (
        select 1 from punches pi
        where pi.employee_id = po.employee_id and pi.type = 'in'
          and paris_date(pi.ts) = v_y and pi.ts < po.ts
          and not exists (select 1 from corrections c2 where c2.kind = 'void' and c2.punch_id = pi.id))
  loop
    v_lines := v_lines || E'\n• ' || r.name || ' — quên chấm VÀO (ra lúc '
            || to_char(r.ts at time zone 'Europe/Paris', 'HH24:MI') || ')';
  end loop;

  select count(*) into v_pend from leave where type = 'pto' and status = 'pending';

  if v_lines <> '' or v_pend > 0 then
    perform tg_send(
      '☀️ Tổng kết ngày ' || to_char(v_y, 'DD/MM') || ':'
      || case when v_lines <> '' then v_lines
              else E'\n• Không có cảnh báo chấm công 🎉' end
      || case when v_pend > 0 then E'\n🌴 Còn ' || v_pend || ' đơn nghỉ phép chờ duyệt' else '' end
      || E'\n→ Xử lý trong trang Quản lý.');
  end if;

  insert into notif_log (kind, ref) values ('digest', v_y::text)
    on conflict do nothing;
end $$;

-- ---------- 6. schedules (unschedule-then-schedule = safe re-run) ----------
do $$ begin perform cron.unschedule('notify-pending-leave'); exception when others then null; end $$;
do $$ begin perform cron.unschedule('morning-digest');       exception when others then null; end $$;
select cron.schedule('notify-pending-leave', '*/5 * * * *', $$select notify_pending_leave()$$);
select cron.schedule('morning-digest',       '15 7 * * *',  $$select notify_morning_digest()$$);

-- ---------- 7. verify ----------
-- select count(*) from notif_log;        -- a number, NOT an error = table exists
-- select notify_pending_leave();         -- your pending PTO should hit Telegram now
-- select jobname, schedule from cron.job; -- expect the 2 jobs
