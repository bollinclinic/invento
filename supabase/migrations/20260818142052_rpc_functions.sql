-- Bollin Clinic Stock Manager — Phase 2: RPC functions
-- Every function here mirrors one action from Code.gs's ACTION_ROLE dispatch,
-- reproducing its exact rank check and business logic as a SECURITY DEFINER
-- Postgres function (transactional by default). Each function performs its
-- OWN authorization check as the first statement, because SECURITY DEFINER
-- bypasses the base table's RLS policies entirely — the function body is the
-- real gate for everything it touches, exactly like doPost's
-- `ROLE_RANK[session.role] < ROLE_RANK[need]` check today.
--
-- All are `to authenticated` only, never anon (this app has no anonymous
-- access at all).

-- ============================================================================
-- items: move (stock in/out — common+; touches only qty/status/batch/expiry,
-- never the full-edit fields that addItem/updateItem (admin) can touch)
-- ============================================================================
create or replace function move_stock(
  p_item_id uuid,
  p_direction text,
  p_qty numeric,
  p_batch text default null,
  p_expiry date default null,
  p_note text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_item items%rowtype;
  v_new_qty numeric;
  v_by text;
begin
  if (select app_role_rank()) < 0 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  if p_direction not in ('in', 'out') then
    raise exception 'direction must be in or out';
  end if;

  select display_name into v_by from profiles where id = auth.uid();
  select * into v_item from items where id = p_item_id for update;
  if not found then
    raise exception 'Item not found';
  end if;

  if v_item.tracker = 'instruments' then
    update items set
      status = case when p_direction = 'out' then 'At Countess' else 'At Bollin' end,
      cycles_to_date = case when p_direction = 'in' then cycles_to_date + 1 else cycles_to_date end
    where id = p_item_id;
    v_new_qty := null;
  else
    v_new_qty := v_item.qty + (case when p_direction = 'in' then p_qty else -p_qty end);
    if v_new_qty < 0 then
      raise exception 'Only % in stock', v_item.qty;
    end if;
    update items set
      qty = v_new_qty,
      batch = case when p_direction = 'in' and p_batch is not null then p_batch else batch end,
      expiry = case when p_direction = 'in' and p_expiry is not null then p_expiry else expiry end
    where id = p_item_id;
  end if;

  insert into activity_log (direction, tracker, item_id, code, name, qty, by, batch, expiry, note, activity)
  values (p_direction, v_item.tracker, p_item_id, v_item.code, v_item.name, p_qty, v_by, p_batch, p_expiry, p_note,
    case when p_direction = 'in' then 'Stock in' else 'Stock out' end);

  return jsonb_build_object('ok', true, 'newQty', v_new_qty, 'name', v_item.name);
end;
$$;

-- ============================================================================
-- items: link (scanned unknown barcode -> existing item — common+)
-- ============================================================================
create or replace function link_barcode(p_item_id uuid, p_barcode text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_item items%rowtype;
begin
  if (select app_role_rank()) < 0 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  select * into v_item from items where id = p_item_id for update;
  if not found then
    raise exception 'Item not found';
  end if;

  update items set barcode = p_barcode where id = p_item_id;

  insert into barcode_link_events (barcode, tracker, item_id, code, linked_by)
  values (p_barcode, v_item.tracker, p_item_id, v_item.code, auth.uid());

  return jsonb_build_object('ok', true);
end;
$$;

-- ============================================================================
-- items: instrumentAdd (direct-add an already-sterile item onto on-hand —
-- staff+, below the admin+ floor that gates addItem/updateItem)
-- ============================================================================
create or replace function instrument_add(p_fields jsonb) returns items
language plpgsql security definer set search_path = public as $$
declare
  v_row items;
begin
  if (select app_role_rank()) < 1 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  if coalesce(p_fields->>'name', '') = '' then
    raise exception 'Name required';
  end if;

  insert into items (tracker, code, barcode, name, category, supplier, location, unit,
    qty, reorder_level, unit_cost, expiry, batch, notes, status, qty_in_tray)
  values ('instruments', p_fields->>'code', p_fields->>'barcode', p_fields->>'name',
    p_fields->>'category', p_fields->>'supplier', p_fields->>'location',
    coalesce(p_fields->>'unit', 'Each'),
    coalesce((p_fields->>'qty')::numeric, 1), coalesce((p_fields->>'reorder_level')::numeric, 0),
    nullif(p_fields->>'unit_cost', '')::numeric, nullif(p_fields->>'expiry', '')::date,
    p_fields->>'batch', p_fields->>'notes', coalesce(p_fields->>'status', 'At Bollin'),
    nullif(p_fields->>'qty_in_tray', '')::numeric)
  returning * into v_row;

  insert into activity_log (tracker, item_id, code, name, qty, activity)
  values ('instruments', v_row.id, v_row.code, v_row.name, v_row.qty_in_tray, 'Instrument registered');

  return v_row;
end;
$$;

-- ============================================================================
-- procedures: procStart (common+). One-open-case-per-room is enforced by the
-- procedures_one_open_per_room unique index from the schema migration.
-- ============================================================================
create or replace function proc_start(
  p_date date,
  p_surgeon text,
  p_procedure_name text,
  p_patient_ref text,
  p_room theatre_room
) returns procedures
language plpgsql security definer set search_path = public as $$
declare
  v_by text;
  v_row procedures;
begin
  if (select app_role_rank()) < 0 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  select display_name into v_by from profiles where id = auth.uid();

  begin
    insert into procedures (date, surgeon, procedure_name, patient_ref, started_by, room)
    values (p_date, p_surgeon, p_procedure_name, p_patient_ref, v_by, p_room)
    returning * into v_row;
  exception when unique_violation then
    raise exception '% already has an open case', p_room;
  end;

  return v_row;
end;
$$;

-- ============================================================================
-- procedures: procSaveCart (common+) — cart is client/edge state until End;
-- (procGetCart needs no RPC — get_procedures() already returns cart to
-- everyone, it is only total_cost that get_procedures() masks)
-- ============================================================================
create or replace function proc_save_cart(p_procedure_id uuid, p_cart jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if (select app_role_rank()) < 0 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  update procedures set cart = p_cart where id = p_procedure_id and status = 'Open';
  if not found then
    raise exception 'Procedure not open or not found';
  end if;
end;
$$;

-- ============================================================================
-- procedures: procCancel (common+) — nothing was consumed pre-end, so this
-- is just a delete of the still-Open row.
-- ============================================================================
create or replace function proc_cancel(p_procedure_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if (select app_role_rank()) < 0 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  delete from procedures where id = p_procedure_id and status = 'Open';
  if not found then
    raise exception 'Only an open, not-yet-ended case can be cancelled';
  end if;
end;
$$;

-- ============================================================================
-- procedures: procConsumeBatch (common+) — THE correctness-critical one.
-- Decrements stock, writes every procedure_lines row, and closes the case in
-- a single transaction (a Postgres function body already IS one transaction,
-- so this is atomic by construction — no client refresh can interrupt it
-- half-way, matching procConsumeBatch_'s single-request design in Code.gs).
-- `for update` on the procedure row also guards against a double-submitted
-- End racing itself. p_lines items are addressed by item_id (a stable uuid)
-- instead of the old code->barcode->name text-matching fallback chain —
-- blank-code meds are no longer a special case, the frontend already knows
-- exactly which row it means.
-- ============================================================================
create or replace function proc_consume_batch(p_procedure_id uuid, p_lines jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_by text;
  v_line jsonb;
  v_item items%rowtype;
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
      select * into v_item from items where id = (v_line->>'item_id')::uuid for update;
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

-- ============================================================================
-- procedures: procReopen (admin+) — restores every consumed line's stock,
-- deletes the lines, rebuilds the cart from them, reopens the case.
-- ============================================================================
create or replace function proc_reopen(p_procedure_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_line procedure_lines%rowtype;
  v_cart jsonb := '[]'::jsonb;
  v_restored int := 0;
  v_failed jsonb := '[]'::jsonb;
  v_by text;
begin
  if (select app_role_rank()) < 2 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  select display_name into v_by from profiles where id = auth.uid();

  if not exists (select 1 from procedures where id = p_procedure_id and status = 'Closed') then
    raise exception 'Only a closed case can be reopened';
  end if;

  for v_line in select * from procedure_lines where procedure_id = p_procedure_id loop
    if v_line.item_id is not null then
      update items set qty = qty + v_line.qty where id = v_line.item_id;
      v_restored := v_restored + 1;
    else
      v_failed := v_failed || jsonb_build_object('name', v_line.name, 'reason', 'item no longer exists');
    end if;
    v_cart := v_cart || jsonb_build_object('item_id', v_line.item_id, 'tracker', v_line.tracker,
      'code', v_line.code, 'name', v_line.name, 'qty', v_line.qty);
  end loop;

  delete from procedure_lines where procedure_id = p_procedure_id;

  update procedures set status = 'Open', cart = v_cart, total_cost = null, end_time = null
  where id = p_procedure_id;

  insert into activity_log (code, name, by, note, activity)
  values (p_procedure_id::text, 'Case reopened', v_by,
    v_restored || ' line(s) stock restored' ||
      case when jsonb_array_length(v_failed) > 0 then ' · ' || jsonb_array_length(v_failed) || ' could not be restored' else '' end,
    'Procedure reopened');

  return jsonb_build_object('ok', true, 'restored', v_restored, 'failed', v_failed);
end;
$$;

-- ============================================================================
-- procedures: procDelete (admin+) — restores stock only if the case was
-- Closed (an Open case never consumed anything); removes lines + the row.
-- ============================================================================
create or replace function proc_delete(p_procedure_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_line procedure_lines%rowtype;
  v_restored int := 0;
  v_failed jsonb := '[]'::jsonb;
  v_by text;
  v_status procedure_status;
begin
  if (select app_role_rank()) < 2 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  select display_name into v_by from profiles where id = auth.uid();

  select status into v_status from procedures where id = p_procedure_id;
  if not found then
    raise exception 'Procedure not found';
  end if;

  if v_status = 'Closed' then
    for v_line in select * from procedure_lines where procedure_id = p_procedure_id loop
      if v_line.item_id is not null then
        update items set qty = qty + v_line.qty where id = v_line.item_id;
        v_restored := v_restored + 1;
      else
        v_failed := v_failed || jsonb_build_object('name', v_line.name, 'reason', 'item no longer exists');
      end if;
    end loop;
  end if;

  delete from procedure_lines where procedure_id = p_procedure_id;
  delete from procedures where id = p_procedure_id;

  insert into activity_log (code, name, by, note, activity)
  values (p_procedure_id::text, 'Case deleted', v_by, v_restored || ' line(s) stock restored', 'Procedure deleted');

  return jsonb_build_object('ok', true, 'restored', v_restored, 'failed', v_failed);
end;
$$;

-- ============================================================================
-- dispatch_log: useLog (common+) — pure insert, no items interaction.
-- ============================================================================
create or replace function use_log(p_lines jsonb, p_date date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_by text;
  v_line jsonb;
  v_added int := 0;
begin
  if (select app_role_rank()) < 0 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  if jsonb_array_length(p_lines) = 0 then
    raise exception 'No lines';
  end if;
  select display_name into v_by from profiles where id = auth.uid();

  for v_line in select * from jsonb_array_elements(p_lines) loop
    insert into dispatch_log (item_name, code, count_out, status, date_used, used_by)
    values (v_line->>'name', v_line->>'code', greatest(1, coalesce((v_line->>'qty')::numeric, 1)),
      'Pending Collection', coalesce(p_date, current_date), v_by);
    insert into activity_log (code, name, qty, by, activity)
    values (v_line->>'code', v_line->>'name', (v_line->>'qty')::numeric, v_by, 'Instrument used');
    v_added := v_added + 1;
  end loop;

  return jsonb_build_object('ok', true, 'added', v_added);
end;
$$;

-- ============================================================================
-- dispatch_log: useEdit / useDelete (admin+, only while Status='Pending
-- Collection' — once dispatched, the sterilisation record can no longer be
-- altered here)
-- ============================================================================
create or replace function use_edit(p_id uuid, p_name text default null, p_code text default null, p_qty numeric default null) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_status text;
begin
  if (select app_role_rank()) < 2 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  select status into v_status from dispatch_log where id = p_id;
  if not found then
    raise exception 'Not found';
  end if;
  if v_status <> 'Pending Collection' then
    raise exception 'This item has already been dispatched and can no longer be edited';
  end if;
  update dispatch_log set
    item_name = coalesce(p_name, item_name),
    code = coalesce(p_code, code),
    count_out = coalesce(greatest(1, p_qty), count_out)
  where id = p_id;
end;
$$;

create or replace function use_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_status text;
begin
  if (select app_role_rank()) < 2 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  select status into v_status from dispatch_log where id = p_id;
  if not found then
    raise exception 'Not found';
  end if;
  if v_status <> 'Pending Collection' then
    raise exception 'This item has already been dispatched and cannot be removed here';
  end if;
  delete from dispatch_log where id = p_id;
end;
$$;

-- ============================================================================
-- dispatch_log: dispatchAssign (staff+) — advances Pending Collection rows to
-- Out, and marks the matching instrument's items row 'At CSSD' (auto-
-- registering it if the code has never been seen before, matching
-- upsertInstrument_'s behaviour in Code.gs).
-- ============================================================================
create or replace function dispatch_assign(
  p_ids uuid[], p_ref text, p_date date default null, p_batch text default null, p_instructions text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_by text;
  v_id uuid;
  v_code text;
  v_item_id uuid;
begin
  if (select app_role_rank()) < 1 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  select display_name into v_by from profiles where id = auth.uid();

  foreach v_id in array p_ids loop
    update dispatch_log set
      dispatch_ref = p_ref,
      date_sent = coalesce(p_date, current_date),
      sent_by = v_by,
      batch_lot = coalesce(p_batch, batch_lot),
      instructions = coalesce(p_instructions, instructions),
      status = 'Out'
    where id = v_id
    returning code into v_code;

    if v_code is not null and v_code <> '' then
      select id into v_item_id from items where tracker = 'instruments' and (code = v_code or barcode = v_code) limit 1;
      if v_item_id is not null then
        update items set status = 'At CSSD' where id = v_item_id;
      else
        insert into items (tracker, code, barcode, name, category, status)
        values ('instruments', v_code, v_code, v_code, 'Instrument', 'At CSSD');
      end if;
    end if;
  end loop;

  insert into activity_log (code, name, qty, by, note, activity)
  values (p_ref, 'Dispatch ' || coalesce(p_ref, ''), array_length(p_ids, 1), v_by,
    array_length(p_ids, 1) || ' line(s) sent to CSSD', 'Instruments dispatched');

  return jsonb_build_object('ok', true, 'dispatched', array_length(p_ids, 1));
end;
$$;

-- ============================================================================
-- dispatch_log: dispatchReceive (staff+) — marks rows Returned, auto-sets
-- expiry = dispatch date + 1 year and 'At Bollin' on the matching instrument
-- (auto-registering it if unseen), matching Code.gs's automatic-expiry rule.
-- ============================================================================
create or replace function dispatch_receive(p_ids uuid[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_by text;
  v_id uuid;
  v_row dispatch_log%rowtype;
  v_expiry date;
  v_item_id uuid;
begin
  if (select app_role_rank()) < 1 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  select display_name into v_by from profiles where id = auth.uid();

  foreach v_id in array p_ids loop
    select * into v_row from dispatch_log where id = v_id;
    if not found then
      continue;
    end if;

    update dispatch_log set date_returned = now(), returned_by = v_by, count_in = v_row.count_out, status = 'Returned'
    where id = v_id;

    if v_row.code is not null and v_row.code <> '' then
      v_expiry := (coalesce(v_row.date_sent, current_date) + interval '1 year')::date;
      select id into v_item_id from items where tracker = 'instruments' and (code = v_row.code or barcode = v_row.code) limit 1;
      if v_item_id is not null then
        update items set expiry = v_expiry, status = 'At Bollin' where id = v_item_id;
      else
        insert into items (tracker, code, barcode, name, category, status, expiry)
        values ('instruments', v_row.code, v_row.code, coalesce(v_row.item_name, v_row.code), 'Instrument', 'At Bollin', v_expiry);
      end if;
    end if;
  end loop;

  insert into activity_log (name, qty, by, note, activity)
  values ('CSSD return', array_length(p_ids, 1), v_by, array_length(p_ids, 1) || ' line(s) received back', 'Instruments received');

  return jsonb_build_object('ok', true, 'received', array_length(p_ids, 1));
end;
$$;

-- ============================================================================
-- dispatch_log: dispatchAdd (staff+) — direct dispatch without a prior
-- 'used' log; dispatchReturn (staff+) — simple return without the
-- instrument-register side effect that dispatchReceive has.
-- ============================================================================
create or replace function dispatch_add(p_ref text, p_lines jsonb, p_date date default null, p_batch text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_by text;
  v_line jsonb;
  v_added int := 0;
begin
  if (select app_role_rank()) < 1 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  if jsonb_array_length(p_lines) = 0 then
    raise exception 'No lines';
  end if;
  select display_name into v_by from profiles where id = auth.uid();

  for v_line in select * from jsonb_array_elements(p_lines) loop
    insert into dispatch_log (dispatch_ref, date_sent, sent_by, item_name, code, count_out, batch_lot, instructions, status)
    values (p_ref, coalesce(p_date, current_date), v_by, v_line->>'name', v_line->>'code',
      greatest(1, coalesce((v_line->>'qtyOut')::numeric, 1)), p_batch, v_line->>'instructions', 'Out');
    v_added := v_added + 1;
  end loop;

  insert into activity_log (code, name, qty, by, note, activity)
  values (p_ref, 'Dispatch ' || coalesce(p_ref, ''), v_added, v_by, v_added || ' line(s) sent to CSSD', 'Instruments dispatched');

  return jsonb_build_object('ok', true, 'added', v_added);
end;
$$;

create or replace function dispatch_return(p_id uuid, p_qty_in numeric default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_by text;
  v_row dispatch_log%rowtype;
  v_qty_in numeric;
  v_status text;
begin
  if (select app_role_rank()) < 1 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  select display_name into v_by from profiles where id = auth.uid();

  select * into v_row from dispatch_log where id = p_id;
  if not found then
    raise exception 'Not found';
  end if;

  v_qty_in := coalesce(p_qty_in, v_row.count_out);
  v_status := case when v_qty_in >= v_row.count_out then 'Returned' else 'Partial' end;

  update dispatch_log set date_returned = now(), returned_by = v_by, count_in = v_qty_in, status = v_status
  where id = p_id;

  insert into activity_log (name, code, qty, by, note, activity)
  values (v_row.item_name, v_row.code, v_qty_in, v_by,
    case when v_status = 'Returned' then 'Fully returned' else 'Partial return' end, 'Instruments received');

  return jsonb_build_object('ok', true);
end;
$$;

-- ============================================================================
-- stocktakes: stocktake (staff+) — logs every entry; when p_apply and the
-- tracker isn't 'instruments', also adjusts the item's qty (a staff-rank
-- write to items.qty, narrower than admin-rank updateItem).
-- ============================================================================
create or replace function stocktake_apply(p_entries jsonb, p_check_type text default 'Month-end', p_apply boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_by text;
  v_entry jsonb;
  v_variance numeric;
  v_saved int := 0;
  v_variances int := 0;
  v_item_id uuid;
  v_first_tracker text;
begin
  if (select app_role_rank()) < 1 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  select display_name into v_by from profiles where id = auth.uid();
  v_first_tracker := p_entries -> 0 ->> 'tracker';

  for v_entry in select * from jsonb_array_elements(p_entries) loop
    v_variance := coalesce((v_entry->>'counted')::numeric, 0) - coalesce((v_entry->>'expected')::numeric, 0);

    insert into stocktakes (check_type, tracker, store, by, code, name, expected, counted, variance)
    values (p_check_type, nullif(v_entry->>'tracker', '')::tracker_kind, v_entry->>'store', v_by,
      v_entry->>'code', v_entry->>'item', (v_entry->>'expected')::numeric, (v_entry->>'counted')::numeric, v_variance);
    v_saved := v_saved + 1;

    if p_apply and v_variance <> 0 and (v_entry->>'tracker') <> 'instruments' then
      v_item_id := nullif(v_entry->>'item_id', '')::uuid;
      if v_item_id is not null then
        update items set qty = (v_entry->>'counted')::numeric where id = v_item_id;
      end if;
    end if;
    if v_variance <> 0 then
      v_variances := v_variances + 1;
    end if;
  end loop;

  insert into activity_log (tracker, name, qty, by, note, activity)
  values (nullif(v_first_tracker, '')::tracker_kind, p_check_type || ' check', v_saved, v_by,
    v_variances || ' variance(s)' || case when p_apply then ', stock adjusted' else '' end, 'Stocktake saved');

  return jsonb_build_object('ok', true, 'saved', v_saved);
end;
$$;

-- ============================================================================
-- settings: medPresetsSave (common+) — the one narrow exception to an
-- otherwise admin-only table: upserts exactly one hardcoded key, so common
-- users can never touch any other setting.
-- ============================================================================
create or replace function save_med_preset(p_value text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if (select app_role_rank()) < 0 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  insert into settings (key, value, description)
  values ('med_sticker_presets', p_value, 'Saved from the app')
  on conflict (key) do update set value = excluded.value;
end;
$$;

-- ============================================================================
-- Lock down EXECUTE: anon gets nothing; authenticated gets exactly these
-- functions (the base tables they touch remain admin+-floor/RLS-denied for
-- direct client access, as established in the RLS migration).
-- ============================================================================
do $$
declare
  fn text;
begin
  foreach fn in array array[
    'move_stock(uuid,text,numeric,text,date,text)',
    'link_barcode(uuid,text)',
    'instrument_add(jsonb)',
    'proc_start(date,text,text,text,theatre_room)',
    'proc_save_cart(uuid,jsonb)',
    'proc_cancel(uuid)',
    'proc_consume_batch(uuid,jsonb)',
    'proc_reopen(uuid)',
    'proc_delete(uuid)',
    'use_log(jsonb,date)',
    'use_edit(uuid,text,text,numeric)',
    'use_delete(uuid)',
    'dispatch_assign(uuid[],text,date,text,text)',
    'dispatch_receive(uuid[])',
    'dispatch_add(text,jsonb,date,text)',
    'dispatch_return(uuid,numeric)',
    'stocktake_apply(jsonb,text,boolean)',
    'save_med_preset(text)'
  ]
  loop
    execute format('revoke execute on function %s from public, anon', fn);
    execute format('grant execute on function %s to authenticated', fn);
  end loop;
end;
$$;
