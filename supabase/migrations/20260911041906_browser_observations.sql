-- Browser hints are untrusted diagnostics, never authentication or fraud proof.
-- Old rows retain 'unknown'; no historical guesses or ledger rewrites.
alter table public.punches add column browser_hint text not null default 'unknown';
create or replace function salon_private.capture_browser_hint()
returns trigger language plpgsql security invoker set search_path = '' as $$
declare ua text := coalesce(nullif(current_setting('request.headers',true),'')::jsonb->>'user-agent','');
begin
  new.browser_hint := case
    when new.session_id is null then 'unknown'
    when ua ~* 'Zalo' then 'Zalo'
    when ua ~* 'FBAN|FBAV|FB_IAB' then 'Facebook'
    when ua ~* 'Instagram' then 'Instagram'
    when ua ~* 'Line/' then 'LINE'
    when ua ~* 'MicroMessenger' then 'WeChat'
    when ua ~* '; wv' then 'Android WebView'
    when ua ~* 'Edg/|EdgiOS/|EdgA/' then 'Edge'
    when ua ~* 'Firefox/|FxiOS/' then 'Firefox'
    when ua ~* 'Chrome/|CriOS/' then 'Chrome'
    when ua ~* 'Version/.*Safari/' then 'Safari'
    else 'unknown' end;
  return new;
end $$;
revoke all on function salon_private.capture_browser_hint() from public,anon,authenticated;
create trigger punches_browser_hint before insert on public.punches
for each row execute function salon_private.capture_browser_hint();
comment on column public.punches.browser_hint is 'Browser hint derived from request User-Agent; spoofable, not a verified device or identity. Unknown for historical/manual entries.';
