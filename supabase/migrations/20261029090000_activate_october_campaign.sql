BEGIN;

DO $$
DECLARE
  v_project_id UUID;
  v_rules_json TEXT;
  v_points_cap INTEGER;
BEGIN
  SELECT id INTO v_project_id
  FROM public.platform_projects
  WHERE project_key = 'mlt-global';

  IF v_project_id IS NULL THEN
    RAISE EXCEPTION 'mlt-global project not found';
  END IF;

  SELECT rules_json, points_cap
  INTO v_rules_json, v_points_cap
  FROM public.campaign_config
  WHERE project_id = v_project_id
    AND period = '2026-09';

  IF v_rules_json IS NULL THEN
    RAISE EXCEPTION '2026-09 campaign rules not found';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('campaign|' || v_project_id::TEXT));

  UPDATE public.campaign_config
  SET is_current_period = false,
      redemption_open = false,
      updated_at = NOW()
  WHERE project_id = v_project_id
    AND period = '2026-09';

  UPDATE public.campaign_config
  SET name = '2026-10 Settlement',
      rules_json = v_rules_json,
      points_cap = v_points_cap,
      is_active = true,
      is_current_period = true,
      submissions_open = false,
      redemption_open = false,
      submissions_close_at = NULL,
      redemption_close_at = NULL,
      updated_at = NOW()
  WHERE project_id = v_project_id
    AND period = '2026-10';

  IF NOT FOUND THEN
    RAISE EXCEPTION '2026-10 campaign configuration not found';
  END IF;
END;
$$;

COMMIT;
