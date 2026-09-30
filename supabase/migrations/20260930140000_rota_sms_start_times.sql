-- Rota texts: start times, per request. Every confirmation text must say when the person starts.
--   * Theatre staff (Scrub, ODP, SFA, Recovery): the theatre's new "List starts" time on the rota
--     (rota_theatres.start_time, saved with the day).
--   * Day-cover staff (Ward nurse, Ward HCA, Night nurse, Night HCA, night RMO): a usual start
--     time per role, set once in the app (settings key sms_default_times, JSON by slot key).
--   * REQUIRED: someone whose confirmed role has no start time can't be texted (reason
--     no_start_time) until the time is filled in.
--   * If a start time changes after someone was texted, the post-save check now OFFERS an
--     updated confirmation (change = 'time_changed'); nothing is sent unless the user presses
--     Send. The send-time safety net HOLDS a scheduled confirmation whose time is out of date.
-- rota_save_day is replaced with an identical copy (20260914090000) plus the one new column.

alter table rota_theatres add column if not exists start_time time;

-- ============================================================================
-- rota_save_day: unchanged except T1_/T2_StartTime -> rota_theatres.start_time
-- ============================================================================
create or replace function rota_save_day(
  p_date date,
  p_expected_updated_at timestamptz,
  p_fields jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_day_id uuid;
  v_current_updated_at timestamptz;
  v_new_day rota_days%rowtype;
  f jsonb := p_fields;
  n int;
begin
  if (select app_role_rank()) < 3 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;

  select id, updated_at into v_day_id, v_current_updated_at from rota_days where date = p_date for update;

  -- A brand-new day (never saved) has nothing to conflict with -- p_expected_updated_at is null
  -- from the frontend in that case. Once a day exists, any save that doesn't know its current
  -- updated_at, or knows an OLDER one, is based on stale data and must be refused rather than
  -- silently applied.
  if v_day_id is not null and (p_expected_updated_at is null or v_current_updated_at <> p_expected_updated_at) then
    raise exception 'ROTA_CONFLICT' using errcode = 'P0001',
      detail = 'This day was changed by someone else since you started editing.';
  end if;

  insert into rota_days (date, theatres, hca_ward, ward_nurse, night_nurse, hca_night,
    rmo_day, rmo_night, housekeeping_am, housekeeping_pm, reception_am, reception_pm, notes, acks, stars)
  values (p_date, coalesce((f->>'Theatres')::int, 0), nullif(f->>'HCAWard',''), nullif(f->>'WardNurse',''),
    nullif(f->>'NightNurse',''), nullif(f->>'HCANight',''), nullif(f->>'RMODay',''), nullif(f->>'RMONight',''),
    nullif(f->>'HousekeepingAM',''), nullif(f->>'HousekeepingPM',''), nullif(f->>'ReceptionAM',''), nullif(f->>'ReceptionPM',''),
    nullif(f->>'Notes',''), coalesce((f->>'AcksJSON')::jsonb,'{}'::jsonb), coalesce((f->>'StarsJSON')::jsonb,'{}'::jsonb))
  on conflict (date) do update set
    theatres = excluded.theatres, hca_ward = excluded.hca_ward, ward_nurse = excluded.ward_nurse,
    night_nurse = excluded.night_nurse, hca_night = excluded.hca_night, rmo_day = excluded.rmo_day,
    rmo_night = excluded.rmo_night, housekeeping_am = excluded.housekeeping_am, housekeeping_pm = excluded.housekeeping_pm,
    reception_am = excluded.reception_am, reception_pm = excluded.reception_pm, notes = excluded.notes,
    acks = excluded.acks, stars = excluded.stars
  returning * into v_new_day;

  for n in 1..2 loop
    insert into rota_theatres (day_id, theatre_number, type, detail, colour, surgeon, surgeon2, surgeon3,
      anaesthetist, sfa, scrub1, scrub2, scrub3, odp, hca, recovery, cases, start_time)
    values (v_new_day.id, n, coalesce(f->>('T'||n||'_Type'), 'GA'), nullif(f->>('T'||n||'_Detail'),''),
      nullif(f->>('T'||n||'_Colour'),''), nullif(f->>('T'||n||'_Surgeon'),''), nullif(f->>('T'||n||'_Surgeon2'),''),
      nullif(f->>('T'||n||'_Surgeon3'),''), nullif(f->>('T'||n||'_Anaesthetist'),''), nullif(f->>('T'||n||'_SFA'),''),
      nullif(f->>('T'||n||'_Scrub1'),''), nullif(f->>('T'||n||'_Scrub2'),''), nullif(f->>('T'||n||'_Scrub3'),''),
      nullif(f->>('T'||n||'_ODP'),''), nullif(f->>('T'||n||'_HCA'),''), nullif(f->>('T'||n||'_Recovery'),''),
      coalesce((f->>('T'||n||'_CasesJSON'))::jsonb, '[]'::jsonb),
      nullif(f->>('T'||n||'_StartTime'),'')::time)
    on conflict (day_id, theatre_number) do update set
      type = excluded.type, detail = excluded.detail, colour = excluded.colour,
      surgeon = excluded.surgeon, surgeon2 = excluded.surgeon2, surgeon3 = excluded.surgeon3,
      anaesthetist = excluded.anaesthetist, sfa = excluded.sfa,
      scrub1 = excluded.scrub1, scrub2 = excluded.scrub2, scrub3 = excluded.scrub3,
      odp = excluded.odp, hca = excluded.hca, recovery = excluded.recovery, cases = excluded.cases,
      start_time = excluded.start_time;
  end loop;

  return jsonb_build_object('ok', true, 'updated_at', v_new_day.updated_at);
end;
$$;

revoke execute on function rota_save_day(date,timestamptz,jsonb) from public, anon;
grant execute on function rota_save_day(date,timestamptz,jsonb) to authenticated;

-- ============================================================================
-- Usual start times for day-cover roles + confirmation wording with {start}
-- ============================================================================
insert into settings (key, value, description)
values ('sms_default_times', '{}', 'Rota SMS: usual start times for day-cover roles (JSON by slot key, HH:MM)')
on conflict (key) do nothing;

-- Only replaces the wording if nobody has edited it yet.
update settings set value =
  'Hi {first_name}, you''re confirmed for {roles} at Bollin Clinic on {day}, starting at {start}. Any problems please reply or call Ruby.'
where key = 'sms_template_confirm'
  and value = 'Hi {first_name}, you''re confirmed for {roles} at Bollin Clinic on {day}. Any problems please reply or call Ruby.';

-- The usual start time (HH:MM) for a day-cover slot key, or null. Bad JSON never breaks anything.
create or replace function sms_default_time(p_key text) returns text
language plpgsql stable security definer set search_path = public as $$
declare v text;
begin
  select (value::jsonb) ->> p_key into v from settings where key = 'sms_default_times';
  if v ~ '^[0-2][0-9]:[0-5][0-9]$' then return v; end if;
  return null;
exception when others then
  return null;
end;
$$;

-- ============================================================================
-- Slots / people now carry each role's start time (return types change -> drop + create)
-- ============================================================================
drop function if exists rota_sms_people(date);
drop function if exists rota_sms_slots(date);

create function rota_sms_slots(p_date date)
returns table(slot_key text, role_label text, theatre int, person text, starred boolean, start_time text)
language sql stable security definer set search_path = public as $$
  select s.slot_key, s.role_label, s.theatre, btrim(s.person),
         coalesce(d.stars ? s.slot_key, false), s.st
  from rota_days d
  cross join lateral (
    select k, label, 0, v, sms_default_time(k)
    from (values ('ward',       'Ward nurse',          d.ward_nurse),
                 ('hcaWard',    'Ward HCA',            d.hca_ward),
                 ('nightNurse', 'Night nurse',         d.night_nurse),
                 ('hcaNight',   'Night HCA',           d.hca_night),
                 ('rmoNight',   'RMO on site (night)', d.rmo_night)) dc(k, label, v)
    union all
    select 't' || t.theatre_number || '.' || r.k, r.label, t.theatre_number, r.v, to_char(t.start_time, 'HH24:MI')
    from rota_theatres t
    cross join lateral (values ('scrub1','Scrub 1',t.scrub1), ('scrub2','Scrub 2',t.scrub2),
                               ('scrub3','Scrub 3',t.scrub3), ('odp','ODP',t.odp),
                               ('sfa','SFA / practitioner',t.sfa),
                               ('recovery','Recovery nurse / ODP',t.recovery)) r(k, label, v)
    where t.day_id = d.id and t.theatre_number <= least(d.theatres, 2)
  ) s(slot_key, role_label, theatre, person, st)
  where d.date = p_date and d.theatres > 0 and nullif(btrim(s.person), '') is not null;
$$;

create function rota_sms_people(p_date date)
returns table(person_key text, person text, confirmed_roles jsonb, all_roles jsonb, has_confirmed boolean, missing_time boolean)
language sql stable security definer set search_path = public as $$
  select lower(person), min(person),
         coalesce(jsonb_agg(jsonb_build_object('key', slot_key, 'label', role_label, 'theatre', theatre, 'start', start_time)
                   order by theatre, slot_key) filter (where not starred), '[]'::jsonb),
         jsonb_agg(jsonb_build_object('key', slot_key, 'label', role_label, 'theatre', theatre, 'starred', starred, 'start', start_time)
                   order by theatre, slot_key),
         bool_or(not starred),
         coalesce(bool_or(not starred and start_time is null), false)
  from rota_sms_slots(p_date)
  group by lower(person);
$$;

-- "07:30", or "07:30 (Scrub 1) and 19:30 (Night nurse)" when one person has different times.
create or replace function sms_start_text(p_roles jsonb) returns text
language sql immutable set search_path = public as $$
  with r as (
    select e->>'start' as st, e->>'label' as label, ord
    from jsonb_array_elements(p_roles) with ordinality x(e, ord)
    where coalesce(e->>'start','') <> '')
  select case
    when (select count(distinct st) from r) <= 1 then coalesce((select min(st) from r), '')
    else (select string_agg(st || ' (' || label || ')', ' and ' order by st, ord) from r) end;
$$;

-- Distinct start times of a roles array, sorted -- what "the time they were told" means.
create or replace function sms_starts_sig(p_roles jsonb) returns text[]
language sql immutable set search_path = public as $$
  select coalesce(array_agg(distinct e->>'start' order by e->>'start'), '{}')
  from jsonb_array_elements(p_roles) e where coalesce(e->>'start','') <> '';
$$;

create or replace function sms_render(p_kind text, p_name text, p_date date, p_roles jsonb)
returns text language sql stable security definer set search_path = public as $$
  select replace(replace(replace(replace(
           coalesce((select value from settings where key = 'sms_template_' || p_kind), ''),
           '{first_name}', split_part(btrim(p_name), ' ', 1)),
           '{day}', to_char(p_date, 'FMDay FMDD FMMonth')),
           '{roles}', sms_roles_text(p_roles)),
           '{start}', sms_start_text(p_roles));
$$;

-- ============================================================================
-- Changes since someone was texted: removed/replaced/provisional, or start time changed
-- ============================================================================
create or replace function rota_sms_affected_core(p_date date) returns jsonb
language sql stable security definer set search_path = public as $$
  with last_confirm as (
    select distinct on (m.staff_id) m.*
    from sms_messages m
    where m.rota_date = p_date and m.kind = 'confirm' and m.staff_id is not null
      and m.status not in ('cancelled','failed','dry_run')
    order by m.staff_id, m.created_at desc, m.id
  ), cur as (
    select c.*, st.name as cur_name, p.has_confirmed, p.confirmed_roles, p.missing_time
    from last_confirm c
    join staff st on st.id = c.staff_id
    left join rota_sms_people(p_date) p on p.person_key = lower(btrim(st.name))
  )
  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) from (
    -- no longer confirmed (removed, replaced, or made provisional)
    select jsonb_build_object(
             'change', 'removed',
             'staff_id', c.staff_id, 'name', c.staff_name, 'confirm_id', c.id,
             'confirm_status', c.status, 'send_at', c.send_at, 'sent_at', c.sent_at,
             'roles', c.roles,
             'body', sms_render('cancel', c.staff_name, p_date, c.roles)) as x
    from cur c
    where not coalesce(c.has_confirmed, false)
      and not exists (select 1 from sms_messages k
                      where k.rota_date = p_date and k.staff_id = c.staff_id and k.kind = 'cancel'
                        and k.created_at > c.created_at and k.status not in ('cancelled','failed'))
    union all
    -- still confirmed, but the start time they were told is no longer right
    select jsonb_build_object(
             'change', 'time_changed',
             'staff_id', c.staff_id, 'name', c.cur_name, 'confirm_id', c.id,
             'confirm_status', c.status, 'send_at', c.send_at, 'sent_at', c.sent_at,
             'roles', c.confirmed_roles,
             'old_start', sms_start_text(c.roles), 'new_start', sms_start_text(c.confirmed_roles),
             'missing_time', c.missing_time,
             'body', sms_render('confirm', c.cur_name, p_date, c.confirmed_roles))
    from cur c
    where coalesce(c.has_confirmed, false)
      and exists (select 1 from jsonb_array_elements(c.roles) e where e ? 'start')   -- texts from before start times: not comparable
      and sms_starts_sig(c.roles) <> sms_starts_sig(c.confirmed_roles)
  ) q;
$$;

-- ============================================================================
-- What the dialog shows: now also "no start time"
-- ============================================================================
create or replace function rota_sms_preview(p_date date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_day rota_days;
  v_people jsonb;
begin
  if (select app_role_rank()) < 3 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  select * into v_day from rota_days where date = p_date;

  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) into v_people from (
    select jsonb_build_object(
      'name', coalesce(st.name, p.person),
      'staff_id', st.id,
      'in_directory', st.id is not null,
      'active', coalesce(st.active, false),
      'has_mobile', st.mobile is not null,
      'mobile_tail', case when st.mobile is not null then right(st.mobile, 3) end,
      'opted_in', coalesce(st.sms_opt_in, false),
      'roles', p.all_roles,
      'confirmed_roles', p.confirmed_roles,
      'missing_time', p.missing_time,
      'eligible', p.has_confirmed and not p.missing_time and st.id is not null and st.active
                  and st.mobile is not null and st.sms_opt_in,
      'reason', case
         when not p.has_confirmed then 'provisional'
         when p.missing_time then 'no_start_time'
         when st.id is null then 'not_in_directory'
         when not st.active then 'inactive'
         when st.mobile is null then 'no_mobile'
         when not st.sms_opt_in then 'not_opted_in'
         else null end,
      'body', case when p.has_confirmed and not p.missing_time
                   then sms_render('confirm', coalesce(st.name, p.person), p_date, p.confirmed_roles) end,
      'messages', coalesce((
         select jsonb_agg(jsonb_build_object('id', m.id, 'kind', m.kind, 'status', m.status,
                  'send_at', m.send_at, 'sent_at', m.sent_at, 'error', m.error) order by m.created_at)
         from sms_messages m
         where m.rota_date = p_date and (m.staff_id = st.id or (st.id is null and lower(m.staff_name) = p.person_key))
      ), '[]'::jsonb)
    ) as x
    from rota_sms_people(p_date) p
    left join staff st on lower(btrim(st.name)) = p.person_key
  ) q;

  return jsonb_build_object(
    'date', p_date,
    'exists', v_day.id is not null,
    'updated_at', v_day.updated_at,
    'theatres', coalesce(v_day.theatres, 0),
    'default_send_at', ((p_date - 1) + time '18:00') at time zone 'Europe/London',
    'people', v_people,
    'affected', rota_sms_affected_core(p_date),
    'cancel_template_preview', sms_render('cancel', '{first_name}', p_date, '[]'::jsonb)
  );
end;
$$;

-- ============================================================================
-- Queue: confirmations need a start time; cancellations only for 'removed'
-- ============================================================================
create or replace function rota_sms_queue(
  p_date date,
  p_expected_updated_at timestamptz,
  p_staff_ids uuid[],
  p_kind text,
  p_send_at timestamptz default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_day rota_days;
  v_by text;
  v_send_at timestamptz;
  v_sid uuid;
  st staff;
  p record;
  a jsonb;
  v_queued int := 0;
  v_skipped jsonb := '[]'::jsonb;
  v_to text;
begin
  if (select app_role_rank()) < 3 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  if p_kind not in ('confirm','cancel') then raise exception 'Unknown message kind'; end if;
  if coalesce(array_length(p_staff_ids, 1), 0) = 0 then raise exception 'Nobody selected'; end if;

  select * into v_day from rota_days where date = p_date for share;
  if v_day.id is null then raise exception 'This day has not been saved yet'; end if;
  if p_expected_updated_at is null or v_day.updated_at <> p_expected_updated_at then
    raise exception 'ROTA_CONFLICT' using errcode = 'P0001',
      detail = 'This day was changed since the message list was opened.';
  end if;

  -- A time in the past is refused, never silently sent now (1 minute grace for clock skew).
  if p_send_at is null then
    v_send_at := now();
  elsif p_send_at < now() - interval '1 minute' then
    raise exception 'SMS_TIME_PASSED' using errcode = 'P0001',
      detail = 'That time has passed - choose Send now or a later time.';
  else
    v_send_at := greatest(p_send_at, now());
  end if;

  select display_name into v_by from profiles where id = auth.uid();

  foreach v_sid in array p_staff_ids loop
    select * into st from staff where id = v_sid;
    if st.id is null then
      v_skipped := v_skipped || jsonb_build_object('staff_id', v_sid, 'reason', 'not_in_directory'); continue;
    end if;

    if p_kind = 'confirm' then
      select * into p from rota_sms_people(p_date) x where x.person_key = lower(btrim(st.name));
      if not found then
        v_skipped := v_skipped || jsonb_build_object('name', st.name, 'reason', 'not_on_rota'); continue;
      elsif not p.has_confirmed then
        v_skipped := v_skipped || jsonb_build_object('name', st.name, 'reason', 'provisional'); continue;
      elsif p.missing_time then
        v_skipped := v_skipped || jsonb_build_object('name', st.name, 'reason', 'no_start_time'); continue;
      elsif not st.active then
        v_skipped := v_skipped || jsonb_build_object('name', st.name, 'reason', 'inactive'); continue;
      elsif st.mobile is null then
        v_skipped := v_skipped || jsonb_build_object('name', st.name, 'reason', 'no_mobile'); continue;
      elsif not st.sms_opt_in then
        v_skipped := v_skipped || jsonb_build_object('name', st.name, 'reason', 'not_opted_in'); continue;
      end if;
      -- a still-unsent confirmation for the same person/day is replaced, never doubled up
      update sms_messages set status = 'cancelled', cancelled_at = now(), cancel_reason = 'replaced by a newer send'
      where rota_date = p_date and staff_id = st.id and kind = 'confirm' and status in ('scheduled','held');
      insert into sms_messages (rota_date, staff_id, staff_name, to_number, kind, roles, body, send_at, created_by_name)
      values (p_date, st.id, st.name, st.mobile, 'confirm', p.confirmed_roles,
              sms_render('confirm', st.name, p_date, p.confirmed_roles), v_send_at, v_by);
      v_queued := v_queued + 1;

    else  -- cancel: only for someone currently no longer confirmed
      a := null;
      select e into a from jsonb_array_elements(rota_sms_affected_core(p_date)) e
      where (e->>'staff_id')::uuid = st.id and e->>'change' = 'removed';
      if a is null then
        v_skipped := v_skipped || jsonb_build_object('name', st.name, 'reason', 'not_affected'); continue;
      end if;
      if (a->>'confirm_status') in ('scheduled','held') then
        v_skipped := v_skipped || jsonb_build_object('name', st.name, 'reason', 'confirmation_not_sent_yet'); continue;
      end if;
      v_to := coalesce(st.mobile, (select to_number from sms_messages where id = (a->>'confirm_id')::uuid));
      insert into sms_messages (rota_date, staff_id, staff_name, to_number, kind, roles, body, send_at, created_by_name)
      values (p_date, st.id, st.name, v_to, 'cancel', a->'roles',
              sms_render('cancel', st.name, p_date, a->'roles'), v_send_at, v_by);
      v_queued := v_queued + 1;
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'queued', v_queued, 'skipped', v_skipped, 'send_at', v_send_at);
end;
$$;

-- ============================================================================
-- Safety net: also HOLD a scheduled confirmation whose start time is now out of date
-- ============================================================================
create or replace function sms_claim_due(p_limit int default 20) returns setof sms_messages
language plpgsql security definer set search_path = public as $$
declare r sms_messages; v_confirmed boolean; v_roles jsonb; st staff;
begin
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

-- ============================================================================
-- Grants (re-created / new functions)
-- ============================================================================
revoke execute on function rota_sms_slots(date) from public, anon, authenticated;
revoke execute on function rota_sms_people(date) from public, anon, authenticated;
revoke execute on function sms_default_time(text) from public, anon, authenticated;
revoke execute on function sms_start_text(jsonb) from public, anon;
revoke execute on function sms_starts_sig(jsonb) from public, anon;
revoke execute on function sms_render(text,text,date,jsonb) from public, anon, authenticated;
revoke execute on function rota_sms_affected_core(date) from public, anon, authenticated;
revoke execute on function rota_sms_preview(date) from public, anon;
revoke execute on function rota_sms_queue(date,timestamptz,uuid[],text,timestamptz) from public, anon;
revoke execute on function sms_claim_due(int) from public, anon, authenticated;
grant execute on function rota_sms_preview(date) to authenticated;
grant execute on function rota_sms_queue(date,timestamptz,uuid[],text,timestamptz) to authenticated;
grant execute on function sms_claim_due(int) to service_role;
