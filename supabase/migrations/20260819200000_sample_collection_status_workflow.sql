-- Sample collection redesign: date collected/sent/result were per-specimen, forcing the same
-- three dates to be re-entered for every specimen logged against one patient visit. Moves
-- them to the collection (parent) level — asked once — and replaces the two "in-the-future"
-- dates (sent/result) with a Collected -> Sent -> Result Received status workflow that
-- auto-stamps time+user on each transition, mirroring the implants order/delivered pattern.
-- date_collected stays a real editable business date (asked once at logging time, since that
-- can be backdated); sent/result are always "now", captured automatically on transition.
alter table sample_collections add column if not exists status text not null default 'Collected';
alter table sample_collections add column if not exists date_collected date;
alter table sample_collections add column if not exists sent_at timestamptz;
alter table sample_collections add column if not exists sent_by text;
alter table sample_collections add column if not exists result_at timestamptz;
alter table sample_collections add column if not exists result_by text;

-- Everyone (including common rank) needs to see the list to act on "mark as sent / result
-- received" — creating/editing full specimen details stays staff+ via the existing write/
-- update policies, only read visibility widens.
drop policy if exists "sample_collections: staff+ read" on sample_collections;
create policy "sample_collections: read" on sample_collections
  for select to authenticated
  using ((select app_role_rank()) >= 0);
drop policy if exists "specimens: staff+ read" on specimens;
create policy "specimens: read" on specimens
  for select to authenticated
  using ((select app_role_rank()) >= 0);

-- Status advance is deliberately open to every authenticated user (rank >= 0), separate from
-- the staff+ gate on creating/editing full records — this is the one action everyone on the
-- ward, not just the sample-logging staff, needs to be able to do.
create or replace function sample_advance_status(p_collection_id uuid, p_new_status text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_by text;
  v_current text;
begin
  if (select app_role_rank()) < 0 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  select display_name into v_by from profiles where id = auth.uid();
  select status into v_current from sample_collections where id = p_collection_id for update;
  if not found then
    raise exception 'Sample collection not found';
  end if;
  if v_current = 'Collected' and p_new_status = 'Sent' then
    update sample_collections set status = 'Sent', sent_at = now(), sent_by = v_by where id = p_collection_id;
  elsif v_current = 'Sent' and p_new_status = 'Result Received' then
    update sample_collections set status = 'Result Received', result_at = now(), result_by = v_by where id = p_collection_id;
  else
    raise exception 'Cannot move from % to %', v_current, p_new_status;
  end if;
  return jsonb_build_object('ok', true, 'status', p_new_status, 'by', v_by);
end;
$$;

revoke execute on function sample_advance_status(uuid,text) from public, anon;
grant execute on function sample_advance_status(uuid,text) to authenticated;
