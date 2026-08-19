-- Every direct client-side write to `items` (addItem/updateItem/setBarcodes/clearBarcode/
-- moveStore/instrumentDelete) has been silently broken since the Supabase port: `items` has
-- no SELECT policy (deliberate — it masks unit_cost from common-rank users), and it turns out
-- PostgREST cannot reliably perform a client-issued INSERT/UPDATE/DELETE against a table with
-- RLS enabled and no SELECT policy — UPDATE returns HTTP 200 with zero rows affected and no
-- error (confirmed empirically: identical policy shape on `settings`, which DOES have a SELECT
-- policy, works correctly for the same session), while INSERT is rejected outright with a
-- 42501 "row violates row-level security policy" error despite the WITH CHECK condition
-- provably passing in isolation. Net effect: the "Edit item" dialog, "Add item", barcode
-- linking cleanup, store moves, and instrument deletion have never actually persisted to the
-- database — the frontend applied changes to local state optimistically and reported success
-- regardless. Fixed by moving every items mutation through SECURITY DEFINER RPC functions,
-- the same pattern already used successfully by move_stock/link_barcode (which is exactly why
-- day-to-day stock scanning has always worked while editing an item's own fields never did).

create or replace function item_add(p_tracker tracker_kind, p_fields jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if (select app_role_rank()) < 2 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  insert into items (tracker, code, barcode, name, category, supplier, location, unit, qty,
    reorder_level, unit_cost, expiry, batch, notes, status, obsolete, obsolete_by, obsolete_at,
    qty_in_tray, cycles_to_date, brand, size, color, description, material, method, max_cycles)
  values (
    p_tracker,
    nullif(p_fields->>'code',''), nullif(p_fields->>'barcode',''), p_fields->>'name',
    nullif(p_fields->>'category',''), nullif(p_fields->>'supplier',''), nullif(p_fields->>'location',''),
    coalesce(nullif(p_fields->>'unit',''), 'Each'), coalesce((p_fields->>'qty')::numeric, 0),
    coalesce((p_fields->>'reorder_level')::numeric, 0), nullif(p_fields->>'unit_cost','')::numeric,
    nullif(p_fields->>'expiry','')::date, nullif(p_fields->>'batch',''), nullif(p_fields->>'notes',''),
    nullif(p_fields->>'status',''), coalesce((p_fields->>'obsolete')::boolean, false),
    nullif(p_fields->>'obsolete_by',''), nullif(p_fields->>'obsolete_at','')::timestamptz,
    nullif(p_fields->>'qty_in_tray','')::numeric, coalesce((p_fields->>'cycles_to_date')::numeric, 0),
    nullif(p_fields->>'brand',''), nullif(p_fields->>'size',''), nullif(p_fields->>'color',''),
    nullif(p_fields->>'description',''), nullif(p_fields->>'material',''), nullif(p_fields->>'method',''),
    nullif(p_fields->>'max_cycles','')::numeric
  ) returning id into v_id;
  return v_id;
end;
$$;

create or replace function item_update(p_item_id uuid, p_fields jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if (select app_role_rank()) < 2 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  update items set
    code = case when p_fields ? 'code' then nullif(p_fields->>'code','') else code end,
    barcode = case when p_fields ? 'barcode' then nullif(p_fields->>'barcode','') else barcode end,
    name = case when p_fields ? 'name' then p_fields->>'name' else name end,
    category = case when p_fields ? 'category' then nullif(p_fields->>'category','') else category end,
    supplier = case when p_fields ? 'supplier' then nullif(p_fields->>'supplier','') else supplier end,
    location = case when p_fields ? 'location' then nullif(p_fields->>'location','') else location end,
    unit = case when p_fields ? 'unit' then coalesce(nullif(p_fields->>'unit',''),'Each') else unit end,
    qty = case when p_fields ? 'qty' then (p_fields->>'qty')::numeric else qty end,
    reorder_level = case when p_fields ? 'reorder_level' then (p_fields->>'reorder_level')::numeric else reorder_level end,
    unit_cost = case when p_fields ? 'unit_cost' then nullif(p_fields->>'unit_cost','')::numeric else unit_cost end,
    expiry = case when p_fields ? 'expiry' then nullif(p_fields->>'expiry','')::date else expiry end,
    batch = case when p_fields ? 'batch' then nullif(p_fields->>'batch','') else batch end,
    notes = case when p_fields ? 'notes' then nullif(p_fields->>'notes','') else notes end,
    status = case when p_fields ? 'status' then nullif(p_fields->>'status','') else status end,
    obsolete = case when p_fields ? 'obsolete' then (p_fields->>'obsolete')::boolean else obsolete end,
    obsolete_by = case when p_fields ? 'obsolete_by' then nullif(p_fields->>'obsolete_by','') else obsolete_by end,
    obsolete_at = case when p_fields ? 'obsolete_at' then nullif(p_fields->>'obsolete_at','')::timestamptz else obsolete_at end,
    qty_in_tray = case when p_fields ? 'qty_in_tray' then nullif(p_fields->>'qty_in_tray','')::numeric else qty_in_tray end,
    cycles_to_date = case when p_fields ? 'cycles_to_date' then (p_fields->>'cycles_to_date')::numeric else cycles_to_date end,
    brand = case when p_fields ? 'brand' then nullif(p_fields->>'brand','') else brand end,
    size = case when p_fields ? 'size' then nullif(p_fields->>'size','') else size end,
    color = case when p_fields ? 'color' then nullif(p_fields->>'color','') else color end,
    description = case when p_fields ? 'description' then nullif(p_fields->>'description','') else description end,
    material = case when p_fields ? 'material' then nullif(p_fields->>'material','') else material end,
    method = case when p_fields ? 'method' then nullif(p_fields->>'method','') else method end,
    max_cycles = case when p_fields ? 'max_cycles' then nullif(p_fields->>'max_cycles','')::numeric else max_cycles end
  where id = p_item_id;
  if not found then
    raise exception 'Item not found';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function item_set_barcode(p_tracker tracker_kind, p_code text, p_barcode text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if (select app_role_rank()) < 2 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  update items set barcode = p_barcode where tracker = p_tracker and code = p_code;
  return jsonb_build_object('ok', true, 'matched', found);
end;
$$;

create or replace function item_clear_barcode(p_item_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if (select app_role_rank()) < 2 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  update items set barcode = null where id = p_item_id;
  if not found then
    raise exception 'Item not found';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function item_move_store(p_item_ids uuid[], p_location text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if (select app_role_rank()) < 2 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  update items set location = p_location where id = any(p_item_ids);
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function item_delete_instrument(p_item_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if (select app_role_rank()) < 2 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  delete from items where id = p_item_id and tracker = 'instruments';
  if not found then
    raise exception 'Instrument not found';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

do $$
declare fn text;
begin
  foreach fn in array array[
    'item_add(tracker_kind,jsonb)',
    'item_update(uuid,jsonb)',
    'item_set_barcode(tracker_kind,text,text)',
    'item_clear_barcode(uuid)',
    'item_move_store(uuid[],text)',
    'item_delete_instrument(uuid)'
  ]
  loop
    execute format('revoke execute on function %s from public, anon', fn);
    execute format('grant execute on function %s to authenticated', fn);
  end loop;
end;
$$;
