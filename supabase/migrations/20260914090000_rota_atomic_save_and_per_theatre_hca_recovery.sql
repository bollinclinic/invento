-- Bug fix: rotaSave wrote rota_days + rota_theatres via a sequence of plain client-side
-- upserts with zero conflict detection -- whichever save request's full-row data was BASED ON
-- the OLDER state (a second browser tab, a stale reload, a device left open) could complete
-- LAST and silently overwrite a newer save with stale data, one full theatre row at a time.
-- Confirmed live: a day's Theatre 2 cases went missing after saving, then after re-entering
-- them and saving again, Theatre 1's case details went missing instead -- exactly the pattern
-- a stale full-row overwrite produces. rota_save_day makes the whole write one atomic,
-- version-checked operation: the caller sends back the day's updated_at from when it started
-- editing, and the save is refused (not silently applied) if the row has changed since.
--
-- Also restructures HCA - theatre and Recovery nurse / ODP from day-level Day Cover fields into
-- per-theatre fields (Theatre HCA / Dual Role, Recovery Nurse / ODP), and adds a new day-level
-- HCA night field. The old rota_days.hca_theatre/recovery_nurse columns are kept (not dropped)
-- for historical data integrity, backfilled into both theatres so existing days aren't left
-- blank, but the app no longer reads or writes them going forward.

alter table rota_theatres add column if not exists hca text;
alter table rota_theatres add column if not exists recovery text;
alter table rota_days add column if not exists hca_night text;

update rota_theatres t set hca = d.hca_theatre, recovery = d.recovery_nurse
  from rota_days d where t.day_id = d.id and (t.hca is null or t.recovery is null);

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
      anaesthetist, sfa, scrub1, scrub2, scrub3, odp, hca, recovery, cases)
    values (v_new_day.id, n, coalesce(f->>('T'||n||'_Type'), 'GA'), nullif(f->>('T'||n||'_Detail'),''),
      nullif(f->>('T'||n||'_Colour'),''), nullif(f->>('T'||n||'_Surgeon'),''), nullif(f->>('T'||n||'_Surgeon2'),''),
      nullif(f->>('T'||n||'_Surgeon3'),''), nullif(f->>('T'||n||'_Anaesthetist'),''), nullif(f->>('T'||n||'_SFA'),''),
      nullif(f->>('T'||n||'_Scrub1'),''), nullif(f->>('T'||n||'_Scrub2'),''), nullif(f->>('T'||n||'_Scrub3'),''),
      nullif(f->>('T'||n||'_ODP'),''), nullif(f->>('T'||n||'_HCA'),''), nullif(f->>('T'||n||'_Recovery'),''),
      coalesce((f->>('T'||n||'_CasesJSON'))::jsonb, '[]'::jsonb))
    on conflict (day_id, theatre_number) do update set
      type = excluded.type, detail = excluded.detail, colour = excluded.colour,
      surgeon = excluded.surgeon, surgeon2 = excluded.surgeon2, surgeon3 = excluded.surgeon3,
      anaesthetist = excluded.anaesthetist, sfa = excluded.sfa,
      scrub1 = excluded.scrub1, scrub2 = excluded.scrub2, scrub3 = excluded.scrub3,
      odp = excluded.odp, hca = excluded.hca, recovery = excluded.recovery, cases = excluded.cases;
  end loop;

  return jsonb_build_object('ok', true, 'updated_at', v_new_day.updated_at);
end;
$$;

revoke execute on function rota_save_day(date,timestamptz,jsonb) from public, anon;
grant execute on function rota_save_day(date,timestamptz,jsonb) to authenticated;
