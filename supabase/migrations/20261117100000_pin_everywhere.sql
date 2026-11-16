-- Sign-in PIN, second version (asked for by the clinic, November 2026):
--   * ONE 4-number PIN per person, set once, usable on any clinic computer (the first version
--     was a separate PIN per person per computer);
--   * a developer can see, set and remove anyone's PIN (Users & roles), so the PIN is stored
--     as typed, not hashed. It is a convenience code for shared clinic computers; the password
--     is still the account's real secret and is still only ever stored hashed by Supabase Auth.
--
-- What still protects it, since this site is on the public internet:
--   * A PIN is only accepted from a browser that has been TRUSTED: one where somebody has
--     signed in with a full password at least once (trusted_devices). A brand-new browser
--     anywhere in the world cannot try PINs at all. Trusting needs a password sign-in: a
--     session that itself came from a PIN cannot trust another browser.
--   * Five wrong tries delete the PIN; the person signs in with the password and sets it again.
--   * Changing or resetting a password deletes the PIN. A deactivated account is refused.
--   * Both tables have RLS on and no policies: reached only through the functions below.
--
-- The first version (login_pins, pin_set / pin_clear / pin_status / pin_check) is left in
-- place so pages that have not been refreshed keep working; the new page does not use it.

create table user_pins (
  user_id  uuid primary key references auth.users(id) on delete cascade,
  pin      text not null check (pin ~ '^\d{4}$'),
  fails    int  not null default 0,
  set_at   timestamptz not null default now(),
  set_by   text
);
alter table user_pins enable row level security;
revoke all on user_pins from public, anon, authenticated;

create table trusted_devices (
  device_hash  text primary key,
  first_user   uuid references auth.users(id) on delete set null,
  created_at   timestamptz not null default now(),
  last_used_at timestamptz not null default now()
);
alter table trusted_devices enable row level security;
revoke all on trusted_devices from public, anon, authenticated;

-- Trust this browser. Only a session that came from a PASSWORD sign-in may do it.
create or replace function device_trust(p_device text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare h text;
begin
  if auth.uid() is null or app_role_rank() < 0 then raise exception 'Not signed in' using errcode = '42501'; end if;
  if length(coalesce(p_device, '')) < 32 then raise exception 'This computer could not be identified'; end if;
  if not coalesce(auth.jwt()->'amr', '[]'::jsonb) @> '[{"method":"password"}]'::jsonb then
    return jsonb_build_object('ok', false, 'reason', 'password_needed');
  end if;
  h := pin_device_hash(p_device);
  insert into trusted_devices (device_hash, first_user) values (h, auth.uid())
  on conflict (device_hash) do update set last_used_at = now();
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function device_trust(text) from public, anon;
grant execute on function device_trust(text) to authenticated;

-- My own PIN: set / change, remove, and "do I have one?"
create or replace function pin_set_mine(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare who text;
begin
  if auth.uid() is null or app_role_rank() < 0 then raise exception 'Not signed in' using errcode = '42501'; end if;
  if coalesce(p_pin, '') !~ '^\d{4}$' then raise exception 'The PIN must be exactly 4 numbers'; end if;
  if pin_too_easy(p_pin) then raise exception 'That PIN is too easy to guess. Choose another'; end if;
  select coalesce(nullif(trim(display_name), ''), username) into who from profiles where id = auth.uid();
  insert into user_pins (user_id, pin, set_by) values (auth.uid(), p_pin, who)
  on conflict (user_id) do update set pin = excluded.pin, fails = 0, set_at = now(), set_by = excluded.set_by;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function pin_set_mine(text) from public, anon;
grant execute on function pin_set_mine(text) to authenticated;

create or replace function pin_clear_mine() returns jsonb
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  delete from user_pins where user_id = auth.uid();
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'removed', n);
end $$;
revoke execute on function pin_clear_mine() from public, anon;
grant execute on function pin_clear_mine() to authenticated;

create or replace function pin_mine() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from user_pins where user_id = auth.uid());
$$;
revoke execute on function pin_mine() from public, anon;
grant execute on function pin_mine() to authenticated;

-- The check itself. Called only by the pin-login Edge Function with the service role.
-- Never raises for a wrong PIN, so the failed try is always counted.
create or replace function pin_check_v2(p_username text, p_device text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare prof profiles; r user_pins; em text; left_n int; h text;
begin
  if length(coalesce(p_device, '')) < 32 then return jsonb_build_object('ok', false, 'reason', 'new_device'); end if;
  h := pin_device_hash(p_device);
  if not exists(select 1 from trusted_devices where device_hash = h) then
    return jsonb_build_object('ok', false, 'reason', 'new_device');      -- before anything else: no guessing from unknown browsers
  end if;
  if coalesce(p_pin, '') !~ '^\d{4}$' then return jsonb_build_object('ok', false, 'reason', 'no_pin'); end if;
  select * into prof from profiles where lower(username) = lower(trim(coalesce(p_username, '')));
  if not found then return jsonb_build_object('ok', false, 'reason', 'no_pin'); end if;
  select * into r from user_pins where user_id = prof.id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no_pin'); end if;
  if not prof.active then return jsonb_build_object('ok', false, 'reason', 'inactive'); end if;

  if r.pin = p_pin then
    update user_pins set fails = 0 where user_id = prof.id;
    update trusted_devices set last_used_at = now() where device_hash = h;
    select email into em from auth.users where id = prof.id;
    if em is null then return jsonb_build_object('ok', false, 'reason', 'no_pin'); end if;
    return jsonb_build_object('ok', true, 'user_id', prof.id, 'email', em);
  end if;

  left_n := 5 - (r.fails + 1);
  if left_n <= 0 then
    delete from user_pins where user_id = prof.id;
    return jsonb_build_object('ok', false, 'reason', 'locked');
  end if;
  update user_pins set fails = r.fails + 1 where user_id = prof.id;
  return jsonb_build_object('ok', false, 'reason', 'wrong', 'left', left_n);
end $$;
revoke execute on function pin_check_v2(text, text, text) from public, anon, authenticated;
grant execute on function pin_check_v2(text, text, text) to service_role;

-- ---------------------------------------------------------------- developer: see, set, remove
-- {"username": "4827", ...} for everyone who has a PIN.
create or replace function pins_admin_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if app_role_rank() < 4 then raise exception 'Developer access required' using errcode = '42501'; end if;
  return coalesce((select jsonb_object_agg(p.username, u.pin) from user_pins u join profiles p on p.id = u.user_id), '{}'::jsonb);
end $$;
revoke execute on function pins_admin_list() from public, anon;
grant execute on function pins_admin_list() to authenticated;

-- Set (p_pin = 4 numbers) or remove (p_pin null) someone's PIN. Written to the activity log
-- (never the PIN itself).
create or replace function pin_admin_set(p_username text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare prof profiles; me text;
begin
  if auth.uid() is null or app_role_rank() < 4 then raise exception 'Developer access required' using errcode = '42501'; end if;
  select * into prof from profiles where lower(username) = lower(trim(coalesce(p_username, '')));
  if not found then raise exception 'Person not found'; end if;
  select coalesce(nullif(trim(display_name), ''), username) into me from profiles where id = auth.uid();
  if p_pin is null then
    delete from user_pins where user_id = prof.id;
  else
    if p_pin !~ '^\d{4}$' then raise exception 'The PIN must be exactly 4 numbers'; end if;
    if pin_too_easy(p_pin) then raise exception 'That PIN is too easy to guess. Choose another'; end if;
    insert into user_pins (user_id, pin, set_by) values (prof.id, p_pin, me)
    on conflict (user_id) do update set pin = excluded.pin, fails = 0, set_at = now(), set_by = excluded.set_by;
  end if;
  insert into activity_log (activity, code, name, by, note)
  values (case when p_pin is null then 'PIN removed' else 'PIN set' end, prof.username,
          coalesce(nullif(trim(prof.display_name), ''), prof.username), me, 'By a developer, on the Users & roles page');
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function pin_admin_set(text, text) from public, anon;
grant execute on function pin_admin_set(text, text) to authenticated;

-- A changed or reset password removes that person's PIN (both versions).
create or replace function pins_drop_on_password_change() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.encrypted_password is distinct from old.encrypted_password then
    delete from public.login_pins where user_id = new.id;
    delete from public.user_pins where user_id = new.id;
  end if;
  return new;
end $$;
revoke execute on function pins_drop_on_password_change() from public, anon, authenticated;
