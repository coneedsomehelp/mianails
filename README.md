# Salon Timekeeper — Chấm công · Pointage

Time-clock and leave-management app for the nail salons. One static page, no build step, backed by Supabase.

## Layout

- **`index.html`** — the whole app: door-tablet kiosk (`?kiosk=1&shop=N&key=UUID`), employee punch/leave flow, and the manager dashboard. Deploy it to any static host; bump the `BUILD` constant on every deploy so open tabs show the update banner.
- **`db_1/`** — the Supabase side: numbered SQL files (run in order in the SQL Editor) plus the runbooks (`RUNBOOK-5.1.md`, `RUNBOOK-5.2.md`) that walk through setup and end-to-end testing.

## Security model (short version)

Employees are anonymous clients: they can only execute the RPC functions in `04_functions.sql` (and the additive ones in 10/11/12/14), each of which validates its own inputs. Managers sign in with Supabase Auth and get row-level-security access gated by the `managers` table. Punches and corrections are append-only — enforced by triggers in `01_schema.sql`.

The `SUPABASE_URL` and anon key in `index.html` are public by design. Never put the `service_role` key anywhere in this repo.

## Policy constants

Business rules (full-day minutes, PTO accrual rate, QR rotation timing, …) live in the `config` table (`03_config_seed.sql`). The admin UI reads `full_day_min` and `pto_rate_per_month` from there at load; the anonymous employee screen uses the RPCs, which read config server-side.
