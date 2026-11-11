-- Anaesthetic checks (Clinical monitoring): when each theatre's breathing circuit, water trap
-- and soda lime were last changed.
--
-- The check records themselves go to the clinic's monitoring Google Sheet, like every other
-- clinical monitoring check, and the app cannot read that Sheet. These three dates are kept here
-- only so that every computer can show "last changed 8 days ago" without staff typing the date
-- again each morning.
--
-- RLS on, no policies: reached only through the two functions below (any active account, since
-- every role does these checks).
create table anaes_dates (
  theatre          text primary key check (theatre in ('Theatre 1', 'Theatre 2')),
  circuit_date     date,
  circuit_by       text,
  water_trap_date  date,
  water_trap_by    text,
  soda_lime_date   date,
  soda_lime_by     text,
  updated_at       timestamptz not null default now(),
  updated_by       text
);
alter table anaes_dates enable row level security;
revoke all on anaes_dates from public, anon, authenticated;

-- One jsonb object keyed by theatre: {"Theatre 1": {"circuit": "2026-11-03", ...}, ...}
create or replace function anaes_get_dates() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if app_role_rank() < 0 then raise exception 'Not signed in' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_object_agg(theatre, jsonb_build_object(
      'circuit', circuit_date, 'circuitBy', circuit_by,
      'trap', water_trap_date, 'trapBy', water_trap_by,
      'soda', soda_lime_date, 'sodaBy', soda_lime_by,
      'updatedAt', updated_at, 'updatedBy', updated_by))
    from anaes_dates), '{}'::jsonb);
end $$;
revoke execute on function anaes_get_dates() from public, anon;
grant execute on function anaes_get_dates() to authenticated;

-- Record the dates after a start-of-list check. A date left out (null) is KEPT, never blanked.
-- The "by" name is stored only with a date that actually changed.
create or replace function anaes_set_dates(
  p_theatre text,
  p_circuit date default null, p_trap date default null, p_soda date default null,
  p_circuit_by text default null, p_trap_by text default null, p_soda_by text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare who text; lim date := (now() at time zone 'Europe/London')::date;
begin
  if auth.uid() is null or app_role_rank() < 0 then
    raise exception 'Not signed in' using errcode = '42501';
  end if;
  if p_theatre is null or p_theatre not in ('Theatre 1', 'Theatre 2') then
    raise exception 'Unknown theatre';
  end if;
  if coalesce(p_circuit, lim) > lim or coalesce(p_trap, lim) > lim or coalesce(p_soda, lim) > lim then
    raise exception 'A change date cannot be in the future';
  end if;
  select coalesce(nullif(trim(display_name), ''), username) into who from profiles where id = auth.uid();

  insert into anaes_dates as a (theatre, circuit_date, circuit_by, water_trap_date, water_trap_by,
                                soda_lime_date, soda_lime_by, updated_by)
  values (p_theatre, p_circuit, case when p_circuit is not null then nullif(trim(p_circuit_by), '') end,
          p_trap, case when p_trap is not null then nullif(trim(p_trap_by), '') end,
          p_soda, case when p_soda is not null then nullif(trim(p_soda_by), '') end, who)
  on conflict (theatre) do update set
    circuit_date    = coalesce(excluded.circuit_date, a.circuit_date),
    circuit_by      = case when excluded.circuit_date is not null and excluded.circuit_date is distinct from a.circuit_date
                           then excluded.circuit_by else a.circuit_by end,
    water_trap_date = coalesce(excluded.water_trap_date, a.water_trap_date),
    water_trap_by   = case when excluded.water_trap_date is not null and excluded.water_trap_date is distinct from a.water_trap_date
                           then excluded.water_trap_by else a.water_trap_by end,
    soda_lime_date  = coalesce(excluded.soda_lime_date, a.soda_lime_date),
    soda_lime_by    = case when excluded.soda_lime_date is not null and excluded.soda_lime_date is distinct from a.soda_lime_date
                           then excluded.soda_lime_by else a.soda_lime_by end,
    updated_at = now(), updated_by = who;
  return anaes_get_dates();
end $$;
revoke execute on function anaes_set_dates(text, date, date, date, text, text, text) from public, anon;
grant execute on function anaes_set_dates(text, date, date, date, text, text, text) to authenticated;
