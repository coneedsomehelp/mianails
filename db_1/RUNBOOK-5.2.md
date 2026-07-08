# Bucket 5.2 Runbook — Server Functions

Time needed: ~15 minutes. One SQL file to run, then a full check-in/check-out simulated end to end from the SQL Editor — you'll watch a punch travel the exact path an employee's phone will use.

## Step 1 — Run the functions

SQL Editor → new query → paste all of `04_functions.sql` → Run. Expect "Success. No rows returned." This creates the five public entry points (kiosk rotation, scan, whoami, punch, leave×3) plus locked internal helpers, and grants execution to anonymous clients — the *only* thing anonymous clients can now do.

## Step 2 — Grab your test ingredients

```sql
select id, name, kiosk_key from shops;                       -- note shop 1's kiosk_key
select name, login_code from employees where active limit 3; -- pick one login_code
```

## Step 3 — Simulate a full check-in (paste each block, in order)

```sql
-- A. The door tablet rotates its code
select kiosk_rotate(1::smallint, '<kiosk_key>'::uuid);
-- expect: {"code":"ABC234","ttl":60} — note the code

-- B. An employee "scans" (device_uuid = any random uuid for testing)
select scan_start(1::smallint, '<code from A>', gen_random_uuid());
-- expect: {"ok":true,"session_id":"..."} — note the session_id

-- C. They type their 6 digits — identity + live status, session NOT consumed
select whoami('<session_id>'::uuid, '<login_code>');
-- expect: ok:true, their name, checked_in:false, minutes_today:0

-- D. They press the button — the punch
select punch('<session_id>'::uuid, '<login_code>');
-- expect: ok:true, type:"in", server ts, state.checked_in:true

-- E. Single-use proof: fire D again with the SAME session_id
select punch('<session_id>'::uuid, '<login_code>');
-- expect: {"ok":false,"error":"session_used"}  ← this failure is a PASS

-- F. Check out: repeat A→B→D with a fresh code and session
--    expect type:"out" and minutes_today > 0

-- G. Wrong inputs behave politely (no exceptions, structured errors):
select scan_start(1::smallint, 'XXXXXX', gen_random_uuid());   -- code_invalid
select whoami('<used session_id>'::uuid, '<login_code>');      -- session_used
select punch('<any live session>'::uuid, '999999');            -- employee_not_found
```

## Step 4 — Simulate the leave flow

```sql
select leave_get('<login_code>');
-- expect: balance = opening + 2.5 × months − 0, empty lists

select leave_request('<login_code>', current_date + 7, current_date + 8, null, 'test request');
-- expect: {"ok":true,"days":2}

select leave_request('<login_code>', current_date + 7, current_date + 7, 'am', null);
-- expect: {"ok":false,"error":"overlap"}   (inside the range above — correct rejection)

select leave_get('<login_code>');            -- the request now shows under "pending"
-- cancel it with the id from the pending list:
select leave_cancel('<login_code>', '<leave_id>'::uuid);
```

## Step 5 — Verify the ledger recorded reality

```sql
select e.name, p.type, p.ts, p.shop_id, p.device_uuid, p.ip
from punches p join employees e on e.id = p.employee_id
order by p.ts;
```

You should see your test punches with server-assigned timestamps and the device UUIDs you generated. (`ip` will be null when called from the SQL Editor — it's captured from API-gateway headers, so it populates once real phones call through the API in 5.3.)

## Step 6 — Clean up test punches

```sql
alter table punches disable trigger punches_immutable;
delete from punches;
alter table punches enable trigger punches_immutable;
delete from leave where note = 'test request' or status = 'cancelled';
delete from sessions;
```

---

**Checkpoint report:** confirm (a) the full A→F cycle produced an "in" then an "out" with minutes counted, (b) step E returned `session_used` — the single-use lock working, and (c) the leave request → overlap rejection → cancel sequence behaved as written. Anything that deviates, paste the output.

**Then Bucket 5.3:** the front-end port — your trial-tested UI with the storage layer swapped for these functions, the kiosk driven by `?shop=1&key=<kiosk_key>` URL parameters, device fingerprinting, and manager login — deployed to GitHub Pages. That's the bucket where a real phone scans a real tablet for the first time.
