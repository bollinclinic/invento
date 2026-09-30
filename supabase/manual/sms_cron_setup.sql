-- One-off setup of the once-a-minute SMS dispatcher job. Run BY HAND per project -- NOT a
-- migration, because the real secret must never be committed (this repo is public).
-- Replace the two placeholders in a local copy only:
--   __PROJECT_REF__      e.g. the staging or production project ref
--   __DISPATCH_SECRET__  the same value as the sms-dispatch DISPATCH_SECRET Edge Function secret
-- Safe to re-run: it replaces the stored secret and the job.
--
-- The job only calls sms-dispatch, which only sends texts a superadmin already queued with Send.
-- It never creates a text.

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

-- keep the secret in Supabase Vault (encrypted), not in the job text
select vault.update_secret(id, '__DISPATCH_SECRET__') from vault.secrets where name = 'sms_dispatch_secret';
select vault.create_secret('__DISPATCH_SECRET__', 'sms_dispatch_secret', 'Shared secret for the sms-dispatch Edge Function')
where not exists (select 1 from vault.secrets where name = 'sms_dispatch_secret');

select cron.unschedule(jobid) from cron.job where jobname = 'sms-dispatch';
select cron.schedule(
  'sms-dispatch',
  '* * * * *',
  $job$
  select net.http_post(
    url := 'https://__PROJECT_REF__.supabase.co/functions/v1/sms-dispatch',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-dispatch-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'sms_dispatch_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000);
  $job$
);

-- To stop all sending immediately:  select cron.unschedule('sms-dispatch');
