BEGIN;

ALTER TABLE public.kocs ADD COLUMN IF NOT EXISTS creator_id UUID DEFAULT gen_random_uuid();
UPDATE public.kocs SET creator_id = gen_random_uuid() WHERE creator_id IS NULL;
ALTER TABLE public.kocs ALTER COLUMN creator_id SET DEFAULT gen_random_uuid();
ALTER TABLE public.kocs ALTER COLUMN creator_id SET NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_kocs_creator_id_unique ON public.kocs(creator_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_kocs_project_uid_unique ON public.kocs(project_id, uid);

ALTER TABLE public.registration_applications ADD COLUMN IF NOT EXISTS creator_id UUID;
ALTER TABLE public.submissions ADD COLUMN IF NOT EXISTS creator_id UUID;
ALTER TABLE public.point_logs ADD COLUMN IF NOT EXISTS creator_id UUID;
ALTER TABLE public.redemption_orders ADD COLUMN IF NOT EXISTS creator_id UUID;
ALTER TABLE public.reward_fulfillments ADD COLUMN IF NOT EXISTS creator_id UUID;
ALTER TABLE public.redemption_order_edits ADD COLUMN IF NOT EXISTS creator_id UUID;

ALTER TABLE public.creator_monthly_tier_scores ADD COLUMN IF NOT EXISTS project_id UUID REFERENCES public.platform_projects(id) ON DELETE RESTRICT;
ALTER TABLE public.creator_monthly_tier_scores ADD COLUMN IF NOT EXISTS creator_id UUID;
ALTER TABLE public.creator_tier_history ADD COLUMN IF NOT EXISTS project_id UUID REFERENCES public.platform_projects(id) ON DELETE RESTRICT;
ALTER TABLE public.creator_tier_history ADD COLUMN IF NOT EXISTS creator_id UUID;

UPDATE public.registration_applications applications
SET creator_id = creators.creator_id
FROM public.kocs creators
WHERE applications.project_id = creators.project_id
  AND applications.uid = creators.uid
  AND applications.creator_id IS NULL;

UPDATE public.submissions records SET creator_id = creators.creator_id
FROM public.kocs creators
WHERE records.project_id = creators.project_id AND records.uid = creators.uid AND records.creator_id IS NULL;
UPDATE public.point_logs records SET creator_id = creators.creator_id
FROM public.kocs creators
WHERE records.project_id = creators.project_id AND records.uid = creators.uid AND records.creator_id IS NULL;
UPDATE public.redemption_orders records SET creator_id = creators.creator_id
FROM public.kocs creators
WHERE records.project_id = creators.project_id AND records.uid = creators.uid AND records.creator_id IS NULL;
UPDATE public.reward_fulfillments records SET creator_id = orders.creator_id
FROM public.redemption_orders orders
WHERE records.project_id = orders.project_id AND records.order_id = orders.id AND records.creator_id IS NULL;
UPDATE public.redemption_order_edits records SET creator_id = creators.creator_id
FROM public.kocs creators
WHERE records.project_id = creators.project_id AND records.uid = creators.uid AND records.creator_id IS NULL;

UPDATE public.creator_monthly_tier_scores records
SET project_id = creators.project_id, creator_id = creators.creator_id
FROM public.kocs creators
WHERE records.uid = creators.uid AND (records.project_id IS NULL OR records.creator_id IS NULL);
UPDATE public.creator_tier_history records
SET project_id = creators.project_id, creator_id = creators.creator_id
FROM public.kocs creators
WHERE records.uid = creators.uid AND (records.project_id IS NULL OR records.creator_id IS NULL);

ALTER TABLE public.submissions ALTER COLUMN creator_id SET NOT NULL;
ALTER TABLE public.point_logs ALTER COLUMN creator_id SET NOT NULL;
ALTER TABLE public.redemption_orders ALTER COLUMN creator_id SET NOT NULL;
ALTER TABLE public.reward_fulfillments ALTER COLUMN creator_id SET NOT NULL;
ALTER TABLE public.redemption_order_edits ALTER COLUMN creator_id SET NOT NULL;
ALTER TABLE public.creator_monthly_tier_scores ALTER COLUMN project_id SET NOT NULL;
ALTER TABLE public.creator_monthly_tier_scores ALTER COLUMN creator_id SET NOT NULL;
ALTER TABLE public.creator_tier_history ALTER COLUMN project_id SET NOT NULL;
ALTER TABLE public.creator_tier_history ALTER COLUMN creator_id SET NOT NULL;

ALTER TABLE public.submissions DROP CONSTRAINT IF EXISTS submissions_creator_id_fkey;
ALTER TABLE public.submissions ADD CONSTRAINT submissions_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.kocs(creator_id) ON DELETE CASCADE;
ALTER TABLE public.point_logs DROP CONSTRAINT IF EXISTS point_logs_creator_id_fkey;
ALTER TABLE public.point_logs ADD CONSTRAINT point_logs_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.kocs(creator_id) ON DELETE CASCADE;
ALTER TABLE public.redemption_orders DROP CONSTRAINT IF EXISTS redemption_orders_creator_id_fkey;
ALTER TABLE public.redemption_orders ADD CONSTRAINT redemption_orders_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.kocs(creator_id) ON DELETE CASCADE;
ALTER TABLE public.reward_fulfillments DROP CONSTRAINT IF EXISTS reward_fulfillments_creator_id_fkey;
ALTER TABLE public.reward_fulfillments ADD CONSTRAINT reward_fulfillments_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.kocs(creator_id) ON DELETE CASCADE;
ALTER TABLE public.redemption_order_edits DROP CONSTRAINT IF EXISTS redemption_order_edits_creator_id_fkey;
ALTER TABLE public.redemption_order_edits ADD CONSTRAINT redemption_order_edits_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.kocs(creator_id) ON DELETE CASCADE;
ALTER TABLE public.creator_monthly_tier_scores DROP CONSTRAINT IF EXISTS creator_monthly_tier_scores_creator_id_fkey;
ALTER TABLE public.creator_monthly_tier_scores ADD CONSTRAINT creator_monthly_tier_scores_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.kocs(creator_id) ON DELETE CASCADE;
ALTER TABLE public.creator_tier_history DROP CONSTRAINT IF EXISTS creator_tier_history_creator_id_fkey;
ALTER TABLE public.creator_tier_history ADD CONSTRAINT creator_tier_history_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.kocs(creator_id) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS idx_registration_applications_creator ON public.registration_applications(project_id, creator_id);
CREATE INDEX IF NOT EXISTS idx_submissions_creator_period ON public.submissions(project_id, creator_id, period);
CREATE INDEX IF NOT EXISTS idx_point_logs_creator_period ON public.point_logs(project_id, creator_id, period);
CREATE INDEX IF NOT EXISTS idx_redemption_orders_creator_period ON public.redemption_orders(project_id, creator_id, period);
CREATE INDEX IF NOT EXISTS idx_reward_fulfillments_creator_period ON public.reward_fulfillments(project_id, creator_id, period);
CREATE INDEX IF NOT EXISTS idx_creator_monthly_tier_scores_creator_period ON public.creator_monthly_tier_scores(project_id, creator_id, period);
CREATE INDEX IF NOT EXISTS idx_creator_tier_history_creator_period ON public.creator_tier_history(project_id, creator_id, effective_period);

CREATE OR REPLACE FUNCTION public.assign_core_record_project()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_parent_project_id UUID;
BEGIN
  IF TG_TABLE_NAME IN (
    'submissions', 'point_logs', 'redemption_orders', 'redemption_order_edits',
    'creator_monthly_tier_scores', 'creator_tier_history'
  ) THEN
    SELECT project_id INTO v_parent_project_id FROM public.kocs WHERE uid = NEW.uid;
  ELSIF TG_TABLE_NAME = 'reward_fulfillments' THEN
    SELECT project_id INTO v_parent_project_id FROM public.redemption_orders WHERE id = NEW.order_id;
  END IF;
  IF NEW.project_id IS NULL THEN
    NEW.project_id := COALESCE(v_parent_project_id, public.default_project_id());
  ELSIF v_parent_project_id IS NOT NULL AND NEW.project_id <> v_parent_project_id THEN
    RAISE EXCEPTION 'project ownership does not match the parent record';
  END IF;
  IF NEW.project_id IS NULL THEN RAISE EXCEPTION 'active project ownership is required'; END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_creator_monthly_tier_scores_assign_project ON public.creator_monthly_tier_scores;
CREATE TRIGGER trg_creator_monthly_tier_scores_assign_project BEFORE INSERT OR UPDATE OF project_id, uid ON public.creator_monthly_tier_scores
FOR EACH ROW EXECUTE FUNCTION public.assign_core_record_project();
DROP TRIGGER IF EXISTS trg_creator_tier_history_assign_project ON public.creator_tier_history;
CREATE TRIGGER trg_creator_tier_history_assign_project BEFORE INSERT OR UPDATE OF project_id, uid ON public.creator_tier_history
FOR EACH ROW EXECUTE FUNCTION public.assign_core_record_project();

CREATE OR REPLACE FUNCTION public.assign_creator_reference()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_creator_id UUID;
  v_creator_project_id UUID;
BEGIN
  IF TG_TABLE_NAME = 'reward_fulfillments' THEN
    SELECT creator_id, project_id INTO v_creator_id, v_creator_project_id
    FROM public.redemption_orders WHERE id = NEW.order_id;
  ELSE
    SELECT creator_id, project_id INTO v_creator_id, v_creator_project_id
    FROM public.kocs WHERE project_id = NEW.project_id AND uid = NEW.uid;
  END IF;

  IF v_creator_id IS NULL THEN
    IF TG_TABLE_NAME = 'registration_applications' THEN RETURN NEW; END IF;
    RAISE EXCEPTION 'creator identity not found for project';
  END IF;
  IF NEW.creator_id IS NOT NULL AND NEW.creator_id <> v_creator_id THEN
    RAISE EXCEPTION 'creator identity does not match project and UID';
  END IF;
  IF NEW.project_id <> v_creator_project_id THEN
    RAISE EXCEPTION 'creator project does not match parent record';
  END IF;
  NEW.creator_id := v_creator_id;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_registration_applications_creator_reference ON public.registration_applications;
CREATE TRIGGER trg_registration_applications_creator_reference BEFORE INSERT OR UPDATE OF project_id, uid, creator_id ON public.registration_applications
FOR EACH ROW EXECUTE FUNCTION public.assign_creator_reference();
DROP TRIGGER IF EXISTS trg_submissions_creator_reference ON public.submissions;
CREATE TRIGGER trg_submissions_creator_reference BEFORE INSERT OR UPDATE OF project_id, uid, creator_id ON public.submissions
FOR EACH ROW EXECUTE FUNCTION public.assign_creator_reference();
DROP TRIGGER IF EXISTS trg_point_logs_creator_reference ON public.point_logs;
CREATE TRIGGER trg_point_logs_creator_reference BEFORE INSERT OR UPDATE OF project_id, uid, creator_id ON public.point_logs
FOR EACH ROW EXECUTE FUNCTION public.assign_creator_reference();
DROP TRIGGER IF EXISTS trg_redemption_orders_creator_reference ON public.redemption_orders;
CREATE TRIGGER trg_redemption_orders_creator_reference BEFORE INSERT OR UPDATE OF project_id, uid, creator_id ON public.redemption_orders
FOR EACH ROW EXECUTE FUNCTION public.assign_creator_reference();
DROP TRIGGER IF EXISTS trg_reward_fulfillments_creator_reference ON public.reward_fulfillments;
CREATE TRIGGER trg_reward_fulfillments_creator_reference BEFORE INSERT OR UPDATE OF project_id, order_id, creator_id ON public.reward_fulfillments
FOR EACH ROW EXECUTE FUNCTION public.assign_creator_reference();
DROP TRIGGER IF EXISTS trg_redemption_order_edits_creator_reference ON public.redemption_order_edits;
CREATE TRIGGER trg_redemption_order_edits_creator_reference BEFORE INSERT OR UPDATE OF project_id, uid, creator_id ON public.redemption_order_edits
FOR EACH ROW EXECUTE FUNCTION public.assign_creator_reference();
DROP TRIGGER IF EXISTS trg_creator_monthly_tier_scores_creator_reference ON public.creator_monthly_tier_scores;
CREATE TRIGGER trg_creator_monthly_tier_scores_creator_reference BEFORE INSERT OR UPDATE OF project_id, uid, creator_id ON public.creator_monthly_tier_scores
FOR EACH ROW EXECUTE FUNCTION public.assign_creator_reference();
DROP TRIGGER IF EXISTS trg_creator_tier_history_creator_reference ON public.creator_tier_history;
CREATE TRIGGER trg_creator_tier_history_creator_reference BEFORE INSERT OR UPDATE OF project_id, uid, creator_id ON public.creator_tier_history
FOR EACH ROW EXECUTE FUNCTION public.assign_creator_reference();

COMMIT;
