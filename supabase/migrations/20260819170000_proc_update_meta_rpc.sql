-- procUpdateMeta was a direct client-side `sb.from('procedures').update(...)` call. The
-- procedures table deliberately has no SELECT policy (financial data masking — reads only
-- go through get_procedures()), and it turns out PostgREST needs SELECT-level row
-- visibility to locate a row for a client-issued UPDATE at all: the request returns
-- HTTP 200 with an empty body/zero affected rows, no error, and the row is never actually
-- touched. Confirmed empirically (identical update on `settings`, which does have a SELECT
-- policy, works correctly for the same session). The frontend updates its local state
-- optimistically and shows "Updated", masking the failure completely until the next
-- reload brings back the untouched original data. Moving this to a SECURITY DEFINER RPC
-- (the same pattern already used for every other procedure mutation) bypasses the
-- SELECT-policy limitation entirely.
create or replace function proc_update_meta(p_procedure_id uuid, p_date date, p_surgeon text,
  p_procedure_name text, p_patient_ref text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if (select app_role_rank()) < 2 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  update procedures set date = coalesce(p_date, date), surgeon = p_surgeon,
    procedure_name = p_procedure_name, patient_ref = p_patient_ref
  where id = p_procedure_id;
  if not found then
    raise exception 'Procedure not found';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function proc_update_meta(uuid,date,text,text,text) from public, anon;
grant execute on function proc_update_meta(uuid,date,text,text,text) to authenticated;
