-- Run after migration, inside BEGIN/ROLLBACK. No employee records are touched.
create temporary table browser_probe(session_id uuid,browser_hint text);
create trigger probe before insert on browser_probe for each row execute function salon_private.capture_browser_hint();
do $$
declare hint text; pair text[];
begin
  foreach pair slice 1 in array array[
    ['Mozilla Zalo/1.0','Zalo'],['Mozilla Chrome/120 Safari/537','Chrome'],
    ['Mozilla Version/17 Safari/605','Safari'],['mystery','unknown'],
    ['Mozilla; wv Chrome/120','Android WebView'],['Mozilla FBAN/test','Facebook']
  ] loop
    perform set_config('request.headers',jsonb_build_object('user-agent',pair[1])::text,true);
    insert into browser_probe values(gen_random_uuid(),'spoofed') returning browser_hint into hint;
    assert hint=pair[2], 'Browser classification mismatch';
  end loop;
  insert into browser_probe values(null,'Zalo') returning browser_hint into hint;
  assert hint='unknown','Manual edits cannot inherit the owner browser';
  perform set_config('request.headers','',true);
  insert into browser_probe values(gen_random_uuid(),'Zalo') returning browser_hint into hint;
  assert hint='unknown','Missing headers must be unknown';
  assert not has_function_privilege('anon','salon_private.capture_browser_hint()','execute');
  assert (select relrowsecurity from pg_class where oid='public.punches'::regclass);
end $$;
