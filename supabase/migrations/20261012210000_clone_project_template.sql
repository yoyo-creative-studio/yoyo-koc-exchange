BEGIN;

CREATE OR REPLACE FUNCTION public.clone_project_template(
  p_source_project_id UUID,
  p_name TEXT DEFAULT NULL,
  p_project_key TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_source public.platform_projects%ROWTYPE;
  v_project_id UUID;
  v_name TEXT;
  v_base_key TEXT;
  v_project_key TEXT;
  v_suffix INTEGER := 1;
  v_reward_count INTEGER := 0;
  v_campaign_count INTEGER := 0;
BEGIN
  SELECT * INTO v_source FROM public.platform_projects WHERE id = p_source_project_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'source project not found'; END IF;

  v_name := COALESCE(NULLIF(btrim(p_name), ''), v_source.name || ' Copy');
  IF length(v_name) > 120 THEN RAISE EXCEPTION 'project name must be 120 characters or fewer'; END IF;

  v_base_key := lower(COALESCE(NULLIF(btrim(p_project_key), ''), v_source.project_key || '-copy'));
  v_base_key := regexp_replace(v_base_key, '[^a-z0-9-]+', '-', 'g');
  v_base_key := regexp_replace(v_base_key, '(^-+|-+$)', '', 'g');
  IF v_base_key = '' THEN v_base_key := 'creator-project'; END IF;
  IF v_base_key !~ '^[a-z0-9]' THEN v_base_key := 'project-' || v_base_key; END IF;
  v_base_key := regexp_replace(left(v_base_key, 63), '-+$', '');
  IF length(v_base_key) < 2 THEN v_base_key := v_base_key || '-project'; END IF;

  v_project_key := v_base_key;
  WHILE EXISTS (SELECT 1 FROM public.platform_projects WHERE project_key = v_project_key) LOOP
    v_suffix := v_suffix + 1;
    v_project_key := left(v_base_key, 63 - length(v_suffix::TEXT) - 1) || '-' || v_suffix::TEXT;
  END LOOP;

  INSERT INTO public.platform_projects (
    project_key, name, status, default_locale, default_timezone, settings
  ) VALUES (
    v_project_key, v_name, 'active', v_source.default_locale, v_source.default_timezone,
    COALESCE(v_source.settings, '{}'::JSONB) || jsonb_build_object(
      'legacy_system', false,
      'cloned_from_project_id', v_source.id,
      'cloned_from_project_key', v_source.project_key,
      'cloned_at', NOW()
    )
  ) RETURNING id INTO v_project_id;

  DELETE FROM public.project_reward_options WHERE project_id = v_project_id;
  INSERT INTO public.project_reward_options (
    project_id, reward_key, fulfillment_type, display_name, points_cost,
    description, amount_text, currency, is_active, sort_order, settings
  )
  SELECT
    v_project_id, reward_key, fulfillment_type, display_name, points_cost,
    description, amount_text, currency, is_active, sort_order, settings
  FROM public.project_reward_options
  WHERE project_id = v_source.id;
  GET DIAGNOSTICS v_reward_count = ROW_COUNT;

  INSERT INTO public.campaign_config (
    project_id, period, name, rules_json, points_cap, is_active,
    submissions_open, redemption_open, is_current_period,
    submissions_close_at, redemption_close_at
  )
  SELECT
    v_project_id, period, name, rules_json, points_cap, is_active,
    false, false, is_current_period, NULL, NULL
  FROM public.campaign_config
  WHERE project_id = v_source.id
  ORDER BY period;
  GET DIAGNOSTICS v_campaign_count = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'project_id', v_project_id,
    'project_key', v_project_key,
    'name', v_name,
    'source_project_id', v_source.id,
    'source_project_key', v_source.project_key,
    'reward_count', v_reward_count,
    'campaign_count', v_campaign_count
  );
END;
$$;

REVOKE ALL ON FUNCTION public.clone_project_template(UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.clone_project_template(UUID, TEXT, TEXT) TO service_role;

COMMIT;
