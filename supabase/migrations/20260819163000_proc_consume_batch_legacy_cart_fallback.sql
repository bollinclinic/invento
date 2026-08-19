-- proc_consume_batch previously matched cart lines to items ONLY by item_id (a uuid).
-- New procedures created in this app always populate item_id from the scan/add-to-cart
-- flow, so that was fine for them — but every migrated procedure's cart (loaded from the
-- old Google Sheets CartJSON, which only ever had code/barcode/name, never a Supabase
-- item_id) has item_id = null on every line. Reopening any of those ~72 migrated
-- procedures for editing and ending it again therefore failed to match ANY line ("item
-- not found" for all of them), silently zeroed total_cost and cleared the cart (the
-- unconditional `cart = '[]'::jsonb` at the end of the old function), and wrote no
-- procedure_lines — destroying the real historical total/cart with no line items ever
-- recorded to replace it. Fixed by falling back to code, then barcode, then name (all
-- scoped to the line's own tracker) when item_id is absent, mirroring the same
-- identifier chain the migration script itself used to resolve items.
create or replace function proc_consume_batch(p_procedure_id uuid, p_lines jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_by text;
  v_line jsonb;
  v_item items%rowtype;
  v_item_id uuid;
  v_tracker tracker_kind;
  v_qty numeric;
  v_new_qty numeric;
  v_line_cost numeric;
  v_running_total numeric := 0;
  v_consumed jsonb := '[]'::jsonb;
  v_failed jsonb := '[]'::jsonb;
begin
  if (select app_role_rank()) < 0 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  select display_name into v_by from profiles where id = auth.uid();

  if not exists (select 1 from procedures where id = p_procedure_id and status = 'Open' for update) then
    raise exception 'Procedure not open or not found';
  end if;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_qty := greatest(1, coalesce((v_line->>'qty')::numeric, 1));
    begin
      v_item_id := nullif(v_line->>'item_id', '')::uuid;
      if v_item_id is not null then
        select * into v_item from items where id = v_item_id for update;
      else
        v_tracker := nullif(v_line->>'tracker', '')::tracker_kind;
        select * into v_item from items
          where tracker = v_tracker
            and ( (nullif(v_line->>'code','') is not null and code = v_line->>'code')
               or (nullif(v_line->>'barcode','') is not null and barcode = v_line->>'barcode')
               or (nullif(v_line->>'name','') is not null and name = v_line->>'name') )
          order by
            (nullif(v_line->>'code','') is not null and code = v_line->>'code') desc,
            (nullif(v_line->>'barcode','') is not null and barcode = v_line->>'barcode') desc
          limit 1
          for update;
      end if;
      if not found then
        v_failed := v_failed || jsonb_build_object('name', v_line->>'name', 'reason', 'item not found');
        continue;
      end if;

      v_new_qty := greatest(0, v_item.qty - v_qty);
      update items set qty = v_new_qty where id = v_item.id;

      v_line_cost := case when v_item.unit_cost is not null then round(v_item.unit_cost * v_qty, 2) else null end;
      if v_line_cost is not null then
        v_running_total := v_running_total + v_line_cost;
      end if;

      insert into procedure_lines (procedure_id, tracker, item_id, code, name, qty, unit_cost, line_cost, by)
      values (p_procedure_id, v_item.tracker, v_item.id, v_item.code, v_item.name, v_qty, v_item.unit_cost, v_line_cost, v_by);

      insert into activity_log (direction, tracker, item_id, code, name, qty, by, note, activity)
      values ('out', v_item.tracker, v_item.id, v_item.code, v_item.name, v_qty, v_by,
        'Consumed — procedure ' || p_procedure_id, 'Stock out');

      v_consumed := v_consumed || jsonb_build_object('name', v_item.name, 'qty', v_qty, 'newQty', v_new_qty);
    exception when others then
      v_failed := v_failed || jsonb_build_object('name', v_line->>'name', 'reason', sqlerrm);
    end;
  end loop;

  update procedures set
    status = 'Closed',
    total_cost = round(v_running_total, 2),
    end_time = now(),
    cart = '[]'::jsonb
  where id = p_procedure_id;

  insert into activity_log (code, name, by, note, activity)
  values (p_procedure_id::text, 'Case closed', v_by,
    jsonb_array_length(v_consumed) || ' line(s) consumed · Total £' || v_running_total::text ||
      case when jsonb_array_length(v_failed) > 0 then ' · ' || jsonb_array_length(v_failed) || ' FAILED' else '' end,
    'Procedure ended');

  return jsonb_build_object('ok', jsonb_array_length(v_failed) = 0,
    'consumed', v_consumed, 'failed', v_failed, 'total', v_running_total);
end;
$$;
