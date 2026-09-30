-- Rota texts, per request:
--  1. Theatre HCA (per theatre) and RMO day (day cover) can now be texted too. Still NOT
--     textable: surgeons (own picker), anaesthetist, housekeeping AM/PM, reception AM/PM.
--  2. Own start time per person: rota_days.times (jsonb, slot key -> 'HH:MM', like stars) lets
--     one person start at a different time from their theatre's "List starts" / their role's
--     usual time (e.g. Recovery starting later). A slot's start = own time if set, else the
--     theatre start / usual time.
-- Nothing is sent because of this change; the post-save prompt and send-time safety net already
-- compare start times, so an own-time change after texting is OFFERED as an updated text.

alter table rota_days add column if not exists times jsonb not null default '{}'::jsonb;

-- ============================================================================
-- rota_save_day: identical to 20260930140000 apart from TimesJSON -> rota_days.times.
-- A save that doesn't send TimesJSON (an older page still open) keeps the existing own times.
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
    rmo_day, rmo_night, housekeeping_am, housekeeping_pm, reception_am, reception_pm, notes, acks, stars, times)
  values (p_date, coalesce((f->>'Theatres')::int, 0), nullif(f->>'HCAWard',''), nullif(f->>'WardNurse',''),
    nullif(f->>'NightNurse',''), nullif(f->>'HCANight',''), nullif(f->>'RMODay',''), nullif(f->>'RMONight',''),
    nullif(f->>'HousekeepingAM',''), nullif(f->>'HousekeepingPM',''), nullif(f->>'ReceptionAM',''), nullif(f->>'ReceptionPM',''),
    nullif(f->>'Notes',''), coalesce((f->>'AcksJSON')::jsonb,'{}'::jsonb), coalesce((f->>'StarsJSON')::jsonb,'{}'::jsonb),
    coalesce((f->>'TimesJSON')::jsonb,'{}'::jsonb))
  on conflict (date) do update set
    theatres = excluded.theatres, hca_ward = excluded.hca_ward, ward_nurse = excluded.ward_nurse,
    night_nurse = excluded.night_nurse, hca_night = excluded.hca_night, rmo_day = excluded.rmo_day,
    rmo_night = excluded.rmo_night, housekeeping_am = excluded.housekeeping_am, housekeeping_pm = excluded.housekeeping_pm,
    reception_am = excluded.reception_am, reception_pm = excluded.reception_pm, notes = excluded.notes,
    acks = excluded.acks, stars = excluded.stars,
    times = case when f ? 'TimesJSON' then excluded.times else rota_days.times end
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

-- 'HH:MM' if valid, else null (a bad value never breaks anything)
create or replace function sms_valid_time(p text) returns text
language sql immutable set search_path = public as $$
  select case when p ~ '^[0-2][0-9]:[0-5][0-9]$' then p end;
$$;

-- Same signature as before; adds Theatre HCA + RMO day, and the per-person own time.
create or replace function rota_sms_slots(p_date date)
returns table(slot_key text, role_label text, theatre int, person text, starred boolean, start_time text)
language sql stable security definer set search_path = public as $$
  select s.slot_key, s.role_label, s.theatre, btrim(s.person),
         coalesce(d.stars ? s.slot_key, false),
         coalesce(sms_valid_time(d.times ->> s.slot_key), s.st)
  from rota_days d
  cross join lateral (
    select k, label, 0, v, sms_default_time(k)
    from (values ('ward',       'Ward nurse',          d.ward_nurse),
                 ('hcaWard',    'Ward HCA',            d.hca_ward),
                 ('nightNurse', 'Night nurse',         d.night_nurse),
                 ('hcaNight',   'Night HCA',           d.hca_night),
                 ('rmoDay',     'RMO on site (day)',   d.rmo_day),
                 ('rmoNight',   'RMO on site (night)', d.rmo_night)) dc(k, label, v)
    union all
    select 't' || t.theatre_number || '.' || r.k, r.label, t.theatre_number, r.v, to_char(t.start_time, 'HH24:MI')
    from rota_theatres t
    cross join lateral (values ('scrub1','Scrub 1',t.scrub1), ('scrub2','Scrub 2',t.scrub2),
                               ('scrub3','Scrub 3',t.scrub3), ('odp','ODP',t.odp),
                               ('sfa','SFA / practitioner',t.sfa),
                               ('hca','Theatre HCA',t.hca),
                               ('recovery','Recovery nurse / ODP',t.recovery)) r(k, label, v)
    where t.day_id = d.id and t.theatre_number <= least(d.theatres, 2)
  ) s(slot_key, role_label, theatre, person, st)
  where d.date = p_date and d.theatres > 0 and nullif(btrim(s.person), '') is not null;
$$;

revoke execute on function rota_sms_slots(date) from public, anon, authenticated;
revoke execute on function sms_valid_time(text) from public, anon;
