# Bucket 5.1 Runbook — Database Foundation

Time needed: ~20 minutes. Everything happens in your own Supabase dashboard and GitHub account — no credentials ever leave your hands.

## Golden rules before starting

1. **Never share the `service_role` key with anyone or paste it into any chat** — it bypasses every security rule we're about to create. The only values you'll ever need to share for the front-end build are the *Project URL* and the *anon public* key, both of which are designed to be public.
2. Run the SQL files **in order**: 01 → 02 → 03. Order matters (security policies reference tables; seeds reference both).

## Step 1 — Run the schema

Supabase dashboard → your project → **SQL Editor** → **New query** → paste the full contents of `01_schema.sql` → **Run**. Expected result: "Success. No rows returned."

## Step 2 — Run the security layer

New query → paste `02_security.sql` → Run. Same expected result. From this moment, anonymous clients can touch nothing directly, and authenticated users see nothing unless they exist in the `managers` table.

## Step 3 — Edit, then run the seed

Open `03_config_seed.sql` in a text editor first:
- Replace the shop names with the salons' real names.
- Uncomment the employees block and fill in the real roster — name, last 6 phone digits, opening PTO balance from the accountant. (You can also add employees later through the app; this just saves 17 clicks.)
- Leave the managers block commented for now — that's Step 4.

Paste the edited file → Run.

## Step 4 — Create manager accounts

1. Dashboard → **Authentication** → **Users** → **Add user** → create one account per manager (their email + a strong password you hand them privately). Create your own owner account too.
2. **Disable public signups** so strangers can't self-register: Authentication → Sign In / Providers → Email → turn off "Allow new users to sign up". (Even if someone did sign up, they'd have no `managers` row and see nothing — this is belt-and-suspenders.)
3. Back in the Users list, copy each user's **UUID**.
4. SQL Editor → new query → the managers insert from the bottom of `03_config_seed.sql`, with real UUIDs and names → Run. Your account gets `role = 'owner'`, `shop_id = null`; each store manager gets their shop's id.

## Step 5 — Verify (the checkpoint)

Run the verification queries at the bottom of `03_config_seed.sql`. Pass criteria:
- `config` has 9 rows; `shops` shows your two salons (each with a generated `kiosk_key`); `employees` matches your roster count.
- The `pg_class` query shows `relrowsecurity = true` for every listed table.
- The final `insert into punches` **fails** — read the error. If it says *"This table is append-only"* your triggers work; if it says a permissions/RLS error, that's also a pass (blocked even earlier). If it *succeeds*, stop and report back — something didn't apply.

## Step 6 — GitHub repo (2 minutes, for Bucket 5.3)

Create a repository named `salon-timekeeper` (public — required for free GitHub Pages, and fine: the front-end will contain only the anon key, which is public by design). Upload the four `bucket5/` files into a `db/` folder so the schema is version-controlled from day one. The application code arrives in Bucket 5.3.

## Step 7 — Collect two values for the next bucket

Dashboard → **Settings** → **API**: copy the **Project URL** (`https://xxxx.supabase.co`) and the **anon public** key. You'll paste these into the front-end config in Bucket 5.3. These two are safe to share. The `service_role` key on the same page is the one that never leaves the dashboard.

---

**Checkpoint report:** reply with (a) the row counts from Step 5, (b) confirmation the forbidden insert failed, and (c) any step that didn't match this document. Then Bucket 5.2 begins: the server-side functions — token minting and redemption, punch recording, corrections, and leave logic.
