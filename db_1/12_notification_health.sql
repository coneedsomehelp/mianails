-- ============================================================
-- Salon Timekeeper — 12_notification_health.sql
-- Managers can verify Telegram delivery from the admin UI
-- (Hệ thống tab) instead of trusting silence. Run AFTER 11.
-- ============================================================

-- managers may read the send log
drop policy if exists mgr_read_notif on notif_log;
create policy mgr_read_notif on notif_log
  for select to authenticated using (is_manager());

-- last delivery attempts, with Telegram's actual answers.
-- NOTE: pg_net auto-deletes its response log after a few hours,
-- so this shows RECENT health, which is exactly what a check needs.
create or replace function tg_health(p_limit int default 10)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_manager() then raise exception 'managers only'; end if;
  return coalesce((
    select json_agg(row_to_json(t)) from (
      select id, status_code, timed_out, error_msg,
             left(coalesce(content::text, ''), 160) as content_snippet,
             created
      from net._http_response
      order by id desc
      limit greatest(1, least(p_limit, 50))
    ) t
  ), '[]'::json);
end $$;

revoke all on function tg_health(int) from public;
grant execute on function tg_health(int) to authenticated;

-- one-tap test message from the admin
create or replace function tg_test()
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_manager() then raise exception 'managers only'; end if;
  perform tg_send('✅ Tin nhắn thử từ trang Quản lý — hệ thống thông báo hoạt động ('
    || to_char(now() at time zone 'Europe/Paris', 'HH24:MI') || ' Paris).');
  return json_build_object('ok', true);
end $$;

revoke all on function tg_test() from public;
grant execute on function tg_test() to authenticated;

-- ============================================================
-- CHANGING THE DAILY REPORT TIME (the recipe, for the manual)
-- Cron runs in UTC. Paris is UTC+2 in summer, UTC+1 in winter.
--   9:00 Paris summer  → '0 7 * * *'
--   9:00 Paris winter  → '0 8 * * *'
-- Pick one; it drifts 1h across the DST change (harmless), or
-- re-run this twice a year for exact 9:00.
--
-- select cron.unschedule('morning-digest');
-- select cron.schedule('morning-digest', '0 7 * * *', $$select notify_morning_digest()$$);
--
-- Leave-alert frequency (default every 5 min) works the same way:
-- select cron.unschedule('notify-pending-leave');
-- select cron.schedule('notify-pending-leave', '*/10 * * * *', $$select notify_pending_leave()$$);
--
-- See what's scheduled right now:
-- select jobname, schedule from cron.job;
-- ============================================================
