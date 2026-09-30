-- Rota SMS: text Scrub / ODP / Ward nurse staff about their rota shifts from the clinic's own
-- phone (an Android phone running SMS Gateway for Android). Rules, per explicit request:
--   * NOTHING is ever sent automatically. A row in sms_messages only ever comes from
--     rota_sms_queue / sms_queue_test, i.e. a superadmin pressing Send for a specific day.
--     There are no triggers here and nothing that creates messages on its own.
--   * Cancellations are offered to the user after a save (rota_sms_affected, read-only) -- they
--     are only queued if the user chooses to send them.
--   * A schedule time that has already passed is refused, never silently turned into "now".
--   * The only automatic behaviour is a safety net that PREVENTS sending: sms_claim_due holds a
--     scheduled text whose person is no longer confirmed (or, for a cancellation, confirmed
--     again) instead of sending it.
-- "Confirmed" = the slot has a name and no provisional star (rota_days.stars has no entry for
-- the slot key). Rota tables and rota_save_day are NOT changed by this migration.
-- Staff mobile numbers and message texts are readable by superadmin+ only, and every write goes
-- through a security-definer function. No secrets live in this file (the repo is public): the
-- gateway credentials are Edge Function secrets, and the cron job is created by hand.

-- ============================================================================
-- Staff directory
-- ============================================================================
create table staff (
  id uuid primary key default gen_random_uuid(),
  name text not null check (btrim(name) <> ''),
  roles text[] not null default '{}',
  mobile text check (mobile is null or mobile ~ '^\+447[0-9]{9}$'),
  sms_opt_in boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index staff_name_ci_uniq on staff (lower(btrim(name)));
create trigger staff_set_updated_at before update on staff
  for each row execute function set_updated_at();

alter table staff enable row level security;
create policy "staff: superadmin read" on staff
  for select to authenticated
  using ((select app_role_rank()) >= 3);
-- no insert/update/delete policies: writes go through staff_upsert only

-- ============================================================================
-- Outbox + log of every text
-- ============================================================================
create table sms_messages (
  id uuid primary key default gen_random_uuid(),
  rota_date date,
  staff_id uuid references staff(id) on delete set null,
  staff_name text not null,
  to_number text not null check (to_number ~ '^\+447[0-9]{9}$'),
  kind text not null check (kind in ('confirm','cancel','test')),
  roles jsonb not null default '[]'::jsonb,
  body text not null,
  send_at timestamptz not null,
  status text not null default 'scheduled'
    check (status in ('scheduled','sending','sent','delivered','failed','held','cancelled','dry_run')),
  gateway_id text,
  error text,
  attempts int not null default 0,
  created_by uuid default auth.uid(),
  created_by_name text,
  -- clock_timestamp, not now(): several texts queued in one transaction must still order correctly
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default now(),
  sent_at timestamptz,
  cancelled_at timestamptz,
  cancel_reason text,
  check (kind = 'test' or rota_date is not null)
);
create index sms_messages_due_idx on sms_messages (status, send_at);
create index sms_messages_date_idx on sms_messages (rota_date);
create index sms_messages_gateway_idx on sms_messages (gateway_id);
create trigger sms_messages_set_updated_at before update on sms_messages
  for each row execute function set_updated_at();

alter table sms_messages enable row level security;
create policy "sms_messages: superadmin read" on sms_messages
  for select to authenticated
  using ((select app_role_rank()) >= 3);
-- no write policies: rows are created/changed only by the functions below

-- Default templates (editable in the app; placeholders {first_name} {day} {roles}).
-- Templates must never contain patient, case or surgeon details.
insert into settings (key, value, description) values
  ('sms_template_confirm',
   'Hi {first_name}, you''re confirmed for {roles} at Bollin Clinic on {day}. Any problems please reply or call Ruby.',
   'Rota SMS: confirmation text'),
  ('sms_template_cancel',
   'Hi {first_name}, your {roles} shift at Bollin Clinic on {day} has been cancelled. Sorry for any inconvenience - please contact Ruby with any questions.',
   'Rota SMS: cancellation text')
on conflict (key) do nothing;

-- ============================================================================
-- Helpers
-- ============================================================================
-- UK mobile -> +447XXXXXXXXX, or null if it isn't one. Accepts spaces, dashes, brackets,
-- 07..., 447..., +447..., 00447...
create or replace function sms_normalise_mobile(p text) returns text
language sql immutable set search_path = public as $$
  select case
    when d ~ '^07[0-9]{9}$'     then '+44' || substr(d, 2)
    when d ~ '^447[0-9]{9}$'    then '+' || d
    when d ~ '^00447[0-9]{9}$'  then '+' || substr(d, 3)
    else null end
  from (select regexp_replace(coalesce(p,''), '[^0-9]', '', 'g') as d) x;
$$;

-- Every in-scope, filled slot on a day: Scrub 1-3 and ODP for each running theatre, plus the
-- Ward nurse -- only when the day actually has theatres running (otherwise the rota UI doesn't
-- show the slots at all). starred = provisional.
create or replace function rota_sms_slots(p_date date)
returns table(slot_key text, role_label text, theatre int, person text, starred boolean)
language sql stable security definer set search_path = public as $$
  select s.slot_key, s.role_label, s.theatre, btrim(s.person),
         coalesce(d.stars ? s.slot_key, false)
  from rota_days d
  cross join lateral (
    select 'ward'::text, 'Ward nurse'::text, 0, d.ward_nurse
    union all
    select 't' || t.theatre_number || '.' || r.k, r.label, t.theatre_number, r.v
    from rota_theatres t
    cross join lateral (values ('scrub1','Scrub 1',t.scrub1), ('scrub2','Scrub 2',t.scrub2),
                               ('scrub3','Scrub 3',t.scrub3), ('odp','ODP',t.odp)) r(k, label, v)
    where t.day_id = d.id and t.theatre_number <= least(d.theatres, 2)
  ) s(slot_key, role_label, theatre, person)
  where d.date = p_date and d.theatres > 0 and nullif(btrim(s.person), '') is not null;
$$;

-- "Scrub 1 (Theatre 2) and Ward nurse" from a roles jsonb array
create or replace function sms_roles_text(p_roles jsonb) returns text
language sql immutable set search_path = public as $$
  select coalesce(string_agg(
           (r->>'label') || case when (r->>'theatre')::int > 0 then ' (Theatre ' || (r->>'theatre') || ')' else '' end,
           ' and ' order by ord), '')
  from jsonb_array_elements(p_roles) with ordinality e(r, ord);
$$;

create or replace function sms_render(p_kind text, p_name text, p_date date, p_roles jsonb)
returns text language sql stable security definer set search_path = public as $$
  select replace(replace(replace(
           coalesce((select value from settings where key = 'sms_template_' || p_kind), ''),
           '{first_name}', split_part(btrim(p_name), ' ', 1)),
           '{day}', to_char(p_date, 'FMDay FMDD FMMonth')),
           '{roles}', sms_roles_text(p_roles));
$$;

-- Per person on a day (grouped case-insensitively): their confirmed (unstarred) roles and
-- whether every one of their slots is starred.
create or replace function rota_sms_people(p_date date)
returns table(person_key text, person text, confirmed_roles jsonb, all_roles jsonb, has_confirmed boolean)
language sql stable security definer set search_path = public as $$
  select lower(person), min(person),
         coalesce(jsonb_agg(jsonb_build_object('key', slot_key, 'label', role_label, 'theatre', theatre)
                   order by theatre, slot_key) filter (where not starred), '[]'::jsonb),
         jsonb_agg(jsonb_build_object('key', slot_key, 'label', role_label, 'theatre', theatre, 'starred', starred)
                   order by theatre, slot_key),
         bool_or(not starred)
  from rota_sms_slots(p_date)
  group by lower(person);
$$;

-- ============================================================================
-- Staff directory writes
-- ============================================================================
create or replace function staff_upsert(
  p_id uuid, p_name text, p_roles text[], p_mobile text, p_sms_opt_in boolean, p_active boolean
) returns staff
language plpgsql security definer set search_path = public as $$
declare
  v_name text := regexp_replace(btrim(coalesce(p_name,'')), '\s+', ' ', 'g');
  v_mobile text;
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
      update staff set name = v_name, roles = coalesce(p_roles,'{}'), mobile = v_mobile,
        sms_opt_in = coalesce(p_sms_opt_in,false), active = coalesce(p_active,true)
      where id = p_id returning * into v_row;
      if v_row.id is null then raise exception 'Staff member not found'; end if;
    end if;
  exception when unique_violation then
    raise exception 'A staff member called "%" already exists', v_name;
  end;
  return v_row;
end;
$$;

-- ============================================================================
-- What the "Message staff" dialog and the post-save cancellation prompt show
-- ============================================================================
-- Everything the dialog needs, computed server-side so the preview is exactly what gets sent.
create or replace function rota_sms_preview(p_date date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_day rota_days;
  v_people jsonb;
  v_affected jsonb;
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
      'eligible', p.has_confirmed and st.id is not null and st.active and st.mobile is not null and st.sms_opt_in,
      'reason', case
         when not p.has_confirmed then 'provisional'
         when st.id is null then 'not_in_directory'
         when not st.active then 'inactive'
         when st.mobile is null then 'no_mobile'
         when not st.sms_opt_in then 'not_opted_in'
         else null end,
      'body', case when p.has_confirmed then sms_render('confirm', coalesce(st.name, p.person), p_date, p.confirmed_roles) end,
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

  v_affected := rota_sms_affected_core(p_date);

  return jsonb_build_object(
    'date', p_date,
    'exists', v_day.id is not null,
    'updated_at', v_day.updated_at,
    'theatres', coalesce(v_day.theatres, 0),
    'default_send_at', ((p_date - 1) + time '18:00') at time zone 'Europe/London',
    'people', v_people,
    'affected', v_affected,
    'cancel_template_preview', sms_render('cancel', '{first_name}', p_date, '[]'::jsonb)
  );
end;
$$;

-- People who were texted a confirmation for this day (sent, or still scheduled/held) and are
-- no longer confirmed, and haven't already been dealt with (a cancellation queued/sent, or the
-- scheduled confirmation cancelled). Moving between slots on the same day is not "affected":
-- matching is by person, not by slot.
create or replace function rota_sms_affected_core(p_date date) returns jsonb
language sql stable security definer set search_path = public as $$
  with last_confirm as (
    select distinct on (m.staff_id) m.*
    from sms_messages m
    where m.rota_date = p_date and m.kind = 'confirm' and m.staff_id is not null
      and m.status not in ('cancelled','failed','dry_run')
    order by m.staff_id, m.created_at desc, m.id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'staff_id', c.staff_id, 'name', c.staff_name, 'confirm_id', c.id,
           'confirm_status', c.status, 'send_at', c.send_at, 'sent_at', c.sent_at,
           'roles', c.roles,
           'still_on_rota_provisional', exists (select 1 from rota_sms_slots(p_date) s where lower(s.person) = lower(btrim(st.name))),
           'body', sms_render('cancel', c.staff_name, p_date, c.roles)
         ) order by c.staff_name), '[]'::jsonb)
  from last_confirm c
  join staff st on st.id = c.staff_id
  where not exists (   -- still confirmed on this day -> not affected
          select 1 from rota_sms_people(p_date) p
          where p.person_key = lower(btrim(st.name)) and p.has_confirmed)
    and not exists (   -- already dealt with: a cancellation after this confirmation
          select 1 from sms_messages k
          where k.rota_date = p_date and k.staff_id = c.staff_id and k.kind = 'cancel'
            and k.created_at > c.created_at and k.status not in ('cancelled','failed'));
$$;

create or replace function rota_sms_affected(p_date date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if (select app_role_rank()) < 3 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  return rota_sms_affected_core(p_date);
end;
$$;

-- ============================================================================
-- Queue texts -- the ONLY way a rota text is ever created (user pressed Send)
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

    else  -- cancel: only for someone currently listed as affected
      select e into a from jsonb_array_elements(rota_sms_affected_core(p_date)) e
      where (e->>'staff_id')::uuid = st.id;
      if a is null then
        v_skipped := v_skipped || jsonb_build_object('name', st.name, 'reason', 'not_affected'); continue;
      end if;
      if (a->>'confirm_status') in ('scheduled','held') then
        -- never sent: nothing to cancel by text -- the user should cancel the scheduled one
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

-- Cancel one not-yet-sent text (scheduled or held). Sent texts can't be unsent.
create or replace function rota_sms_cancel(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_by text; n int;
begin
  if (select app_role_rank()) < 3 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  select display_name into v_by from profiles where id = auth.uid();
  update sms_messages set status = 'cancelled', cancelled_at = now(),
    cancel_reason = 'cancelled by ' || coalesce(v_by, 'user')
  where id = p_id and status in ('scheduled','held');
  get diagnostics n = row_count;
  if n = 0 then raise exception 'That text has already gone (or was already cancelled)'; end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- "Send test text" from the staff panel -- user-triggered, to one number, sent now.
create or replace function sms_queue_test(p_mobile text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_to text := sms_normalise_mobile(p_mobile); v_by text; v_id uuid;
begin
  if (select app_role_rank()) < 3 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  if v_to is null then raise exception 'Not a UK mobile number: %', p_mobile; end if;
  select display_name into v_by from profiles where id = auth.uid();
  insert into sms_messages (staff_name, to_number, kind, body, send_at, created_by_name)
  values ('Test', v_to, 'test', 'Test message from the Bollin Clinic rota app. No action needed.', now(), v_by)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- Recent texts for the staff panel (phone health + log). Superadmin+.
create or replace function sms_recent(p_limit int default 50) returns setof sms_messages
language plpgsql stable security definer set search_path = public as $$
begin
  if (select app_role_rank()) < 3 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  return query select * from sms_messages order by created_at desc limit least(greatest(p_limit,1),500);
end;
$$;

-- ============================================================================
-- Dispatcher side -- called only by the sms-dispatch Edge Function (service_role), never by the
-- browser. The gateway message id is OUR sms_messages.id and the gateway refuses a duplicate id
-- (HTTP 409), so re-trying an interrupted hand-over can never produce a second text.
-- ============================================================================
-- Claims due texts. Safety net (prevents sending, never creates): a confirmation whose person
-- is no longer confirmed, a cancellation whose person is confirmed again, or any rota text to
-- someone since deactivated / opted out, is HELD instead. Also re-claims a hand-over that was
-- interrupted (status 'sending' but the gateway never confirmed it) -- safe, see above.
create or replace function sms_claim_due(p_limit int default 20) returns setof sms_messages
language plpgsql security definer set search_path = public as $$
declare r sms_messages; v_confirmed boolean; st staff;
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
      select coalesce(bool_or(p.has_confirmed), false) into v_confirmed
      from rota_sms_people(r.rota_date) p
      where p.person_key = lower(btrim(coalesce((select name from staff where id = r.staff_id), r.staff_name)));
      if (r.kind = 'confirm' and not v_confirmed) or (r.kind = 'cancel' and v_confirmed) then
        update sms_messages set status = 'held',
          error = case when r.kind = 'confirm' then 'Held: no longer confirmed on the rota'
                       else 'Held: confirmed on the rota again' end
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

-- Result of handing a text to the phone gateway.
--   p_outcome: 'accepted' (gateway took it; stays 'sending' until the phone reports back),
--              'dry_run', 'retry' (safe to try again, e.g. gateway returned an error),
--              'failed'.
create or replace function sms_mark_result(p_id uuid, p_outcome text, p_gateway_id text, p_error text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_outcome = 'accepted' then
    update sms_messages set gateway_id = p_gateway_id, error = null where id = p_id;
  elsif p_outcome = 'dry_run' then
    update sms_messages set status = 'dry_run', sent_at = now(), error = p_error where id = p_id;
  elsif p_outcome = 'retry' then
    update sms_messages set status = case when attempts >= 3 then 'failed' else 'scheduled' end,
      send_at = case when attempts >= 3 then send_at else now() + interval '2 minutes' end,
      error = p_error where id = p_id;
  else
    update sms_messages set status = 'failed', error = p_error where id = p_id;
  end if;
end;
$$;

-- Texts whose phone-side state should be checked (the dispatcher asks the gateway each minute;
-- no public webhook endpoint needed). Touches updated_at so each row is re-checked at most
-- every minute or so. 'sent' rows keep being checked for a delivery report for a day.
create or replace function sms_due_status_checks(p_limit int default 20) returns setof sms_messages
language sql security definer set search_path = public as $$
  update sms_messages set updated_at = now()
  where id in (
    select id from sms_messages
    where gateway_id is not null and created_at > now() - interval '3 days'
      and ((status = 'sending' and updated_at < now() - interval '50 seconds')
        or (status = 'sent' and updated_at < now() - interval '5 minutes' and sent_at > now() - interval '1 day'))
    order by updated_at
    limit p_limit
    for update skip locked)
  returning *;
$$;

-- The gateway's state for a text (lower-cased ProcessingState): pending | processed | sent |
-- delivered | failed | cancelled. Never moves a text backwards.
create or replace function sms_gateway_event(p_gateway_id text, p_state text, p_error text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update sms_messages set
    status = case
      when p_state = 'delivered' and status in ('sending','sent','failed') then 'delivered'
      when p_state = 'sent' and status = 'sending' then 'sent'
      when p_state in ('failed','cancelled') and status in ('sending','sent') then 'failed'
      else status end,
    sent_at = case when p_state in ('sent','delivered') then coalesce(sent_at, now()) else sent_at end,
    error = case
      when p_state = 'failed' and status in ('sending','sent') then coalesce(nullif(p_error,''), 'The phone could not send this text')
      when p_state = 'cancelled' and status in ('sending','sent') then 'Cancelled on the phone (or expired before the phone came online)'
      when p_state = 'delivered' then null
      else error end
  where gateway_id = p_gateway_id;
end;
$$;

-- ============================================================================
-- Grants
-- ============================================================================
revoke execute on function sms_normalise_mobile(text) from public, anon;
revoke execute on function rota_sms_slots(date) from public, anon, authenticated;
revoke execute on function rota_sms_people(date) from public, anon, authenticated;
revoke execute on function sms_roles_text(jsonb) from public, anon;
revoke execute on function sms_render(text,text,date,jsonb) from public, anon, authenticated;
revoke execute on function rota_sms_affected_core(date) from public, anon, authenticated;
revoke execute on function staff_upsert(uuid,text,text[],text,boolean,boolean) from public, anon;
revoke execute on function rota_sms_preview(date) from public, anon;
revoke execute on function rota_sms_affected(date) from public, anon;
revoke execute on function rota_sms_queue(date,timestamptz,uuid[],text,timestamptz) from public, anon;
revoke execute on function rota_sms_cancel(uuid) from public, anon;
revoke execute on function sms_queue_test(text) from public, anon;
revoke execute on function sms_recent(int) from public, anon;
revoke execute on function sms_claim_due(int) from public, anon, authenticated;
revoke execute on function sms_mark_result(uuid,text,text,text) from public, anon, authenticated;
revoke execute on function sms_gateway_event(text,text,text) from public, anon, authenticated;
revoke execute on function sms_due_status_checks(int) from public, anon, authenticated;

grant execute on function sms_normalise_mobile(text) to authenticated;
grant execute on function sms_roles_text(jsonb) to authenticated;
grant execute on function staff_upsert(uuid,text,text[],text,boolean,boolean) to authenticated;
grant execute on function rota_sms_preview(date) to authenticated;
grant execute on function rota_sms_affected(date) to authenticated;
grant execute on function rota_sms_queue(date,timestamptz,uuid[],text,timestamptz) to authenticated;
grant execute on function rota_sms_cancel(uuid) to authenticated;
grant execute on function sms_queue_test(text) to authenticated;
grant execute on function sms_recent(int) to authenticated;
grant execute on function sms_claim_due(int) to service_role;
grant execute on function sms_mark_result(uuid,text,text,text) to service_role;
grant execute on function sms_gateway_event(text,text,text) to service_role;
grant execute on function sms_due_status_checks(int) to service_role;
