BEGIN;

DROP INDEX IF EXISTS public.idx_point_logs_operation_key_unique;
CREATE UNIQUE INDEX IF NOT EXISTS idx_point_logs_project_operation_key_unique
  ON public.point_logs(project_id, operation_key)
  WHERE operation_key IS NOT NULL AND operation_key <> '';

CREATE OR REPLACE FUNCTION public.add_project_point_log_once(
  p_project_key TEXT,
  p_uid TEXT,
  p_change INTEGER,
  p_source TEXT,
  p_reason TEXT,
  p_period TEXT,
  p_created_by TEXT,
  p_operation_key TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_project_id UUID;
  v_creator_id UUID;
  v_balance INTEGER;
  v_log_id BIGINT;
BEGIN
  p_project_key := btrim(COALESCE(p_project_key, ''));
  p_uid := btrim(COALESCE(p_uid, ''));
  p_operation_key := btrim(COALESCE(p_operation_key, ''));
  IF p_project_key = '' OR p_uid = '' OR p_operation_key = '' THEN
    RAISE EXCEPTION 'project key, uid and operation key are required';
  END IF;

  SELECT projects.id INTO v_project_id
  FROM public.platform_projects projects
  WHERE projects.project_key = p_project_key AND projects.status = 'active';
  IF v_project_id IS NULL THEN RAISE EXCEPTION 'active project not found'; END IF;

  SELECT creators.creator_id INTO v_creator_id
  FROM public.kocs creators
  WHERE creators.project_id = v_project_id AND creators.uid = p_uid
  FOR UPDATE;
  IF v_creator_id IS NULL THEN RAISE EXCEPTION 'creator not found in project'; END IF;

  PERFORM pg_advisory_xact_lock(hashtext('points|' || v_project_id::TEXT || '|' || v_creator_id::TEXT));

  SELECT logs.id INTO v_log_id
  FROM public.point_logs logs
  WHERE logs.project_id = v_project_id AND logs.operation_key = p_operation_key
  LIMIT 1;

  SELECT COALESCE(SUM(logs.change), 0)::INTEGER INTO v_balance
  FROM public.point_logs logs
  WHERE logs.project_id = v_project_id AND logs.creator_id = v_creator_id;

  IF v_log_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', true, 'inserted', false, 'log_id', v_log_id,
      'balance', v_balance, 'project_id', v_project_id, 'creator_id', v_creator_id
    );
  END IF;

  v_balance := v_balance + p_change;
  INSERT INTO public.point_logs (
    project_id, creator_id, uid, change, balance_after, source, reason, period,
    created_by, operation_key, created_at
  ) VALUES (
    v_project_id, v_creator_id, p_uid, p_change, v_balance, p_source, p_reason, p_period,
    COALESCE(p_created_by, ''), p_operation_key, NOW()
  ) RETURNING id INTO v_log_id;

  RETURN jsonb_build_object(
    'ok', true, 'inserted', true, 'log_id', v_log_id,
    'balance', v_balance, 'project_id', v_project_id, 'creator_id', v_creator_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.add_point_log_once(
  p_uid TEXT,
  p_change INTEGER,
  p_source TEXT,
  p_reason TEXT,
  p_period TEXT,
  p_created_by TEXT,
  p_operation_key TEXT
)
RETURNS JSONB
LANGUAGE SQL
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.add_project_point_log_once(
    'mlt-global', p_uid, p_change, p_source, p_reason,
    p_period, p_created_by, p_operation_key
  );
$$;

ALTER TABLE public.creator_tier_preview_batches
  ADD COLUMN IF NOT EXISTS project_id UUID REFERENCES public.platform_projects(id) ON DELETE RESTRICT;
UPDATE public.creator_tier_preview_batches
SET project_id = public.default_project_id()
WHERE project_id IS NULL;
ALTER TABLE public.creator_tier_preview_batches ALTER COLUMN project_id SET NOT NULL;
CREATE INDEX IF NOT EXISTS idx_creator_tier_preview_batches_project
  ON public.creator_tier_preview_batches(project_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.preview_project_legacy_tier_upgrades(p_project_key TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_project_id UUID;
  v_id UUID := gen_random_uuid();
  v_rows JSONB;
BEGIN
  SELECT projects.id INTO v_project_id
  FROM public.platform_projects projects
  WHERE projects.project_key = btrim(p_project_key) AND projects.status = 'active';
  IF v_project_id IS NULL THEN RAISE EXCEPTION 'active project not found'; END IF;

  WITH scores AS (
    SELECT creators.creator_id, creators.uid, creators.discord_name,
      COALESCE(creators.tier, 'certified') current_tier,
      MAX(scores.historical_final_score) FILTER (WHERE scores.period = '2026-06' AND scores.historical_confirmed) score_2026_06,
      MAX(scores.historical_final_score) FILTER (WHERE scores.period = '2026-07' AND scores.historical_confirmed) score_2026_07,
      MAX(scores.historical_final_score) FILTER (WHERE scores.period = '2026-08' AND scores.historical_confirmed) score_2026_08
    FROM public.kocs creators
    LEFT JOIN public.creator_monthly_tier_scores scores
      ON scores.project_id = creators.project_id
      AND scores.creator_id = creators.creator_id
      AND scores.period BETWEEN '2026-06' AND '2026-08'
    WHERE creators.project_id = v_project_id
      AND creators.uid <> '__config__'
      AND creators.status = 'active'
    GROUP BY creators.creator_id, creators.uid, creators.discord_name, creators.tier
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
    'creator_id', creator_id, 'uid', uid, 'discord_name', discord_name,
    'current_tier', current_tier, 'proposed_tier', calculated_tier,
    'score_2026_06', score_2026_06, 'score_2026_07', score_2026_07,
    'score_2026_08', score_2026_08
  ) ORDER BY discord_name), '[]'::jsonb) INTO v_rows
  FROM upgrades WHERE calculated_rank > current_rank;

  INSERT INTO public.creator_tier_preview_batches(id, project_id, through_period, rule_key, preview_rows)
  VALUES (v_id, v_project_id, '2026-08', 'legacy-through-2026-08', v_rows);
  RETURN jsonb_build_object(
    'batch_id', v_id, 'project_id', v_project_id, 'project_key', p_project_key,
    'through_period', '2026-08', 'count', jsonb_array_length(v_rows), 'upgrades', v_rows
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.apply_project_legacy_tier_upgrade_preview(
  p_project_key TEXT,
  p_batch_id UUID,
  p_confirmation TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_project_id UUID;
  v_batch public.creator_tier_preview_batches%ROWTYPE;
  v_row JSONB;
  v_creator_id UUID;
  v_uid TEXT;
  v_current TEXT;
  v_applied INTEGER := 0;
BEGIN
  IF p_confirmation <> 'CONFIRM 2026-08 TIER UPGRADES' THEN
    RAISE EXCEPTION 'confirmation phrase does not match';
  END IF;
  SELECT projects.id INTO v_project_id
  FROM public.platform_projects projects
  WHERE projects.project_key = btrim(p_project_key) AND projects.status = 'active';
  IF v_project_id IS NULL THEN RAISE EXCEPTION 'active project not found'; END IF;

  PERFORM pg_advisory_xact_lock(hashtext('legacy-tier-upgrade|' || v_project_id::TEXT || '|2026-08'));
  SELECT * INTO v_batch
  FROM public.creator_tier_preview_batches batches
  WHERE batches.id = p_batch_id AND batches.project_id = v_project_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'preview batch not found in project'; END IF;
  IF v_batch.status = 'applied' THEN
    RETURN jsonb_build_object('ok', true, 'idempotent', true, 'applied', 0, 'project_id', v_project_id);
  END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(v_batch.preview_rows)
  LOOP
    v_creator_id := (v_row->>'creator_id')::UUID;
    SELECT creators.uid, COALESCE(creators.tier, 'certified') INTO v_uid, v_current
    FROM public.kocs creators
    WHERE creators.project_id = v_project_id AND creators.creator_id = v_creator_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'preview creator no longer exists in project'; END IF;

    IF (CASE v_row->>'proposed_tier' WHEN 'platinum' THEN 2 WHEN 'gold' THEN 1 ELSE 0 END) >
       (CASE v_current WHEN 'platinum' THEN 2 WHEN 'gold' THEN 1 ELSE 0 END) THEN
      INSERT INTO public.creator_tier_history(
        project_id, creator_id, uid, effective_period, from_tier, to_tier, rule_key, preview_batch_id
      ) VALUES (
        v_project_id, v_creator_id, v_uid, '2026-08', v_current,
        v_row->>'proposed_tier', v_batch.rule_key, v_batch.id
      ) ON CONFLICT DO NOTHING;
      IF FOUND THEN
        UPDATE public.kocs SET
          tier = v_row->>'proposed_tier', tier_updated_at = NOW(),
          tier_history = COALESCE((SELECT jsonb_agg(entry) FROM (
            SELECT DISTINCT ON (item->>'month', item->>'tier', COALESCE(item->>'rule_version','')) item entry
            FROM jsonb_array_elements(
              CASE WHEN COALESCE(tier_history,'') ~ '^\s*\[' THEN tier_history::jsonb ELSE '[]'::jsonb END ||
              jsonb_build_array(jsonb_build_object(
                'month', '2026-08', 'tier', v_row->>'proposed_tier', 'rule_version', v_batch.rule_key
              ))
            ) item
            ORDER BY item->>'month', item->>'tier', COALESCE(item->>'rule_version','')
          ) deduplicated), '[]'::jsonb)::TEXT
        WHERE project_id = v_project_id AND creator_id = v_creator_id;
        v_applied := v_applied + 1;
      END IF;
    END IF;
  END LOOP;

  UPDATE public.creator_tier_preview_batches
  SET status = 'applied', applied_at = NOW(), applied_by = 'admin_confirm'
  WHERE id = v_batch.id AND project_id = v_project_id;
  RETURN jsonb_build_object(
    'ok', true, 'idempotent', false, 'applied', v_applied, 'project_id', v_project_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.preview_legacy_tier_upgrades()
RETURNS JSONB
LANGUAGE SQL
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.preview_project_legacy_tier_upgrades('mlt-global');
$$;

CREATE OR REPLACE FUNCTION public.apply_legacy_tier_upgrade_preview(p_batch_id UUID, p_confirmation TEXT)
RETURNS JSONB
LANGUAGE SQL
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.apply_project_legacy_tier_upgrade_preview('mlt-global', p_batch_id, p_confirmation);
$$;

REVOKE ALL ON FUNCTION public.add_project_point_log_once(TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.preview_project_legacy_tier_upgrades(TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.apply_project_legacy_tier_upgrade_preview(TEXT, UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.add_project_point_log_once(TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.preview_project_legacy_tier_upgrades(TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.apply_project_legacy_tier_upgrade_preview(TEXT, UUID, TEXT) TO service_role;

COMMIT;
