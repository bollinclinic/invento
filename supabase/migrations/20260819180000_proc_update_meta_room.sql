-- Extends proc_update_meta to also set room (theatre), so historical migrated procedures
-- (which all came in with room = null, since the concurrent-rooms feature postdates them)
-- can be assigned a theatre retroactively from the same inline-edit flow used for
-- surgeon/date/patient corrections. p_room accepts null/empty to leave it unassigned.
create or replace function proc_update_meta(p_procedure_id uuid, p_date date, p_surgeon text,
  p_procedure_name text, p_patient_ref text, p_room theatre_room default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if (select app_role_rank()) < 2 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  update procedures set date = coalesce(p_date, date), surgeon = p_surgeon,
    procedure_name = p_procedure_name, patient_ref = p_patient_ref, room = p_room
  where id = p_procedure_id;
  if not found then
    raise exception 'Procedure not found';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function proc_update_meta(uuid,date,text,text,text,theatre_room) from public, anon;
grant execute on function proc_update_meta(uuid,date,text,text,text,theatre_room) to authenticated;

-- The old 5-arg overload is now shadowed by the 6-arg version above but Postgres keeps both
-- signatures registered; drop the stale one so there's exactly one proc_update_meta.
drop function if exists proc_update_meta(uuid,date,text,text,text);
