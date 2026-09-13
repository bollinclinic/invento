-- item_move_qty's destination-row lookup used plain `location = p_to_location`, but SQL
-- equality with NULL is never true -- so moving an item TO a blank/no location, when another
-- row for the same tracker+code already sits at a blank location, never found it as a match.
-- The lookup also required a non-blank code to match at all (`coalesce(code,'')<>''`), so any
-- item identified only by barcode (no code) could never match a destination either. In both
-- cases the function fell through to its "nothing already exists there" branch and, for a
-- PARTIAL move (moving less than the full quantity), inserted a brand-new cloned row instead of
-- merging into the existing one -- a genuine duplicate item with the same code/barcode/name,
-- confirmed live: reported after moving location + adjusting quantity on some items, several of
-- which had no location and/or no code set.
create or replace function item_move_qty(p_item_id uuid, p_qty numeric, p_to_location text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tracker tracker_kind;
  v_code text;
  v_barcode text;
  v_current_qty numeric;
  v_dest_id uuid;
  v_full boolean;
begin
  if (select app_role_rank()) < 2 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;

  select tracker, code, barcode, qty into v_tracker, v_code, v_barcode, v_current_qty
  from items where id = p_item_id for update;
  if not found then
    raise exception 'Item not found';
  end if;
  if p_qty is null or p_qty <= 0 then
    raise exception 'Quantity to move must be greater than zero';
  end if;
  if p_qty > v_current_qty then
    raise exception 'Cannot move % — only % in stock', p_qty, v_current_qty;
  end if;
  v_full := (p_qty = v_current_qty);

  -- `is not distinct from` so a blank/NULL destination location correctly matches an existing
  -- blank/NULL-location row instead of never matching (SQL `=` with NULL is never true). Match
  -- on code when the source item has one; otherwise fall back to barcode, so a barcode-only item
  -- can still merge into its own existing row at the destination rather than always cloning.
  select id into v_dest_id from items
    where tracker = v_tracker and location is not distinct from p_to_location and id <> p_item_id
      and (
        (coalesce(v_code,'') <> '' and code = v_code)
        or (coalesce(v_code,'') = '' and coalesce(v_barcode,'') <> '' and barcode = v_barcode)
      )
    for update;

  if v_dest_id is not null then
    update items set qty = qty + p_qty where id = v_dest_id;
    if v_full then
      delete from items where id = p_item_id;
    else
      update items set qty = qty - p_qty where id = p_item_id;
    end if;
    return jsonb_build_object('ok', true, 'split', true, 'merged', true, 'item_id', v_dest_id, 'qty', p_qty);
  end if;

  if v_full then
    update items set location = p_to_location where id = p_item_id;
    return jsonb_build_object('ok', true, 'split', false, 'merged', false, 'item_id', p_item_id, 'qty', p_qty);
  end if;

  update items set qty = qty - p_qty where id = p_item_id;
  insert into items (tracker, code, barcode, name, category, supplier, location, unit, qty,
    reorder_level, unit_cost, expiry, batch, notes, status)
  select tracker, code, barcode, name, category, supplier, p_to_location, unit, p_qty,
    reorder_level, unit_cost, expiry, batch, notes, status
  from items where id = p_item_id
  returning id into v_dest_id;

  return jsonb_build_object('ok', true, 'split', true, 'merged', false, 'item_id', v_dest_id, 'qty', p_qty);
end;
$$;

revoke execute on function item_move_qty(uuid,numeric,text) from public, anon;
grant execute on function item_move_qty(uuid,numeric,text) to authenticated;
