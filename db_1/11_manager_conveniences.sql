-- ============================================================
-- Salon Timekeeper — 11_manager_conveniences.sql
-- (1) Kiosk key rotation from the admin UI (managers only)
-- (2) Telegram messages gain a button that opens the admin
--     directly on the right tab (?open=leave)
-- Run AFTER 08 and 09. Requires site_url set in config (09).
-- ============================================================

-- ---------- 1. rotate a shop's kiosk key (kills a lost tablet) ----------
create or replace function rotate_kiosk_key(p_shop_id smallint)
returns json language plpgsql security definer set search_path = public as $$
declare v_new uuid;
begin
  if not is_manager() then
    raise exception 'managers only';
  end if;
  update shops set kiosk_key = gen_random_uuid()
  where id = p_shop_id
  returning kiosk_key into v_new;
  if v_new is null then
    return json_build_object('ok', false, 'error', 'shop_not_found');
  end if;
  return json_build_object('ok', true, 'kiosk_key', v_new);
end $$;

revoke all on function rotate_kiosk_key(smallint) from public;
grant execute on function rotate_kiosk_key(smallint) to authenticated;

-- ---------- 2. tg_send with an optional URL button ----------
-- (drop the old single-arg version first to avoid an ambiguous overload)
drop function if exists tg_send(text);

create or replace function tg_send(p_text text, p_btn_label text default null, p_btn_url text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_token text; v_chat text; v_body jsonb;
begin
  select value #>> '{}' into v_token from config where key = 'telegram_bot_token';
  if v_token is null or v_token = 'PASTE_ME_BOT_TOKEN' then return; end if;
  for v_chat in
    select jsonb_array_elements_text(value) from config where key = 'telegram_chat_ids'
  loop
    v_body := jsonb_build_object('chat_id', v_chat, 'text', p_text);
    if p_btn_label is not null and p_btn_url is not null and p_btn_url not like '%YOUR-%' then
      v_body := v_body || jsonb_build_object('reply_markup', jsonb_build_object(
        'inline_keyboard', jsonb_build_array(jsonb_build_array(
          jsonb_build_object('text', p_btn_label, 'url', p_btn_url)))));
    end if;
    perform net.http_post(
      url     := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
      body    := v_body,
      headers := '{"Content-Type":"application/json"}'::jsonb
    );
  end loop;
end $$;

-- ---------- 3. notifications now carry the button ----------
create or replace function notify_pending_leave() returns void
language plpgsql security definer set search_path = public as $$
declare r record; v_msg text; v_url text;
begin
  select value #>> '{}' into v_url from config where key = 'site_url';
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
          || coalesce(E'\nLý do: ' || nullif(trim(r.note), ''), '');
    perform tg_send(v_msg, 'Duyệt ngay · Approuver', v_url || '?open=leave');
    insert into notif_log (kind, ref) values ('leave', r.id::text)
      on conflict do nothing;
  end loop;
end $$;

-- morning digest: same body as 09, button added
create or replace function notify_morning_digest() returns void
language plpgsql security definer set search_path = public as $$
declare
  v_t   date := paris_date(now());
  v_m   date := date_trunc('month', v_t)::date;
  v_url text; v_dow text; v_off text := ''; v_pend text := '';
  r record; v_msg text;
begin
  if exists (select 1 from notif_log where kind = 'digest' and ref = v_t::text) then
    return;
  end if;
  select value #>> '{}' into v_url from config where key = 'site_url';
  v_dow := case extract(dow from v_t)::int
    when 0 then 'Chủ Nhật' when 1 then 'Thứ Hai' when 2 then 'Thứ Ba'
    when 3 then 'Thứ Tư'  when 4 then 'Thứ Năm' when 5 then 'Thứ Sáu'
    else 'Thứ Bảy' end;

  for r in
    select * from (
      select e.name, 'weekly' as k, null::text as half
      from leave l join employees e on e.id = l.employee_id
      where l.type = 'dayoff' and l.date = v_t and e.active
      union all
      select e.name, 'pto', l.half
      from leave l join employees e on e.id = l.employee_id
      where l.type = 'pto' and l.status = 'approved'
        and l.start_date <= v_t and l.end_date >= v_t and e.active
    ) q order by name
  loop
    v_off := v_off || E'\n• ' || r.name || ' → '
          || case when r.k = 'weekly' then 'Nghỉ tuần'
                  else 'Nghỉ phép'
                    || case when r.half = 'am' then ' (nửa ngày — sáng)'
                            when r.half = 'pm' then ' (nửa ngày — chiều)'
                            else '' end
             end;
  end loop;
  if v_off = '' then v_off := E'\n• Không ai nghỉ — đủ đội hình 💪'; end if;

  for r in
    select * from (
      select e.name, 1 as ord, paris_date(pi.ts) as d1, null::date as d2, 'mout' as k
      from punches pi join employees e on e.id = pi.employee_id
      where pi.type = 'in' and paris_date(pi.ts) >= v_m and paris_date(pi.ts) < v_t and e.active
        and not exists (select 1 from corrections c where c.kind = 'void'    and c.punch_id = pi.id)
        and not exists (select 1 from corrections c where c.kind = 'add-out' and c.punch_id = pi.id)
        and not exists (
          select 1 from punches po
          where po.employee_id = pi.employee_id and po.type = 'out' and po.ts > pi.ts
            and not exists (select 1 from corrections c2 where c2.kind = 'void' and c2.punch_id = po.id))
      union all
      select e.name, 1, paris_date(po.ts), null, 'min'
      from punches po join employees e on e.id = po.employee_id
      where po.type = 'out' and paris_date(po.ts) >= v_m and paris_date(po.ts) < v_t and e.active
        and not exists (select 1 from corrections c where c.kind = 'void'   and c.punch_id = po.id)
        and not exists (select 1 from corrections c where c.kind = 'add-in' and c.punch_id = po.id)
        and not exists (
          select 1 from punches pi
          where pi.employee_id = po.employee_id and pi.type = 'in'
            and paris_date(pi.ts) = paris_date(po.ts) and pi.ts < po.ts
            and not exists (select 1 from corrections c2 where c2.kind = 'void' and c2.punch_id = pi.id))
      union all
      select e.name, 2, l.start_date, l.end_date, 'pto'
      from leave l join employees e on e.id = l.employee_id
      where l.type = 'pto' and l.status = 'pending'
    ) q order by ord, d1
  loop
    v_pend := v_pend || E'\n• ' || r.name || ' → '
           || case r.k
                when 'mout' then 'Quên chấm RA ('  || to_char(r.d1, 'DD/MM') || ')'
                when 'min'  then 'Quên chấm VÀO (' || to_char(r.d1, 'DD/MM') || ')'
                else 'Đơn xin nghỉ (' || to_char(r.d1, 'DD/MM') || ' → ' || to_char(r.d2, 'DD/MM') || ')'
              end;
  end loop;
  if v_pend = '' then v_pend := E'\n• Không có gì chờ xử lý 🎉'; end if;

  v_msg := '☀️ Báo cáo ngày (' || v_dow || ', ' || to_char(v_t, 'DD/MM') || ')'
        || E'\n\nHôm nay nghỉ:'          || v_off
        || E'\n\nChờ xử lý (tháng này):' || v_pend;
  perform tg_send(v_msg, 'Mở trang quản lý · Ouvrir', v_url || '?open=today');
  insert into notif_log (kind, ref) values ('digest', v_t::text)
    on conflict do nothing;
end $$;

-- ---------- verification ----------
-- select tg_send('✅ Test nút bấm', 'Mở trang quản lý', (select value #>> '{}' from config where key='site_url') || '?open=leave');
--   → message arrives WITH a button; tapping it opens the admin on Nghỉ phép.
-- select rotate_kiosk_key(1::smallint);   -- run signed in? SQL editor is admin:
--   NOTE: from the SQL editor is_manager() is false → 'managers only' error is the
--   expected PASS there. Test the button in the admin UI instead.
