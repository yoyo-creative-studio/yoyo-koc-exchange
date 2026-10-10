BEGIN;

CREATE OR REPLACE FUNCTION public.is_project_campaign_window_open(
  p_project_key TEXT, p_period TEXT, p_window TEXT
)
RETURNS BOOLEAN
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.campaign_config campaigns
    JOIN public.platform_projects projects ON projects.id = campaigns.project_id
    WHERE projects.project_key = p_project_key
      AND projects.status = 'active'
      AND campaigns.period = p_period
      AND campaigns.is_current_period = true
      AND campaigns.is_active = true
      AND CASE p_window
        WHEN 'submissions' THEN campaigns.submissions_open = true
          AND (campaigns.submissions_close_at IS NULL OR NOW() < campaigns.submissions_close_at)
        WHEN 'redemption' THEN campaigns.redemption_open = true
          AND (campaigns.redemption_close_at IS NULL OR NOW() < campaigns.redemption_close_at)
        ELSE false
      END
  );
$$;

REVOKE ALL ON FUNCTION public.is_project_campaign_window_open(TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.is_project_campaign_window_open(TEXT, TEXT, TEXT) TO service_role;

COMMIT;
