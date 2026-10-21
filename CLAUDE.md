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
- **Samples tile** (`samplesAwaitingTile`, the 10th tile): appears only while samples are
  recorded and not yet marked Sent (status `Collected`), for everyone who can open Sample
  collection. It counts **patients, not specimens** (`samplesAwaiting`: distinct PAT number,
  case-insensitive; a collection with no PAT counts as one patient), e.g. "4 — Patient samples
  awaiting collection · 9 specimens".

**Requests** (all roles create; staff+ respond): two ways to raise one, chosen by chips
(`reqForm.mode`):
- **Type the item** (the original free-text form, for things not stocked).
- **Pick from inventory** (`reqStockForm`): search live stock by name, reference, barcode or
  extra code (`reqSearchItems`; never obsolete, offsite or services), choose the item, enter a
  quantity. The request is saved with the item's name plus `item_code` (its code, else its
  barcode), `tracker` and `item_id` (migration `20261011100000_request_item_link.sql`), and the
  list shows "Ref …" under the name, with the stock right now on open requests.
- `reqForm.pick` is a snapshot taken when the item is chosen, so a background reload can't
  change what is submitted. A typed request sends none of the inventory fields.

**Sterilisation workflow**: instruments go **used → dispatched to CSSD → received back**.
Tabs: Log used, Dispatch, Receive, On hand, History, each with **one** search box (§9 #4).
On-hand rows open a detail dialog; admin can edit or delete (identity-guarded). Already-sterile
items can be added directly to on-hand (user enters expiry); the normal flow auto-sets
expiry = dispatch date + 1 year.

**Procedure case costing** (all roles; financials admin+):
- **Concurrent: one open case per room** (`PROC_ROOMS`: Theatre 1, Theatre 2, Minor ops),
  selectable via room tabs. Scanning adds to the room on screen.
- **A running case always has a theatre** (migration `20261010100000_proc_keep_room.sql`, §9
  #15):
  - CHECK `procedures_open_needs_room`. `proc_update_meta` keeps an open case's room when none
    is sent, and refuses a move into a busy theatre. `proc_reopen` refuses a busy theatre
    before touching stock, and puts a room-less closed case into the first free theatre.
  - Every call that edits a case must send its room (`procRoomOf(p)`).
  - **On load the database's room wins** over the screen's memory (memory only supplies carts
    and not-yet-confirmed local cases). A legacy room-less open case goes in the room this
    screen had it in, else the first free one, and is flagged `_roomGuessed` with an admin
    "Yes, it is in …" button (`procConfirmRoom`). It never displaces a case that has a room.
    With no free room it is listed in `state.procUnplaced` as a warning.
- Items sit in a cart. Stock is NOT decremented until the case is **ended**. Ending is one
  atomic RPC, `proc_consume_batch`: consume stock, record cost + bill lines, close the case.
- The cart auto-saves to the server. Manual "Save progress" sorts A→Z; autosave never reorders.
- **Several devices, one case** (migration `20261022100000_proc_cart_versions.sql`, §9 #16):
  - **Versioned saves.** `procedures.cart_version` goes up by one whenever the cart changes
    (a trigger, so every path counts). `proc_save_cart_v2(id, cart, expected_version)` saves
    only from the version the device last saw. Otherwise it saves nothing and returns the
    newer cart, and the page **combines** its own changes with it (`procMergeCarts`, three-way
    against `p._base`), then saves again. The old `proc_save_cart` is kept for unrefreshed
    devices, and its saves move the version on too.
  - **A case saves itself** (`procQueueSave(p)` / `procSaveNow(id)`), never "the room on
    screen". There is one save at a time per case, a change made mid-save is saved straight
    after, and failures retry every 5 s ("⚠ Not saved yet, retrying").
  - **Every screen refreshes running cases** (`procPoll` → `get_open_procedures`): every 20 s
    on the costing page, on opening it, on tapping a room tab, and before Start. A newer
    server cart replaces this device's copy only when the device has nothing unsaved. A case
    ended or cancelled elsewhere triggers a full reload.
  - **Start checks the server first.** A start the server refuses is taken off the screen at
    once with an alert, never left as a local case to scan into. Items scanned while a start is
    still on its way are saved when it lands.
  - **End** saves first. If that save had to combine another device's changes, End stops and
    shows the combined list, so nothing is consumed unseen.
  - **Starts and cancels are logged** in `activity_log` (a trigger), so a cancelled case leaves
    a trace.
  - **All cases are fetched in pages of 1000** (`sbRpcAllRows`), because Supabase returns at
    most 1000 rows a request.
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

**Theatre rota** (superadmin+): replaces Ruby's transposed spreadsheet. Since the October 2026
redesign (migrations `20261016100000_rota_people_model.sql` and
`20261016110000_rota_sms_labels.sql`), the rota has **two views of the same data**. More than one
surgeon group now uses the theatres (Aftab Siddiqui's lists, Transform, private surgeons), so two
theatres and the minor op room can run on the same day.
- **Rota** (view `rota`, `rotaGridView`) is an Excel-style grid. Dates run across the top
  (week / 2 weeks / month, with Today and ‹ ›) and roles run down a sticky first column, in Ruby's
  order (`ROTA_GRID_ROWS`): Operating surgeons, Anaesthetists, Info (GA / LA / Overnight), SFAs,
  ODPs, Scrubs, Recovery, Ward nurses, Theatre HCAs, Ward HCAs, Reception, RMO, Housekeeping.
  - A cell holds any number of name chips, each tagged with its rooms ("T1", "T1+T2",
    "Minor op") or shift ("Day", "Night", "AM", "PM"). Missing people show as red hints ("T2 needs
    one").
  - The date header shows the running rooms with their start times and the open-gap count.
    Clicking it opens the day pop-up (`rotaDayDlgOpen`): rooms on/off, List starts, colour,
    detail, night team time, notes, gaps with cover notes, ✉ Message staff, Day PDF, copy last
    week, and "Open in Allocation".
  - Clicking a cell opens the cell editor (`rotaCellOpen`). For each name it offers rooms
    (several allowed), shift, ★, 🕐 own time, Lead (scrubs), Edit (swap the person) and Delete,
    plus "Add names". Add names (`rotaPickOpen`) is a multi-select with search and an optional
    theatre: surgeons come from the surgeon list, anaesthetists from names used before (or
    typed), and everyone else from the Staff database filtered by "Works as", with "show everyone"
    and "＋ add new person".
  - **The grid saves every change at once** (ctx `'grid'` → `rotaSaveDay(date,{fromGrid:true})`).
    A day with unsaved Allocation edits on this screen can't be edited in the grid until those are
    saved or discarded, and a locked day stays locked.
- **Allocation** (view `rotaalloc`, `rotaAllocView`): the old rota page, rebuilt on the new model
  and moved under Rota in the sidebar. It shows a panel per running room (Theatre 1, Theatre 2,
  Minor op) with its tags, List starts, colour, detail, team and case list. It also has a "No
  theatre yet" strip and Day cover. It keeps the weekly / monthly / custom-range views, **Edit day
  / Save day** (a draft in `_rotaDrafts`), ✉ Message staff, staff search and the PDFs.
- **One model, one set of edit functions:** both views go through `rotaEdit(date, ctx, fn)` and
  the helpers built on it (`rotaAddPeople`, `rotaPersonPatch`, `rotaPersonToggleRoom`,
  `rotaRoomToggleTag`, …). So the two views can't disagree.
- **People** (`rota_days.people`): `{id, role, name, rooms, shift, star, time, lead}`.
  - **Roles** (`ROTA_ROLE`): surgeon, anaesthetist, sfa, odp, scrub, recovery, theatre_hca,
    ward_nurse, ward_hca, rmo, reception, housekeeping.
  - **rooms** ⊂ {1, 2, 3} (3 = Minor op). `[]` means "no theatre yet": the name can go in before
    the room is known, and counts as a gap until it is placed. Several rooms replaces the old "2
    theatres" tick.
  - **shift** is `day`/`night` for ward nurse, ward HCA and RMO, and `am`/`pm` for reception and
    housekeeping. A night ward nurse is a "Night nurse".
  - `star` is ★ provisional, `time` is the 🕐 own start time, and `lead` is the Lead scrub (one
    per day).
  - **Never key anything on slot positions again**: stars, times and Lead live on the person.
- **Rooms** (`rota_theatres` rows 1–3) have `running`, `tags` (text[]), `la_no_anaesthetist`,
  start time, detail, colour and cases.
  - **A room runs** when it is switched on, or when a surgeon is allocated to it.
  - **Always loop over `rotaRoomsRunning(day)`**, never `1..theatres`. `rota_days.theatres` is
    kept as the count of running rooms for older readers.
  - **Tags** are per room. The options are GA / LA / Overnight plus any added with "＋ Add option",
    which stay (setting `rota_tag_options`, `rotaTagOptions`).
- **Gaps** (`rotaGaps`, keys like `r2.anaesthetist`, `unplaced`, `ward_nurse.day`):
  - **Theatre 1 / 2** need a surgeon, an anaesthetist (unless the room is LA-only or ticked
    "LA — no anaesthetist"), SFA and ODP (not on LA-only), a scrub, a theatre HCA and recovery.
  - **Minor op** is a lighter team: a surgeon plus a scrub or nurse.
  - **Day cover** needs ward HCA (day), ward nurse (day) and RMO (day).
  - **Scrub numbers** are advice only, never a gap (`rotaScrubAdvice`: 1 room 1–2, 2 rooms 2–4,
    3 rooms 3–5).
  - Cover notes (`acks`) silence a gap.
- **Case surgeons follow the room** (`rotaSyncCaseSurgeons`, `rotaCaseSurgeonField`):
  - With one surgeon in the room, every case that is empty or names someone else gets that
    surgeon.
  - With 2+ surgeons, each case picks from a dropdown of the room's surgeons.
  - A case naming someone not on the list is kept and flagged "(not on this list)".
- **Case lists** are surgeon / procedure / stay -- **no PAT numbers** (removed on request
  2026-09-30). Migration `20260930220000_rota_remove_pat.sql` deleted stored ones, a trigger on
  `rota_theatres` strips any `pat` key, and the page drops it on load and save.
- **Expected start for later surgeons:** a surgeon's 🕐 time shows as "from 10:30". Surgeons are
  never texted.
- **PDFs** (Day with 1–3 room panels, week, month, range, staff) show "Name (07:30) — LEAD",
  multi-room names under each of their rooms, and a "No theatre yet" row when someone is
  unplaced.
- **Saving** is one atomic, version-checked RPC, `rota_save_day_v2(date, expected_updated_at,
  day)`: a stale save is refused, never silently applied (§9 #8). It validates roles, rooms,
  shifts and the single Lead.
  - **The old `rota_save_day` now refuses** ("The rota has been upgraded. Please refresh…"), so a
    device still on the old page can never write the old columns.
  - The old slot columns (`rota_theatres.surgeon`/`scrub1…`/`type`, `rota_days.ward_nurse…`,
    `stars`, `flags`)
    are **kept untouched as history**. Live data is `people` + the room columns.

**Rota texts (SMS)** (superadmin+): texts rota staff from the clinic's own phone. **Nothing
is ever sent automatically; this is a firm rule from Yasar.**
- **Who is textable** (`ROTA_ROLE[role].textable` and `rotaIsTextable` in `index.html`, which
  must match `rota_sms_slots()` in the database; since the redesign that function reads
  `rota_days.people`, with the same output columns, so preview, send, cancellation and the
  safety net are unchanged):
  - theatre team, **once placed in a running room**: Scrub, ODP, SFA / practitioner, Theatre
    HCA, Recovery nurse / ODP. Nobody with "no theatre yet" can be texted.
  - day cover: Ward nurse, Night nurse, Ward HCA, Night HCA, RMO on site (day / night).
  - Labels: "Scrub (Theatre 2) - Lead" for one theatre, and "Theatre HCA (Theatres 1 and 2)" or
    "Scrub (Minor op)" for several rooms or the minor op (theatre column 0, the rooms in the
    label; `rota_room_words`).
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
    own start for the day (e.g. Recovery starting later than the list). It is stored on the
    person (`people[].time`), shows next to their name, and is dropped when the person is
    swapped for someone else.
  - **Night team time:** "🌙 Night team starts" (Day cover heading, same picker) sets Night
    nurse, HCA night and RMO night (everyone on a night shift) at once. It is stored as
    `rota_days.times.nightTeam`.
  - **Precedence:** own time > night team time (night roles only) > theatre "List starts" /
    usual time. A person in several rooms takes the first running room's List starts. Frontend
    helpers are `rotaPersonOwnTime` / `rotaPersonBaseTime` / `rotaPersonTime`; they mirror
    `rota_sms_slots()`.
  - **PDFs:** Day, week, month and range PDFs show "Starts HH:MM" per room and times for
    ward, night and RMO names (`rotaPdfName`). The **Day PDF** shows every textable
    theatre-team member's start time next to their name (`allTimes`). Week, month and range
    PDFs add a time there only for own times. Anaesthetist, housekeeping and reception never
    show a time, and surgeons show only "(from 10:30)".
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
- **Staff picker:** every role except surgeons and anaesthetists is chosen from the Staff
  database ("Add names", `rotaPickOpen`), filtered by "Works as", including housekeeping and
  reception (in the staff database but never texted, with no time controls). A new person is
  added with the staff form (`openStaffDlg` with `ctx.add`). Names on the rota that aren't in
  the database are listed by `rotaUnlistedNames` and can't be texted until added.
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
    a **collapsible child item under Rota in the sidebar**.
    - Rota has two children, in this order: **Allocation** (`a.navsub#navRotaAlloc`) and
      **Staff database** (`a.navsub#navRotaStaff`).
    - The caret on Rota calls `toggleRotaSub`, with state in localStorage `bollin_rota_sub`.
      `applyRotaSub` shows both children on the Rota page unless the user collapsed them, and
      always on either child's own page.
    - Yasar asked for this explicitly: these must **not** be inline sections of the rota page.
      The Rota grid and Allocation only show a one-line notice (`rotaUnlistedNotice`) when names
      on the rota aren't in the database.
    - Use `navGo(view)` to go to a sidebar page from code.
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
  - **✉ Text settings** (`rotaSmsSettingsPanel`, a collapsible panel at the bottom of the Rota
    grid page): the usual start times for ward and night
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
- The only indented child items are Rota > Allocation and Rota > Staff database (`a.navsub`).
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
- **Rota data since October 2026** lives in `rota_days.people` (jsonb, one entry per person;
  see §4 Theatre rota) and the room columns on `rota_theatres` rows 1–3 (`running`, `tags`,
  `la_no_anaesthetist`, `start_time`, `detail`, `colour`, `cases`). `theatre_number` is checked
  to be 1–3. `rota_valid_people()` validates the array, `rota_save_day_v2` is the only writer
  from the page, and `rota_rename_person` renames inside `people` (never surgeons or
  anaesthetists).
- **Old rota columns are kept as history only:** the slot columns, `stars`, `flags`, and the
  older `rota_days.hca_theatre` / `recovery_nurse`. The conversion copied them into `people`,
  then moved the cover-note keys (`acks`) to the new keys, e.g. `t2.scrub1` → `r2.scrub` and
  `ward` → `ward_nurse.day`.

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
- **`rota_days.times`** (`jsonb`): the day's `nightTeam` time. Since the people model,
  per-person own times live on `people[].time`; before it, they were keyed by slot here.
- **`rota_days.flags`** (`jsonb`, migration `20261004100000_rota_lead_and_both_theatres.sql`):
  the old `{lead, both}` ticks. **History only now**: Lead is `people[].lead`, and "both
  theatres" is `people[].rooms`.
- **Names are text** in `people[].name`, and the server matches them to `staff.name`
  case-insensitively.
- **`rota_sms_slots()`** (rebuilt in `20261016100000`, labels in `20261016110000`) reads
  `people`.
  - `theatre` is the room when the person is in exactly one of Theatre 1 / 2. It is 0 for the
    minor op, several rooms and day cover, and the room words go in the label instead.
    **Never put the theatre in the label when `theatre` is 1 or 2:** `sms_roles_text` already
    adds " (Theatre N)", which would give "Scrub (Theatre 1) (Theatre 1)". This was caught on
    staging.
  - Change detection (`rota_sms_affected_core`) compares start times, not labels, so the
    conversion didn't flag anyone already texted.
- **Tests:** `tests/sql/rota_sms_db_tests.sql` and `tests/sql/rota_people_db_tests.sql` run
  against staging and clean up after themselves.

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
15. **Running procedure lost its theatre (Oct 2026):** "Edit details" on a running case
    called `proc_update_meta` without `p_room`, and the function saved `room = p_room`, i.e.
    NULL. The editing screen still showed the right room, but other devices and fresh logins
    put the case under Theatre 1 (or hid a real Theatre 1 case). A screen that still held it
    showed it in its old room, and the theatre was no longer reserved, so a second case could
    start there. Found when a case showed in the wrong theatre after a change of login and
    had to be restarted. Rule: an optional parameter must never mean "set to null" on an
    update; default to keeping the current value, and send every field that the RPC writes.
16. **A theatre's items vanished on other devices (21 Oct 2026):** two theatres were running, and
    after a log-out / log-in one case showed with nothing scanned, in the wrong tab. The server's
    cases were fine.
    - **Cause, in the page:**
      - every device kept its own copy of every running case and never refreshed it;
      - the autosave saved whichever room was on screen when its timer fired, so a device
        holding an old copy could write it over the real list;
      - a save started while another was in flight was dropped;
      - a theatre could look free when another device was using it, and a start the server
        refused left a local case that people scanned into and that could never be saved.
    - **Fixed by** versioned saves with a three-way combine, per-case save queues, a 20 s
      refresh, and Start checking the server first (§4 "Several devices, one case").
    - **Rule:** anything several devices edit needs a version check on the server and a
      refresh on the page. Last write wins is never acceptable.
    - **Also found:** reopen read `procedures` directly, which has no read policy, so it
      reported "Could not reopen" after reopening. It now reads through `get_open_procedures`.

---

## 10. Testing

Regression suites live in **`tests/`** and run with `node tests/run_all.js`:
- Theatre & Ward;
- Theatre & Ward room tabs;
- stock/procedures (7-feature batch);
- item scan codes (`item_codes_tests.js`: extra codes, linking, one-click codes; database side
  in `tests/sql/item_barcodes_db_tests.sql`, staging only);
- procedure rooms (`proc_rooms_tests.js`: where running cases appear after a load, "Edit
  details" keeping the theatre, the guessed-theatre warning; database side in
  `tests/sql/proc_room_db_tests.sql`, staging only, needs no running cases on staging);
- procedure costing on several devices (`proc_devices_tests.js`: several copies of the app
  against one fake server that behaves like the database, replaying the 21 Oct incident, stale
  copies, combining, slow and failed saves, refused starts, ending and cancelling elsewhere;
  database side in `tests/sql/proc_cart_db_tests.sql`, staging only, needs no running cases);
- dashboard samples tile and inventory requests (`dash_requests_tests.js`; database side in
  `tests/sql/request_item_db_tests.sql`, staging only);
- rota (`rota_tests.js`: the people model, Allocation, gaps, saving, PDFs);
- rota texts (screens; `rota_sms_tests.js`);
- rota grid (`rota_grid_tests.js` run by `rota_grid_run_tests.js`: the grid, cell editor, Add
  names picker, rooms and shifts, two-way sync with Allocation, immediate save and conflicts,
  role gates);
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

Database tests for the rota: `tests/sql/rota_people_db_tests.sql` (conversion, save, conflict,
role gates, the old save refused, texting slots) and `tests/sql/rota_sms_db_tests.sql`. The
latter writes days through a `pg_temp.zz_save` shim that turns the old slot format into
`people`. Run both against **staging** with `supabase db query --linked -f …`.

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
