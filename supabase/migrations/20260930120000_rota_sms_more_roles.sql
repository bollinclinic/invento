-- Rota texts: more people can be texted, per request. As well as Scrub 1-3, ODP and Ward nurse:
--   per running theatre: SFA / practitioner, Recovery nurse / ODP
--   day cover:          Ward HCA, Night nurse, Night HCA, RMO on site (night)
-- Only rota_sms_slots() changes (same signature); everything else -- the Message staff list,
-- the cancellation check and the send-time safety net -- reads from it, so they all pick the
-- new roles up automatically. Nothing else is sent automatically because of this change.
-- Labels are plain ASCII on purpose: a character like an em dash would switch a text to UCS-2,
-- cutting a single SMS from 160 to 70 characters.
-- slot_key values match the rota's own keys (and so its provisional-star keys):
--   theatre: t1.sfa, t1.recovery ...   day: hcaWard, nightNurse, hcaNight, rmoNight

create or replace function rota_sms_slots(p_date date)
returns table(slot_key text, role_label text, theatre int, person text, starred boolean)
language sql stable security definer set search_path = public as $$
  select s.slot_key, s.role_label, s.theatre, btrim(s.person),
         coalesce(d.stars ? s.slot_key, false)
  from rota_days d
  cross join lateral (
    select k, label, 0, v
    from (values ('ward',       'Ward nurse',          d.ward_nurse),
                 ('hcaWard',    'Ward HCA',            d.hca_ward),
                 ('nightNurse', 'Night nurse',         d.night_nurse),
                 ('hcaNight',   'Night HCA',           d.hca_night),
                 ('rmoNight',   'RMO on site (night)', d.rmo_night)) dc(k, label, v)
    union all
    select 't' || t.theatre_number || '.' || r.k, r.label, t.theatre_number, r.v
    from rota_theatres t
    cross join lateral (values ('scrub1','Scrub 1',t.scrub1), ('scrub2','Scrub 2',t.scrub2),
                               ('scrub3','Scrub 3',t.scrub3), ('odp','ODP',t.odp),
                               ('sfa','SFA / practitioner',t.sfa),
                               ('recovery','Recovery nurse / ODP',t.recovery)) r(k, label, v)
    where t.day_id = d.id and t.theatre_number <= least(d.theatres, 2)
  ) s(slot_key, role_label, theatre, person)
  where d.date = p_date and d.theatres > 0 and nullif(btrim(s.person), '') is not null;
$$;

revoke execute on function rota_sms_slots(date) from public, anon, authenticated;
