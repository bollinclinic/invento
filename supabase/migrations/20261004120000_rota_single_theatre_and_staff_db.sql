-- Rota, per request:
--  1. On a one-theatre day the list can run in Theatre 1 OR Theatre 2: rota_days.flags.only = 2
--     means "the single running theatre is Theatre 2" (absent / anything else = Theatre 1).
--     rota_sms_slots() (same signature) now reads the running theatre from that, so texts name
--     the right theatre. rota_save_day is unchanged (flags are already saved).
--  2. Staff database: staff can be deleted (staff_delete), and correcting a staff member's NAME
--     (staff_upsert) now also corrects it everywhere that person is named on the rota, so old
--     days don't keep the old spelling. Affected days get a new updated_at, so a page that had
--     them open is told to reload rather than saving the old spelling back.
-- Nothing here sends a text.

-- ============================================================================
-- 1. Which theatre runs on a one-theatre day
-- ============================================================================
create or replace function rota_sms_slots(p_date date)
returns table(slot_key text, role_label text, theatre int, person text, starred boolean, start_time text)
language sql stable security definer set search_path = public as $$
  select s.slot_key, s.role_label, s.theatre, btrim(s.person),
         coalesce(d.stars ? s.slot_key, false),
         coalesce(sms_valid_time(d.times ->> s.slot_key), s.st)
  from rota_days d
  cross join lateral (
    select k, label, 0, v,
           case when k in ('nightNurse','hcaNight','rmoNight')
                then coalesce(sms_valid_time(d.times ->> 'nightTeam'), sms_default_time(k))
                else sms_default_time(k) end
    from (values ('ward',       'Ward nurse',          d.ward_nurse),
                 ('hcaWard',    'Ward HCA',            d.hca_ward),
                 ('nightNurse', 'Night nurse',         d.night_nurse),
                 ('hcaNight',   'Night HCA',           d.hca_night),
                 ('rmoDay',     'RMO on site (day)',   d.rmo_day),
                 ('rmoNight',   'RMO on site (night)', d.rmo_night)) dc(k, label, v)
    union all
    select x.sk,
           r.label
             || case when r.k like 'scrub%' and d.flags ->> 'lead' = x.sk then ' - Lead' else '' end
             || case when x.both then ' (Theatres 1 and 2)' else '' end,
           -- theatre 0 = "no single theatre": the label already names both
           case when x.both then 0 else t.theatre_number end,
           r.v, to_char(t.start_time, 'HH24:MI')
    from rota_theatres t
    cross join lateral (values ('scrub1','Scrub 1',t.scrub1), ('scrub2','Scrub 2',t.scrub2),
                               ('scrub3','Scrub 3',t.scrub3), ('odp','ODP',t.odp),
                               ('sfa','SFA / practitioner',t.sfa),
                               ('hca','Theatre HCA',t.hca),
                               ('recovery','Recovery nurse / ODP',t.recovery)) r(k, label, v)
    cross join lateral (
      select 't' || t.theatre_number || '.' || r.k as sk,
             (d.theatres >= 2 and jsonb_typeof(d.flags -> 'both') = 'object'
               and (d.flags -> 'both') ? ('t' || t.theatre_number || '.' || r.k)) as both) x
    where t.day_id = d.id
      and ((d.theatres >= 2 and t.theatre_number <= 2)
        or (d.theatres = 1 and t.theatre_number = case when d.flags ->> 'only' = '2' then 2 else 1 end))
  ) s(slot_key, role_label, theatre, person, st)
  where d.date = p_date and d.theatres > 0 and nullif(btrim(s.person), '') is not null;
$$;

revoke execute on function rota_sms_slots(date) from public, anon, authenticated;

-- ============================================================================
-- 2. Staff database: rename follows through to the rota; delete
-- ============================================================================
-- Replaces a person's name (matched case-insensitively, trimmed) in every rota name box that
-- uses the staff list. Surgeon and anaesthetist boxes are not part of the staff database.
create or replace function rota_rename_person(p_old text, p_new text) returns int
language plpgsql security definer set search_path = public as $$
declare k text := lower(btrim(coalesce(p_old,''))); n int := 0; c int; v_days uuid[];
begin
  if k = '' or btrim(coalesce(p_new,'')) = '' or k = lower(btrim(p_new)) and p_old = p_new then return 0; end if;

  select array_agg(distinct day_id) into v_days from rota_theatres
  where k in (lower(btrim(sfa)), lower(btrim(scrub1)), lower(btrim(scrub2)), lower(btrim(scrub3)),
              lower(btrim(odp)), lower(btrim(hca)), lower(btrim(recovery)));

  update rota_theatres set
    sfa      = case when lower(btrim(sfa))      = k then p_new else sfa end,
    scrub1   = case when lower(btrim(scrub1))   = k then p_new else scrub1 end,
    scrub2   = case when lower(btrim(scrub2))   = k then p_new else scrub2 end,
    scrub3   = case when lower(btrim(scrub3))   = k then p_new else scrub3 end,
    odp      = case when lower(btrim(odp))      = k then p_new else odp end,
    hca      = case when lower(btrim(hca))      = k then p_new else hca end,
    recovery = case when lower(btrim(recovery)) = k then p_new else recovery end
  where day_id = any(coalesce(v_days, '{}'));
  get diagnostics c = row_count; n := n + c;

  -- day-cover boxes; also touches the days whose theatre rows changed, so their updated_at moves
  update rota_days set
    hca_ward        = case when lower(btrim(hca_ward))        = k then p_new else hca_ward end,
    ward_nurse      = case when lower(btrim(ward_nurse))      = k then p_new else ward_nurse end,
    night_nurse     = case when lower(btrim(night_nurse))     = k then p_new else night_nurse end,
    hca_night       = case when lower(btrim(hca_night))       = k then p_new else hca_night end,
    rmo_day         = case when lower(btrim(rmo_day))         = k then p_new else rmo_day end,
    rmo_night       = case when lower(btrim(rmo_night))       = k then p_new else rmo_night end,
    housekeeping_am = case when lower(btrim(housekeeping_am)) = k then p_new else housekeeping_am end,
    housekeeping_pm = case when lower(btrim(housekeeping_pm)) = k then p_new else housekeeping_pm end,
    reception_am    = case when lower(btrim(reception_am))    = k then p_new else reception_am end,
    reception_pm    = case when lower(btrim(reception_pm))    = k then p_new else reception_pm end
  where id = any(coalesce(v_days, '{}'))
     or k in (lower(btrim(hca_ward)), lower(btrim(ward_nurse)), lower(btrim(night_nurse)), lower(btrim(hca_night)),
              lower(btrim(rmo_day)), lower(btrim(rmo_night)), lower(btrim(housekeeping_am)), lower(btrim(housekeeping_pm)),
              lower(btrim(reception_am)), lower(btrim(reception_pm)));
  get diagnostics c = row_count; n := n + c;
  return n;
end;
$$;

-- Same as before, plus: if an existing person's name is changed, the rota follows.
create or replace function staff_upsert(
  p_id uuid, p_name text, p_roles text[], p_mobile text, p_sms_opt_in boolean, p_active boolean
) returns staff
language plpgsql security definer set search_path = public as $$
declare
  v_name text := regexp_replace(btrim(coalesce(p_name,'')), '\s+', ' ', 'g');
  v_mobile text;
  v_old text;
  v_row staff;
begin
  if (select app_role_rank()) < 3 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  if v_name = '' then raise exception 'Name is required'; end if;
  if nullif(btrim(coalesce(p_mobile,'')), '') is not null then
    v_mobile := sms_normalise_mobile(p_mobile);
    if v_mobile is null then
      raise exception 'Not a UK mobile number: %', p_mobile using hint = 'Use the 07... format';
    end if;
  end if;
  begin
    if p_id is null then
      insert into staff (name, roles, mobile, sms_opt_in, active)
      values (v_name, coalesce(p_roles,'{}'), v_mobile, coalesce(p_sms_opt_in,false), coalesce(p_active,true))
      returning * into v_row;
    else
      select name into v_old from staff where id = p_id for update;
      update staff set name = v_name, roles = coalesce(p_roles,'{}'), mobile = v_mobile,
        sms_opt_in = coalesce(p_sms_opt_in,false), active = coalesce(p_active,true)
      where id = p_id returning * into v_row;
      if v_row.id is null then raise exception 'Staff member not found'; end if;
      if v_old is distinct from v_name then perform rota_rename_person(v_old, v_name); end if;
    end if;
  exception when unique_violation then
    raise exception 'A staff member called "%" already exists', v_name;
  end;
  return v_row;
end;
$$;

-- Delete a staff member from the database. Their name stays as typed on any rota day (shown as
-- "Not in the staff list"); their past texts stay in the log (staff_id becomes null); a text
-- still waiting to go to them is cancelled, never sent.
create or replace function staff_delete(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_name text; n int;
begin
  if (select app_role_rank()) < 3 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  select name into v_name from staff where id = p_id;
  if v_name is null then raise exception 'Staff member not found'; end if;
  update sms_messages set status = 'cancelled', cancelled_at = now(), cancel_reason = 'staff member deleted'
  where staff_id = p_id and status in ('scheduled','held');
  get diagnostics n = row_count;
  delete from staff where id = p_id;
  return jsonb_build_object('ok', true, 'name', v_name, 'cancelled_texts', n);
end;
$$;

revoke execute on function rota_rename_person(text,text) from public, anon, authenticated;
revoke execute on function staff_upsert(uuid,text,text[],text,boolean,boolean) from public, anon;
revoke execute on function staff_delete(uuid) from public, anon;
grant execute on function staff_upsert(uuid,text,text[],text,boolean,boolean) to authenticated;
grant execute on function staff_delete(uuid) to authenticated;
