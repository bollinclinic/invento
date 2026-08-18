-- Bollin Clinic Stock Manager — core schema
-- Mirrors the Google Sheets tabs documented in CLAUDE.md §6 / Code.gs migrate(),
-- normalized into real tables with foreign keys and typed columns.

-- ============================================================================
-- Enum types
-- ============================================================================
create type user_role as enum ('common', 'staff', 'admin', 'superadmin');
create type tracker_kind as enum ('consumables', 'meds', 'garments', 'instruments', 'linen');
create type procedure_status as enum ('Open', 'Closed');
create type theatre_room as enum ('Theatre 1', 'Theatre 2', 'Minor ops');

-- ============================================================================
-- Shared helpers
-- ============================================================================
create or replace function set_updated_at() returns trigger
language plpgsql set search_path = public as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function role_rank(r user_role) returns int
language sql immutable set search_path = public as $$
  select case r
    when 'common' then 0
    when 'staff' then 1
    when 'admin' then 2
    when 'superadmin' then 3
  end;
$$;

-- ============================================================================
-- profiles (role/display-name companion to auth.users)
-- ============================================================================
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique,
  display_name text not null,
  role user_role not null default 'common',
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- app_role_rank() reads the CALLING user's own profile row. SECURITY DEFINER
-- is required here, not optional: this function is also used inside profiles'
-- OWN "admin reads all" RLS policy. If its internal query went through RLS
-- like a normal caller, checking that policy would call this function, whose
-- query would re-check the same policy, calling this function again —
-- infinite recursion (Postgres error 54001 "stack depth limit exceeded").
-- SECURITY DEFINER makes the internal lookup bypass RLS entirely, breaking
-- the cycle. Confirmed live: this exact recursion fired for every admin+
-- login, since only the rank>=2 "read all profiles" path touches the
-- self-referencing policy branch.
create or replace function app_role_rank() returns int
language sql stable security definer set search_path = public as $$
  select coalesce(role_rank((select role from profiles where id = auth.uid())), -1);
$$;

-- Auto-create a profile row whenever a new auth.users row is created.
-- Username/display_name/role are supplied via raw_user_meta_data at signup
-- (set by the admin-created-user flow during migration/user management, not
-- self-signup — there is no public signup form in this app).
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, username, display_name, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1)),
    coalesce(new.raw_user_meta_data->>'display_name', new.raw_user_meta_data->>'username', split_part(new.email, '@', 1)),
    coalesce((new.raw_user_meta_data->>'role')::user_role, 'common')
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- ============================================================================
-- items (Consumables / Meds / Garments / Instruments / Linen — unified)
-- ============================================================================
create table items (
  id uuid primary key default gen_random_uuid(),
  tracker tracker_kind not null,
  code text,
  barcode text,
  name text not null,
  category text,
  supplier text,
  location text,
  unit text not null default 'Each',
  qty numeric not null default 0,
  reorder_level numeric not null default 0,
  unit_cost numeric,
  expiry date,
  batch text,
  notes text,
  status text,
  obsolete boolean not null default false,
  obsolete_by text,
  obsolete_at timestamptz,
  qty_in_tray numeric,          -- instruments only
  cycles_to_date numeric not null default 0,  -- instruments only
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index items_tracker_code_uq on items (tracker, code)
  where code is not null and code <> '';
create unique index items_tracker_barcode_uq on items (tracker, barcode)
  where barcode is not null and barcode <> '';
create index items_tracker_idx on items (tracker);
create index items_obsolete_idx on items (obsolete);
create index items_name_idx on items using gin (to_tsvector('simple', name));

create trigger items_set_updated_at before update on items
  for each row execute function set_updated_at();

-- Read-only accessor: masks unit_cost from role 'common', matching getAll_'s
-- `hideCost = session.role === 'common'` behaviour today.
-- A SECURITY DEFINER FUNCTION, not a view: Supabase's linter flags views as
-- an ERROR here because a plain view's implicit owner-context read is a
-- common accidental-RLS-bypass footgun, indistinguishable from an intentional
-- one. An explicit `security definer` function is the sanctioned equivalent —
-- same "runs with the function owner's table access" mechanism, but opted
-- into deliberately and visibly. authenticated has no grant on the base
-- `items` table at all (see rls_policies.sql), so this function and the
-- Phase-2 RPC functions are the only path to items data; unit_cost can never
-- be read around the masking CASE below. app_role_rank() still resolves to
-- the real caller because auth.uid() reads the request's JWT claim,
-- independent of the function's SECURITY DEFINER privilege context.
create or replace function get_items() returns setof items
language sql stable security definer set search_path = public as $$
  select
    id, tracker, code, barcode, name, category, supplier, location, unit, qty,
    reorder_level,
    case when app_role_rank() >= 1 then unit_cost else null end,
    expiry, batch, notes, status, obsolete, obsolete_by, obsolete_at,
    qty_in_tray, cycles_to_date, created_at, updated_at
  from items;
$$;

-- Audit trail for barcode -> item linking (the `link` action). items.barcode
-- remains the live lookup column; this table is history only.
create table barcode_link_events (
  id bigint generated always as identity primary key,
  barcode text not null,
  tracker tracker_kind not null,
  item_id uuid references items(id) on delete set null,
  code text,
  linked_by uuid references profiles(id),
  linked_at timestamptz not null default now()
);
create index barcode_link_events_item_idx on barcode_link_events (item_id);
create index barcode_link_events_linked_by_idx on barcode_link_events (linked_by);

-- ============================================================================
-- dispatch_log (sterilisation workflow: used -> dispatched -> received)
-- ============================================================================
create table dispatch_log (
  id uuid primary key default gen_random_uuid(),
  dispatch_ref text,
  item_id uuid references items(id) on delete set null,
  item_name text not null,
  code text,
  date_sent date,
  sent_by text,
  count_out numeric,
  batch_lot text,
  instructions text,
  collected_by text,
  date_collected date,
  countess_ref text,
  date_returned date,
  returned_by text,
  count_in numeric,
  status text not null default 'Out',
  date_used date,
  used_by text,
  created_at timestamptz not null default now()
);
create index dispatch_log_item_idx on dispatch_log (item_id);
create index dispatch_log_status_idx on dispatch_log (status);

-- ============================================================================
-- procedures / procedure_lines (case costing)
-- ============================================================================
create table procedures (
  id uuid primary key default gen_random_uuid(),
  date date not null,
  surgeon text,
  procedure_name text,
  patient_ref text,
  started_by text,
  status procedure_status not null default 'Open',
  start_time timestamptz not null default now(),
  end_time timestamptz,
  total_cost numeric,
  notes text,
  cart jsonb not null default '[]'::jsonb,
  room theatre_room not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Enforces "one open case per room" at the database level (previously an
-- app-level check in procStart_).
create unique index procedures_one_open_per_room on procedures (room)
  where status = 'Open';
create index procedures_status_room_idx on procedures (status, room);

create trigger procedures_set_updated_at before update on procedures
  for each row execute function set_updated_at();

create table procedure_lines (
  id bigint generated always as identity primary key,
  procedure_id uuid not null references procedures(id) on delete cascade,
  ts timestamptz not null default now(),
  tracker tracker_kind not null,
  item_id uuid references items(id) on delete set null,
  code text,
  name text not null,
  qty numeric not null,
  unit_cost numeric,
  line_cost numeric,
  by text
);
create index procedure_lines_procedure_idx on procedure_lines (procedure_id);
create index procedure_lines_item_idx on procedure_lines (item_id);

-- Read-only accessor: masks total_cost for role rank < 2 (staff/common),
-- matching procForRole_'s `o.TotalCost = ''` behaviour today. Same
-- SECURITY DEFINER FUNCTION reasoning as get_items() above.
create or replace function get_procedures() returns setof procedures
language sql stable security definer set search_path = public as $$
  select
    id, date, surgeon, procedure_name, patient_ref, started_by, status,
    start_time, end_time,
    case when app_role_rank() >= 2 then total_cost else null end,
    notes, cart, room, created_at, updated_at
  from procedures;
$$;

-- ============================================================================
-- Theatre rota (superadmin only)
-- ============================================================================
create table rota_days (
  id uuid primary key default gen_random_uuid(),
  date date not null unique,
  theatres int not null default 0,
  hca_ward text,
  hca_theatre text,
  ward_nurse text,
  night_nurse text,
  recovery_nurse text,
  rmo_day text,
  rmo_night text,
  housekeeping_am text,
  housekeeping_pm text,
  reception_am text,
  reception_pm text,
  notes text,
  acks jsonb not null default '{}'::jsonb,   -- silenced-gap cover notes
  stars jsonb not null default '{}'::jsonb,  -- provisional-booking flags
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger rota_days_set_updated_at before update on rota_days
  for each row execute function set_updated_at();

create table rota_theatres (
  id uuid primary key default gen_random_uuid(),
  day_id uuid not null references rota_days(id) on delete cascade,
  theatre_number int not null check (theatre_number >= 1),
  type text not null default 'GA',
  detail text,
  colour text,
  surgeon text,
  surgeon2 text,
  surgeon3 text,
  anaesthetist text,
  sfa text,
  scrub1 text,
  scrub2 text,
  scrub3 text,
  odp text,
  cases jsonb not null default '[]'::jsonb,
  unique (day_id, theatre_number)
);

-- ============================================================================
-- Sample collection (specimens)
-- ============================================================================
create table sample_collections (
  id uuid primary key default gen_random_uuid(),
  date date not null,
  patient_initials text,
  pat_number text,
  surgeon text,
  logged_by text,
  created_at timestamptz not null default now()
);
create index sample_collections_pat_idx on sample_collections (pat_number);

create table specimens (
  id uuid primary key default gen_random_uuid(),
  collection_id uuid not null references sample_collections(id) on delete cascade,
  specimen_no text,
  details text,
  category text,
  formalin boolean,
  date_collected date,
  date_sent date,
  date_result date,
  notes text,
  created_at timestamptz not null default now()
);
create index specimens_collection_idx on specimens (collection_id);

-- ============================================================================
-- Implants
-- ============================================================================
create table implants (
  id uuid primary key default gen_random_uuid(),
  patient_initials text,
  pat_number text,
  surgeon text,
  surgery_date date,
  details text,
  qty numeric,
  remarks text,
  date_ordered date,
  ordered_by text,
  status text not null default 'Pending',
  received_by text,
  received_date date,
  received_qty numeric,
  storage_location text,
  scanned_ref text,
  return_details text,
  returned_qty numeric,
  returned_by text,
  returned_date date,
  notes text,
  created_at timestamptz not null default now()
);

-- ============================================================================
-- Stock requests
-- ============================================================================
create table stock_requests (
  id uuid primary key default gen_random_uuid(),
  requested_at timestamptz not null default now(),
  requested_by text,
  item text not null,
  qty numeric,
  size text,
  status text not null default 'Requested',
  handled_by text,
  responded_at timestamptz,
  remarks text
);

-- ============================================================================
-- Activity log (Transactions tab)
-- ============================================================================
create table activity_log (
  id bigint generated always as identity primary key,
  ts timestamptz not null default now(),
  direction text,
  tracker tracker_kind,
  item_id uuid references items(id) on delete set null,
  code text,
  name text,
  qty numeric,
  by text,
  batch text,
  expiry date,
  note text,
  activity text
);
create index activity_log_ts_idx on activity_log (ts desc);
create index activity_log_item_idx on activity_log (item_id);

-- ============================================================================
-- Alerts
-- ============================================================================
-- Columns match what dailyStockCheck_/ackAlert_/escalationCheck_ actually
-- write in Code.gs (a positional appendRow whose order doesn't match
-- migrate()'s declared header list — a real bug in the current app; this
-- table is built from the true write order, not the mislabeled headers).
create table alerts (
  id bigint generated always as identity primary key,
  ts timestamptz not null default now(),
  type text not null,
  tracker tracker_kind,
  item_id uuid references items(id) on delete set null,
  code text,
  name text,
  detail text,
  status text not null default 'Sent',
  ack_by text,
  ack_at timestamptz
);
create index alerts_item_idx on alerts (item_id);

-- ============================================================================
-- Assets (admin only, invisible to other roles)
-- ============================================================================
create table assets (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  serial_number text,
  function text,
  supplier text,
  supplier_contact text,
  location text,
  last_maintenance date,
  next_maintenance_due date,
  status text not null default 'Working',
  notes text
);

-- ============================================================================
-- Gas room daily checks
-- ============================================================================
create table gas_checks (
  id bigint generated always as identity primary key,
  ts timestamptz not null default now(),
  date date not null,
  by text,
  o2_left_bank numeric,
  o2_right_bank numeric,
  o2_pipeline numeric,
  o2_in_use_bank text,
  o2_delivery_booked boolean not null default false,
  air_left_bank numeric,
  air_right_bank numeric,
  air_pipeline numeric,
  air_in_use_bank text,
  air_delivery_booked boolean not null default false,
  helium_total numeric,
  helium_full numeric,
  helium_empty numeric,
  trolley_o2_total numeric,
  trolley_o2_full numeric,
  trolley_o2_empty numeric,
  trolley_o2_next_delivery date,
  vacuum_duty_pump text,
  vacuum_status text,
  airflow_th1_off boolean not null default false,
  airflow_th2_off boolean not null default false,
  notes text
);

-- ============================================================================
-- Stores (named storage locations per tracker)
-- ============================================================================
create table stores (
  id bigint generated always as identity primary key,
  tracker tracker_kind not null,
  store text not null,
  unique (tracker, store)
);

-- ============================================================================
-- Settings (key/value)
-- ============================================================================
create table settings (
  key text primary key,
  value text,
  description text
);

-- ============================================================================
-- Stocktakes
-- ============================================================================
create table stocktakes (
  id bigint generated always as identity primary key,
  ts timestamptz not null default now(),
  check_type text not null default 'Month-end',
  tracker tracker_kind,
  store text,
  by text,
  code text,
  name text,
  expected numeric,
  counted numeric,
  variance numeric,
  unit_cost numeric,
  variance_value numeric
);
