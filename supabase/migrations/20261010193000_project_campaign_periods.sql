BEGIN;

ALTER TABLE public.campaign_config
  ADD COLUMN IF NOT EXISTS project_id UUID REFERENCES public.platform_projects(id) ON DELETE CASCADE;

UPDATE public.campaign_config
SET project_id = (SELECT id FROM public.platform_projects WHERE project_key = 'mlt-global')
WHERE project_id IS NULL;

ALTER TABLE public.campaign_config ALTER COLUMN project_id SET NOT NULL;
DROP INDEX IF EXISTS public.idx_campaign_config_single_current;
ALTER TABLE public.campaign_config DROP CONSTRAINT IF EXISTS campaign_config_period_key;

CREATE UNIQUE INDEX IF NOT EXISTS idx_campaign_config_project_period
  ON public.campaign_config(project_id, period);
CREATE UNIQUE INDEX IF NOT EXISTS idx_campaign_config_project_current
  ON public.campaign_config(project_id) WHERE is_current_period = true;

CREATE OR REPLACE FUNCTION public.get_project_campaign_periods(p_project_key TEXT DEFAULT 'mlt-global')
RETURNS TABLE (period TEXT, is_current_period BOOLEAN)
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT campaigns.period, campaigns.is_current_period
  FROM public.campaign_config campaigns
  JOIN public.platform_projects projects ON projects.id = campaigns.project_id
  WHERE projects.project_key = p_project_key AND projects.status = 'active'
  ORDER BY campaigns.period;
$$;

CREATE OR REPLACE FUNCTION public.get_current_project_campaign(p_project_key TEXT DEFAULT 'mlt-global')
RETURNS TABLE (
  period TEXT, name TEXT, rules_json TEXT, points_cap INTEGER,
  submissions_open BOOLEAN, redemption_open BOOLEAN,
  submissions_close_at TIMESTAMPTZ, redemption_close_at TIMESTAMPTZ,
  is_active BOOLEAN, is_current_period BOOLEAN
)
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT campaigns.period, campaigns.name, campaigns.rules_json, campaigns.points_cap,
         campaigns.submissions_open, campaigns.redemption_open,
         campaigns.submissions_close_at, campaigns.redemption_close_at,
         campaigns.is_active, campaigns.is_current_period
  FROM public.campaign_config campaigns
  JOIN public.platform_projects projects ON projects.id = campaigns.project_id
  WHERE projects.project_key = p_project_key
    AND projects.status = 'active'
    AND campaigns.is_current_period = true;
$$;

REVOKE ALL ON FUNCTION public.get_project_campaign_periods(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_current_project_campaign(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_project_campaign_periods(TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_current_project_campaign(TEXT) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.publish_project_campaign_period(
  p_project_key TEXT, p_period TEXT, p_rules_json TEXT, p_points_cap INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_project_id UUID;
BEGIN
  IF p_period IS NULL OR p_period !~ '^\d{4}-\d{2}$' THEN
    RAISE EXCEPTION 'invalid campaign period';
  END IF;
  SELECT id INTO v_project_id FROM public.platform_projects
  WHERE project_key = p_project_key AND status = 'active';
  IF v_project_id IS NULL THEN RAISE EXCEPTION 'active project not found'; END IF;

  PERFORM pg_advisory_xact_lock(hashtext('campaign|' || v_project_id::TEXT));
  UPDATE public.campaign_config SET is_current_period = false, updated_at = NOW()
  WHERE project_id = v_project_id AND is_current_period = true AND period <> p_period;

  INSERT INTO public.campaign_config (
    project_id, period, name, rules_json, points_cap, is_active, is_current_period, updated_at
  ) VALUES (
    v_project_id, p_period, p_period || ' Settlement',
    COALESCE(NULLIF(p_rules_json, ''), '{}'), p_points_cap, true, true, NOW()
  )
  ON CONFLICT (project_id, period) DO UPDATE SET
    rules_json = EXCLUDED.rules_json, points_cap = EXCLUDED.points_cap,
    is_active = true, is_current_period = true, updated_at = NOW();

  RETURN jsonb_build_object('ok', true, 'project_key', p_project_key, 'period', p_period);
END;
$$;

CREATE OR REPLACE FUNCTION public.publish_campaign_period(
  p_period TEXT, p_rules_json TEXT, p_points_cap INTEGER
)
RETURNS JSONB LANGUAGE SQL SECURITY DEFINER SET search_path = public AS $$
  SELECT public.publish_project_campaign_period('mlt-global', p_period, p_rules_json, p_points_cap);
$$;

REVOKE ALL ON FUNCTION public.publish_project_campaign_period(TEXT, TEXT, TEXT, INTEGER) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.publish_campaign_period(TEXT, TEXT, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.publish_project_campaign_period(TEXT, TEXT, TEXT, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.publish_campaign_period(TEXT, TEXT, INTEGER) TO service_role;

COMMIT;
