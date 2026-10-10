BEGIN;

ALTER TABLE public.kocs ADD COLUMN IF NOT EXISTS project_id UUID REFERENCES public.platform_projects(id) ON DELETE RESTRICT;
ALTER TABLE public.registration_applications ADD COLUMN IF NOT EXISTS project_id UUID REFERENCES public.platform_projects(id) ON DELETE RESTRICT;
ALTER TABLE public.submissions ADD COLUMN IF NOT EXISTS project_id UUID REFERENCES public.platform_projects(id) ON DELETE RESTRICT;
ALTER TABLE public.point_logs ADD COLUMN IF NOT EXISTS project_id UUID REFERENCES public.platform_projects(id) ON DELETE RESTRICT;
ALTER TABLE public.redemption_orders ADD COLUMN IF NOT EXISTS project_id UUID REFERENCES public.platform_projects(id) ON DELETE RESTRICT;
ALTER TABLE public.reward_fulfillments ADD COLUMN IF NOT EXISTS project_id UUID REFERENCES public.platform_projects(id) ON DELETE RESTRICT;
ALTER TABLE public.redemption_order_edits ADD COLUMN IF NOT EXISTS project_id UUID REFERENCES public.platform_projects(id) ON DELETE RESTRICT;

UPDATE public.kocs
SET project_id = (SELECT id FROM public.platform_projects WHERE project_key = 'mlt-global')
WHERE project_id IS NULL;

UPDATE public.registration_applications
SET project_id = (SELECT id FROM public.platform_projects WHERE project_key = 'mlt-global')
WHERE project_id IS NULL;

UPDATE public.submissions records
SET project_id = creators.project_id
FROM public.kocs creators
WHERE records.uid = creators.uid AND records.project_id IS NULL;

UPDATE public.point_logs records
SET project_id = creators.project_id
FROM public.kocs creators
WHERE records.uid = creators.uid AND records.project_id IS NULL;

UPDATE public.redemption_orders records
SET project_id = creators.project_id
FROM public.kocs creators
WHERE records.uid = creators.uid AND records.project_id IS NULL;

UPDATE public.reward_fulfillments records
SET project_id = orders.project_id
FROM public.redemption_orders orders
WHERE records.order_id = orders.id AND records.project_id IS NULL;

UPDATE public.redemption_order_edits records
SET project_id = creators.project_id
FROM public.kocs creators
WHERE records.uid = creators.uid AND records.project_id IS NULL;

ALTER TABLE public.kocs ALTER COLUMN project_id SET NOT NULL;
ALTER TABLE public.registration_applications ALTER COLUMN project_id SET NOT NULL;
ALTER TABLE public.submissions ALTER COLUMN project_id SET NOT NULL;
ALTER TABLE public.point_logs ALTER COLUMN project_id SET NOT NULL;
ALTER TABLE public.redemption_orders ALTER COLUMN project_id SET NOT NULL;
ALTER TABLE public.reward_fulfillments ALTER COLUMN project_id SET NOT NULL;
ALTER TABLE public.redemption_order_edits ALTER COLUMN project_id SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_kocs_project ON public.kocs(project_id, status);
CREATE INDEX IF NOT EXISTS idx_registration_applications_project ON public.registration_applications(project_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_submissions_project_period ON public.submissions(project_id, period, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_point_logs_project_period ON public.point_logs(project_id, period, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_redemption_orders_project_period ON public.redemption_orders(project_id, period, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_reward_fulfillments_project_period ON public.reward_fulfillments(project_id, period, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_redemption_order_edits_project_period ON public.redemption_order_edits(project_id, period, created_at DESC);

CREATE OR REPLACE FUNCTION public.default_project_id()
RETURNS UUID
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT id FROM public.platform_projects WHERE project_key = 'mlt-global' AND status = 'active';
$$;

CREATE OR REPLACE FUNCTION public.assign_core_record_project()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_parent_project_id UUID;
BEGIN
  IF TG_TABLE_NAME IN ('submissions', 'point_logs', 'redemption_orders', 'redemption_order_edits') THEN
    SELECT project_id INTO v_parent_project_id FROM public.kocs WHERE uid = NEW.uid;
  ELSIF TG_TABLE_NAME = 'reward_fulfillments' THEN
    SELECT project_id INTO v_parent_project_id FROM public.redemption_orders WHERE id = NEW.order_id;
  END IF;

  IF NEW.project_id IS NULL THEN
    NEW.project_id := COALESCE(v_parent_project_id, public.default_project_id());
  ELSIF v_parent_project_id IS NOT NULL AND NEW.project_id <> v_parent_project_id THEN
    RAISE EXCEPTION 'project ownership does not match the parent record';
  END IF;

  IF NEW.project_id IS NULL THEN
    RAISE EXCEPTION 'active project ownership is required';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_kocs_assign_project ON public.kocs;
CREATE TRIGGER trg_kocs_assign_project BEFORE INSERT OR UPDATE OF project_id ON public.kocs
FOR EACH ROW EXECUTE FUNCTION public.assign_core_record_project();
DROP TRIGGER IF EXISTS trg_registration_applications_assign_project ON public.registration_applications;
CREATE TRIGGER trg_registration_applications_assign_project BEFORE INSERT OR UPDATE OF project_id ON public.registration_applications
FOR EACH ROW EXECUTE FUNCTION public.assign_core_record_project();
DROP TRIGGER IF EXISTS trg_submissions_assign_project ON public.submissions;
CREATE TRIGGER trg_submissions_assign_project BEFORE INSERT OR UPDATE OF project_id, uid ON public.submissions
FOR EACH ROW EXECUTE FUNCTION public.assign_core_record_project();
DROP TRIGGER IF EXISTS trg_point_logs_assign_project ON public.point_logs;
CREATE TRIGGER trg_point_logs_assign_project BEFORE INSERT OR UPDATE OF project_id, uid ON public.point_logs
FOR EACH ROW EXECUTE FUNCTION public.assign_core_record_project();
DROP TRIGGER IF EXISTS trg_redemption_orders_assign_project ON public.redemption_orders;
CREATE TRIGGER trg_redemption_orders_assign_project BEFORE INSERT OR UPDATE OF project_id, uid ON public.redemption_orders
FOR EACH ROW EXECUTE FUNCTION public.assign_core_record_project();
DROP TRIGGER IF EXISTS trg_reward_fulfillments_assign_project ON public.reward_fulfillments;
CREATE TRIGGER trg_reward_fulfillments_assign_project BEFORE INSERT OR UPDATE OF project_id, order_id ON public.reward_fulfillments
FOR EACH ROW EXECUTE FUNCTION public.assign_core_record_project();
DROP TRIGGER IF EXISTS trg_redemption_order_edits_assign_project ON public.redemption_order_edits;
CREATE TRIGGER trg_redemption_order_edits_assign_project BEFORE INSERT OR UPDATE OF project_id, uid ON public.redemption_order_edits
FOR EACH ROW EXECUTE FUNCTION public.assign_core_record_project();

CREATE OR REPLACE FUNCTION public.get_default_project_context()
RETURNS TABLE (project_id UUID, project_key TEXT, name TEXT, default_locale TEXT, default_timezone TEXT)
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT id, project_key, name, default_locale, default_timezone
  FROM public.platform_projects
  WHERE project_key = 'mlt-global' AND status = 'active';
$$;

REVOKE ALL ON FUNCTION public.get_default_project_context() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_default_project_context() TO anon, authenticated;

DROP FUNCTION IF EXISTS public.get_project_campaign_periods(TEXT);
CREATE FUNCTION public.get_project_campaign_periods(p_project_key TEXT DEFAULT 'mlt-global')
RETURNS TABLE (project_id UUID, period TEXT, is_current_period BOOLEAN)
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT campaigns.project_id, campaigns.period, campaigns.is_current_period
  FROM public.campaign_config campaigns
  JOIN public.platform_projects projects ON projects.id = campaigns.project_id
  WHERE projects.project_key = p_project_key AND projects.status = 'active'
  ORDER BY campaigns.period;
$$;

DROP FUNCTION IF EXISTS public.get_current_project_campaign(TEXT);
CREATE FUNCTION public.get_current_project_campaign(p_project_key TEXT DEFAULT 'mlt-global')
RETURNS TABLE (
  project_id UUID, period TEXT, name TEXT, rules_json TEXT, points_cap INTEGER,
  submissions_open BOOLEAN, redemption_open BOOLEAN,
  submissions_close_at TIMESTAMPTZ, redemption_close_at TIMESTAMPTZ,
  is_active BOOLEAN, is_current_period BOOLEAN
)
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT campaigns.project_id, campaigns.period, campaigns.name, campaigns.rules_json,
         campaigns.points_cap, campaigns.submissions_open, campaigns.redemption_open,
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

COMMIT;
