-- Developer-only "pre-fill from past case" for Procedure Costing: given a surgeon + procedure
-- name (typed into the same Start-a-new-procedure form, before the case exists), find that
-- surgeon's most recent CLOSED case for that exact procedure and return its item lines so the
-- frontend can offer to copy them into the new case instead of re-scanning everything by hand.
-- "Exact procedure" is matched case-insensitively and trimmed (not literal byte-for-byte) --
-- procedure name is free text, and treating "Breast Augmentation" and "breast augmentation " as
-- different cases would make this feature useless in practice; this mirrors how surgeon-name
-- matching elsewhere in the app already tolerates trivial formatting differences.
create or replace function proc_find_prefill_case(p_surgeon_id uuid, p_procedure_name text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_proc procedures%rowtype;
  v_lines jsonb;
begin
  if (select app_role_rank()) < 4 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  if p_surgeon_id is null or coalesce(trim(p_procedure_name),'') = '' then
    return jsonb_build_object('found', false);
  end if;

  select * into v_proc from procedures
    where surgeon_id = p_surgeon_id
      and status = 'Closed'
      and lower(trim(procedure_name)) = lower(trim(p_procedure_name))
    order by date desc, end_time desc nulls last, created_at desc
    limit 1;
  if not found then
    return jsonb_build_object('found', false);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('tracker', tracker, 'code', code, 'name', name, 'qty', qty) order by ts), '[]'::jsonb)
    into v_lines
    from procedure_lines where procedure_id = v_proc.id;

  return jsonb_build_object('found', true, 'procedure_id', v_proc.id, 'date', v_proc.date, 'lines', v_lines);
end;
$$;

revoke execute on function proc_find_prefill_case(uuid,text) from public, anon;
grant execute on function proc_find_prefill_case(uuid,text) to authenticated;
