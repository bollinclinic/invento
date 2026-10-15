-- Rota: flexible staffing over up to three rooms (Theatre 1, Theatre 2, Minor op).
--
-- Until now each day stored fixed slots: two theatres, each with one SFA, one ODP, Scrub 1-3,
-- one HCA, one Recovery and up to three surgeons, plus one name per day-cover box. The new Rota
-- grid needs any number of people per role, people not yet given a room, a third room (Minor op)
-- and several day/night or AM/PM names per row. So:
--
--   rota_days.people   jsonb array, one entry per person per day:
--     {id, role, name, rooms:[1|2|3,...], shift, star, time, lead}
--       role   surgeon | anaesthetist | sfa | odp | scrub | recovery | theatre_hca
--              | ward_nurse | ward_hca | rmo | reception | housekeeping
--       rooms  [] = not allocated yet; the FIRST room is the one whose list-start time applies
--       shift  day|night (ward_nurse, ward_hca, rmo) or am|pm (reception, housekeeping)
--       star   provisional;  time  the person's own start 'HH:MM';  lead  Lead scrub (one a day)
--   rota_theatres rows 1..3 gain: running, tags (e.g. {GA,Overnight}), la_no_anaesthetist
--
-- Every existing day is converted in place below. The old slot columns are left untouched as
-- history (like hca_theatre) and nothing reads them any more. The old rota_save_day now REFUSES,
-- so a device still running the old page can never save into the old columns.
--
-- Every text-message function reads people through rota_sms_slots(), rebuilt here on the new
-- model with the same output columns, so preview, send, cancellation and the safety net are
-- unchanged. Start times are worked out exactly as before (own > night team > list start / usual
-- time), so nobody already texted is shown as "time changed" by the conversion.

alter table rota_days add column people jsonb not null default '[]'::jsonb;
alter table rota_theatres
  add column running boolean not null default false,
  add column tags text[] not null default '{}',
  add column la_no_anaesthetist boolean not null default false;
alter table rota_theatres add constraint rota_theatres_room_1_to_3 check (theatre_number between 1 and 3);

-- ---------------------------------------------------------------------------------------------
-- 1. Convert every existing day
-- ---------------------------------------------------------------------------------------------
do $$
declare
  d rota_days;
  t rota_theatres;
  v_people jsonb;
  v_acks jsonb;
  v_running int[];
  v_stars jsonb;
  v_times jsonb;
  v_flags jsonb;
  v_lead text;
  v_both jsonb;
  n int;
  other int;
  r record;
  k text;
  v_name text;
  v_rooms jsonb;
  dc record;
begin
  for d in select * from rota_days loop
    v_people := '[]'::jsonb;
    v_stars := coalesce(d.stars, '{}'::jsonb);
    v_times := coalesce(d.times, '{}'::jsonb);
    v_flags := case when jsonb_typeof(d.flags) = 'object' then d.flags else '{}'::jsonb end;
    v_lead  := v_flags ->> 'lead';
    v_both  := case when jsonb_typeof(v_flags -> 'both') = 'object' then v_flags -> 'both' else '{}'::jsonb end;
    v_running := case when coalesce(d.theatres, 0) >= 2 then array[1,2]
                      when coalesce(d.theatres, 0) = 1 then array[case when v_flags ->> 'only' = '2' then 2 else 1 end]
                      else '{}'::int[] end;

    foreach n in array v_running loop
      select * into t from rota_theatres where day_id = d.id and theatre_number = n;
      if not found then continue; end if;
      other := case when n = 1 then 2 else 1 end;
      for r in
        select * from (values
          ('surgeon','surgeon',t.surgeon), ('surgeon2','surgeon',t.surgeon2), ('surgeon3','surgeon',t.surgeon3),
          ('anaes','anaesthetist',t.anaesthetist), ('sfa','sfa',t.sfa),
          ('scrub1','scrub',t.scrub1), ('scrub2','scrub',t.scrub2), ('scrub3','scrub',t.scrub3),
          ('odp','odp',t.odp), ('hca','theatre_hca',t.hca), ('recovery','recovery',t.recovery)
        ) s(slot, role, person)
      loop
        v_name := btrim(coalesce(r.person, ''));
        if v_name = '' then continue; end if;
        k := 't' || n || '.' || r.slot;
        v_rooms := jsonb_build_array(n);
        -- "supporting both theatres" (2-theatre days only) becomes rooms [this, other]
        if coalesce(d.theatres, 0) >= 2 and v_both ? k then
          v_rooms := jsonb_build_array(n, other);
        end if;
        -- the same person already added from the other theatre's "both" tick: skip the duplicate
        if exists (select 1 from jsonb_array_elements(v_people) e
                   where e->>'role' = r.role and lower(e->>'name') = lower(v_name)
                     and (e->'rooms') @> jsonb_build_array(n)) then
          continue;
        end if;
        v_people := v_people || jsonb_build_object(
          'id', gen_random_uuid()::text, 'role', r.role, 'name', v_name, 'rooms', v_rooms,
          'shift', null, 'star', v_stars ? k,
          'time', case when coalesce(v_times ->> k, '') ~ '^[0-2][0-9]:[0-5][0-9]$' then v_times ->> k end,
          'lead', (r.role = 'scrub' and v_lead = k));
      end loop;
      update rota_theatres set running = true,
        tags = case when t.type = 'LA' then array['LA'] else array['GA'] end
      where id = t.id;
    end loop;

    -- day cover: old key, role, shift, name
    for dc in
      select * from (values
        ('ward','ward_nurse','day',d.ward_nurse), ('nightNurse','ward_nurse','night',d.night_nurse),
        ('hcaWard','ward_hca','day',d.hca_ward), ('hcaNight','ward_hca','night',d.hca_night),
        ('rmoDay','rmo','day',d.rmo_day), ('rmoNight','rmo','night',d.rmo_night),
        ('receptionAM','reception','am',d.reception_am), ('receptionPM','reception','pm',d.reception_pm),
        ('housekeepAM','housekeeping','am',d.housekeeping_am), ('housekeepPM','housekeeping','pm',d.housekeeping_pm)
      ) s(k, role, shift, person)
    loop
      v_name := btrim(coalesce(dc.person, ''));
      if v_name = '' then continue; end if;
      v_people := v_people || jsonb_build_object(
        'id', gen_random_uuid()::text, 'role', dc.role, 'name', v_name, 'rooms', '[]'::jsonb,
        'shift', dc.shift, 'star', v_stars ? dc.k,
        'time', case when coalesce(v_times ->> dc.k, '') ~ '^[0-2][0-9]:[0-5][0-9]$' then v_times ->> dc.k end,
        'lead', false);
    end loop;

    -- cover notes: old slot keys -> room/role keys ("t2.scrub1" -> "r2.scrub", "ward" -> "ward_nurse.day")
    select coalesce(jsonb_object_agg(nk, val), '{}'::jsonb) into v_acks from (
      select distinct on (nk) nk, val from (
        select case
          when key ~ '^t[12]\.' then
            'r' || substr(key, 2, 1) || '.' ||
            case regexp_replace(substr(key, 4), '[0-9]+$', '')
              when 'anaes' then 'anaesthetist' when 'hca' then 'theatre_hca' when 'scrub' then 'scrub'
              else regexp_replace(substr(key, 4), '[0-9]+$', '') end
          when key = 'ward' then 'ward_nurse.day'      when key = 'nightNurse' then 'ward_nurse.night'
          when key = 'hcaWard' then 'ward_hca.day'     when key = 'hcaNight' then 'ward_hca.night'
          when key = 'rmoDay' then 'rmo.day'           when key = 'rmoNight' then 'rmo.night'
          else key end as nk, value as val
        from jsonb_each(case when jsonb_typeof(d.acks) = 'object' then d.acks else '{}'::jsonb end)
      ) a order by nk
    ) b;

    update rota_days set people = v_people, acks = v_acks where id = d.id;
  end loop;
end $$;

-- ---------------------------------------------------------------------------------------------
-- 2. Saving: one atomic, version-checked save of the whole day (CLAUDE.md section 9 #8)
-- ---------------------------------------------------------------------------------------------
create or replace function rota_valid_people(p jsonb) returns jsonb
language plpgsql volatile set search_path = public as $$
declare
  e jsonb;
  out jsonb := '[]'::jsonb;
  v_role text; v_name text; v_shift text; v_rooms jsonb; v_id text; v_time text;
  v_ids text[] := '{}';
  v_leads int := 0;
  rm jsonb;
begin
  if p is null then return '[]'::jsonb; end if;
  if jsonb_typeof(p) <> 'array' then raise exception 'People must be a list'; end if;
  for e in select * from jsonb_array_elements(p) loop
    v_role := e->>'role';
    if v_role not in ('surgeon','anaesthetist','sfa','odp','scrub','recovery','theatre_hca',
                      'ward_nurse','ward_hca','rmo','reception','housekeeping') then
      raise exception 'Unknown rota role: %', coalesce(v_role, '(none)');
    end if;
    v_name := regexp_replace(btrim(coalesce(e->>'name', '')), '\s+', ' ', 'g');
    if v_name = '' then continue; end if;                       -- blank entries are dropped
    if length(v_name) > 120 then raise exception 'Name too long: %', left(v_name, 40); end if;

    v_rooms := '[]'::jsonb;
    if jsonb_typeof(e->'rooms') = 'array' then
      for rm in select * from jsonb_array_elements(e->'rooms') loop
        if jsonb_typeof(rm) <> 'number' or (rm::text)::int not between 1 and 3 then
          raise exception 'Room must be 1, 2 or 3';
        end if;
        if not v_rooms @> jsonb_build_array((rm::text)::int) then v_rooms := v_rooms || jsonb_build_array((rm::text)::int); end if;
      end loop;
    end if;
    -- day cover never sits in a theatre
    if v_role in ('ward_nurse','ward_hca','rmo','reception','housekeeping') then v_rooms := '[]'::jsonb; end if;

    v_shift := nullif(e->>'shift', '');
    if v_role in ('ward_nurse','ward_hca','rmo') then
      v_shift := coalesce(v_shift, 'day');
      if v_shift not in ('day','night') then raise exception 'Shift must be day or night'; end if;
    elsif v_role in ('reception','housekeeping') then
      v_shift := coalesce(v_shift, 'am');
      if v_shift not in ('am','pm') then raise exception 'Shift must be AM or PM'; end if;
    else
      v_shift := null;
    end if;

    v_time := nullif(e->>'time', '');
    if v_time is not null and v_time !~ '^[0-2][0-9]:[0-5][0-9]$' then raise exception 'Start time must be HH:MM'; end if;

    v_id := nullif(btrim(coalesce(e->>'id', '')), '');
    if v_id is null or v_id = any(v_ids) then v_id := gen_random_uuid()::text; end if;
    v_ids := v_ids || v_id;

    if coalesce((e->>'lead')::boolean, false) then
      if v_role <> 'scrub' then raise exception 'Only a scrub can be Lead'; end if;
      v_leads := v_leads + 1;
    end if;

    out := out || jsonb_build_object('id', v_id, 'role', v_role, 'name', v_name, 'rooms', v_rooms,
      'shift', v_shift, 'star', coalesce((e->>'star')::boolean, false), 'time', v_time,
      'lead', coalesce((e->>'lead')::boolean, false));
  end loop;
  if v_leads > 1 then raise exception 'Only one Lead scrub per day'; end if;
  return out;
end;
$$;

create or replace function rota_save_day_v2(p_date date, p_expected_updated_at timestamptz, p_day jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_day_id uuid;
  v_current timestamptz;
  v_people jsonb;
  v_rooms jsonb := coalesce(p_day->'rooms', '{}'::jsonb);
  v_room jsonb;
  v_running boolean;
  v_count int := 0;
  v_new rota_days%rowtype;
  v_tags text[];
  n int;
begin
  if (select app_role_rank()) < 3 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  if p_date is null then raise exception 'Date required'; end if;
  v_people := rota_valid_people(p_day->'people');
  if jsonb_typeof(v_rooms) <> 'object' then raise exception 'Rooms must be an object'; end if;

  select id, updated_at into v_day_id, v_current from rota_days where date = p_date for update;
  if v_day_id is not null and (p_expected_updated_at is null or v_current <> p_expected_updated_at) then
    raise exception 'ROTA_CONFLICT' using errcode = 'P0001',
      detail = 'This day was changed by someone else since you started editing.';
  end if;

  -- a room runs if it is switched on, or a surgeon is allocated to it
  for n in 1..3 loop
    v_room := coalesce(v_rooms -> n::text, '{}'::jsonb);
    v_running := coalesce((v_room->>'running')::boolean, false)
      or exists (select 1 from jsonb_array_elements(v_people) e
                 where e->>'role' = 'surgeon' and (e->'rooms') @> jsonb_build_array(n));
    if v_running then v_count := v_count + 1; end if;
  end loop;

  insert into rota_days (date, theatres, people, notes, acks, times)
  values (p_date, v_count, v_people, nullif(p_day->>'notes', ''),
          case when jsonb_typeof(p_day->'acks') = 'object' then p_day->'acks' else '{}'::jsonb end,
          case when jsonb_typeof(p_day->'times') = 'object' then p_day->'times' else '{}'::jsonb end)
  on conflict (date) do update set
    theatres = excluded.theatres, people = excluded.people, notes = excluded.notes,
    acks = excluded.acks, times = excluded.times
  returning * into v_new;

  for n in 1..3 loop
    v_room := coalesce(v_rooms -> n::text, '{}'::jsonb);
    v_running := coalesce((v_room->>'running')::boolean, false)
      or exists (select 1 from jsonb_array_elements(v_people) e
                 where e->>'role' = 'surgeon' and (e->'rooms') @> jsonb_build_array(n));
    select coalesce(array_agg(distinct btrim(x)) filter (where btrim(x) <> ''), '{}') into v_tags
      from jsonb_array_elements_text(case when jsonb_typeof(v_room->'tags') = 'array' then v_room->'tags' else '[]'::jsonb end) x;
    insert into rota_theatres (day_id, theatre_number, running, tags, la_no_anaesthetist, type, detail, colour,
                               cases, start_time)
    values (v_new.id, n, v_running, v_tags, coalesce((v_room->>'laNoAnaesthetist')::boolean, false),
            case when 'LA' = any(v_tags) and not ('GA' = any(v_tags)) then 'LA' else 'GA' end,
            nullif(v_room->>'detail', ''), nullif(v_room->>'colour', ''),
            case when jsonb_typeof(v_room->'cases') = 'array' then v_room->'cases' else '[]'::jsonb end,
            case when coalesce(v_room->>'startTime', '') ~ '^[0-2][0-9]:[0-5][0-9]$' then (v_room->>'startTime')::time end)
    on conflict (day_id, theatre_number) do update set
      running = excluded.running, tags = excluded.tags, la_no_anaesthetist = excluded.la_no_anaesthetist,
      type = excluded.type, detail = excluded.detail, colour = excluded.colour,
      cases = excluded.cases, start_time = excluded.start_time;
  end loop;

  return jsonb_build_object('ok', true, 'updated_at', v_new.updated_at, 'people', v_people, 'theatres', v_count);
end;
$$;

-- the old save: refused, so a page that hasn't been refreshed can't write into the old columns
create or replace function rota_save_day(p_date date, p_expected_updated_at timestamptz, p_fields jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  raise exception 'The rota has been upgraded. Please refresh the page (your change was not saved).'
    using errcode = 'P0001';
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. Texts: who is on a day, read from people. Same columns as before.
-- ---------------------------------------------------------------------------------------------
create or replace function rota_room_words(p_rooms jsonb) returns text
language sql immutable set search_path = public as $$
  -- [1] -> 'Theatre 1'; [3] -> 'Minor op'; [1,2] -> 'Theatres 1 and 2'; [1,3] -> 'Theatre 1 and Minor op'
  with r as (select (x::text)::int as n, ord from jsonb_array_elements(p_rooms) with ordinality a(x, ord)),
       th as (select string_agg(n::text, ' and ' order by n) as nums, count(*) as c from r where n in (1,2)),
       mo as (select count(*) as c from r where n = 3)
  select case
    when (select c from th) = 0 and (select c from mo) > 0 then 'Minor op'
    when (select c from th) = 1 then 'Theatre ' || (select nums from th) || case when (select c from mo) > 0 then ' and Minor op' else '' end
    when (select c from th) = 2 then 'Theatres ' || (select nums from th) || case when (select c from mo) > 0 then ' and Minor op' else '' end
    else '' end;
$$;

drop function if exists rota_sms_slots(date);
create function rota_sms_slots(p_date date)
returns table(slot_key text, role_label text, theatre int, person text, starred boolean, start_time text)
language sql stable security definer set search_path = public as $$
  with d as (select * from rota_days where date = p_date),
  running as (
    select t.theatre_number as n, to_char(t.start_time, 'HH24:MI') as st
    from rota_theatres t join d on t.day_id = d.id where t.running
  ),
  ppl as (
    select e, e->>'role' as role, coalesce(e->>'shift', '') as shift,
           -- only rooms that are actually running count
           coalesce((select jsonb_agg(x order by ord) from jsonb_array_elements(e->'rooms') with ordinality a(x, ord)
                     where (x::text)::int in (select n from running)), '[]'::jsonb) as rooms
    from d, jsonb_array_elements(d.people) e
    where nullif(btrim(e->>'name'), '') is not null
  )
  select p.e->>'id',
         case p.role
           when 'scrub'       then 'Scrub (' || rota_room_words(p.rooms) || ')' || case when (p.e->>'lead')::boolean then ' - Lead' else '' end
           when 'sfa'         then 'SFA / practitioner (' || rota_room_words(p.rooms) || ')'
           when 'odp'         then 'ODP (' || rota_room_words(p.rooms) || ')'
           when 'recovery'    then 'Recovery nurse / ODP (' || rota_room_words(p.rooms) || ')'
           when 'theatre_hca' then 'Theatre HCA (' || rota_room_words(p.rooms) || ')'
           when 'ward_nurse'  then case when p.shift = 'night' then 'Night nurse' else 'Ward nurse' end
           when 'ward_hca'    then case when p.shift = 'night' then 'Night HCA' else 'Ward HCA' end
           when 'rmo'         then case when p.shift = 'night' then 'RMO on site (night)' else 'RMO on site (day)' end
         end,
         case when p.role in ('ward_nurse','ward_hca','rmo') then 0
              when jsonb_array_length(p.rooms) = 1 then (p.rooms->>0)::int
              else 0 end,
         btrim(p.e->>'name'),
         coalesce((p.e->>'star')::boolean, false),
         coalesce(
           sms_valid_time(p.e->>'time'),
           case when p.role in ('ward_nurse','ward_hca','rmo') then
             case when p.shift = 'night' then
               coalesce(sms_valid_time((select times->>'nightTeam' from d)),
                        sms_default_time(case p.role when 'ward_nurse' then 'nightNurse' when 'ward_hca' then 'hcaNight' else 'rmoNight' end))
             else sms_default_time(case p.role when 'ward_nurse' then 'ward' when 'ward_hca' then 'hcaWard' else 'rmoDay' end) end
           else (select st from running where n = (p.rooms->>0)::int) end)
  from ppl p
  where (select theatres from d) > 0
    and (p.role in ('ward_nurse','ward_hca','rmo')
         or (p.role in ('scrub','sfa','odp','recovery','theatre_hca') and jsonb_array_length(p.rooms) > 0));
$$;
revoke execute on function rota_sms_slots(date) from public, anon, authenticated;
revoke execute on function rota_valid_people(jsonb) from public, anon;
revoke execute on function rota_room_words(jsonb) from public, anon;

-- ---------------------------------------------------------------------------------------------
-- 4. Staff database rename follows through to the rota (staff roles only: not surgeons or
--    anaesthetists, who aren't in the staff database)
-- ---------------------------------------------------------------------------------------------
create or replace function rota_rename_person(p_old text, p_new text) returns int
language plpgsql security definer set search_path = public as $$
declare k text := lower(btrim(coalesce(p_old,''))); v_new text := btrim(coalesce(p_new,'')); n int;
begin
  if k = '' or v_new = '' or (k = lower(v_new) and p_old = p_new) then return 0; end if;
  update rota_days d set people = (
      select jsonb_agg(case when e->>'role' not in ('surgeon','anaesthetist') and lower(btrim(e->>'name')) = k
                            then jsonb_set(e, '{name}', to_jsonb(v_new)) else e end order by ord)
      from jsonb_array_elements(d.people) with ordinality a(e, ord))
  where exists (select 1 from jsonb_array_elements(d.people) e
                where e->>'role' not in ('surgeon','anaesthetist') and lower(btrim(e->>'name')) = k);
  get diagnostics n = row_count;
  return n;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- grants
-- ---------------------------------------------------------------------------------------------
revoke execute on function rota_save_day_v2(date,timestamptz,jsonb) from public, anon;
grant execute on function rota_save_day_v2(date,timestamptz,jsonb) to authenticated;
revoke execute on function rota_save_day(date,timestamptz,jsonb) from public, anon;
grant execute on function rota_save_day(date,timestamptz,jsonb) to authenticated;
