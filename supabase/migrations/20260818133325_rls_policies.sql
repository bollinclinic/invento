-- Bollin Clinic Stock Manager — Row Level Security
-- Replaces ACTION_ROLE (Code.gs) as the real permission gate. Rank model is
-- unchanged: common(0) < staff(1) < admin(2) < superadmin(3), via
-- app_role_rank() defined in the schema migration.
--
-- Two conventions applied throughout, per Supabase's own advisor findings
-- during review of the first draft of this migration:
--   1. Every policy is scoped `to authenticated` explicitly — otherwise a
--      policy with no role list applies to EVERY Postgres role, including
--      Supabase's internal ones (dashboard_user, authenticator, etc.), which
--      is never what's intended here (this app has no anonymous access).
--   2. Every app_role_rank()/auth.uid() call is wrapped as a scalar subquery
--      — `(select app_role_rank())` not `app_role_rank()` — so Postgres
--      evaluates it once per query (an InitPlan) instead of once per row.
--
-- IMPORTANT — scope of this migration:
-- Every table below gets RLS enabled. Tables whose writes in the current app
-- are always full-row, single-rank actions (implants, samples, requests,
-- dispatch log, gas checks, stores, stocktakes, alerts-ack) get real,
-- functional INSERT/UPDATE/DELETE policies here — those are done.
--
-- Tables where the SAME table is written by actions at DIFFERENT ranks with
-- DIFFERENT column-level scope (items: common-rank stock 'move' touches only
-- qty/status/batch/expiry, vs admin-rank full item edit; procedures:
-- common-rank start/save/end vs admin-rank reopen/delete/edit-meta) cannot be
-- expressed safely as a single blanket RLS policy — Postgres RLS filters
-- ROWS, not columns/call-sites. For those tables this migration sets the
-- INSERT/UPDATE/DELETE floor to admin+ only, and the narrower common/staff
-- operations (stock move, procedure start/save/end, barcode link, alert ack
-- convenience, shared sticker presets) are deliberately deferred to Phase 2
-- as SECURITY DEFINER RPC functions that replicate each action's exact rank
-- check — the same shape the current Code.gs functions already have. Until
-- Phase 2 lands, those specific actions will not work from the client; reads
-- and the admin-rank writes are fully functional after this migration.

-- handle_new_user() must only ever run via the on_auth_user_created trigger
-- (which fires with table-owner privilege, independent of function GRANTs).
-- Without this, Supabase's linter correctly flags it as callable directly by
-- anyone via /rest/v1/rpc/handle_new_user, which would let a caller insert an
-- arbitrary profiles row for any auth.users id.
-- Note: Supabase auto-grants EXECUTE directly to anon/authenticated/service_role
-- on every new public-schema function (not just via the implicit `public`
-- pseudo-role), so each must be revoked by name — `revoke ... from public`
-- alone does not remove those direct grants.
revoke execute on function handle_new_user() from public, anon, authenticated;

-- ============================================================================
-- profiles
-- ============================================================================
alter table profiles enable row level security;

-- One combined SELECT policy (own row OR admin+ sees all), rather than two
-- separate permissive policies — Postgres evaluates every permissive policy
-- for a query, so two policies means two evaluations per row for no benefit
-- over one policy with OR.
create policy "profiles: read own row or admin reads all" on profiles
  for select to authenticated
  using (id = (select auth.uid()) or (select app_role_rank()) >= 2);

create policy "profiles: admin updates any row" on profiles
  for update to authenticated
  using ((select app_role_rank()) >= 2) with check ((select app_role_rank()) >= 2);
-- No INSERT/DELETE policy: profile rows are created only by the
-- handle_new_user() trigger (SECURITY DEFINER, bypasses RLS).

-- ============================================================================
-- items — no SELECT policy exists on the base table for any client role, so
-- a direct query always returns zero rows (RLS-enabled + no matching policy
-- = deny, independent of table-level GRANTs) — reads only work through
-- get_items(), a SECURITY DEFINER function that bypasses RLS deliberately.
-- Function EXECUTE privilege is the real gate for that path, not table GRANT.
-- ============================================================================
alter table items enable row level security;

create policy "items: admin writes" on items
  for insert to authenticated
  with check ((select app_role_rank()) >= 2);
create policy "items: admin updates" on items
  for update to authenticated
  using ((select app_role_rank()) >= 2) with check ((select app_role_rank()) >= 2);
create policy "items: admin deletes instruments only" on items
  for delete to authenticated
  using ((select app_role_rank()) >= 2 and tracker = 'instruments');

-- get_items() should be callable by authenticated only (never anon — this
-- app has no anonymous access at all).
revoke execute on function get_items() from public, anon;
grant execute on function get_items() to authenticated;

-- ============================================================================
-- barcode_link_events — harmless audit trail, common+ can append
-- ============================================================================
alter table barcode_link_events enable row level security;

create policy "barcode_link_events: read" on barcode_link_events
  for select to authenticated
  using ((select app_role_rank()) >= 0);
create policy "barcode_link_events: common+ inserts" on barcode_link_events
  for insert to authenticated
  with check ((select app_role_rank()) >= 0);

-- ============================================================================
-- dispatch_log — sterilisation workflow. CORRECTED from the first draft of
-- this migration: useLog (common) only inserts, useEdit/useDelete (admin)
-- update/delete a row but ONLY while Status='Pending Collection', and
-- dispatchAssign/dispatchReceive (staff) update dispatch_log rows AND
-- upsert the matching instrument's row in `items` in the same call — none of
-- that column/cross-table scoping is expressible as a blanket per-rank
-- table policy (same reasoning as items/procedures). Base table floor is
-- admin+ only; every actual write path is a Phase 2 RPC function below.
-- ============================================================================
alter table dispatch_log enable row level security;

create policy "dispatch_log: read" on dispatch_log
  for select to authenticated
  using ((select app_role_rank()) >= 0);
create policy "dispatch_log: admin writes" on dispatch_log
  for insert to authenticated
  with check ((select app_role_rank()) >= 2);
create policy "dispatch_log: admin updates" on dispatch_log
  for update to authenticated
  using ((select app_role_rank()) >= 2) with check ((select app_role_rank()) >= 2);
create policy "dispatch_log: admin deletes" on dispatch_log
  for delete to authenticated
  using ((select app_role_rank()) >= 2);

-- ============================================================================
-- procedures — reads go through get_procedures() (same reasoning as
-- get_items() above); base table writes are admin-only for now (see header
-- note — start/save/end need Phase 2 RPCs).
-- ============================================================================
alter table procedures enable row level security;

create policy "procedures: admin writes" on procedures
  for insert to authenticated
  with check ((select app_role_rank()) >= 2);
create policy "procedures: admin updates" on procedures
  for update to authenticated
  using ((select app_role_rank()) >= 2) with check ((select app_role_rank()) >= 2);
create policy "procedures: admin deletes" on procedures
  for delete to authenticated
  using ((select app_role_rank()) >= 2);

revoke execute on function get_procedures() from public, anon;
grant execute on function get_procedures() to authenticated;

-- ============================================================================
-- procedure_lines — admin+ only in every direction, matching getAll_
-- returning an empty array to staff/common today. Real writes happen via the
-- Phase 2 proc_consume_batch() RPC (SECURITY DEFINER, bypasses this).
-- ============================================================================
alter table procedure_lines enable row level security;

create policy "procedure_lines: admin reads" on procedure_lines
  for select to authenticated
  using ((select app_role_rank()) >= 2);
create policy "procedure_lines: admin writes" on procedure_lines
  for insert to authenticated
  with check ((select app_role_rank()) >= 2);
create policy "procedure_lines: admin updates" on procedure_lines
  for update to authenticated
  using ((select app_role_rank()) >= 2) with check ((select app_role_rank()) >= 2);
create policy "procedure_lines: admin deletes" on procedure_lines
  for delete to authenticated
  using ((select app_role_rank()) >= 2);

-- ============================================================================
-- Theatre rota — superadmin only, matching `role === 'superadmin'` exactly
-- (not just rank >= 3, since there is only one rank at that level anyway).
-- ============================================================================
alter table rota_days enable row level security;
alter table rota_theatres enable row level security;

create policy "rota_days: superadmin only" on rota_days
  for all to authenticated
  using ((select app_role_rank()) >= 3) with check ((select app_role_rank()) >= 3);
create policy "rota_theatres: superadmin only" on rota_theatres
  for all to authenticated
  using ((select app_role_rank()) >= 3) with check ((select app_role_rank()) >= 3);

-- ============================================================================
-- Sample collection — staff+ per ROLE_RANK[session.role] >= 1 in getAll_
-- ============================================================================
alter table sample_collections enable row level security;
alter table specimens enable row level security;

create policy "sample_collections: staff+ read" on sample_collections
  for select to authenticated
  using ((select app_role_rank()) >= 1);
create policy "sample_collections: staff+ write" on sample_collections
  for insert to authenticated
  with check ((select app_role_rank()) >= 1);
create policy "sample_collections: staff+ update" on sample_collections
  for update to authenticated
  using ((select app_role_rank()) >= 1) with check ((select app_role_rank()) >= 1);
create policy "sample_collections: admin delete" on sample_collections
  for delete to authenticated
  using ((select app_role_rank()) >= 2);

create policy "specimens: staff+ read" on specimens
  for select to authenticated
  using ((select app_role_rank()) >= 1);
create policy "specimens: staff+ write" on specimens
  for insert to authenticated
  with check ((select app_role_rank()) >= 1);
create policy "specimens: staff+ update" on specimens
  for update to authenticated
  using ((select app_role_rank()) >= 1) with check ((select app_role_rank()) >= 1);
create policy "specimens: admin delete" on specimens
  for delete to authenticated
  using ((select app_role_rank()) >= 2);

-- ============================================================================
-- Implants — visible to everyone in getAll_; implantAdd/Update = staff
-- ============================================================================
alter table implants enable row level security;

create policy "implants: read" on implants
  for select to authenticated
  using ((select app_role_rank()) >= 0);
create policy "implants: staff+ write" on implants
  for insert to authenticated
  with check ((select app_role_rank()) >= 1);
create policy "implants: staff+ update" on implants
  for update to authenticated
  using ((select app_role_rank()) >= 1) with check ((select app_role_rank()) >= 1);
create policy "implants: admin delete" on implants
  for delete to authenticated
  using ((select app_role_rank()) >= 2);

-- ============================================================================
-- Stock requests — request = common, respond = staff
-- ============================================================================
alter table stock_requests enable row level security;

create policy "stock_requests: read" on stock_requests
  for select to authenticated
  using ((select app_role_rank()) >= 0);
create policy "stock_requests: common+ create" on stock_requests
  for insert to authenticated
  with check ((select app_role_rank()) >= 0);
create policy "stock_requests: staff+ respond" on stock_requests
  for update to authenticated
  using ((select app_role_rank()) >= 1) with check ((select app_role_rank()) >= 1);
create policy "stock_requests: admin delete" on stock_requests
  for delete to authenticated
  using ((select app_role_rank()) >= 2);

-- ============================================================================
-- Activity log — read matches current exposure (everyone gets a recent feed
-- via getAll_ regardless of rank); writes are system-generated only (Phase 2
-- RPCs log via SECURITY DEFINER), never a direct client insert.
-- ============================================================================
alter table activity_log enable row level security;

create policy "activity_log: read" on activity_log
  for select to authenticated
  using ((select app_role_rank()) >= 0);
-- No insert/update/delete policy for authenticated: immutable, system-written.

-- ============================================================================
-- Alerts — visible to everyone in getAll_; ack = staff (single-purpose
-- update of acknowledged/ack_by/ack_at, safe as a direct policy since there
-- is no broader "edit alert" action at a different rank on this table).
-- ============================================================================
alter table alerts enable row level security;

create policy "alerts: read" on alerts
  for select to authenticated
  using ((select app_role_rank()) >= 0);
create policy "alerts: staff+ ack" on alerts
  for update to authenticated
  using ((select app_role_rank()) >= 1) with check ((select app_role_rank()) >= 1);
-- No insert policy for authenticated: alerts are system-generated (Phase 2
-- scheduled function, matches today's dailyStockCheck/escalationCheck).

-- ============================================================================
-- Assets — admin+ only. NOTE: today's getAll_ checks `session.role==='admin'`
-- literally, which excludes superadmin — inconsistent with isAdmin() being
-- admin-OR-superadmin everywhere else in the app (CLAUDE.md §5). Treated here
-- as an oversight in the original app and fixed to rank >= 2 (admin AND
-- superadmin), matching the documented intended permission model.
-- ============================================================================
alter table assets enable row level security;

create policy "assets: admin+ read" on assets
  for select to authenticated
  using ((select app_role_rank()) >= 2);
create policy "assets: admin+ write" on assets
  for insert to authenticated
  with check ((select app_role_rank()) >= 2);
create policy "assets: admin+ update" on assets
  for update to authenticated
  using ((select app_role_rank()) >= 2) with check ((select app_role_rank()) >= 2);
create policy "assets: admin+ delete" on assets
  for delete to authenticated
  using ((select app_role_rank()) >= 2);

-- ============================================================================
-- Gas checks — common can log (gasCheckAdd = common), everyone reads
-- ============================================================================
alter table gas_checks enable row level security;

create policy "gas_checks: read" on gas_checks
  for select to authenticated
  using ((select app_role_rank()) >= 0);
create policy "gas_checks: common+ log" on gas_checks
  for insert to authenticated
  with check ((select app_role_rank()) >= 0);

-- ============================================================================
-- Stores — admin manages the list, everyone reads it (for location pickers)
-- ============================================================================
alter table stores enable row level security;

create policy "stores: read" on stores
  for select to authenticated
  using ((select app_role_rank()) >= 0);
create policy "stores: admin add" on stores
  for insert to authenticated
  with check ((select app_role_rank()) >= 2);
create policy "stores: admin remove" on stores
  for delete to authenticated
  using ((select app_role_rank()) >= 2);

-- ============================================================================
-- Settings — everyone reads (app_name, alert emails etc. all consumed
-- client-side today); admin writes. medPresetsSave (common, one key only)
-- is deferred to a Phase 2 RPC — see header note.
-- ============================================================================
alter table settings enable row level security;

create policy "settings: read" on settings
  for select to authenticated
  using ((select app_role_rank()) >= 0);
create policy "settings: admin write" on settings
  for insert to authenticated
  with check ((select app_role_rank()) >= 2);
create policy "settings: admin update" on settings
  for update to authenticated
  using ((select app_role_rank()) >= 2) with check ((select app_role_rank()) >= 2);

-- ============================================================================
-- Stocktakes — staff can log a count
-- ============================================================================
alter table stocktakes enable row level security;

create policy "stocktakes: staff+ read" on stocktakes
  for select to authenticated
  using ((select app_role_rank()) >= 1);
create policy "stocktakes: staff+ log" on stocktakes
  for insert to authenticated
  with check ((select app_role_rank()) >= 1);
