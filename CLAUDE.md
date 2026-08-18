# CLAUDE.md — Bollin Clinic Stock Manager

Guidance for Claude Code (and any future maintainer) working on this project. Read this
before making changes. The current production app is a **single-file** web app on GitHub
Pages backed by Google Sheets + Apps Script; this document also describes the target
**Supabase** rebuild.

---

## 1. What this is

An operational inventory + theatre-management tool for **Bollin Clinic**, an aesthetic
surgery clinic in Altrincham, UK. It is used daily by clinical staff (nurses, scrub team,
ODPs) and by the clinic manager. The maintainer/owner is **Yasar** (a nurse at the clinic).
The clinic manager is **Ruby**, who owns the theatre rota.

The app must be **production-grade and regression-free** — real patients, real stock, real
theatre lists depend on it. The working mantra throughout the build has been:
**"no guesswork, hard check, smoke test everything."**

---

## 2. Working principles (non-negotiable)

1. **Hard-check before editing.** Never assume file structure. Grep/read the actual current
   state first. Version drift between edits has repeatedly caused bugs.
2. **Full implementation per turn.** No placeholders, no partial edits, no "TODO".
3. **Smoke test everything** with data shapes that match *production*, not just tidy test
   data. Several severe bugs only appeared with real-world data (see §9).
4. **`node --check` + a browser-load simulation on every change.** Parse-clean is not
   enough — a runtime error on load blanks the whole SPA (see §9, the accessor bug).
5. **Never break existing features.** Any introduced regression is a blocker. Multi-part
   requests are addressed in full, in one turn.
6. **Staging first, always.** Test on staging before production. Never deploy straight to prod.

---

## 3. Current architecture (Sheets + Apps Script)

- **Frontend:** one file, `index.html` (~5,500 lines) — HTML + CSS + vanilla JS, no build
  step, no framework. Rendered by a single `render()` that swaps `#main` innerHTML based on
  a hash route. State lives in a global `state` object; `loadAll()` fetches everything.
- **Backend:** Google Apps Script `Code.gs` — a `doPost(e)` dispatcher that switches on
  `req.action`. Data stored in a Google Sheet (one tab per entity).
- **Auth:** custom. A `Users` sheet (Username, Password, Role, DisplayName, Active). Login
  returns a token; the token is sent with each request. **Roles are ranked:**
  `common(0) < staff(1) < admin(2) < superadmin(3)` (`ROLE_RANK`). `isAdmin()` = admin OR
  superadmin. Financials and destructive actions are admin+; rota and user-management are
  superadmin/admin per action.
- **Hosting:** GitHub Pages. Production repo `database` → custom domain
  `bollin.hashirhub.uk` (Cloudflare CNAME, **DNS-only / grey cloud** — Cloudflare must NOT
  proxy or cache it). Staging repo `database-staging` → `*.github.io/database-staging/`.
- **Two backends:** a production Sheet and a separate `Bollin_Inventory_STAGING` Sheet, each
  with its own Apps Script deployment URL. The staging `index.html` is identical to prod
  except: the API URL, the `[STAGING]` title, a `STAGING` badge in the header, and a striped
  top-border marker.
- **Scanning:** a Netum USB barcode scanner acting as a **keyboard wedge** (HID keyboard
  input, NOT a camera). Global keydown handler buffers fast keystrokes ending in Enter.

### Deploy flow (current)
1. Paste `Code.gs` into the Sheet's Apps Script editor → Save.
2. If the schema changed, **run `migrate()`** (idempotent — creates missing tabs/columns).
3. Deploy → Manage deployments → Edit → **New version** (required for `doPost` changes to
   go live).
4. Upload the built `index.html` to the GitHub repo.
5. Test on staging, then repeat on production.

---

## 4. Feature inventory (what exists today)

**Stock trackers** (5): medicines, consumables, garments, instruments, linen. Each item:
code, barcode, name, category, location, qty, reorder level, unit cost, expiry, batch,
status, notes/remarks, obsolete flag. Scanning an item opens a stock-movement dialog;
unknown barcodes can be linked to an item.

**Dashboard** — live low-stock counts across trackers.

**Sterilisation workflow** — instruments go **used → dispatched to CSSD → received back**.
Tabs: Log used, Dispatch, Receive, On hand, History. Each of the first three + on-hand +
history has a **search box** (one per tab — watch for the per-row duplication regression,
§9). On-hand rows are **clickable** → detail dialog; **admin** can edit (name/code/barcode/
type/tray count/expiry) or **delete** (identity-guarded on the backend so a stale row number
can't delete the wrong item). Already-sterile items can be **added directly** to on-hand
(user enters expiry); the normal flow auto-sets expiry = dispatch date + 1 year.

**Procedure case costing** — per-surgery consumption tracking. **Concurrent: one open case
per room** (Theatre 1, Theatre 2, Minor ops), selectable via room tabs; scanning adds to the
room on screen. Items sit in an in-memory cart (stock is NOT decremented until the case is
**ended**, so mistakes are free to fix). Ending is one atomic backend call
(`procConsumeBatch`) that consumes stock + records cost lines + closes the case. Admin can
edit meta (surgeon/procedure/date/patient ref — staff sometimes put patient names in the
surgeon box), reopen a closed case (returns stock, reopens for editing), or delete a case
(returns stock). Financials/PDF are **admin-only**; in-stock column and the workflow are all
roles. Cart auto-saves to the server (`CartJSON`) so a refresh/crash loses nothing; manual
"Save progress" sorts A→Z, autosave never reorders.

**Sticker printer** (all roles) — prints onto 21-per-A4 label sheets (3×7,
64.5mm × 40mm cells). Four tabs:
- **Patient stickers** — name/DOB/PAT/address/surgeon.
- **Medication labels** — for blocks/infiltrations/locals. Enter medication (name, strength,
  route) + optional "mixed with" diluent. Prints a box with the drug (bold, auto-shrinking
  font so nothing is ever clipped) + a "___ ml" pen blank; the diluent with its own blank, or
  an empty pen line if none; plus Patient: ___ and Prepared-by / Checked-by initial boxes.
  Saved presets (shared, stored in Settings) shown as one-click chips.
- **TTO / discharge** — 13 take-home medication labels (dropdown). Pack counts and dosing are
  **dotted blanks** (different suppliers/quantities — written by pen). Directions auto-shrink
  to fit. PT Name / Dispensing Date / Dispensed by / Checked by + "Keep out of the sight and
  reach of children" footer.
- **Barcode / QR** — printable codes filtered by tracker/category/location.

**Implant logging** — order → delivered → used, with a PDF status report (landscape, logo,
teal header, striped table) — this is the **canonical PDF style** other reports copy.

**Sample collection** — specimen log. Per patient: date, initials, PAT number, surgeon, and
**one-or-more specimens** (＋ Add specimen) each with details, category (Histology, Cytology,
Microbiology, Frozen section, Immunology, Biochemistry, Other), Formalin Yes/No, and dates
collected/sent/result. List groups a patient's specimens together, shows pending vs received.
**Search by PAT number** (also initials/surgeon/details). PDF export (implants style) by
day/week/month/surgeon/current-search. Admin can delete a specimen. (staff+)

**Theatre rota** (superadmin only) — replaces Ruby's transposed spreadsheet.
- **Weekly / Monthly / Custom-range** views. Month = calendar grid; each date shows theatre
  count, a red badge with unresolved gap count (green ✓ when covered), a ★ provisional count,
  and colour stripes per list. Click a date to expand the full day inline.
- Per day: **0/1/2 theatres**. Per theatre: **GA/LA type**, **colour** (per-surgeon colour
  coding), a detail line (Overnight, Transform, AM only), **up to 3 surgeons** sharing the
  theatre, the shared team (anaesthetist, SFA, scrub 1/2/3, ODP), and a **case list**
  (0–20 cases, each: surgeon / procedure / PAT number / day-case-or-overnight).
- **Day cover** split roles: HCA ward, HCA theatre, ward nurse, night nurse, recovery
  nurse/ODP, RMO day, RMO on-site night, housekeeping AM/PM, reception AM/PM.
- **Gap detection:** empty required slots glow red. **LA lists don't require** anaesthetist/
  ODP/SFA. Any gap can be **silenced with a cover note** ("second scrub arranged — agency")
  stored per-day; notes are removable. A red week banner + a nav badge count unsilenced
  current-week gaps.
- **★ provisional star** on every name slot (booked but not confirmed).
- **Staff search:** type any name → all their shifts across this month / this year / custom
  range, with PDF.
- **PDF exports** (implants style): week, month, custom range, or per-staff.
- ⧉ copies the same weekday from last week (cover notes deliberately not copied).
- Dates stored as **text** (column A `@` format) to avoid UTC timezone drift; a midday-shift
  helper guards any legacy Date-typed cells.

**Users & roles** (admin+) — list users, change roles via dropdown. Appoint the (3)
superadmins here.

**Themes / settings** — theme, accent colour, font, density, corners (cog menu, top-left).
Item remarks/notes. Activity log with filterable PDF export.

---

## 5. Roles & permissions summary

| Area | common | staff | admin | superadmin |
|---|---|---|---|---|
| View trackers, run procedures, print stickers, sterilisation | ✓ | ✓ | ✓ | ✓ |
| See procedure financials / case PDF | | | ✓ | ✓ |
| Edit/delete on-hand instruments; reopen/delete/edit procedures | | | ✓ | ✓ |
| Sample collection | | ✓ | ✓ | ✓ |
| Delete a specimen | | | ✓ | ✓ |
| Users & roles (change roles) | | | ✓ | ✓ |
| Theatre rota | | | | ✓ |

Enforced in **two places**: `viewAllowed(view)` on the frontend (nav/routing) and
`ACTION_ROLE[action]` on the backend (the real gate). Never rely on the frontend alone.

---

## 6. Data model (sheet tabs → target tables)

Current sheet tabs and their key columns (these map directly to Supabase tables):

- **Users**: Username, Password, Role, DisplayName, Active
- **Meds / Consumables / Garments / Instruments / Linen**: Code, Barcode, Name, Category,
  Location, Unit, Qty, ReorderLevel, UnitCost, Expiry, Batch, Status, Notes, Obsolete,
  ObsoleteBy, ObsoleteAt; instruments also QtyInTray, CyclesToDate
- **Transactions**: the activity log (timestamp, action, item, qty, user, note)
- **Dispatch**: sterilisation records (instrument, used-by, dates, status, batch, ref)
- **Implants**: surgery date, patient initials, PAT, surgeon, details, qty, order/receive
  dates, status, storage, returns, remarks
- **Procedures**: `ProcedureID, Date, Surgeon, Procedure, PatientRef, StartedBy, Status,
  StartTime, EndTime, TotalCost, Notes, CartJSON, Room`
- **ProcedureLines**: `ProcedureID, Timestamp, Tracker, Code, Name, Qty, UnitCost, LineCost, By`
- **Samples**: `SampleID, Date, PatientInitials, PATNumber, Surgeon, SpecimenNo,
  SampleDetails, Category, Formalin, DateCollected, DateSent, DateResult, By, Notes`
  (one row per specimen; a patient's specimens share the header fields)
- **Rota**: one row per **date** (stored as text). Day-level: Theatres, HCAWard, HCATheatre,
  WardNurse, NightNurse, RecoveryNurse, RMODay, RMONight, HousekeepingAM, HousekeepingPM,
  ReceptionAM, ReceptionPM, Notes, AcksJSON (silenced gaps), StarsJSON (provisional flags).
  Per theatre T1_/T2_: Type, Detail, Colour, CasesJSON, Surgeon, Surgeon2, Surgeon3,
  Anaesthetist, SFA, Scrub1, Scrub2, Scrub3, ODP. (42 columns total.)
- **Assets, Requests, GasChecks, Settings, Stores**: supporting tabs.

**JSON-in-a-cell** columns (CartJSON, CasesJSON, AcksJSON, StarsJSON) become proper related
tables or `jsonb` columns in Supabase.

Backend actions (the full API surface to reproduce): getAll, addItem, updateItem, move,
moveStore, link, clearBarcode, setBarcodes, request, respond, ack, useLog, useEdit,
useDelete, dispatchAdd, dispatchAssign, dispatchReceive, dispatchReturn, implantAdd,
implantUpdate, instrumentAdd, instrumentDelete, procStart, procConsume, procConsumeBatch,
procSaveCart, procGetCart, procEnd, procReopen, procDelete, procUpdateMeta, procCancel,
sampleSave, sampleDelete, rotaSave, userSetRole, setSetting, medPresetsSave, gasCheckAdd,
assetAdd, assetUpdate, storeAdd, storeRemove, stocktake, getTransactions, changePassword.

---

## 7. Target rebuild: Supabase + Claude Code

The intended future architecture:

- **Database:** Supabase Postgres. One table per entity above. Use real foreign keys
  (ProcedureLines → Procedures, specimens → a patient/collection row). Convert JSON-blob
  columns to related rows or `jsonb`. Store dates as `date`/`timestamptz` — but be deliberate
  about timezone (the Sheets version stored rota dates as *text* specifically to dodge a UTC
  off-by-one; in Postgres, use `date` and render in Europe/London).
- **Auth:** Supabase Auth. Replace the custom Users-sheet/token scheme. Map the four roles to
  a `role` column on a `profiles` table (or custom claims). **Enforce with Row Level Security**
  — RLS policies are the server-side gate that `ACTION_ROLE` currently provides. Keep the same
  rank model: common < staff < admin < superadmin.
- **API:** Supabase client from the frontend for straightforward reads/writes; **Edge
  Functions** (or Postgres RPC) for the atomic multi-step operations that must not partially
  apply — above all `procConsumeBatch` (decrement stock + insert cost lines + close case in
  one transaction) and the stock-restoring reopen/delete. These are correctness-critical.
- **Frontend:** can stay vanilla, or move to a framework — but preserve the offline-tolerant,
  auto-saving cart behaviour and the keyboard-wedge scanner handling. If kept vanilla, the
  existing `render()`/route/view structure ports directly.
- **Realtime:** Supabase realtime is a natural fit for the concurrent theatres (two rooms on
  two devices) and the rota — subscribe so a case started on one device appears on another.

Migration: export each sheet tab to CSV → import to the matching table. Parse the JSON-blob
columns into their related rows during import.

---

## 8. Reproducing behaviour that matters (subtle but important)

- **Numeric-looking cells:** Google Sheets returns a JS **number** for all-digit cells. Any
  text field (name, code, barcode…) MUST be `String()`-coerced on read, or `.toLowerCase()`
  in search throws and silently freezes the UI on a stale list. Postgres avoids this if
  columns are typed `text`, but keep the coercion habit for anything free-form.
- **Concurrent procedures:** `activeProc` is a **plain variable** pointing at the current
  room's open case; `_procByRoom` maps room→case; `_procRoom` is the room on screen. After
  any change to either, call `procSyncActive()`. Ending/cancelling a case must remove it from
  `_procByRoom` (`procClearRoom(id)`), not just null the pointer. On load, every room's cart
  is preserved and each Open case is placed into its room slot. **Do not** reintroduce a
  getter/setter accessor for `activeProc` (see §9).
- **Stock is only decremented on End**, never per scan — this is deliberate so mistakes cost
  nothing mid-case. Preserve this in the Supabase version (cart is client/edge state until the
  atomic end call).
- **Sterilisation expiry:** normal flow auto-sets expiry on dispatch (+1 year); only direct
  on-hand entry takes a user-entered expiry.
- **PDF house style:** landscape A4, logo top-left, bold teal title top-right, gold rule under
  the header, `autoTable` grid with teal header rows and light-teal alternating rows. Reused
  by implants, rota, and samples. Copy it for any new report.
- **Sticker geometry:** 3×7 = 21 labels per A4; cell 64.5mm × 40mm. Text that can overflow
  (medication names, TTO directions) auto-shrinks its font rather than clipping.

---

## 9. Bugs already hit and fixed (do not repeat)

1. **Layout flip:** a popover placed as a direct child of the `.app` CSS grid broke the whole
   layout. Body-level overlays must live outside the grid.
2. **Production search freeze:** numeric cell → number → `.toLowerCase()` crash → render aborts
   → stale unfiltered list. Fixed by String-coercing all text fields on read. Diagnosis rule:
   *"works in staging, not production, same code" is almost always a data-shape difference.*
3. **`isAdmin` shadowing:** a bulk rename created `const isAdmin = session && isAdmin()` — a
   local const shadowing the global function (temporal dead zone) — which crashed on click.
   Never name a local the same as a function you call on the same line.
4. **Per-row search boxes:** a search-row template placed inside a `.map()` rendered once per
   data row (10 instruments → 10 boxes). Emit shared UI at the tab's outer return, not inside
   the row loop.
5. **The blank-site accessor bug (most recent):** converting `activeProc` to concurrent rooms
   using `Object.defineProperty(window,'activeProc',{get,set})` **plus** `var activeProc` at
   top level threw on load in the real browser (redefining a property), blanking the entire
   SPA — while Node's looser global tolerated it and hid the fault. Lesson: **top-level
   `var`/`let` and `Object.defineProperty(window,...)` for the same name conflict; never do
   it.** The fix was a plain `let activeProc` kept in sync via `procSyncActive()`/
   `procClearRoom()`. Also: a browser-load simulation (not just `node --check`) is required,
   and a real browser check is the gold standard for load-time errors.
6. **`ROLE_RANK` missing on the frontend:** it existed only in `Code.gs`. Using it in
   `index.html` threw at runtime. Define shared constants on **both** sides (added
   `ROLE_RANK`/`roleRank()`/`isStaffPlus()` to the frontend).
7. **GitHub Pages custom domain unbinding:** editing Cloudflare DNS (or flipping to the orange
   proxy) fails GitHub's health check and GitHub silently removes the custom domain → 404.
   Recovery: re-add the domain in repo Settings → Pages; GitHub may then require **domain
   verification** — add the `_github-pages-challenge-<user>` TXT record in Cloudflare (grey
   cloud), Verify, then re-enter the custom domain and enforce HTTPS. Keep the TXT record
   forever. The `bollin` record must stay **DNS-only (grey cloud)** so Cloudflare never caches.

---

## 10. Testing recipe used throughout

For the single-file app, the smoke-test harness: extract the last `<script>` block, `node
--check` it, then `eval` it in Node under a stubbed `document`/`window`/`localStorage`, with a
recording `jsPDF` stub (chunking `splitTextToSize` so hidden/clipped text is detectable) and a
reassignable `api()` returning fixtures shaped like production. Assertions cover: every view
renders for all four roles; the specific feature's happy path; role gates; and any bug's exact
repro. **Add a full browser-load simulation** (run the whole script, assert it doesn't throw
and that `render`/`loadAll` are defined) to catch load-time errors. For the Supabase rebuild,
prefer real integration tests against a local Supabase instance, especially for the atomic
stock operations and the RLS role gates.
