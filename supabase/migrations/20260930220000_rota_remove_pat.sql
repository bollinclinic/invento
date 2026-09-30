-- Remove PAT numbers from the theatre rota completely, per request. The rota's case lists
-- (rota_theatres.cases, a jsonb array of {surgeon, procedure, pat, stay}) no longer carry a
-- PAT number:
--   1. every PAT number already saved in a rota case list is deleted (the 'pat' key is removed
--      from each case object -- this is permanent);
--   2. a trigger strips any 'pat' key before a rota theatre row is stored, so even a page that
--      was opened before this change can't save one again.
-- PAT numbers elsewhere (implants, samples, stickers) are separate features and are untouched.
-- rota_save_day is not changed.

create or replace function rota_cases_without_pat(p_cases jsonb) returns jsonb
language sql immutable set search_path = public as $$
  select case when jsonb_typeof(p_cases) = 'array'
    then coalesce((select jsonb_agg(case when jsonb_typeof(e) = 'object' then e - 'pat' else e end order by ord)
                   from jsonb_array_elements(p_cases) with ordinality x(e, ord)), '[]'::jsonb)
    else p_cases end;
$$;

create or replace function rota_theatres_strip_pat() returns trigger
language plpgsql set search_path = public as $$
begin
  new.cases := rota_cases_without_pat(new.cases);
  return new;
end;
$$;

drop trigger if exists rota_theatres_strip_pat on rota_theatres;
create trigger rota_theatres_strip_pat before insert or update of cases on rota_theatres
  for each row execute function rota_theatres_strip_pat();

-- delete every PAT number already stored in rota case lists
update rota_theatres set cases = rota_cases_without_pat(cases)
where cases::text like '%"pat"%';

revoke execute on function rota_cases_without_pat(jsonb) from public, anon;
revoke execute on function rota_theatres_strip_pat() from public, anon, authenticated;
