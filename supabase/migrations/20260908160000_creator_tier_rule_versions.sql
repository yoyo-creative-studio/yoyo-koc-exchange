BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS public.creator_tier_rule_versions (
  rule_key TEXT PRIMARY KEY,
  effective_from TEXT,
  effective_before TEXT,
  score_source TEXT NOT NULL,
  gold_months INTEGER NOT NULL,
  gold_threshold NUMERIC NOT NULL,
  gold_inclusive BOOLEAN NOT NULL,
  platinum_months INTEGER NOT NULL,
  platinum_threshold NUMERIC NOT NULL,
  platinum_inclusive BOOLEAN NOT NULL,
  CHECK (effective_from IS NULL OR effective_from ~ '^\d{4}-\d{2}$'),
  CHECK (effective_before IS NULL OR effective_before ~ '^\d{4}-\d{2}$')
);

INSERT INTO public.creator_tier_rule_versions VALUES
  ('legacy-through-2026-08', NULL, '2026-09', 'historical_final_score', 2, 5, false, 3, 5, false),
  ('content-from-2026-09', '2026-09', NULL, 'content_capped_points', 2, 20, true, 3, 40, true)
ON CONFLICT (rule_key) DO UPDATE SET
  effective_from = EXCLUDED.effective_from,
  effective_before = EXCLUDED.effective_before,
  score_source = EXCLUDED.score_source,
  gold_months = EXCLUDED.gold_months,
  gold_threshold = EXCLUDED.gold_threshold,
  gold_inclusive = EXCLUDED.gold_inclusive,
  platinum_months = EXCLUDED.platinum_months,
  platinum_threshold = EXCLUDED.platinum_threshold,
  platinum_inclusive = EXCLUDED.platinum_inclusive;

CREATE TABLE IF NOT EXISTS public.creator_monthly_tier_scores (
  uid TEXT NOT NULL REFERENCES public.kocs(uid) ON DELETE CASCADE,
  period TEXT NOT NULL CHECK (period ~ '^\d{4}-\d{2}$'),
  historical_final_score NUMERIC,
  content_raw_points NUMERIC,
  content_capped_points NUMERIC,
  historical_confirmed BOOLEAN NOT NULL DEFAULT false,
  source_note TEXT NOT NULL DEFAULT '',
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (uid, period),
  CHECK (historical_final_score IS NULL OR historical_final_score >= 0),
  CHECK (content_raw_points IS NULL OR content_raw_points >= 0),
  CHECK (content_capped_points IS NULL OR content_capped_points >= 0),
  CHECK (period < '2026-09' OR historical_final_score IS NULL),
  CHECK (period >= '2026-09' OR (content_raw_points IS NULL AND content_capped_points IS NULL))
);

-- Existing tier_history values are treated as already-confirmed historical settlement,
-- never recomputed from submissions or point_logs.
INSERT INTO public.creator_monthly_tier_scores (
  uid, period, historical_final_score, historical_confirmed, source_note
)
SELECT
  k.uid,
  item->>'month',
  GREATEST(0, COALESCE((item->>'monthly_points')::NUMERIC, 0)),
  true,
  'Migrated from confirmed kocs.tier_history'
FROM public.kocs k
CROSS JOIN LATERAL jsonb_array_elements(
  CASE WHEN COALESCE(k.tier_history, '') ~ '^\s*\[' THEN k.tier_history::jsonb ELSE '[]'::jsonb END
) item
WHERE item->>'month' ~ '^\d{4}-\d{2}$'
  AND item->>'month' <= '2026-08'
  AND COALESCE(item->>'monthly_points', '') ~ '^\d+(\.\d+)?$'
ON CONFLICT (uid, period) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.creator_tier_preview_batches (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  through_period TEXT NOT NULL CHECK (through_period = '2026-08'),
  rule_key TEXT NOT NULL REFERENCES public.creator_tier_rule_versions(rule_key),
  preview_rows JSONB NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'applied')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  applied_at TIMESTAMPTZ,
  applied_by TEXT
);

CREATE TABLE IF NOT EXISTS public.creator_tier_history (
  id BIGSERIAL PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES public.kocs(uid) ON DELETE CASCADE,
  effective_period TEXT NOT NULL,
  from_tier TEXT NOT NULL CHECK (from_tier IN ('certified','gold','platinum')),
  to_tier TEXT NOT NULL CHECK (to_tier IN ('gold','platinum')),
  rule_key TEXT NOT NULL REFERENCES public.creator_tier_rule_versions(rule_key),
  preview_batch_id UUID REFERENCES public.creator_tier_preview_batches(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by TEXT NOT NULL DEFAULT 'admin',
  UNIQUE (uid, effective_period, rule_key, to_tier)
);

CREATE OR REPLACE FUNCTION public.refresh_creator_content_tier_score()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid TEXT := COALESCE(NEW.uid, OLD.uid);
  v_period TEXT := COALESCE(NEW.period, OLD.period);
  v_raw NUMERIC;
  v_capped NUMERIC;
BEGIN
  IF v_period IS NULL OR v_period < '2026-09' THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
  END IF;
  SELECT COALESCE(SUM(points_earned), 0) INTO v_raw
  FROM public.submissions
  WHERE uid = v_uid AND period = v_period AND status = 'scored'
    AND COALESCE(submission_type, 'work') <> 'showcase';
  v_capped := CASE WHEN v_raw >= 40 THEN 40 WHEN v_raw >= 20 THEN 20 ELSE v_raw END;
  INSERT INTO public.creator_monthly_tier_scores (
    uid, period, content_raw_points, content_capped_points, source_note, updated_at
  ) VALUES (v_uid, v_period, v_raw, v_capped, 'Scored work submissions only', NOW())
  ON CONFLICT (uid, period) DO UPDATE SET
    content_raw_points = EXCLUDED.content_raw_points,
    content_capped_points = EXCLUDED.content_capped_points,
    source_note = EXCLUDED.source_note,
    updated_at = NOW();
  IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$$;

DROP TRIGGER IF EXISTS submissions_refresh_creator_tier_score ON public.submissions;
CREATE TRIGGER submissions_refresh_creator_tier_score
AFTER INSERT OR UPDATE OF uid, period, status, points_earned, submission_type OR DELETE
ON public.submissions FOR EACH ROW EXECUTE FUNCTION public.refresh_creator_content_tier_score();

CREATE OR REPLACE FUNCTION public.preview_legacy_tier_upgrades()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id UUID := gen_random_uuid();
  v_rows JSONB;
BEGIN
  WITH scores AS (
    SELECT k.uid, k.discord_name, COALESCE(k.tier, 'certified') current_tier,
      MAX(s.historical_final_score) FILTER (WHERE s.period = '2026-06' AND s.historical_confirmed) score_2026_06,
      MAX(s.historical_final_score) FILTER (WHERE s.period = '2026-07' AND s.historical_confirmed) score_2026_07,
      MAX(s.historical_final_score) FILTER (WHERE s.period = '2026-08' AND s.historical_confirmed) score_2026_08
    FROM public.kocs k
    LEFT JOIN public.creator_monthly_tier_scores s ON s.uid = k.uid AND s.period BETWEEN '2026-06' AND '2026-08'
    WHERE k.uid <> '__config__' AND k.status = 'active'
    GROUP BY k.uid, k.discord_name, k.tier
  ), decisions AS (
    SELECT *, CASE
      WHEN score_2026_06 > 5 AND score_2026_07 > 5 AND score_2026_08 > 5 THEN 'platinum'
      WHEN score_2026_07 > 5 AND score_2026_08 > 5 THEN 'gold'
      ELSE current_tier END calculated_tier
    FROM scores
  ), upgrades AS (
    SELECT *, CASE current_tier WHEN 'platinum' THEN 2 WHEN 'gold' THEN 1 ELSE 0 END current_rank,
      CASE calculated_tier WHEN 'platinum' THEN 2 WHEN 'gold' THEN 1 ELSE 0 END calculated_rank
    FROM decisions
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'uid', uid, 'discord_name', discord_name, 'current_tier', current_tier,
    'proposed_tier', calculated_tier, 'score_2026_06', score_2026_06,
    'score_2026_07', score_2026_07, 'score_2026_08', score_2026_08
  ) ORDER BY discord_name), '[]'::jsonb) INTO v_rows
  FROM upgrades WHERE calculated_rank > current_rank;

  INSERT INTO public.creator_tier_preview_batches(id, through_period, rule_key, preview_rows)
  VALUES (v_id, '2026-08', 'legacy-through-2026-08', v_rows);
  RETURN jsonb_build_object('batch_id', v_id, 'through_period', '2026-08', 'count', jsonb_array_length(v_rows), 'upgrades', v_rows);
END;
$$;

CREATE OR REPLACE FUNCTION public.apply_legacy_tier_upgrade_preview(p_batch_id UUID, p_confirmation TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_batch public.creator_tier_preview_batches%ROWTYPE;
  v_row JSONB;
  v_current TEXT;
  v_applied INTEGER := 0;
BEGIN
  IF p_confirmation <> 'CONFIRM 2026-08 TIER UPGRADES' THEN RAISE EXCEPTION 'confirmation phrase does not match'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('legacy-tier-upgrade-2026-08'));
  SELECT * INTO v_batch FROM public.creator_tier_preview_batches WHERE id = p_batch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'preview batch not found'; END IF;
  IF v_batch.status = 'applied' THEN RETURN jsonb_build_object('ok', true, 'idempotent', true, 'applied', 0); END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(v_batch.preview_rows)
  LOOP
    SELECT COALESCE(tier, 'certified') INTO v_current FROM public.kocs WHERE uid = v_row->>'uid' FOR UPDATE;
    IF (CASE v_row->>'proposed_tier' WHEN 'platinum' THEN 2 WHEN 'gold' THEN 1 ELSE 0 END) >
       (CASE v_current WHEN 'platinum' THEN 2 WHEN 'gold' THEN 1 ELSE 0 END) THEN
      INSERT INTO public.creator_tier_history(uid, effective_period, from_tier, to_tier, rule_key, preview_batch_id)
      VALUES (v_row->>'uid', '2026-08', v_current, v_row->>'proposed_tier', v_batch.rule_key, v_batch.id)
      ON CONFLICT DO NOTHING;
      IF FOUND THEN
        UPDATE public.kocs SET
          tier = v_row->>'proposed_tier', tier_updated_at = NOW(),
          tier_history = COALESCE((SELECT jsonb_agg(x) FROM (
            SELECT DISTINCT ON (e->>'month', e->>'tier', COALESCE(e->>'rule_version','')) e x
            FROM jsonb_array_elements(CASE WHEN COALESCE(tier_history,'') ~ '^\s*\[' THEN tier_history::jsonb ELSE '[]'::jsonb END ||
              jsonb_build_array(jsonb_build_object('month','2026-08','tier',v_row->>'proposed_tier','rule_version',v_batch.rule_key))) e
            ORDER BY e->>'month', e->>'tier', COALESCE(e->>'rule_version','')
          ) dedup), '[]'::jsonb)::TEXT
        WHERE uid = v_row->>'uid';
        v_applied := v_applied + 1;
      END IF;
    END IF;
  END LOOP;
  UPDATE public.creator_tier_preview_batches SET status='applied', applied_at=NOW(), applied_by='admin_confirm' WHERE id=v_batch.id;
  RETURN jsonb_build_object('ok', true, 'idempotent', false, 'applied', v_applied);
END;
$$;

ALTER TABLE public.creator_tier_rule_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.creator_monthly_tier_scores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.creator_tier_preview_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.creator_tier_history ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.creator_monthly_tier_scores, public.creator_tier_preview_batches, public.creator_tier_history FROM anon, authenticated;
GRANT SELECT ON public.creator_tier_rule_versions TO anon, authenticated;
REVOKE ALL ON FUNCTION public.preview_legacy_tier_upgrades() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.apply_legacy_tier_upgrade_preview(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.preview_legacy_tier_upgrades() TO service_role;
GRANT EXECUTE ON FUNCTION public.apply_legacy_tier_upgrade_preview(UUID, TEXT) TO service_role;

COMMIT;
