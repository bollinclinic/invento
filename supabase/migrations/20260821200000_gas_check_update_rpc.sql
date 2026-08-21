-- Gas checks had no way to correct a mistaken date/reading after saving, and no way to
-- backdate/fix an entry while transferring historical readings over from the old system
-- (the daily-check form always stamps `date = today`, so backdated data has to be entered
-- then corrected). `gas_checks` has a SELECT policy but no UPDATE policy, so a direct client
-- UPDATE would silently match zero rows (same class of silent failure as the items/procedures
-- bug — see item_update). Fixed with an admin+ SECURITY DEFINER RPC using the same JSONB
-- partial-update pattern as item_update: only keys present in p_fields are touched.

create or replace function gas_check_update(p_id bigint, p_fields jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if (select app_role_rank()) < 2 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  update gas_checks set
    date = case when p_fields ? 'date' then (p_fields->>'date')::date else date end,
    by = case when p_fields ? 'by' then nullif(p_fields->>'by','') else by end,
    o2_left_bank = case when p_fields ? 'o2_left_bank' then nullif(p_fields->>'o2_left_bank','')::numeric else o2_left_bank end,
    o2_right_bank = case when p_fields ? 'o2_right_bank' then nullif(p_fields->>'o2_right_bank','')::numeric else o2_right_bank end,
    o2_pipeline = case when p_fields ? 'o2_pipeline' then nullif(p_fields->>'o2_pipeline','')::numeric else o2_pipeline end,
    o2_in_use_bank = case when p_fields ? 'o2_in_use_bank' then nullif(p_fields->>'o2_in_use_bank','') else o2_in_use_bank end,
    o2_delivery_booked = case when p_fields ? 'o2_delivery_booked' then (p_fields->>'o2_delivery_booked')::boolean else o2_delivery_booked end,
    air_left_bank = case when p_fields ? 'air_left_bank' then nullif(p_fields->>'air_left_bank','')::numeric else air_left_bank end,
    air_right_bank = case when p_fields ? 'air_right_bank' then nullif(p_fields->>'air_right_bank','')::numeric else air_right_bank end,
    air_pipeline = case when p_fields ? 'air_pipeline' then nullif(p_fields->>'air_pipeline','')::numeric else air_pipeline end,
    air_in_use_bank = case when p_fields ? 'air_in_use_bank' then nullif(p_fields->>'air_in_use_bank','') else air_in_use_bank end,
    air_delivery_booked = case when p_fields ? 'air_delivery_booked' then (p_fields->>'air_delivery_booked')::boolean else air_delivery_booked end,
    helium_total = case when p_fields ? 'helium_total' then nullif(p_fields->>'helium_total','')::numeric else helium_total end,
    helium_full = case when p_fields ? 'helium_full' then nullif(p_fields->>'helium_full','')::numeric else helium_full end,
    helium_empty = case when p_fields ? 'helium_empty' then nullif(p_fields->>'helium_empty','')::numeric else helium_empty end,
    trolley_o2_total = case when p_fields ? 'trolley_o2_total' then nullif(p_fields->>'trolley_o2_total','')::numeric else trolley_o2_total end,
    trolley_o2_full = case when p_fields ? 'trolley_o2_full' then nullif(p_fields->>'trolley_o2_full','')::numeric else trolley_o2_full end,
    trolley_o2_empty = case when p_fields ? 'trolley_o2_empty' then nullif(p_fields->>'trolley_o2_empty','')::numeric else trolley_o2_empty end,
    trolley_o2_next_delivery = case when p_fields ? 'trolley_o2_next_delivery' then nullif(p_fields->>'trolley_o2_next_delivery','')::date else trolley_o2_next_delivery end,
    vacuum_duty_pump = case when p_fields ? 'vacuum_duty_pump' then nullif(p_fields->>'vacuum_duty_pump','') else vacuum_duty_pump end,
    vacuum_status = case when p_fields ? 'vacuum_status' then nullif(p_fields->>'vacuum_status','') else vacuum_status end,
    airflow_th1_off = case when p_fields ? 'airflow_th1_off' then (p_fields->>'airflow_th1_off')::boolean else airflow_th1_off end,
    airflow_th2_off = case when p_fields ? 'airflow_th2_off' then (p_fields->>'airflow_th2_off')::boolean else airflow_th2_off end,
    notes = case when p_fields ? 'notes' then nullif(p_fields->>'notes','') else notes end
  where id = p_id;
  if not found then
    raise exception 'Gas check not found';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function gas_check_update(bigint,jsonb) from public, anon;
grant execute on function gas_check_update(bigint,jsonb) to authenticated;
