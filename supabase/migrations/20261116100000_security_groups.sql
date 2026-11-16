-- Security group: named permissions, with per-person ticks on top of the role.
--
-- Until now every server rule asked "is this person's ROLE high enough?" (app_role_rank() >= N).
-- This migration gives each of those rules a NAMED permission instead and asks app_can('name').
--
--   * app_permissions  : the catalogue. Each permission has the lowest role that has it by
--                        default (min_rank), which is exactly the level the rule used before.
--   * user_permissions : one row per person per permission the developer has ticked or
--                        unticked for them. No row = the role decides, as before.
--   * app_can(key)     : inactive -> no; developer -> always yes; locked permission -> role
--                        only; otherwise the person's own tick if there is one, else the role.
--
-- NOTHING CHANGES for anyone until a developer changes a tick: with no rows in
-- user_permissions, app_can(key) is the same test as before. The conversion below CHECKS this:
-- it refuses to run unless each rule's old level equals its permission's min_rank.
--
-- The conversion rewrites the live functions and table rules in place (the same text swap on
-- staging and production) and stops with an error, changing nothing, if any rule is not
-- exactly as expected.
--
-- Reads that every screen needs when it loads (rules that only ask "is this an active
-- account?") are left alone on purpose, so unticking a page for someone can never stop the app
-- from loading for them. Their page is hidden and the server refuses their WRITES there.

-- ---------------------------------------------------------------- catalogue
create table app_permissions (
  key       text primary key,
  grp       text not null,
  label     text not null,
  detail    text not null default '',
  kind      text not null check (kind in ('view', 'manage')),
  min_rank  int  not null check (min_rank between 0 and 4),
  locked    boolean not null default false,   -- role only: can never be ticked for a person
  server    boolean not null default true,    -- false = the page is hidden only (no rule in this database behind it)
  sort      int  not null
);
alter table app_permissions enable row level security;
revoke all on app_permissions from public, anon, authenticated;

insert into app_permissions (sort, key, grp, label, kind, min_rank, locked, server, detail) values
  ( 10, 'dashboard.view',   'Overview',          'Dashboard',                          'view',   0, false, false, 'The dashboard and its lists (low stock, out of stock, expiring)'),
  ( 20, 'stock.view',       'Trackers',          'Trackers: view and move stock',      'view',   0, false, true,  'Medicines, consumables, garments, linen: see stock, scan, stock in and out, link a barcode'),
  ( 30, 'stock.manage',     'Trackers',          'Add and edit items',                 'manage', 2, false, true,  'Add items, edit details, set or remove barcodes, print item labels'),
  ( 40, 'costs.view',       'Trackers',          'Costs and prices',                   'view',   1, false, true,  'See unit cost and bill price, and the Stock value page'),
  ( 50, 'stock.bulk',       'Trackers',          'Bulk item tools',                    'manage', 3, false, true,  'Bulk edit, bulk barcodes, bulk obsolete, one-click codes'),
  ( 60, 'stock.delete',     'Trackers',          'Delete an item permanently',         'manage', 4, false, true,  'Remove an obsolete item for good'),
  ( 70, 'steril.view',      'Sterilisation',     'Sterilisation: view and log used',   'view',   0, false, true,  'See instruments and log a tray as used'),
  ( 80, 'steril.dispatch',  'Sterilisation',     'Dispatch and receive',               'manage', 1, false, true,  'Send trays to CSSD, receive them back, add an instrument'),
  ( 90, 'steril.manage',    'Sterilisation',     'Edit and delete',                    'manage', 2, false, true,  'Edit or delete used and on-hand records, delete an instrument'),
  (100, 'stores.manage',    'Stock',             'Stores, offsite and services',       'manage', 2, false, true,  'Stores list, transfers, the offsite store and billable services'),
  (110, 'obsolete.manage',  'Stock',             'Obsolete stock',                     'manage', 2, false, true,  'Mark items obsolete and restore them'),
  (120, 'stocktake.view',   'Stock',             'Stocktake',                          'view',   1, false, true,  'Run a stocktake and apply the counts'),
  (130, 'stocktake.sheet',  'Stock',             'Physical stock-take sheet',          'manage', 3, false, false, 'Print the stock-take sheet'),
  (140, 'alerts.view',      'Stock',             'Alerts',                             'view',   1, false, true,  'See and acknowledge alerts'),
  (150, 'assets.manage',    'Stock',             'Assets register',                    'manage', 2, false, true,  'See and edit the assets register'),
  (160, 'implants.view',    'Implants',          'Implants: view, order, update',      'view',   1, false, true,  'Implant orders, deliveries and use'),
  (170, 'implants.manage',  'Implants',          'Delete implant records',             'manage', 2, false, true,  ''),
  (180, 'requests.use',     'Activity',          'Requests: view and raise',           'view',   0, false, true,  'See stock requests and raise one'),
  (190, 'requests.respond', 'Activity',          'Respond to requests',                'manage', 1, false, true,  ''),
  (200, 'requests.delete',  'Activity',          'Delete requests',                    'manage', 2, false, true,  ''),
  (210, 'log.view',         'Activity',          'Transaction log',                    'view',   0, false, false, ''),
  (220, 'proc.use',         'Records',           'Procedure costing: run a case',      'view',   0, false, true,  'Start a case, scan items, end or cancel it'),
  (230, 'proc.manage',      'Records',           'Procedure costs and admin controls', 'manage', 2, false, true,  'See costs, edit details, reopen, delete, billing lines'),
  (240, 'proc.prefill',     'Records',           'Pre-fill from a past case',          'manage', 4, false, true,  ''),
  (250, 'billing.view',     'Records',           'Surgeon billing report',             'view',   4, false, true,  ''),
  (260, 'itemusage.view',   'Records',           'Item usage search',                  'view',   4, false, true,  ''),
  (270, 'samples.view',     'Records',           'Samples: view and move status',      'view',   0, false, true,  'See sample collections and mark them Sent / Result received'),
  (280, 'samples.edit',     'Records',           'Create and edit samples',            'manage', 1, false, true,  ''),
  (290, 'samples.delete',   'Records',           'Delete samples',                     'manage', 2, false, true,  ''),
  (300, 'tw.view',          'Records',           'Theatre & Ward',                     'view',   0, false, false, 'Saved to SharePoint, not this database: unticking hides the page only'),
  (310, 'gas.view',         'Checks',            'Gas room checks',                    'view',   0, false, true,  'See and log the daily gas room check'),
  (320, 'gas.manage',       'Checks',            'Edit a saved gas check',             'manage', 2, false, true,  ''),
  (330, 'monitor.view',     'Checks',            'Clinical monitoring',                'view',   0, false, false, 'Saved to the Google Sheet, not this database: unticking hides the page only'),
  (340, 'stickers.view',    'Admin',             'Sticker printer',                    'view',   0, false, true,  'Patient, medication, TTO and barcode stickers'),
  (350, 'rota.view',        'Rota',              'Rota and Allocation: view',          'view',   3, false, true,  'See the rota grid, Allocation and the PDFs'),
  (360, 'rota.manage',      'Rota',              'Rota and Allocation: edit',          'manage', 3, false, true,  'Change and save rota days'),
  (370, 'rota.staff',       'Rota',              'Staff database and rota texts',      'manage', 3, false, true,  'Staff mobiles, add or edit staff, text staff'),
  (380, 'users.manage',     'Users',             'Users & roles, Security group',      'manage', 4, true,  true,  'Developers only. Cannot be given to anyone else');

-- ---------------------------------------------------------------- per-person ticks
create table user_permissions (
  user_id  uuid not null references auth.users(id) on delete cascade,
  perm     text not null references app_permissions(key) on delete cascade,
  allowed  boolean not null,
  set_by   text,
  set_at   timestamptz not null default now(),
  primary key (user_id, perm)
);
alter table user_permissions enable row level security;
revoke all on user_permissions from public, anon, authenticated;

-- ---------------------------------------------------------------- the test every rule now uses
create or replace function app_can(p_key text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select case
      when r.rank < 0 then false                         -- no profile, or deactivated
      when p.key is null then false                      -- unknown permission: never allow
      when r.rank >= 4 then true                         -- developers always have everything
      when p.locked then r.rank >= p.min_rank
      else coalesce((select u.allowed from user_permissions u where u.user_id = auth.uid() and u.perm = p.key),
                    r.rank >= p.min_rank)
    end
    from (select app_role_rank() as rank) r
    left join app_permissions p on p.key = p_key), false);
$$;
revoke execute on function app_can(text) from public, anon;
grant execute on function app_can(text) to authenticated;

-- What I can do, for the page: {"stock.view": true, ...}. Inactive = every one false.
create or replace function my_permissions() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(key, app_can(key)), '{}'::jsonb) from app_permissions;
$$;
revoke execute on function my_permissions() from public, anon;
grant execute on function my_permissions() to authenticated;

-- ---------------------------------------------------------------- the Security group page (developer only)
create or replace function security_get() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if app_role_rank() < 4 then raise exception 'Developer access required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'perms', (select jsonb_agg(jsonb_build_object('key', key, 'grp', grp, 'label', label, 'detail', detail, 'kind', kind,
                                                  'min_rank', min_rank, 'locked', locked, 'server', server) order by sort)
                from app_permissions),
    'users', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'username', p.username, 'name', p.display_name,
                                                           'role', p.role, 'active', p.active,
                                                           'ticks', coalesce((select jsonb_object_agg(u.perm, u.allowed) from user_permissions u where u.user_id = p.id), '{}'::jsonb))
                                        order by lower(coalesce(nullif(p.display_name, ''), p.username))), '[]'::jsonb)
                from profiles p));
end $$;
revoke execute on function security_get() from public, anon;
grant execute on function security_get() to authenticated;

-- Replace one person's ticks with p_ticks ({"key": true|false, ...}). A tick that only repeats
-- what the role already gives is not stored, so "no rows" always means "as the role".
create or replace function security_set_user(p_user uuid, p_ticks jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare prof profiles; me text; k text; v jsonb; perm app_permissions; n_on int := 0; n_off int := 0; rnk int;
begin
  if auth.uid() is null or app_role_rank() < 4 then raise exception 'Developer access required' using errcode = '42501'; end if;
  select * into prof from profiles where id = p_user;
  if not found then raise exception 'Person not found'; end if;
  if prof.role::text = 'developer' then raise exception 'A developer always has full access. Change their role first'; end if;
  if p_ticks is null or jsonb_typeof(p_ticks) <> 'object' then raise exception 'The ticks are not valid'; end if;
  rnk := role_rank(prof.role);
  select coalesce(nullif(trim(display_name), ''), username) into me from profiles where id = auth.uid();
  -- check everything before changing anything
  for k, v in select * from jsonb_each(p_ticks) loop
    select * into perm from app_permissions where key = k;
    if not found then raise exception 'Unknown permission: %', k; end if;
    if perm.locked then raise exception '"%" is for developers only and cannot be given to anyone else', perm.label; end if;
    if jsonb_typeof(v) <> 'boolean' then raise exception 'The tick for "%" is not valid', perm.label; end if;
  end loop;
  delete from user_permissions where user_id = p_user;
  for k, v in select * from jsonb_each(p_ticks) loop
    select * into perm from app_permissions where key = k;
    if (v::text = 'true') is distinct from (rnk >= perm.min_rank) then
      insert into user_permissions (user_id, perm, allowed, set_by) values (p_user, k, v::text = 'true', me);
      if v::text = 'true' then n_on := n_on + 1; else n_off := n_off + 1; end if;
    end if;
  end loop;
  insert into activity_log (activity, code, name, by, note)
  values ('Access changed', prof.username, coalesce(nullif(trim(prof.display_name), ''), prof.username), me,
          case when n_on + n_off = 0 then 'Back to what the ' || prof.role::text || ' role gives'
               else n_on || ' given, ' || n_off || ' taken away, on top of the ' || prof.role::text || ' role' end);
  return jsonb_build_object('ok', true, 'given', n_on, 'taken', n_off,
    'ticks', coalesce((select jsonb_object_agg(u.perm, u.allowed) from user_permissions u where u.user_id = p_user), '{}'::jsonb));
end $$;
revoke execute on function security_set_user(uuid, jsonb) from public, anon;
grant execute on function security_set_user(uuid, jsonb) to authenticated;

-- ---------------------------------------------------------------- convert the live rules
do $convert$
declare
  -- function, the level it asked for, its permission
  fn_map constant text[][] := array[
    ['billing_report','4','billing.view'], ['item_usage_report','4','itemusage.view'], ['proc_find_prefill_case','4','proc.prefill'],
    ['dispatch_add','1','steril.dispatch'], ['dispatch_assign','1','steril.dispatch'], ['dispatch_receive','1','steril.dispatch'],
    ['dispatch_return','1','steril.dispatch'], ['instrument_add','1','steril.dispatch'],
    ['gas_check_update','2','gas.manage'],
    ['item_add','2','stock.manage'], ['item_set_barcode','2','stock.manage'], ['item_set_barcode_by_id','2','stock.manage'],
    ['item_clear_barcode','2','stock.manage'], ['item_barcode_remove','2','stock.manage'],
    ['item_bulk_generate_barcodes','3','stock.bulk'], ['item_bulk_obsolete','3','stock.bulk'], ['item_bulk_update','3','stock.bulk'],
    ['item_assign_missing_barcodes','3','stock.bulk'],
    ['item_delete','4','stock.delete'], ['item_delete_instrument','2','steril.manage'],
    ['item_move_qty','2','stores.manage'], ['item_move_store','2','stores.manage'],
    ['move_stock','0','stock.view'], ['link_barcode','0','stock.view'],
    ['proc_cancel','0','proc.use'], ['proc_consume_batch','0','proc.use'], ['proc_save_cart','0','proc.use'],
    ['proc_save_cart_v2','0','proc.use'], ['proc_start','0','proc.use'],
    ['proc_add_billing_line','2','proc.manage'], ['proc_delete','2','proc.manage'], ['proc_reopen','2','proc.manage'],
    ['proc_update_meta','2','proc.manage'],
    ['rota_save_day_v2','3','rota.manage'],
    ['rota_sms_affected','3','rota.staff'], ['rota_sms_cancel','3','rota.staff'], ['rota_sms_preview','3','rota.staff'],
    ['rota_sms_queue','3','rota.staff'], ['sms_queue_test','3','rota.staff'], ['sms_recent','3','rota.staff'],
    ['sms_set_log_days','3','rota.staff'], ['staff_delete','3','rota.staff'], ['staff_upsert','3','rota.staff'],
    ['sample_advance_status','0','samples.view'], ['save_med_preset','0','stickers.view'],
    ['stocktake_apply','1','stocktake.view'],
    ['use_delete','2','steril.manage'], ['use_edit','2','steril.manage'], ['use_log','0','steril.view']];
  -- the three read functions hide costs with "app_role_rank() >= N" (function, level, permission, how many times)
  mask_map constant text[][] := array[
    ['get_items','1','costs.view','2'], ['get_procedures','2','proc.manage','1'], ['get_open_procedures','2','proc.manage','1']];
  -- table, command, level, permission. A rule not listed here is left exactly as it is.
  pol_map constant text[][] := array[
    ['alerts','UPDATE','1','alerts.view'],
    ['assets','DELETE','2','assets.manage'], ['assets','INSERT','2','assets.manage'], ['assets','SELECT','2','assets.manage'], ['assets','UPDATE','2','assets.manage'],
    ['dispatch_log','DELETE','2','steril.manage'], ['dispatch_log','INSERT','2','steril.manage'], ['dispatch_log','UPDATE','2','steril.manage'],
    ['dispatch_log','INSERT','1','steril.dispatch'], ['dispatch_log','UPDATE','1','steril.dispatch'],
    ['gas_checks','INSERT','0','gas.view'],
    ['implants','INSERT','1','implants.view'], ['implants','UPDATE','1','implants.view'], ['implants','DELETE','2','implants.manage'],
    ['items','INSERT','2','stock.manage'], ['items','UPDATE','2','stock.manage'], ['items','DELETE','2','stock.manage'],
    ['procedure_lines','DELETE','2','proc.manage'], ['procedure_lines','INSERT','2','proc.manage'], ['procedure_lines','SELECT','2','proc.manage'], ['procedure_lines','UPDATE','2','proc.manage'],
    ['procedures','DELETE','2','proc.manage'], ['procedures','INSERT','2','proc.manage'], ['procedures','UPDATE','2','proc.manage'],
    ['sample_collections','INSERT','1','samples.edit'], ['sample_collections','UPDATE','1','samples.edit'], ['sample_collections','DELETE','2','samples.delete'],
    ['specimens','INSERT','1','samples.edit'], ['specimens','UPDATE','1','samples.edit'], ['specimens','DELETE','2','samples.delete'],
    ['stock_requests','INSERT','0','requests.use'], ['stock_requests','UPDATE','1','requests.respond'], ['stock_requests','DELETE','2','requests.delete'],
    ['stocktakes','INSERT','1','stocktake.view'], ['stocktakes','SELECT','1','stocktake.view'],
    ['stores','INSERT','2','stores.manage'], ['stores','DELETE','2','stores.manage'],
    ['sms_messages','SELECT','3','rota.staff'], ['staff','SELECT','3','rota.staff']];
  RANK_POL constant text := '( SELECT app_role_rank() AS app_role_rank)';
  m text[]; def text; old text; neu text; n int; mr int; pol record; q text; w text; hit boolean; done int := 0;
begin
  -- ---- functions that refuse with: if (select app_role_rank()) < N then
  foreach m slice 1 in array fn_map loop
    select min_rank into mr from app_permissions where key = m[3];
    if mr is null then raise exception 'security: no permission %', m[3]; end if;
    if mr <> m[2]::int then raise exception 'security: % asked for level % but % is level %', m[1], m[2], m[3], mr; end if;
    select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = m[1];
    if n <> 1 then raise exception 'security: expected one function called %, found %', m[1], n; end if;
    select pg_get_functiondef(p.oid) into def from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = m[1];
    old := '(select app_role_rank()) < ' || m[2];
    neu := 'not app_can(''' || m[3] || ''')';
    n := (length(def) - length(replace(def, old, ''))) / length(old);
    if n <> 1 then raise exception 'security: % has % copies of "%" (expected 1)', m[1], n, old; end if;
    if (length(def) - length(replace(def, 'app_role_rank()', ''))) / length('app_role_rank()') <> 1 then
      raise exception 'security: % checks the role in more than one place', m[1];
    end if;
    execute replace(def, old, neu);
    done := done + 1;
  end loop;

  -- ---- item_update: editing needs stock.manage; marking obsolete / restoring alone needs obsolete.manage
  select pg_get_functiondef('public.item_update'::regproc) into def;
  old := '(select app_role_rank()) < 2';
  if (length(def) - length(replace(def, old, ''))) / length(old) <> 1
     or (select min_rank from app_permissions where key = 'stock.manage') <> 2
     or (select min_rank from app_permissions where key = 'obsolete.manage') <> 2 then
    raise exception 'security: item_update is not as expected';
  end if;
  execute replace(def, old,
    'not (app_can(''stock.manage'') or (app_can(''obsolete.manage'') and (p_fields - ''obsolete'' - ''obsolete_by'' - ''obsolete_at'') = ''{}''::jsonb))');
  done := done + 1;

  -- ---- read functions that hide costs with: app_role_rank() >= N
  foreach m slice 1 in array mask_map loop
    select min_rank into mr from app_permissions where key = m[3];
    if mr is null or mr <> m[2]::int then raise exception 'security: % level % does not match %', m[1], m[2], m[3]; end if;
    select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = m[1];
    if n <> 1 then raise exception 'security: expected one function called %, found %', m[1], n; end if;
    select pg_get_functiondef(p.oid) into def from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = m[1];
    old := 'app_role_rank() >= ' || m[2];
    neu := '(select app_can(''' || m[3] || '''))';      -- worked out once per call, not once per row
    n := (length(def) - length(replace(def, old, ''))) / length(old);
    if n <> m[4]::int then raise exception 'security: % has % copies of "%" (expected %)', m[1], n, old, m[4]; end if;
    execute replace(def, old, neu);
    done := done + 1;
  end loop;

  -- ---- table rules: ( SELECT app_role_rank() AS app_role_rank) >= N
  foreach m slice 1 in array pol_map loop
    select min_rank into mr from app_permissions where key = m[4];
    if mr is null or mr <> m[3]::int then raise exception 'security: rule on % (%) level % does not match %', m[1], m[2], m[3], m[4]; end if;
  end loop;
  for pol in select * from pg_policies where schemaname = 'public' and cmd <> 'ALL'
              and (coalesce(qual, '') like '%app_role_rank%' or coalesce(with_check, '') like '%app_role_rank%') loop
    hit := false;
    foreach m slice 1 in array pol_map loop
      if m[1] = pol.tablename and m[2] = pol.cmd then
        old := RANK_POL || ' >= ' || m[3];
        if position(old in coalesce(pol.qual, '') || coalesce(pol.with_check, '')) > 0 then
          neu := '( SELECT app_can(''' || m[4] || '''))';
          q := replace(pol.qual, old, neu); w := replace(pol.with_check, old, neu);
          if coalesce(q, '') like '%app_role_rank%' or coalesce(w, '') like '%app_role_rank%' then
            raise exception 'security: rule "%" on % still checks the role after conversion', pol.policyname, pol.tablename;
          end if;
          execute format('alter policy %I on public.%I', pol.policyname, pol.tablename)
               || case when q is not null then ' using (' || q || ')' else '' end
               || case when w is not null then ' with check (' || w || ')' else '' end;
          hit := true; done := done + 1;
        end if;
      end if;
    end loop;
    -- a rule we chose to leave: only "any active account" (>= 0), settings and profiles
    if not hit and not (
         (coalesce(pol.qual, '') || coalesce(pol.with_check, '')) like '%' || RANK_POL || ' >= 0%'
         or pol.tablename in ('settings', 'profiles')) then
      raise exception 'security: rule "%" on % (%) was not expected: %', pol.policyname, pol.tablename, pol.cmd, coalesce(pol.qual, pol.with_check);
    end if;
  end loop;

  -- ---- the rota tables had one rule for everything (super admin+). Split: reading is rota.view,
  --      changing is rota.manage (the page itself saves through rota_save_day_v2).
  if (select min_rank from app_permissions where key = 'rota.view') <> 3 or (select min_rank from app_permissions where key = 'rota.manage') <> 3 then
    raise exception 'security: rota levels are not as expected';
  end if;
  foreach old in array array['rota_days', 'rota_theatres'] loop
    select count(*) into n from pg_policies where schemaname = 'public' and tablename = old;
    select count(*) into mr from pg_policies where schemaname = 'public' and tablename = old and cmd = 'ALL'
       and qual = '(' || RANK_POL || ' >= 3)' and with_check = '(' || RANK_POL || ' >= 3)';
    if n <> 1 or mr <> 1 then raise exception 'security: the rules on % are not as expected', old; end if;
    select policyname into neu from pg_policies where schemaname = 'public' and tablename = old;
    execute format('drop policy %I on public.%I', neu, old);
    execute format('create policy %I on public.%I for select to authenticated using ((select app_can(''rota.view'')))', old || ': view', old);
    execute format('create policy %I on public.%I for insert to authenticated with check ((select app_can(''rota.manage'')))', old || ': edit (insert)', old);
    execute format('create policy %I on public.%I for update to authenticated using ((select app_can(''rota.manage''))) with check ((select app_can(''rota.manage'')))', old || ': edit (update)', old);
    execute format('create policy %I on public.%I for delete to authenticated using ((select app_can(''rota.manage'')))', old || ': edit (delete)', old);
    done := done + 1;
  end loop;

  raise notice 'security: % rules converted', done;
end $convert$;
