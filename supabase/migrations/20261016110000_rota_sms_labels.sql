-- Rota texts: role wording for the people model (follow-up to 20261016100000_rota_people_model).
--
-- sms_roles_text() already adds " (Theatre N)" to a role whose theatre is 1 or 2, so a role in a
-- single theatre must NOT carry the room in its label (that gave "Scrub (Theatre 1) (Theatre 1)").
-- Minor op is room 3: sms_roles_text would call it "Theatre 3", so a Minor op role carries
-- "(Minor op)" itself with theatre 0, as do roles covering more than one room.
--   one theatre      label 'Scrub' / 'Scrub - Lead', theatre 1|2   -> "Scrub - Lead (Theatre 1)"
--   minor op         label 'Scrub (Minor op)', theatre 0
--   several rooms    label 'Theatre HCA (Theatres 1 and 2)', theatre 0
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
           coalesce((select jsonb_agg(x order by ord) from jsonb_array_elements(e->'rooms') with ordinality a(x, ord)
                     where (x::text)::int in (select n from running)), '[]'::jsonb) as rooms
    from d, jsonb_array_elements(d.people) e
    where nullif(btrim(e->>'name'), '') is not null
  ),
  lab as (
    select p.*,
           case when jsonb_array_length(p.rooms) = 1 and (p.rooms->>0)::int in (1, 2) then (p.rooms->>0)::int else 0 end as th,
           case p.role
             when 'scrub'       then 'Scrub' || case when coalesce((p.e->>'lead')::boolean, false) then ' - Lead' else '' end
             when 'sfa'         then 'SFA / practitioner'
             when 'odp'         then 'ODP'
             when 'recovery'    then 'Recovery nurse / ODP'
             when 'theatre_hca' then 'Theatre HCA'
           end as base
    from ppl p
  )
  select l.e->>'id',
         case l.role
           when 'ward_nurse' then case when l.shift = 'night' then 'Night nurse' else 'Ward nurse' end
           when 'ward_hca'   then case when l.shift = 'night' then 'Night HCA' else 'Ward HCA' end
           when 'rmo'        then case when l.shift = 'night' then 'RMO on site (night)' else 'RMO on site (day)' end
           else l.base || case when l.th = 0 then ' (' || rota_room_words(l.rooms) || ')' else '' end
         end,
         case when l.role in ('ward_nurse','ward_hca','rmo') then 0 else l.th end,
         btrim(l.e->>'name'),
         coalesce((l.e->>'star')::boolean, false),
         coalesce(
           sms_valid_time(l.e->>'time'),
           case when l.role in ('ward_nurse','ward_hca','rmo') then
             case when l.shift = 'night' then
               coalesce(sms_valid_time((select times->>'nightTeam' from d)),
                        sms_default_time(case l.role when 'ward_nurse' then 'nightNurse' when 'ward_hca' then 'hcaNight' else 'rmoNight' end))
             else sms_default_time(case l.role when 'ward_nurse' then 'ward' when 'ward_hca' then 'hcaWard' else 'rmoDay' end) end
           else (select st from running where n = (l.rooms->>0)::int) end)
  from lab l
  where (select theatres from d) > 0
    and (l.role in ('ward_nurse','ward_hca','rmo')
         or (l.role in ('scrub','sfa','odp','recovery','theatre_hca') and jsonb_array_length(l.rooms) > 0));
$$;
revoke execute on function rota_sms_slots(date) from public, anon, authenticated;
