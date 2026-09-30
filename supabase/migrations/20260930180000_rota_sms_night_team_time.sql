-- Rota texts: one "Night team starts" time per day, per request. It sets the start time for the
-- whole night team at once -- Night nurse, Night HCA and RMO on site (night) -- instead of giving
-- each an own time. Stored in rota_days.times under the key 'nightTeam' (slot keys never use that
-- name), so rota_save_day does not change.
-- Precedence for a night role: the person's own time > the day's night team time > the role's
-- usual time (sms_default_times). Only rota_sms_slots() changes (same signature).

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
