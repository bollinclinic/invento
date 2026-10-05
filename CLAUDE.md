# CLAUDE.md — Bollin Clinic Stock Manager

Guidance for Claude Code (and any future maintainer) working on this project. Read this
before making changes. The app is a **single-file** web app (`index.html`) on GitHub Pages,
backed by **Supabase** (Postgres + Auth + RPC + Edge Functions). The Theatre & Ward screen
also writes to a **SharePoint Excel** file through a Cloudflare Worker. The original Google
Sheets / Apps Script backend is retired (`Code.gs` is kept for reference only).

> **This repo is public.** GitHub Pages serves every tracked file, including this one, at
> `bollin.hashirhub.uk/<path>`. Never commit passwords, service-role keys, real patient names,
> PAT numbers or DOBs: not in code, not in comments, not in docs, not in commit messages.
> Secrets live in the git-ignored `secrets/` folder. Test fixtures use fictional patients.

---

## 1. What this is

An operational inventory + theatre-management tool for **Bollin Clinic**, an aesthetic
surgery clinic in Altrincham, UK. It is used daily by clinical staff (nurses, scrub team,
ODPs) and by the clinic manager. The maintainer/owner is **Yasar** (a nurse at the clinic).
The clinic manager is **Ruby**, who owns the theatre rota.

The app must be **production-grade and regression-free**: real patients, real stock, real
theatre lists depend on it. The working mantra throughout the build has been:
**"no guesswork, hard check, smoke test everything."**

---

## 2. Working principles (non-negotiable)

1. **Hard-check before editing.** Never assume file structure. Grep/read the actual current
   state first. Version drift between edits has repeatedly caused bugs.
2. **Full implementation per turn.** No placeholders, no partial edits, no "TODO".
3. **Smoke test everything** with data shapes that match *production*, not just tidy test
   data. Several severe bugs only appeared with real-world data (see §9).
4. **`node tests/run_all.js` on every change**, and extend the relevant suite for each fix.
   Parse-clean is not enough: a runtime error on load blanks the whole SPA (§9 #5).
5. **Never break existing features.** Any introduced regression is a blocker. Multi-part
   requests are addressed in full, in one turn.
6. **Staging first, always.** Test on staging before production. Never deploy straight to
   prod. **Never push to production without Yasar's explicit go-ahead.** Ask whether a live
   list is running first. Pushing mid-list is safe for data, but open devices keep the old
   code until refreshed.

---

## 3. Architecture

- **Frontend:** one file, `index.html` (~9,300 lines): HTML + CSS + vanilla JS, no build
  step, no framework. CDN libs: supabase-js v2, jsPDF + autoTable, JsBarcode, qrcodejs. A
  single `render()` swaps `#main` innerHTML based on `currentView`; `nav(view)` routes;
  state lives in a global `state` object; `loadAll()` fetches everything.
- **Data layer:** the old `api({action:'x', ...})` call shape was **kept** at every call site;
  only `api()`'s internals changed (the dispatcher in the "Supabase data layer" section) to
  call `sb.rpc(...)` / `sb.from(...)`. Translators (`itemToSheetRow`, `fieldsToItemRow`, …)
  map Postgres snake_case rows to the old Sheet-header PascalCase shapes. `_row` on every
  record is now the row's **uuid**.
- **Backend:** Supabase. Schema, RLS policies and ~45 RPC functions live in
  `supabase/migrations/*.sql` (applied in filename order). Multi-step writes are
  `SECURITY DEFINER` RPCs that check `app_role_rank()` themselves.
- **Edge Functions** (`supabase/functions/`):
  - `create-user` and `manage-user` (reset password, rename) need the service-role key, so
    they run server-side and verify the caller is an active `developer` first.
  - `sms-dispatch` sends rota texts (see "Rota texts pipeline" below).
- **Auth:** Supabase Auth. Staff log in with a **username**; the app turns it into a
  synthetic email `username@bollin.local` (`synthEmail`). Role and active flag live on
  `profiles`. `app_role_rank()` returns -1 for an inactive profile, so deactivation takes
  effect everywhere at once, including already-open sessions.
- **Rota texts pipeline:** texts go from the **clinic's own Android phone** (SIM with
  unlimited texts), running the open-source *SMS Gateway for Android* app (sms-gate.app,
  cloud mode).
  - **Queueing:** `rota_sms_queue` (a superadmin pressed Send) writes rows to
    `sms_messages`.
  - **Sending:** a **pg_cron** job calls `sms-dispatch` every minute with an
    `x-dispatch-secret` header (via pg_net; the secret is in Supabase Vault). The function
    claims due rows, hands them to the gateway, and polls the gateway for
    sent/delivered/failed.
  - **No double texts:** the gateway message id = our `sms_messages.id`, and the gateway
    returns 409 for a duplicate id, so a retry can't double-text.
  - **Secrets** (Edge Function secrets, never in the repo): `DISPATCH_SECRET`, `SMS_MODE`
    (`live` sends; anything else is a dry run, which is the default), `SMS_ALLOWLIST`
    (staging: the only numbers really texted), `SMS_GATEWAY_USER` and `SMS_GATEWAY_PASS`.
    Texts expire after 12 h if the phone is offline.
  - **The cron job is created by hand** per project from `supabase/manual/sms_cron_setup.sql`
    (placeholders replaced in a local copy that is then deleted). It is **never** a
    migration, because migrations are public. To stop all sending at once, run
    `select cron.unschedule('sms-dispatch');`.
- **Theatre & Ward pipeline (not Supabase):** `THEATRE_WORKER_URL`
  (`bollin-theatre-proxy.bollinclinic.workers.dev`) is a Cloudflare Worker → Microsoft Graph →
  SharePoint Excel `Table1` (23 columns, mapped by `TW_COL`). The Worker has no delete action;
  orphan rows must be removed by hand in Excel. **Staging uses the same Worker, so Theatre &
  Ward entries made on staging land in the REAL SharePoint file.**
- **Hosting:** GitHub Pages.
  - Production: repo `bollinclinic/invento` (git remote `origin`), branch `main` → custom
    domain `bollin.hashirhub.uk` (Cloudflare CNAME, **DNS-only / grey cloud**).
  - Staging: repo `bollinclinic/invento-staging` (git remote `staging`) →
    `bollinclinic.github.io/invento-staging/`.
- **Supabase projects** (CONFIG in `index.html` holds the URL + public anon key):
  - Production "bollinclinic's Project", ref `ozkragagmtdjjlkvygjc`.
  - Staging "invento-staging", ref `ozlskwtbgblfmqjgcrmf`.
- **Scanning:** a Netum USB barcode scanner acting as a **keyboard wedge** (HID keyboard
  input, NOT a camera). A global keydown handler buffers fast keystrokes ending in Enter.
  The clinic's Netum reads **both barcodes and QR codes** (confirmed by Yasar, 2026-10-06; an
  earlier note here said 1D only, which was wrong for their unit).

### Deploy flow

**Frontend** (most changes):
1. Edit `index.html` only. Never hand-edit `index_STAGING.html`.
2. `node tests/run_all.js`: all suites must pass.
3. `bash sync-staging.sh`: regenerates `index_STAGING.html` (staging title, staging
   Supabase URL/key). Commit both files.
4. `bash deploy-staging.sh`: force-pushes a temporary branch to the `staging` remote's
   `main`. Verify on the staging URL. **Commit first:** the script switches branches and
   copies over `index.html`, so uncommitted edits to it would be lost.
5. Only after Yasar's go-ahead: `git push origin main`. Then confirm the Pages build
   (`gh api repos/bollinclinic/invento/pages/builds/latest`) and that the live
   `bollin.hashirhub.uk` file matches the pushed `index.html`.

**Database** (schema/RPC changes): add a new timestamped file in `supabase/migrations/`.
Never edit an applied one. The Supabase CLI isn't on PATH; it lives at
`%LOCALAPPDATA%\supabase-cli\supabase.exe`. **The project folder is normally linked to
PRODUCTION.** Sequence: `supabase link --project-ref ozlskwtbgblfmqjgcrmf` (staging) →
`supabase db push` → test (RPC tests via `supabase db query --linked`, impersonating a user
with `set_config('request.jwt.claim.sub', …)`, cleaning up test rows) → deploy the matching
frontend to staging → with go-ahead, `supabase link --project-ref ozkragagmtdjjlkvygjc` →
`supabase db push`. Always check which project is linked before any `db` command. If
`db push` fails part-way on a migration that has only reached staging, remove what it
created, run `supabase migration repair --status reverted <version> --linked`, fix the file
and push again.

**Edge Functions:** `supabase functions deploy <name> --project-ref <ref> --use-api`
(bundled server-side, so no Docker is needed), staging first. Functions not called by a
signed-in user need `verify_jwt = false` in `supabase/config.toml` and must check their own
secret.

**Shell gotcha (Windows):** never name a shell variable `TMP` or `TEMP`. On Windows these are
the system temp-folder settings, and changing them makes the Supabase CLI fail with a
misleading "Access token not provided".

---

## 4. Feature inventory (what exists today)

**Stock trackers** (6): medicines, consumables, garments, instruments, linen, **services**.
Services are billable techniques with a `bill_price` and are never decremented. Each item:
code, barcode, name, category, supplier, location, unit, qty, reorder level, unit cost,
bill price, expiry, batch, status, notes, obsolete flag. Instruments also have qty-in-tray and
cycles-to-date. Scanning an item opens a stock-movement dialog; unknown barcodes can be
linked to an item. Superadmin+ can bulk-edit category/location/supplier, bulk-generate
barcodes (13-digit, collision-checked) and bulk-obsolete.

**More than one scan code per item** (migration `20261006100000_item_extra_barcodes.sql`), so
staff can scan either the maker's barcode on the product or the clinic's printed code:
- `items.barcode` is the **main** code (what a sticker prints). Further codes live in
  `item_barcodes` (item_id, barcode; one code → one item across all trackers; max 10 per item).
- A scan matches the main barcode or item code first, then extras (`scanExtraIx`). Extras are
  held on each item as `extraCodes`, **not** as item indexes, which go stale on delete/reload.
- **Linking adds, never replaces** (`itemLinkCode` → RPC `link_barcode`, any active user). The
  server answers `primary` (item had no barcode), `extra` or `same`, and refuses a code that
  already belongs to another item as its barcode, item code or extra. Not optimistic.
- The item edit box has **Other codes**: add (scan or type) and remove (admin+,
  `item_barcode_remove`), saved at once, not with "Save changes".
- **Sterilisation items keep a single code**: that workflow is keyed on the tray code.
- A trigger on `items` stops a barcode/code being set to another item's extra, and drops an
  item's own extra if it becomes its main barcode.
- `item_barcodes` has RLS on and **no policies**: it is reached only through
  `get_item_barcodes()` (one jsonb value, so the 1000-row cap can't truncate it) and the RPCs.
- **One-click codes** (superadmin+): Sticker printer → Barcode / QR shows "＋ Give the N
  without a barcode a code" (`stkAssignMissing` → `item_assign_missing_barcodes`). It never
  replaces an existing barcode, unlike the tracker's "Generate new barcodes".

**Stores / offsite** (admin+): stores list and transfers (whole item or a quantity).
Stock moved to `MS Offsite Store` is **invisible everywhere in active inventory** (trackers,
dashboard, stock value, procedure scanning, stocktake) until moved back. It appears only in
the Offsite tab. Applies to the 4 non-instrument trackers.

**Dashboard**: low / out / expiring-within-90-days counts, plus a "Theatre & Ward today"
shortcut. Also: stock requests, alerts, stock value explorer, obsolete stock, activity log
(filterable PDF), stocktake (month-end/annual; a physical stock-take sheet for superadmin+),
barcode/label printing, assets register (admin), gas room daily checks.

**Sterilisation workflow**: instruments go **used → dispatched to CSSD → received back**.
Tabs: Log used, Dispatch, Receive, On hand, History, each with **one** search box (§9 #4).
On-hand rows open a detail dialog; admin can edit or delete (identity-guarded). Already-sterile
items can be added directly to on-hand (user enters expiry); the normal flow auto-sets
expiry = dispatch date + 1 year.

**Procedure case costing** (all roles; financials admin+):
- **Concurrent: one open case per room** (`PROC_ROOMS`: Theatre 1, Theatre 2, Minor ops),
  selectable via room tabs. Scanning adds to the room on screen.
- Items sit in a cart. Stock is NOT decremented until the case is **ended**. Ending is one
  atomic RPC, `proc_consume_batch`: consume stock, record cost + bill lines, close the case.
- The cart auto-saves to the server (`proc_save_cart`). Manual "Save progress" sorts A→Z;
  autosave never reorders.
- Surgeon comes from the canonical **surgeon picker** (`surgeons` table + `surgeon_id`), so
  names can't fragment. Anyone can add a new surgeon.
- Admin can edit meta, reopen (returns stock) or delete (returns stock) a case.
- Developer-only extras: **pre-fill from past case** (`proc_find_prefill_case`: the same
  surgeon's latest closed case for that procedure), **Surgeon billing report**
  (`billing_report`, uses `bill_price`, which is unrelated to `unit_cost`) and **Item usage
  search** (`item_usage_report`).

**Sticker printer** (all roles): 21-per-A4 label sheets (3×7, 64.5mm × 40mm cells).
- **Patient stickers**.
- **Medication labels**: drug + optional diluent, pen blanks, Prepared-by / Checked-by
  boxes. Shared presets are stored in settings.
- **TTO / discharge**: 13 take-home labels with dotted pen blanks for counts and dosing.
- **Barcode / QR**: pick items by tracker, location, category, search and a **barcode filter**
  ("No barcode yet" / "Has a barcode", meaning the item's own `barcode` field is filled). One
  function, `stkCodesList()`, feeds the list, the count and "Tick all shown". A sticker encodes
  `barcode || code`, and a code is generated only when an item has neither.

Text that can overflow auto-shrinks rather than clipping.

**Implant logging** (staff+): order → delivered → used, with a PDF status report. This
report is the **canonical PDF style** (§8).

**Sample collection**:
- A collection (patient visit: date collected, initials, PAT, surgeon) has one or more
  specimens (details, category, formalin).
- Status workflow **Collected → Sent → Result received**. Each step auto-stamps time + user
  (`sample_advance_status`).
- Everyone can view and advance status; creating/editing is staff+; deleting is admin+.
- Search by PAT/initials/surgeon/details. PDF by day/week/month/surgeon/search.

**Clinical monitoring** (all roles; sidebar: Checks; view `monitor`, `monitorView`): the old
stand-alone "Clinical Monitoring Hub" page (`temperature-checklist.html` in the public repo
`bollinclinic/bollinclinic`) rebuilt inside the app at Yasar's request, **still saving to the
same Google Sheet** (his choice over moving it to Supabase).
- **Tabs:** Temperature (5 rooms), Fridge (5 fridges), Fluid warmer, Hand hygiene audit
  (observations by staff category and the 5 moments, compliance %, CSV backup), Theatre
  cleaning (pre/post-surgery checklists per theatre, plus "not in use" date ranges), and
  Sent today.
- **Not Supabase.** Each submit is a `no-cors` POST to the Google Apps Script `MON_SHEET_URL`,
  which writes the Sheet. That URL is not a secret: it has always been in the public old page.
- **The payloads must stay exactly as the old page built them** (keys, key order, room and
  reading labels, `OK` / `Warning` / `Out of Range`, `Pre-Surgery` / `Post-Surgery`). The Apps
  Script only knows those shapes and nobody here can see its code. `MON_TEMP`, `MON_FRIDGE`,
  `MON_FLUID`, `MON_CLEANING` are copied from the old page; changing a label changes what
  lands in the Sheet.
- **What the app can and can't know:** the reply to a `no-cors` request is unreadable. A
  network failure is caught (form kept, "Not sent"); a refusal by the script is invisible. So
  the wording is "Sent", never "Saved". The app cannot read the Sheet either: **Sent today**
  is only what this device sent today (localStorage `bollin_mon_sent`).
- **Deliberate differences from the old page:** the signed-in person's name is pre-filled; a
  name and at least one reading are required; a failed send keeps the form; Submit can't
  double-send; the hand hygiene session clears after sending (its CSV is still offered); and
  "not in use" ranges include every day (the old page dropped the last day of a range that
  crossed a clock change).
- Form state is the top-level `mon` object (like `gas`), so typing survives a re-render.
  Reading boxes are patched in place (`monReading`), not re-rendered, to keep the cursor.
- **Staging posts to the REAL Sheet** (as Theatre & Ward does with SharePoint); the page says
  so on staging. Demo mode never posts (`monCanSend`).

**Theatre & Ward timings** (all roles):
- **Theatre** form: patient, procedure, surgeon(s), SFA, anaesthetist/type, and the timing
  chain from time sent to discharge.
- **Ward** form, plus a "currently in recovery" list.
- **Per-room instances** (`TW_ROOMS`: Theatre 1, Theatre 2, Minor Op Room). Each room has
  its own lookup, draft and write queue. Ward has a single instance.
- **Drafts** (localStorage, per room) keep only fields that differ from what's showing, plus
  `_pid`. A lookup that finds a record discards any draft that isn't that same patient's.
- **Autosave only UPDATES a row it has confirmed exists.** Only the explicit Save buttons
  may add a row, after a lag-tolerant recheck (§9 #9).
- Details: `bollin-clinic-project-notes.md` (git-ignored, local only).

**Theatre rota** (superadmin+): replaces Ruby's transposed spreadsheet.
- **Views:** weekly, monthly (calendar grid with gap badges and ★ provisional counts) and
  custom range.
- **Theatres:** 0–2 per day. Per theatre: GA/LA type, colour, **"List starts" time**, detail
  line, up to 3 surgeons, anaesthetist/SFA/scrub 1–3/ODP, **per-theatre HCA and recovery
  nurse/ODP**, and a case list (surgeon / procedure / stay -- **no PAT numbers**: removed on request
  2026-09-30; migration `20260930220000_rota_remove_pat.sql` deleted stored ones and a trigger on
  `rota_theatres` strips any `pat` key, and the page drops it on load and save).
- **Which theatre on a one-list day:** the day dropdown is "No lists / 1 theatre — Theatre 1 /
  1 theatre — Theatre 2 / 2 theatres". `rota_days.theatres` is still the count;
  `flags.only = 2` means the single list runs in Theatre 2, and its data lives in `t2`.
  **Always loop over `rotaRunning(day)`** (`[]`, `[1]`, `[2]` or `[1,2]`), never `1..theatres`.
  Switching a one-list day between theatres moves the whole list, with its ★, own times, Lead
  tick and cover notes (`rotaSwapTheatres`). `rota_sms_slots()` applies the same rule.
- **Case surgeons follow the list** (`rotaSyncCaseSurgeons`, `rotaCaseSurgeonField`):
  - With one surgeon on the list, every case that is empty or names someone off the list gets
    that surgeon automatically (new cases, a swapped surgeon, and older days on first edit).
  - With 2–3 surgeons, each case's surgeon is a dropdown of just those surgeons; nothing is
    guessed.
  - With no surgeon yet, the normal surgeon search is used.
  - A case naming someone not on the list is kept and flagged "(not on this list)".
- **Expected start for the 2nd / 3rd surgeon:** 🕐 on those boxes (the same clock picker),
  stored in `rota_days.times` (`t1.surgeon2` …). The 1st surgeon starts at the list start. It
  shows as "Expected from 10:30" on the rota, as an "Expected: … from 10:30" line under the
  Day PDF ribbon, and as "Name (from 10:30)" in week/month/range PDFs. Surgeons are never
  texted.
- **Lead scrub and "both theatres"** (`rota_days.flags`; never typed into a name box, because
  that makes two spellings of one person and breaks the staff-list match):
  - **Lead:** a tick under each named Scrub. One Lead per day (`flags.lead` = slot key).
  - **2 theatres:** a tick under theatre-team names on two-theatre days (`flags.both[slotKey]`).
    The same slot in the other theatre then counts as covered (`rotaSharedFrom`), so it is not a
    gap, and shows "Covered by …".
  - Both are cleared when a different person is put in the box.
  - PDFs show "Name (07:30) — LEAD" and "Name (07:30) (both theatres)", the latter under both
    theatres (`rotaTeamName`). Texts say "Scrub 1 - Lead" and "Theatre HCA (Theatres 1 and 2)".
- **Day cover** roles, including HCA night.
- **Gap detection:** LA lists don't require an anaesthetist, ODP or SFA. Gaps can be silenced
  with per-day cover notes, and every name slot has a ★ provisional flag.
- **Staff search** and **PDFs** (week/month/range/staff/day). ⧉ copies last week's weekday.
- **Saving** is one atomic, version-checked RPC, `rota_save_day`: a stale save is refused,
  never silently applied (§9 #8).

**Rota texts (SMS)** (superadmin+): texts rota staff from the clinic's own phone. **Nothing
is ever sent automatically; this is a firm rule from Yasar.**
- **Textable slots** (`ROTA_SMS_T_KEYS` / `ROTA_SMS_D_KEYS` in `index.html`, which must match
  `rota_sms_slots()` in the database):
  - per running theatre: Scrub 1–3, ODP, SFA / practitioner, Theatre HCA, Recovery nurse /
    ODP;
  - day cover: Ward nurse, HCA — ward, Night nurse, HCA night, RMO — day, RMO on site — night.
  - **Not textable (Yasar's choice):** surgeons (they keep the surgeon picker), anaesthetist,
    housekeeping AM/PM and reception AM/PM.
  - Role names in texts are plain ASCII ("Ward HCA", "RMO on site (night)"), because one
    non-GSM character (like "—") cuts a text from 160 to 70 characters.
- **Start times (required):** every confirmation says when the person starts (`{start}`).
  - Theatre staff get their theatre's "List starts" time from the rota.
  - Day-cover roles get their usual time, set once in Text settings (setting
    `sms_default_times`, JSON keyed by slot, e.g. `{"nightNurse":"19:30"}`).
  - **Own time per person:** the 🕐 button next to a textable name's ★ opens a **clock
    picker** (`timePickerOpen`, `#timeDlg`). It has one-tap "list +30 min … +3 h" buttons,
    common times, an exact time box, and "Use normal time". The chosen time is that person's
    own start for the day (e.g. Recovery starting later than the list). It is stored in
    `rota_days.times` (keyed by slot, like `stars`), shows under their name, and is dropped
    when a different person is put in that box.
  - **Night team time:** "🌙 Night team starts" (Day cover heading, same picker) sets Night
    nurse, HCA night and RMO night at once. It is stored as `rota_days.times.nightTeam`, so
    `rota_save_day` is unchanged by it.
  - **Precedence:** own time > night team time (night roles only) > theatre "List starts" /
    usual time. Frontend helpers are `rotaSlotOwnTime` / `rotaSlotBaseTime` / `rotaSlotTime`;
    they mirror `rota_sms_slots()`.
  - **PDFs:** Day, week, month and range PDFs show "Starts HH:MM" per theatre and times for
    ward, night and RMO names (`rotaNameWithTime`). The **Day PDF** shows every theatre-team
    member's start time next to their name (`allTimes`: SFA, Scrub 1–3, ODP, Theatre HCA,
    Recovery). Week, month and range PDFs add a time there only for own times. Anaesthetist,
    surgeons, housekeeping and reception never show a time.
  - No time means the person can't be ticked (`no_start_time`), and the dialog says where to
    fill it in.
  - If a start time changes after someone was texted, the post-save prompt **offers** an
    updated confirmation ("told 07:30, now 08:00"). A scheduled text whose time is out of date
    is held at send time.
  - The confirmation wording must contain `{start}`.
- **Confirmations:** "✉ Message staff" (next to Save/Edit day; enabled only for a saved day
  with no unsaved changes) opens a tick-list of that day's people. Confirmed means named with
  no ★. Provisional, not-in-list, no-mobile and not-opted-in people can't be ticked. You
  choose "Send now" or "Schedule for" (pre-filled with 18:00 the evening before).
  - A schedule time that has passed is refused.
  - "Send now" at night (22:00–07:00) asks whether to send anyway or schedule for 07:00.
- **Cancellations:** after a save, if someone already texted is no longer confirmed
  (removed, replaced or ★'d; moving slots on the same day doesn't count), a prompt
  **offers** to send a cancellation, or to cancel their unsent text. "Not now" leaves a ⚠ chip
  on the day.
- **Safety net:** at send time the server **holds** (never sends) a confirmation for someone
  no longer confirmed, a cancellation for someone confirmed again, or any text to someone
  deactivated or opted out.
- **Staff picker:** every rota name box except surgeons and anaesthetist uses a staff picker
  (`rotaStaffSlot`, modelled on the surgeon picker, which is untouched). That includes
  housekeeping and reception, which are in the staff database but never texted and have no
  time controls. Typing a new name opens the add form straight away. If that is cancelled, the
  name is saved as typed and flagged "Not in the staff list · Add".
- **Who:** only superadmin+ can see or use any of this, in the UI (`isSuperadmin()`) and on the
  server (RLS and RPCs at `app_role_rank() >= 3`).
- **Text log keep period:** 30 days after the shift by default (setting `sms_log_keep_days`,
  7–365). It can be changed in Text settings → Recent texts by superadmin/developer only,
  via `sms_set_log_days()` (the general settings table is admin-writable, so this has its own
  gate). `sms_purge_old()` runs hourly from `sms_claim_due`. It never clears a future shift's
  texts (needed for the cancellation check) or anything scheduled or sending.
- **Clinic phone:** the SMS Gateway for Android APK comes from GitHub releases
  (github.com/capcom6/android-sms-gateway). In the app: grant SMS permissions → Settings →
  System → turn off battery optimisation → toggle "Cloud Server" → tap "Offline" so it shows
  "Online" → the username and password appear in the Cloud Server section. Put those into
  `secrets/`, then set them with `supabase secrets set` (`SMS_GATEWAY_USER`/`PASS`). Set
  Settings → Messages → "Delay between messages" (a few seconds) to stay under Android's
  sending limit. The phone can be carried: it only needs to be switched on with signal or
  data. Texts wait while it's offline and expire after 12 h.
- **Staff database and Text settings:**
  - **👥 Staff database** is its **own page** (view `rotastaff`, `rotaStaffView`), reached from
    a **collapsible child item under Rota in the sidebar** (`a.navsub#navRotaStaff`; the caret
    on Rota calls `toggleRotaSub`; state in localStorage `bollin_rota_sub`; `applyRotaSub` opens
    it on the Rota page unless the user collapsed it, and always on its own page). Yasar asked
    for this explicitly: it must **not** be an inline section of the rota page. The rota page
    only shows a one-line notice (`rotaUnlistedNotice`) when names on the rota aren't in the
    database. Use `navGo(view)` to go to a sidebar page from code.
    One row per person (Name, Works as, Mobile, Active yes/no, Texts), with search, a filter by
    job role and status, and sorting by name or role. It covers everyone except surgeons and
    anaesthetists.
    - People can be **added** here or from a rota box. **Edit and Delete are only here.**
    - It lists names that are on the rota but not in the database, each with an Add button
      (`rotaUnlistedNames`).
    - **Rename follows through:** `staff_upsert` calls `rota_rename_person`, so a corrected
      name is corrected in every staff box on every rota day, and those days' `updated_at`
      moves. The page blocks a rename while rota days are unsaved, then reloads.
    - **Delete** (`staff_delete`): the name stays on rota days as typed, waiting texts to them
      are cancelled, and the log keeps past texts.
  - **✉ Text settings** (`rotaSmsSettingsPanel`, a collapsible panel that stays on the rota
    page): the usual start times for ward and night
    roles, the message wording (templates in `settings`, placeholders `{first_name}` `{day}`
    `{roles}` `{start}`, never patient details), a test text, and the recent-texts log.

**Users & roles** (developer only): list users, change role, activate/deactivate, create
accounts (`create-user`), reset password / rename (`manage-user`).

**Sidebar** (`<nav id="nav">`; Checks holds Gas room checks and Clinical monitoring):
- Eight section headers, in order: Overview, Trackers, Implants, Activity, Checks, **Stock**,
  **Records**, Admin. Each is a button (`.navsec[data-navgrp]`) that expands/collapses the
  `.navgrp#navgrp-<name>` after it, with a ▾ / ▸ chevron. All open by default; closed ones are
  remembered per device (localStorage `bollin_nav_closed`, read by `navClosedPref`; no
  top-level variable, §9 #5).
- **Stock and Records are section headers like the rest** (Yasar's explicit choice: not
  tab-style parents with indented children). Stock: Stocktake, Stock value, Item usage search,
  Obsolete stock, Stores & transfers (moved from Admin on request). Records: Procedure costing, Sample collection, Theatre & Ward, Services,
  Surgeon billing report, Item usage search. **Item usage search is in both on purpose**
  (Yasar listed it under each), so one page can have two links: `navMarkActive` (called by
  `nav()`) highlights both; the second has `navdup` and is hidden in the phone layout.
- The only indented child item is Rota > Staff database (`a.navsub`).
- `applyNavGroups()` hides a header when `viewAllowed` is false for every link in its group.
  Role gates are still only `viewAllowed`; moving a link never changes who sees it.
- Every link has a mask icon (`--icn`, 24px grid, stroke 2, drawn 18px). A new sidebar item
  needs its own `--icn` rule.
- Phone layout: headers are hidden and every allowed link sits in one scrolling row, whatever
  is collapsed.

**Themes / settings**: theme, accent, font, density, corners (cog menu, top-left).

---

## 5. Roles & permissions summary

Ranks: `common(0) < staff(1) < admin(2) < superadmin(3) < developer(4)`. The frontend has
`ROLE_RANK`/`roleRank()`, plus these helpers:
- `isAdmin()`: admin/superadmin/developer.
- `isSuperadmin()`: rank ≥ 3.
- `isDeveloper()`: rank ≥ 4.
- `isStaffPlus()`: rank ≥ 1.

`PERMS[role]` holds per-feature flags. The backend equivalent is `app_role_rank()` in RLS
policies and RPCs.

| Area | common | staff | admin | superadmin | developer |
|---|---|---|---|---|---|
| Trackers, procedures workflow, stickers, sterilisation view, Theatre & Ward, samples (view + advance status) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Unit cost / bill price visible (masked in `get_items`) | | ✓ | ✓ | ✓ | ✓ |
| Stocktake, implants, alerts, stock value, create/edit samples | | ✓ | ✓ | ✓ | ✓ |
| Add/edit items, labels, stores/offsite/services, obsolete, assets, procedure financials & admin controls, delete specimen | | | ✓ | ✓ | ✓ |
| Theatre rota, rota texts & staff mobiles, bulk item edit, physical stock-take sheet | | | | ✓ | ✓ |
| Users & roles, billing report, item usage, procedure pre-fill | | | | | ✓ |

Enforced in **two places**: `viewAllowed(view)` / `can()` on the frontend, and RLS + RPC rank
checks in Postgres (the real gate). Never rely on the frontend alone. When adding a role
gate, add it on **both** sides (§9 #6).

---

## 6. Data model (Supabase tables)

`profiles`, `items` (all trackers; `tracker` enum incl. `services`), `item_barcodes` (extra scan codes), `barcode_link_events`,
`dispatch_log`, `procedures` (`cart` jsonb, `room`, `surgeon_id`), `procedure_lines` (cost +
bill snapshots), `surgeons`, `rota_days`, `rota_theatres` (`cases` jsonb of {surgeon, procedure,
stay}; no PAT), 
`sample_collections`, `specimens`, `implants`, `stock_requests`, `activity_log`, `alerts`,
`assets`, `gas_checks`, `stores`, `settings`, `stocktakes`.

Rules:
- Dates are `date`/`timestamptz`; render in Europe/London. The old Sheets version stored
  rota dates as text specifically to dodge a UTC off-by-one, so keep date handling
  deliberate.
- `unit_cost` (the clinic's purchase price) and `bill_price` (the surgeon-group invoice rate)
  are **different numbers**. Never conflate them. Both are snapshotted onto
  `procedure_lines` at consumption time.
- Old `rota_days.hca_theatre` / `recovery_nurse` columns are kept for history; live data is
  per-theatre.

Rota texts (migrations `20260930100000_rota_sms.sql`, then
`20260930120000_rota_sms_more_roles.sql`, which added the extra textable roles, then
`20260930140000_rota_sms_start_times.sql`, then `20260930160000_rota_sms_hca_rmo_own_times.sql`,
then `20260930180000_rota_sms_night_team_time.sql`):
- **`staff`:** the directory. Name unique case-insensitively; mobile stored as `+447…`;
  `sms_opt_in`; `active`. Superadmin-read only, written via `staff_upsert`.
- **`sms_messages`:** the outbox and log. `kind` confirm/cancel/test; `status` scheduled →
  sending → sent/delivered, or failed/held/cancelled/dry_run. Superadmin-read only, written
  only by RPCs and the dispatcher.
- **`rota_theatres.start_time`** (`time`): the theatre's "List starts".
- **`rota_days.times`** (`jsonb`): per-person own start times keyed by slot, plus the day's
  `nightTeam` time.
- **`rota_days.flags`** (`jsonb`, migration `20261004100000_rota_lead_and_both_theatres.sql`):
  `{lead: slotKey, both: {slotKey: 1}}`. `rota_save_day` saves `FlagsJSON` and keeps the
  existing flags if an older page doesn't send it.
- **`rota_save_day`** was re-created identically apart from saving `T1_/T2_StartTime` and
  `TimesJSON`. An older page that sends neither still saves: the list time is left empty and
  the existing own times are **kept**, not wiped.
- **Slots still hold names as text,** and the server matches them to `staff.name`
  case-insensitively.
- **Tests:** `tests/sql/rota_sms_db_tests.sql` runs against staging and cleans up after
  itself.

The SharePoint Theatre Records Excel is **not** in Supabase (see §3).

---

## 7. History

The app started on Google Sheets + Apps Script (`Code.gs`, custom Users sheet + tokens) and
was rebuilt on Supabase in August 2026 (see the migrations from `20260818…`). The legacy data
was imported from sheet CSV exports. `START_HERE.md` and `CONVERSATION.md` are the historical
Sheets-era notes and may be out of date; this file is the current reference.

---

## 8. Reproducing behaviour that matters (subtle but important)

- **Numeric-looking values:** anything free-form must be `String()`-coerced before
  `.toLowerCase()` etc. (§9 #2). Postgres `text` columns mostly avoid this, but keep the
  habit, especially for imported, JSON and SharePoint values.
- **Concurrent procedures:** `activeProc` is a **plain `let`** pointing at the current room's
  open case; `_procByRoom` maps room→case; `_procRoom` is the room on screen. After any change
  call `procSyncActive()`. Ending/cancelling must `procClearRoom(id)`. **Do not** reintroduce
  a getter/setter accessor for `activeProc` (§9 #5). Theatre & Ward's per-room instances
  follow the same model.
- **Stock is only decremented on End**, never per scan, in one atomic RPC. Reopen/delete
  restore stock atomically too. Services are never decremented.
- **Anything multi-step or concurrent goes in one RPC** with server-side checks (rank,
  identity, version). Never do a sequence of client upserts (§9 #8).
- **Sterilisation expiry:** normal flow auto-sets expiry on dispatch (+1 year); only direct
  on-hand entry takes a user-entered expiry.
- **PDF house style:** landscape A4, logo top-left, bold teal title top-right, gold rule
  under the header, `autoTable` grid with teal header rows and light-teal alternating rows.
  Copy it for any new report.
- **Sticker geometry:** 3×7 = 21 labels per A4; cell 64.5mm × 40mm. Overflowing text
  auto-shrinks rather than clipping.

---

## 9. Bugs already hit and fixed (do not repeat)

1. **Layout flip:** a popover placed as a direct child of the `.app` CSS grid broke the whole
   layout. Body-level overlays must live outside the grid.
2. **Production search freeze:** numeric cell → number → `.toLowerCase()` crash → render
   aborts → stale unfiltered list. Diagnosis rule: *"works in staging, not production, same
   code" is almost always a data-shape difference.*
3. **`isAdmin` shadowing:** `const isAdmin = session && isAdmin()` shadowed the global
   function (temporal dead zone) and crashed on click. Never name a local the same as a
   function you call on the same line.
4. **Per-row search boxes:** a search template inside a `.map()` rendered once per data row.
   Emit shared UI at the tab's outer return, not inside the row loop.
5. **The blank-site accessor bug:** `Object.defineProperty(window,'activeProc',{get,set})`
   plus a top-level `var activeProc` threw on load in the real browser (Node tolerated it),
   blanking the SPA. **Top-level `var`/`let` and `Object.defineProperty(window,...)` for the
   same name conflict; never do it.** A browser-load simulation is required, and a real
   browser check is the gold standard.
6. **`ROLE_RANK` missing on the frontend:** it existed only on the backend. Define shared
   constants on **both** sides.
7. **GitHub Pages custom domain unbinding:** editing Cloudflare DNS (or flipping to the
   orange proxy) fails GitHub's health check and GitHub silently removes the custom domain
   (404). Recovery: re-add the domain in repo Settings → Pages; if asked, add the
   `_github-pages-challenge-<user>` TXT record in Cloudflare (grey cloud), verify, re-enter
   the domain, enforce HTTPS. Keep the TXT record forever and keep `bollin` DNS-only.
8. **Rota stale overwrite:** saves were a sequence of client upserts with no conflict
   check. An older tab/device finishing last silently wiped a newer save (Theatre 2's cases
   vanished, then Theatre 1's). Fixed by the atomic, `updated_at`-checked `rota_save_day`.
9. **Theatre & Ward duplicate SharePoint rows:** two theatres shared one set of globals
   (one patient written ~10×). Then autosave re-created rows because SharePoint reads lag
   writes, and a per-session row cache didn't help across reloads/devices (12–13 duplicates).
   Fixed by per-room instances, per-room serialized write queues, and **autosave never
   creating rows**. Only explicit Save adds, after a 1.5s wait-and-recheck.
10. **Theatre & Ward leftover draft blanked a loaded record:** drafts captured every field
    (blanks included) and drafts outrank the loaded record, so a stale draft masked a
    correctly loaded patient on one device only. Fixed: drafts store only changed fields plus
    `_pid`, and non-matching drafts are discarded on lookup. Old drafts are cleaned on load,
    and the device reopens on its last room.
11. **Windows line endings vs `sync-staging.sh`:** git's `core.autocrlf=true` checks
    `index.html` out with CRLF, and the script's multi-line replaces (STAGING badge, striped
    border) silently don't match. The title and Supabase URL swaps still work. Known and
    deliberately left as-is; don't rely on the badge to tell staging apart, check the URL.
12. **Same-transaction timestamps:** `now()` is the *transaction* start time, so rows
    inserted in one transaction share `created_at` and "latest row" ordering becomes
    arbitrary. Use `default clock_timestamp()` where ordering matters (as `sms_messages`
    does).
13. **`$` patterns in JavaScript `String.replace`:** in the *replacement* string, `$$`
    becomes `$` (breaking SQL function bodies) and `` $` `` / `$'` insert the text before or
    after the match (duplicating half a file). When scripting edits to SQL, use
    `s.split(a).join(b)` or a replacer function, or use the editor. Check that dollar-quote
    pairs balance before running.
14. **Barcode links silently never saved (Aug–Oct 2026):** the `link` action sent
    `payload.row || payload.code`, but the caller never passed `row`, so the item's *code text*
    went where the RPC wanted a uuid and every link failed with only a toast. Nobody noticed
    for six weeks; the evidence was `barcode_link_events` having no row newer than the import.
    When moving a call from "match by code" to "match by id", check every caller passes the
    id, and look at the table for proof that writes are landing.

---

## 10. Testing

Regression suites live in **`tests/`** and run with `node tests/run_all.js`:
- Theatre & Ward;
- Theatre & Ward room tabs;
- stock/procedures (7-feature batch);
- item scan codes (`item_codes_tests.js`: extra codes, linking, one-click codes; database side
  in `tests/sql/item_barcodes_db_tests.sql`, staging only);
- rota;
- rota texts (screens);
- SMS dispatcher: `tests/sms_dispatch_tests.mjs`, which runs the Edge Function's `core.ts`
  directly (Node 24 runs TypeScript without a build step);
- sidebar navigation: `tests/nav_browser_tests.js`, which loads a demo-mode copy of the page
  in **headless Chrome** and checks, per role, which links, headers and parents are really
  visible, plus collapsing, icons and highlighting;
- clinical monitoring: `tests/monitor_browser_tests.js`, also in headless Chrome. It puts the
  same entries through a copy of the **old page** (`tests/fixtures/`) and through the new one
  with `fetch` replaced by a recorder, and requires the requests to be identical (URL, mode,
  headers, body, key order). Then it checks the new page's behaviour. It never posts to the
  real Sheet.

Database tests for rota texts: `tests/sql/rota_sms_db_tests.sql`. Run it against **staging**
with `supabase db query --linked -f …`.

`tests/extract.js` pulls the last `<script>` block from the current `index.html`. Each suite
runs the **whole app script** in a `vm` context with stubbed `document`/`window`/
`localStorage`, a recording `jsPDF` stub and a reassignable data layer returning
production-shaped fixtures. That doubles as the browser-load simulation.

`tests/` is excluded via `.git/info/exclude` (not `.gitignore`), because the repo is public.
**Never `git add tests/`.** Fixtures must use fictional patients only.

For database changes, test the RPCs on the **staging** project: impersonate a user with
`set_config('request.jwt.claim.sub', '<uuid>', true)`, assert both the happy path and the
role gates, then delete every test row. A real browser check on staging is the final gate
before asking for the go-ahead to production.
