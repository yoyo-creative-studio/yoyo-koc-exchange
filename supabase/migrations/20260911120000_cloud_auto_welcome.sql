create table if not exists public.mochi_auto_welcome_state (
  id integer primary key check (id = 1),
  enabled boolean not null default false,
  bot_token text,
  cron_secret text not null default gen_random_uuid()::text,
  known_member_ids jsonb not null default '[]'::jsonb,
  last_checked_at timestamptz,
  last_result jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.mochi_auto_welcome_state enable row level security;
revoke all on public.mochi_auto_welcome_state from anon, authenticated;
insert into public.mochi_auto_welcome_state (id) values (1) on conflict (id) do nothing;

create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'mochi-auto-welcome-every-5-minutes') then
    perform cron.unschedule('mochi-auto-welcome-every-5-minutes');
  end if;
  perform cron.schedule(
    'mochi-auto-welcome-every-5-minutes',
    '*/5 * * * *',
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
