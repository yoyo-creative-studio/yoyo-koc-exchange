do $$
begin
  if exists (select 1 from cron.job where jobname = 'mochi-auto-welcome-every-5-minutes') then
    perform cron.unschedule('mochi-auto-welcome-every-5-minutes');
  end if;
  if exists (select 1 from cron.job where jobname = 'mochi-auto-welcome-every-6-hours') then
    perform cron.unschedule('mochi-auto-welcome-every-6-hours');
  end if;
  perform cron.schedule(
    'mochi-auto-welcome-every-6-hours',
    '0 */6 * * *',
    $job$
      select net.http_post(
        url := 'https://rryzofimrehmkijkckrm.supabase.co/functions/v1/mochi-auto-welcome',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-cron-secret', (select cron_secret from public.mochi_auto_welcome_state where id = 1)
        ),
        body := '{"action":"scan"}'::jsonb
      );
    $job$
  );
end $$;
