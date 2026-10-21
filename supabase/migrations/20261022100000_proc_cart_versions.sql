-- Procedure costing: a device can never overwrite a newer item list (cart) with an older copy.
--
-- What went wrong (Oct 2026): every device keeps its own copy of every running case and only
-- refreshed it on log-in or on ending a case. A device that still held an old copy of another
-- theatre's case could save that copy over the real one (a scan, "Save progress" or the
-- background save while that theatre's tab was showing), so other devices and refreshes then
-- showed the case with nothing scanned.
--
-- Now:
--   * procedures.cart_version goes up by one every time the cart changes, whoever changes it
--     (a trigger, so older pages, reopen and ending all count).
--   * proc_save_cart_v2(id, cart, expected_version) saves only if the case is still at the
--     version the device last saw. Otherwise it saves nothing and returns the newer cart, so the
--     page can combine its own changes with it instead of wiping them.
--   * get_open_procedures() lets every device refresh running cases cheaply and often.
--   * Starting and cancelling a case are written to the activity log (ending already was), so
--     there is a record of every case that was opened, even one cancelled later.
-- The old proc_save_cart is kept, so a device still on the old page keeps saving during a list
-- until it is refreshed; its saves move the version on, so newer pages notice them.

alter table procedures add column if not exists cart_version integer not null default 0;

create or replace function procedures_bump_cart_version() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.cart is distinct from old.cart then
    new.cart_version := old.cart_version + 1;
  else
    new.cart_version := old.cart_version;   -- never set by hand
  end if;
  return new;
end;
$$;
drop trigger if exists procedures_cart_version on procedures;
create trigger procedures_cart_version before update on procedures
  for each row execute function procedures_bump_cart_version();

-- get_procedures() returns setof procedures, matched by column POSITION: cart_version is the
-- new trailing column, so it goes at the end of the list.
create or replace function get_procedures() returns setof procedures
language sql stable security definer set search_path = public as $$
  select
    id, date, surgeon, procedure_name, patient_ref, started_by, status,
    start_time, end_time,
    case when app_role_rank() >= 2 then total_cost else null end,
    notes, cart, room, created_at, updated_at, surgeon_id, cart_version
  from procedures;
$$;

-- Only the running cases: what every device polls to stay up to date.
create or replace function get_open_procedures() returns setof procedures
language sql stable security definer set search_path = public as $$
  select
    id, date, surgeon, procedure_name, patient_ref, started_by, status,
    start_time, end_time,
    case when app_role_rank() >= 2 then total_cost else null end,
    notes, cart, room, created_at, updated_at, surgeon_id, cart_version
  from procedures
  where status = 'Open' and app_role_rank() >= 0;
$$;
revoke execute on function get_open_procedures() from public, anon;
grant execute on function get_open_procedures() to authenticated;

create or replace function proc_save_cart_v2(p_procedure_id uuid, p_cart jsonb, p_expected_version integer)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v procedures;
  v_new integer;
begin
  if (select app_role_rank()) < 0 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  if p_cart is null or jsonb_typeof(p_cart) <> 'array' then
    raise exception 'The item list is not valid';
  end if;
  select * into v from procedures where id = p_procedure_id for update;
  if not found or v.status <> 'Open' then
    raise exception 'Procedure not open or not found';
  end if;
  if p_expected_version is null or v.cart_version <> p_expected_version then
    return jsonb_build_object('ok', false, 'conflict', true, 'version', v.cart_version, 'cart', v.cart);
  end if;
  update procedures set cart = p_cart where id = p_procedure_id
    returning cart_version into v_new;
  return jsonb_build_object('ok', true, 'version', v_new);
end;
$$;
revoke execute on function proc_save_cart_v2(uuid,jsonb,integer) from public, anon;
grant execute on function proc_save_cart_v2(uuid,jsonb,integer) to authenticated;

-- Record every start and every cancel. (A cancel deletes the still-open row, so without this
-- there was no trace a case had ever existed.) No patient reference is written here.
create or replace function procedures_log_start_cancel() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_by text;
begin
  select display_name into v_by from profiles where id = auth.uid();
  if tg_op = 'INSERT' then
    insert into activity_log (activity, code, name, by, note)
    values ('Procedure started', new.id::text, concat_ws(' — ', new.surgeon, new.procedure_name),
            coalesce(v_by, new.started_by), new.room::text || ' · case costing opened');
    return new;
  end if;
  if old.status = 'Open' then
    insert into activity_log (activity, code, name, by, note)
    values ('Procedure cancelled', old.id::text, concat_ws(' — ', old.surgeon, old.procedure_name), v_by,
            old.room::text || ' · cancelled before it was ended, nothing taken from stock · '
              || jsonb_array_length(coalesce(old.cart, '[]'::jsonb)) || ' line(s) discarded');
  end if;
  return old;
end;
$$;
drop trigger if exists procedures_log_start on procedures;
create trigger procedures_log_start after insert on procedures
  for each row execute function procedures_log_start_cancel();
drop trigger if exists procedures_log_cancel on procedures;
create trigger procedures_log_cancel after delete on procedures
  for each row execute function procedures_log_start_cancel();
