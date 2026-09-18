BEGIN;

ALTER TABLE public.kocs
  ADD COLUMN IF NOT EXISTS discord_user_id TEXT,
  ADD COLUMN IF NOT EXISTS discord_username TEXT,
  ADD COLUMN IF NOT EXISTS discord_display_name TEXT,
  ADD COLUMN IF NOT EXISTS discord_aliases JSONB NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS discord_identity_synced_at TIMESTAMPTZ;

CREATE UNIQUE INDEX IF NOT EXISTS idx_kocs_discord_user_id_unique
  ON public.kocs(discord_user_id)
  WHERE discord_user_id IS NOT NULL AND btrim(discord_user_id) <> '';

COMMIT;
