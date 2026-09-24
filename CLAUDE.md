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
- **Edge Functions** (`supabase/functions/`): `create-user`, `manage-user` (reset password,
  rename). They need the service-role key, so they run server-side and verify the caller is
  an active `developer` first.
- **Auth:** Supabase Auth. Staff log in with a **username**; the app turns it into a
  synthetic email `username@bollin.local` (`synthEmail`). Role and active flag live on
  `profiles`. `app_role_rank()` returns 0 for an inactive profile, so deactivation takes
  effect everywhere at once, including already-open sessions.
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
  Netum 1D scanners can't read QR codes.

### Deploy flow

**Frontend** (most changes):
1. Edit `index.html` only. Never hand-edit `index_STAGING.html`.
2. `node tests/run_all.js`: all suites must pass.
3. `bash sync-staging.sh`: regenerates `index_STAGING.html` (staging title, staging
   Supabase URL/key). Commit both files.
4. `bash deploy-staging.sh`: force-pushes a temporary branch to the `staging` remote's
   `main`. Verify on the staging URL.
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
`supabase db push`. Always check which project is linked before any `db` command.

**Edge Functions:** `supabase functions deploy <name> --project-ref <ref>`, staging first.

---

## 4. Feature inventory (what exists today)

**Stock trackers** (6): medicines, consumables, garments, instruments, linen, **services**.
Services are billable techniques with a `bill_price` and are never decremented. Each item:
code, barcode, name, category, supplier, location, unit, qty, reorder level, unit cost,
bill price, expiry, batch, status, notes, obsolete flag. Instruments also have qty-in-tray and
cycles-to-date. Scanning an item opens a stock-movement dialog; unknown barcodes can be
linked to an item. Superadmin+ can bulk-edit category/location/supplier, bulk-generate
barcodes (13-digit, collision-checked) and bulk-obsolete.

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
- **Barcode / QR**.

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
- **Theatres:** 0–2 per day. Per theatre: GA/LA type, colour, detail line, up to 3 surgeons,
  anaesthetist/SFA/scrub 1–3/ODP, **per-theatre HCA and recovery nurse/ODP**, and a case list.
- **Day cover** roles, including HCA night.
- **Gap detection:** LA lists don't require an anaesthetist, ODP or SFA. Gaps can be silenced
  with per-day cover notes, and every name slot has a ★ provisional flag.
- **Staff search** and **PDFs** (week/month/range/staff/day). ⧉ copies last week's weekday.
- **Saving** is one atomic, version-checked RPC, `rota_save_day`: a stale save is refused,
  never silently applied (§9 #8).

**Users & roles** (developer only): list users, change role, activate/deactivate, create
accounts (`create-user`), reset password / rename (`manage-user`).

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
| Theatre rota, bulk item edit, physical stock-take sheet | | | | ✓ | ✓ |
| Users & roles, billing report, item usage, procedure pre-fill | | | | | ✓ |

Enforced in **two places**: `viewAllowed(view)` / `can()` on the frontend, and RLS + RPC rank
checks in Postgres (the real gate). Never rely on the frontend alone. When adding a role
gate, add it on **both** sides (§9 #6).

---

## 6. Data model (Supabase tables)

`profiles`, `items` (all trackers; `tracker` enum incl. `services`), `barcode_link_events`,
`dispatch_log`, `procedures` (`cart` jsonb, `room`, `surgeon_id`), `procedure_lines` (cost +
bill snapshots), `surgeons`, `rota_days`, `rota_theatres` (`cases` jsonb), 
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

---

## 10. Testing

Regression suites live in **`tests/`** and run with `node tests/run_all.js`:
- Theatre & Ward;
- Theatre & Ward room tabs;
- stock/procedures (7-feature batch);
- rota.

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
