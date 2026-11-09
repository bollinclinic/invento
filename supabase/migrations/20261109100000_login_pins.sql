-- Sign in with a 4-digit PIN on a computer the person has already signed in on with a password.
--
-- How it is kept safe:
--   * A PIN belongs to ONE person on ONE computer. The computer holds a long random "device
--     key" (made by the page, kept in that browser); the database stores only its SHA-256 and a
--     bcrypt hash of the PIN. Without the device key the PIN is useless, so a PIN can't be tried
--     from anywhere else.
--   * Five wrong tries delete the PIN: the person signs in with the password and sets a new one.
--   * Changing or resetting a password deletes every PIN of that person.
--   * A deactivated account can't sign in with a PIN.
--   * The table has RLS on and no policies: it is reached only through the functions below.
--     pin_check is for the pin-login Edge Function only (service role).
create extension if not exists pgcrypto with schema extensions;

create table login_pins (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  device_hash  text not null,
  pin_hash     text not null,
  fails        int  not null default 0,
  created_at   timestamptz not null default now(),
  last_used_at timestamptz,
  unique (user_id, device_hash)
);
alter table login_pins enable row level security;
revoke all on login_pins from public, anon, authenticated;

create or replace function pin_device_hash(p_device text) returns text
language sql immutable set search_path = public, extensions as $$
  select encode(digest(coalesce(p_device, ''), 'sha256'), 'hex');
$$;
revoke execute on function pin_device_hash(text) from public, anon, authenticated;

-- PINs that are the first thing anyone would try
create or replace function pin_too_easy(p_pin text) returns boolean
language sql immutable set search_path = public as $$
  select p_pin ~ '^(\d)\1{3}$' or p_pin in ('1234', '4321', '0123', '2580');
$$;
revoke execute on function pin_too_easy(text) from public, anon;
grant execute on function pin_too_easy(text) to authenticated;

-- Set (or change) my PIN on this computer.
create or replace function pin_set(p_device text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); h text;
begin
  if uid is null or app_role_rank() < 0 then
    raise exception 'Not signed in' using errcode = '42501';
  end if;
  if coalesce(p_pin, '') !~ '^\d{4}$' then raise exception 'The PIN must be 4 numbers'; end if;
  if pin_too_easy(p_pin) then raise exception 'That PIN is too easy to guess. Choose another'; end if;
  if length(coalesce(p_device, '')) < 32 then raise exception 'This computer could not be identified'; end if;
  h := pin_device_hash(p_device);
  insert into login_pins (user_id, device_hash, pin_hash)
  values (uid, h, crypt(p_pin, gen_salt('bf', 10)))
  on conflict (user_id, device_hash)
  do update set pin_hash = excluded.pin_hash, fails = 0, created_at = now(), last_used_at = null;
  -- at most 10 computers per person: the ones used longest ago go
  delete from login_pins where user_id = uid and id not in (
    select id from login_pins where user_id = uid
    order by coalesce(last_used_at, created_at) desc limit 10);
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function pin_set(text, text) from public, anon;
grant execute on function pin_set(text, text) to authenticated;

-- Remove my PIN from this computer (p_device) or from every computer (null).
create or replace function pin_clear(p_device text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); n int;
begin
  if uid is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  delete from login_pins
   where user_id = uid and (p_device is null or device_hash = pin_device_hash(p_device));
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'removed', n);
end $$;
revoke execute on function pin_clear(text) from public, anon;
grant execute on function pin_clear(text) to authenticated;

-- Do I still have a PIN on this computer? (It goes after 5 wrong tries or a password change.)
create or replace function pin_status(p_device text) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists(select 1 from login_pins
                 where user_id = auth.uid() and device_hash = pin_device_hash(p_device));
$$;
revoke execute on function pin_status(text) from public, anon;
grant execute on function pin_status(text) to authenticated;

-- The check itself. Called only by the pin-login Edge Function with the service role.
-- Never raises for a wrong PIN, so the failed try is always counted.
create or replace function pin_check(p_username text, p_device text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare prof profiles; r login_pins; em text; left_n int;
begin
  if coalesce(p_pin, '') !~ '^\d{4}$' or length(coalesce(p_device, '')) < 32 then
    return jsonb_build_object('ok', false, 'reason', 'no_pin');
  end if;
  select * into prof from profiles where lower(username) = lower(trim(coalesce(p_username, '')));
  if not found then return jsonb_build_object('ok', false, 'reason', 'no_pin'); end if;
  select * into r from login_pins
   where user_id = prof.id and device_hash = pin_device_hash(p_device) for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no_pin'); end if;
  if not prof.active then return jsonb_build_object('ok', false, 'reason', 'inactive'); end if;

  if r.pin_hash = crypt(p_pin, r.pin_hash) then
    update login_pins set fails = 0, last_used_at = now() where id = r.id;
    select email into em from auth.users where id = prof.id;
    if em is null then return jsonb_build_object('ok', false, 'reason', 'no_pin'); end if;
    return jsonb_build_object('ok', true, 'user_id', prof.id, 'email', em);
  end if;

  left_n := 5 - (r.fails + 1);
  if left_n <= 0 then
    delete from login_pins where id = r.id;
    return jsonb_build_object('ok', false, 'reason', 'locked');
  end if;
  update login_pins set fails = r.fails + 1 where id = r.id;
  return jsonb_build_object('ok', false, 'reason', 'wrong', 'left', left_n);
end $$;
revoke execute on function pin_check(text, text, text) from public, anon, authenticated;
grant execute on function pin_check(text, text, text) to service_role;

-- A changed or reset password removes that person's PINs everywhere.
create or replace function pins_drop_on_password_change() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.encrypted_password is distinct from old.encrypted_password then
    delete from public.login_pins where user_id = new.id;
  end if;
  return new;
end $$;
revoke execute on function pins_drop_on_password_change() from public, anon, authenticated;

drop trigger if exists pins_drop_on_password_change on auth.users;
create trigger pins_drop_on_password_change
  after update of encrypted_password on auth.users
  for each row execute function public.pins_drop_on_password_change();
