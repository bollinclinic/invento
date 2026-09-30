-- Rota texts: keep the text log short, per request. By default a text is kept for 30 days after
-- the shift it was about (tests: 30 days after it was queued); super admins and developers can
-- change this (7-365 days) in the app via sms_set_log_days(). Old texts are cleared once an
-- hour by the dispatcher's own claim step -- this only deletes old log rows, it never sends.
-- A text for a shift that is still in the future is never cleared (the post-save cancellation
-- check needs it), and nothing still waiting to go (scheduled / sending) is ever cleared.

create index if not exists sms_messages_created_idx on sms_messages (created_at);

insert into settings (key, value, description)
values ('sms_log_keep_days', '30', 'Rota SMS: days to keep sent texts after the shift (7-365)')
on conflict (key) do nothing;

-- Days to keep (7-365); anything else -> 30. A bad value never breaks anything.
create or replace function sms_log_keep_days() returns int
language plpgsql stable security definer set search_path = public as $$
declare v int;
begin
  select value::int into v from settings where key = 'sms_log_keep_days';
  if v between 7 and 365 then return v; end if;
  return 30;
exception when others then
  return 30;
end;
$$;

create or replace function sms_purge_old() returns int
language plpgsql security definer set search_path = public as $$
declare k int := sms_log_keep_days(); n int;
begin
  delete from sms_messages
  where status not in ('scheduled','sending')
    and ((rota_date is not null and rota_date < current_date - k)
      or (rota_date is null and created_at < now() - make_interval(days => k)));
  get diagnostics n = row_count;
  return n;
end;
$$;

-- Super admins / developers only (the general settings table is admin-writable, so this has
-- its own stricter gate).
create or replace function sms_set_log_days(p_days int) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if (select app_role_rank()) < 3 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  if p_days is null or p_days < 7 or p_days > 365 then
    raise exception 'Choose between 7 and 365 days';
  end if;
  insert into settings (key, value, description)
  values ('sms_log_keep_days', p_days::text, 'Rota SMS: days to keep sent texts after the shift (7-365)')
  on conflict (key) do update set value = excluded.value;
  return jsonb_build_object('ok', true, 'days', p_days);
end;
$$;

-- sms_claim_due: identical to 20260930140000 apart from the hourly clear-out at the top.
create or replace function sms_claim_due(p_limit int default 20) returns setof sms_messages
language plpgsql security definer set search_path = public as $$
declare r sms_messages; v_confirmed boolean; v_roles jsonb; st staff;
begin
  -- hourly housekeeping: clear texts older than the keep period (never sends anything)
  if extract(minute from now()) = 0 then perform sms_purge_old(); end if;
  for r in
    select * from sms_messages
    where (status = 'scheduled' and send_at <= now())
       or (status = 'sending' and gateway_id is null and updated_at < now() - interval '5 minutes')
    order by send_at
    limit p_limit
    for update skip locked
  loop
    if r.status = 'sending' and r.attempts >= 3 then
      update sms_messages set status = 'failed', error = 'Gave up: the gateway never confirmed this text'
      where id = r.id;
      continue;
    end if;
    if r.kind in ('confirm','cancel') then
      select * into st from staff where id = r.staff_id;
      if not found or not st.active or not st.sms_opt_in then
        update sms_messages set status = 'held', error = 'Held: staff member deactivated or opted out'
        where id = r.id;
        continue;
      end if;
      select coalesce(bool_or(p.has_confirmed), false), min(p.confirmed_roles::text)::jsonb
        into v_confirmed, v_roles
      from rota_sms_people(r.rota_date) p
      where p.person_key = lower(btrim(st.name));
      if (r.kind = 'confirm' and not v_confirmed) or (r.kind = 'cancel' and v_confirmed) then
        update sms_messages set status = 'held',
          error = case when r.kind = 'confirm' then 'Held: no longer confirmed on the rota'
                       else 'Held: confirmed on the rota again' end
        where id = r.id;
        continue;
      end if;
      if r.kind = 'confirm'
         and exists (select 1 from jsonb_array_elements(r.roles) e where e ? 'start')
         and sms_starts_sig(r.roles) <> sms_starts_sig(coalesce(v_roles, '[]'::jsonb)) then
        update sms_messages set status = 'held', error = 'Held: the start time has changed since this was queued'
        where id = r.id;
        continue;
      end if;
    end if;
    update sms_messages set status = 'sending', attempts = attempts + 1, error = null
    where id = r.id returning * into r;
    return next r;
  end loop;
end;
$$;

revoke execute on function sms_log_keep_days() from public, anon, authenticated;
revoke execute on function sms_purge_old() from public, anon, authenticated;
revoke execute on function sms_set_log_days(int) from public, anon;
revoke execute on function sms_claim_due(int) from public, anon, authenticated;
grant execute on function sms_set_log_days(int) to authenticated;
grant execute on function sms_purge_old() to service_role;
grant execute on function sms_claim_due(int) to service_role;
