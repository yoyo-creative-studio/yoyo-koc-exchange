BEGIN;

CREATE TABLE IF NOT EXISTS public.platform_project_secrets (
  project_id UUID PRIMARY KEY REFERENCES public.platform_projects(id) ON DELETE CASCADE,
  discord_bot_token TEXT,
  updated_by UUID REFERENCES public.platform_admins(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO public.platform_project_secrets (project_id, discord_bot_token)
SELECT projects.id, state.bot_token
FROM public.platform_projects projects
CROSS JOIN public.mochi_auto_welcome_state state
WHERE projects.project_key = 'mlt-global'
  AND state.id = 1
  AND NULLIF(trim(state.bot_token), '') IS NOT NULL
ON CONFLICT (project_id) DO UPDATE
SET discord_bot_token = COALESCE(NULLIF(public.platform_project_secrets.discord_bot_token, ''), EXCLUDED.discord_bot_token),
    updated_at = NOW();

UPDATE public.mochi_auto_welcome_state
SET bot_token = '', updated_at = NOW()
WHERE id = 1 AND NULLIF(trim(bot_token), '') IS NOT NULL;

ALTER TABLE public.platform_project_secrets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.platform_project_secrets FROM PUBLIC, anon, authenticated;

COMMIT;
