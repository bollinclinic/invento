-- Security group: the signed-in person's own ticks, for the page.
--
-- {"rota.view": true, "proc.use": false}: only what a developer has ticked or unticked for
-- this person (never a locked permission). Empty for a developer, a deactivated account or
-- someone with no ticks: the page then shows exactly what the role gives, as it always has.
-- The server decides for real (app_can); this only lets the page show the right tabs.
create or replace function my_ticks() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when app_role_rank() between 0 and 3 then
    coalesce((select jsonb_object_agg(u.perm, u.allowed)
                from user_permissions u join app_permissions p on p.key = u.perm
               where u.user_id = auth.uid() and not p.locked), '{}'::jsonb)
  else '{}'::jsonb end;
$$;
revoke execute on function my_ticks() from public, anon;
grant execute on function my_ticks() to authenticated;
