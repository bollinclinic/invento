-- Developer-only permanent item delete, for the Edit Item modal (Consumables/Medicines) and
-- Obsolete Stock. Every table with a foreign key to items(id) -- barcode_link_events,
-- dispatch_log, procedure_lines, activity_log, alerts -- was already built with
-- "on delete set null" (see 20260818133322_schema.sql), so deleting an item preserves that
-- history (each row keeps its own snapshotted name/code/qty) while just dropping the live
-- link; a plain `delete from items` is already safe by design, no cascade logic needed here.
--
-- stocktakes is the one exception: it was never given a foreign key at all (it's matched by
-- tracker + code/name snapshot, same as the old Sheets model), so it needs an explicit cleanup
-- -- "delete the item and its recorded counts" means both. Matched against the item's code,
-- barcode, AND name (whichever was used as the identity value at the time a given stocktake
-- was logged -- saveStocktake sends code||barcode||name), scoped to the same tracker so a
-- blank/shared value can't reach into an unrelated item's history.
create or replace function item_delete(p_item_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_item items%rowtype;
  v_stk_count int;
begin
  if (select app_role_rank()) < 4 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;

  select * into v_item from items where id = p_item_id for update;
  if not found then
    raise exception 'Item not found';
  end if;

  delete from stocktakes
    where tracker = v_item.tracker
      and code in (nullif(v_item.code,''), nullif(v_item.barcode,''), nullif(v_item.name,''));
  get diagnostics v_stk_count = row_count;

  delete from items where id = p_item_id;

  return jsonb_build_object('ok', true, 'name', v_item.name, 'stocktakes_removed', v_stk_count);
end;
$$;

revoke execute on function item_delete(uuid) from public, anon;
grant execute on function item_delete(uuid) to authenticated;
