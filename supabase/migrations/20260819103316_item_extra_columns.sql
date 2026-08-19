-- Real production data (discovered while building the Phase 4 data migration)
-- has columns beyond what migrate()'s declared header list in Code.gs ever
-- specified: Garments carries Brand/Size/Color, Instruments carries
-- Description/Material/Method/MaxCycles. These were maintained directly in
-- the sheet, never through the app's own add/edit dialogs (which only ever
-- touched the declared ITEM_HEADERS) — preserving them here rather than
-- silently dropping real operational data during migration.
alter table items add column if not exists brand text;
alter table items add column if not exists size text;
alter table items add column if not exists color text;
alter table items add column if not exists description text;
alter table items add column if not exists material text;
alter table items add column if not exists method text;
alter table items add column if not exists max_cycles numeric;

-- Historical procedures predate the concurrent-rooms feature and genuinely
-- have no room value — forcing a fake one would misrepresent the data.
alter table procedures alter column room drop not null;

-- get_items() returns setof items, so its column list must be extended to
-- match — same masking logic as before, just with the new columns appended.
create or replace function get_items() returns setof items
language sql stable security definer set search_path = public as $$
  select
    id, tracker, code, barcode, name, category, supplier, location, unit, qty,
    reorder_level,
    case when app_role_rank() >= 1 then unit_cost else null end,
    expiry, batch, notes, status, obsolete, obsolete_by, obsolete_at,
    qty_in_tray, cycles_to_date, created_at, updated_at,
    brand, size, color, description, material, method, max_cycles
  from items;
$$;
