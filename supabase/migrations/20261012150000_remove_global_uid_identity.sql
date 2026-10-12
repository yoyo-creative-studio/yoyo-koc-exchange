BEGIN;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.kocs
    GROUP BY project_id, uid HAVING COUNT(*) > 1
  ) THEN RAISE EXCEPTION 'duplicate UID exists inside a project'; END IF;

  IF EXISTS (SELECT 1 FROM public.submissions WHERE creator_id IS NULL)
    OR EXISTS (SELECT 1 FROM public.point_logs WHERE creator_id IS NULL)
    OR EXISTS (SELECT 1 FROM public.redemption_orders WHERE creator_id IS NULL)
    OR EXISTS (SELECT 1 FROM public.reward_fulfillments WHERE creator_id IS NULL)
    OR EXISTS (SELECT 1 FROM public.redemption_order_edits WHERE creator_id IS NULL)
    OR EXISTS (SELECT 1 FROM public.creator_monthly_tier_scores WHERE creator_id IS NULL)
    OR EXISTS (SELECT 1 FROM public.creator_tier_history WHERE creator_id IS NULL)
  THEN RAISE EXCEPTION 'business records with missing creator identity must be repaired first'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.registration_applications
    WHERE status = 'approved' AND creator_id IS NULL
  ) THEN RAISE EXCEPTION 'approved registration is missing creator identity'; END IF;
END;
$$;

ALTER TABLE public.registration_applications
  DROP CONSTRAINT IF EXISTS registration_applications_creator_id_fkey;
ALTER TABLE public.registration_applications
  ADD CONSTRAINT registration_applications_creator_id_fkey
  FOREIGN KEY (creator_id) REFERENCES public.kocs(creator_id) ON DELETE SET NULL;

DROP INDEX IF EXISTS public.idx_registration_pending_uid_unique;
DROP INDEX IF EXISTS public.idx_registration_pending_account_unique;
DROP INDEX IF EXISTS public.idx_submissions_showcase_uid_period_unique;
DROP INDEX IF EXISTS public.idx_redemption_orders_uid_request_type_unique;

CREATE UNIQUE INDEX idx_registration_pending_project_uid_unique
  ON public.registration_applications(project_id, uid)
  WHERE status IN ('pending', 'approved');
CREATE UNIQUE INDEX idx_registration_pending_project_account_unique
  ON public.registration_applications(project_id, account_id)
  WHERE status IN ('pending', 'approved');
CREATE UNIQUE INDEX idx_submissions_showcase_creator_period_unique
  ON public.submissions(project_id, creator_id, period)
  WHERE submission_type = 'showcase' AND COALESCE(period, '') <> '';
CREATE UNIQUE INDEX idx_redemption_orders_creator_request_type_unique
  ON public.redemption_orders(project_id, creator_id, request_id, option_type)
  WHERE request_id IS NOT NULL AND request_id <> '';

ALTER TABLE public.creator_monthly_tier_scores
  DROP CONSTRAINT IF EXISTS creator_monthly_tier_scores_pkey;
ALTER TABLE public.creator_monthly_tier_scores
  ADD CONSTRAINT creator_monthly_tier_scores_pkey
  PRIMARY KEY (project_id, creator_id, period);

ALTER TABLE public.creator_tier_history
  DROP CONSTRAINT IF EXISTS creator_tier_history_uid_effective_period_rule_key_to_tier_key;
ALTER TABLE public.creator_tier_history
  ADD CONSTRAINT creator_tier_history_creator_period_rule_tier_key
  UNIQUE (project_id, creator_id, effective_period, rule_key, to_tier);

CREATE OR REPLACE FUNCTION public.assign_core_record_project()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_parent_project_id UUID;
BEGIN
  IF TG_TABLE_NAME = 'reward_fulfillments' THEN
    SELECT project_id INTO v_parent_project_id
    FROM public.redemption_orders WHERE id = NEW.order_id;
  ELSIF NEW.creator_id IS NOT NULL THEN
    SELECT project_id INTO v_parent_project_id
    FROM public.kocs WHERE creator_id = NEW.creator_id;
  ELSIF NEW.project_id IS NOT NULL AND COALESCE(NEW.uid, '') <> '' THEN
    SELECT project_id INTO v_parent_project_id
    FROM public.kocs WHERE project_id = NEW.project_id AND uid = NEW.uid;
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

CREATE OR REPLACE FUNCTION public.assign_creator_reference()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_creator_id UUID;
  v_creator_project_id UUID;
  v_creator_uid TEXT;
BEGIN
  IF TG_TABLE_NAME = 'reward_fulfillments' THEN
    SELECT creator_id, project_id, uid INTO v_creator_id, v_creator_project_id, v_creator_uid
    FROM public.redemption_orders WHERE id = NEW.order_id;
  ELSIF NEW.creator_id IS NOT NULL THEN
    SELECT creator_id, project_id, uid INTO v_creator_id, v_creator_project_id, v_creator_uid
    FROM public.kocs WHERE creator_id = NEW.creator_id;
  ELSE
    SELECT creator_id, project_id, uid INTO v_creator_id, v_creator_project_id, v_creator_uid
    FROM public.kocs WHERE project_id = NEW.project_id AND uid = NEW.uid;
  END IF;

  IF v_creator_id IS NULL THEN
    IF TG_TABLE_NAME = 'registration_applications' AND NEW.status <> 'approved' THEN RETURN NEW; END IF;
    RAISE EXCEPTION 'creator identity not found for project';
  END IF;
  IF NEW.creator_id IS NOT NULL AND NEW.creator_id <> v_creator_id THEN
    RAISE EXCEPTION 'creator identity does not match project';
  END IF;
  IF NEW.project_id <> v_creator_project_id THEN
    RAISE EXCEPTION 'creator project does not match parent record';
  END IF;
  IF TG_TABLE_NAME <> 'reward_fulfillments' AND COALESCE(NEW.uid, '') <> v_creator_uid THEN
    RAISE EXCEPTION 'creator UID does not match immutable identity';
  END IF;
  NEW.creator_id := v_creator_id;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.refresh_creator_content_tier_score()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_project_id UUID := COALESCE(NEW.project_id, OLD.project_id);
  v_creator_id UUID := COALESCE(NEW.creator_id, OLD.creator_id);
  v_period TEXT := COALESCE(NEW.period, OLD.period);
  v_uid TEXT;
  v_raw NUMERIC;
  v_capped NUMERIC;
BEGIN
  IF v_period IS NULL OR v_period < '2026-09' THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
  END IF;
  SELECT uid INTO v_uid FROM public.kocs
  WHERE project_id = v_project_id AND creator_id = v_creator_id;
  IF v_uid IS NULL THEN RAISE EXCEPTION 'creator identity not found for tier score'; END IF;

  SELECT COALESCE(SUM(points_earned), 0) INTO v_raw
  FROM public.submissions
  WHERE project_id = v_project_id AND creator_id = v_creator_id
    AND period = v_period AND status = 'scored'
    AND COALESCE(submission_type, 'work') <> 'showcase';
  v_capped := CASE WHEN v_raw >= 40 THEN 40 WHEN v_raw >= 20 THEN 20 ELSE v_raw END;

  INSERT INTO public.creator_monthly_tier_scores (
    project_id, creator_id, uid, period, content_raw_points,
    content_capped_points, source_note, updated_at
  ) VALUES (
    v_project_id, v_creator_id, v_uid, v_period, v_raw,
    v_capped, 'Scored work submissions only', NOW()
  ) ON CONFLICT (project_id, creator_id, period) DO UPDATE SET
    uid = EXCLUDED.uid,
    content_raw_points = EXCLUDED.content_raw_points,
    content_capped_points = EXCLUDED.content_capped_points,
    source_note = EXCLUDED.source_note,
    updated_at = NOW();
  IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.change_project_creator_uid(
  p_project_key TEXT, p_old_uid TEXT, p_new_uid TEXT
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_project_id UUID;
  v_creator_id UUID;
BEGIN
  p_old_uid := btrim(p_old_uid);
  p_new_uid := btrim(p_new_uid);
  IF p_old_uid = '' OR p_new_uid = '' OR p_new_uid !~ '^[A-Za-z0-9]+$' THEN RAISE EXCEPTION 'Invalid creator UID'; END IF;
  IF p_old_uid = p_new_uid THEN RETURN; END IF;
  SELECT id INTO v_project_id FROM public.platform_projects WHERE project_key = p_project_key AND status = 'active';
  IF v_project_id IS NULL THEN RAISE EXCEPTION 'Active project not found'; END IF;
  SELECT creator_id INTO v_creator_id FROM public.kocs
  WHERE project_id = v_project_id AND uid = p_old_uid FOR UPDATE;
  IF v_creator_id IS NULL THEN RAISE EXCEPTION 'Creator not found'; END IF;
  IF EXISTS (SELECT 1 FROM public.kocs WHERE project_id = v_project_id AND uid = p_new_uid) THEN
    RAISE EXCEPTION 'Target UID is already registered in this project';
  END IF;

  UPDATE public.kocs SET uid = p_new_uid
  WHERE project_id = v_project_id AND creator_id = v_creator_id;
  UPDATE public.registration_applications SET uid = p_new_uid
  WHERE project_id = v_project_id AND creator_id = v_creator_id;
  UPDATE public.submissions SET uid = p_new_uid
  WHERE project_id = v_project_id AND creator_id = v_creator_id;
  UPDATE public.point_logs SET uid = p_new_uid
  WHERE project_id = v_project_id AND creator_id = v_creator_id;
  UPDATE public.redemption_orders SET uid = p_new_uid
  WHERE project_id = v_project_id AND creator_id = v_creator_id;
  UPDATE public.reward_fulfillments SET uid = p_new_uid
  WHERE project_id = v_project_id AND creator_id = v_creator_id;
  UPDATE public.redemption_order_edits SET uid = p_new_uid
  WHERE project_id = v_project_id AND creator_id = v_creator_id;
  UPDATE public.creator_monthly_tier_scores SET uid = p_new_uid
  WHERE project_id = v_project_id AND creator_id = v_creator_id;
  UPDATE public.creator_tier_history SET uid = p_new_uid
  WHERE project_id = v_project_id AND creator_id = v_creator_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.ship_redemption_order(p_order_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_order public.redemption_orders%ROWTYPE;
  v_project_key TEXT;
  v_point_result JSONB;
BEGIN
  SELECT * INTO v_order FROM public.redemption_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'order not found'; END IF;
  IF v_order.status = 'cancelled' THEN RAISE EXCEPTION 'cancelled order cannot be shipped'; END IF;
  SELECT project_key INTO v_project_key FROM public.platform_projects WHERE id = v_order.project_id;
  IF v_project_key IS NULL THEN RAISE EXCEPTION 'order project not found'; END IF;

  UPDATE public.redemption_orders
  SET status = 'shipped', processed_at = COALESCE(processed_at, NOW()), processed_by = 'admin'
  WHERE id = p_order_id;
  IF COALESCE(v_order.points_spent, 0) > 0 THEN
    v_point_result := public.add_project_point_log_once(
      v_project_key, v_order.uid, -v_order.points_spent, 'redemption',
      'Shipped order #' || v_order.id,
      COALESCE(NULLIF(v_order.period, ''), TO_CHAR(NOW(), 'YYYY-MM')),
      'admin_ship', 'ship-order:' || v_order.id
    );
  END IF;
  RETURN jsonb_build_object(
    'ok', true, 'already_shipped', v_order.status = 'shipped',
    'points_deducted', COALESCE((v_point_result->>'inserted')::BOOLEAN, false)
  );
END;
$$;

DO $$
DECLARE
  dependency RECORD;
BEGIN
  FOR dependency IN
    SELECT constraints.conrelid::regclass AS table_name, constraints.conname
    FROM pg_constraint constraints
    WHERE constraints.contype = 'f'
      AND constraints.confrelid = 'public.kocs'::regclass
      AND EXISTS (
        SELECT 1
        FROM unnest(constraints.confkey) referenced_column(attnum)
        JOIN pg_attribute attributes
          ON attributes.attrelid = constraints.confrelid
         AND attributes.attnum = referenced_column.attnum
        WHERE attributes.attname = 'uid'
      )
  LOOP
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', dependency.table_name, dependency.conname);
  END LOOP;
END;
$$;

ALTER TABLE public.kocs DROP CONSTRAINT kocs_pkey;
ALTER TABLE public.kocs
  ADD CONSTRAINT kocs_pkey PRIMARY KEY USING INDEX idx_kocs_creator_id_unique;

CREATE OR REPLACE FUNCTION public.change_creator_uid(p_old_uid TEXT, p_new_uid TEXT)
RETURNS VOID LANGUAGE SQL SECURITY DEFINER SET search_path = public AS $$
  SELECT public.change_project_creator_uid('mlt-global', p_old_uid, p_new_uid);
$$;

CREATE OR REPLACE FUNCTION public.update_creator_profile(p_uid TEXT, p_changes JSONB)
RETURNS VOID LANGUAGE SQL SECURITY DEFINER SET search_path = public AS $$
  SELECT public.update_project_creator_profile('mlt-global', p_uid, p_changes);
$$;

CREATE OR REPLACE FUNCTION public.submit_creator_work(
  p_uid TEXT, p_account_id TEXT, p_period TEXT, p_discord_name TEXT,
  p_server TEXT, p_links TEXT, p_feedback TEXT DEFAULT ''
)
RETURNS JSONB LANGUAGE SQL SECURITY DEFINER SET search_path = public AS $$
  SELECT public.submit_project_creator_work(
    'mlt-global', p_uid, p_account_id, p_period, p_discord_name,
    p_server, p_links, p_feedback
  );
$$;

CREATE OR REPLACE FUNCTION public.submit_creator_showcase(
  p_uid TEXT, p_account_id TEXT, p_period TEXT, p_discord_name TEXT,
  p_server TEXT, p_link TEXT
)
RETURNS JSONB LANGUAGE SQL SECURITY DEFINER SET search_path = public AS $$
  SELECT public.submit_project_creator_showcase(
    'mlt-global', p_uid, p_account_id, p_period, p_discord_name, p_server, p_link
  );
$$;

CREATE OR REPLACE FUNCTION public.redeem_points(
  p_uid TEXT, p_account_id TEXT, p_period TEXT, p_items JSONB,
  p_contact_info TEXT DEFAULT '', p_request_id TEXT DEFAULT ''
)
RETURNS JSONB LANGUAGE SQL SECURITY DEFINER SET search_path = public AS $$
  SELECT public.redeem_project_points(
    'mlt-global', p_uid, p_account_id, p_period, p_items, p_contact_info, p_request_id
  );
$$;

CREATE OR REPLACE FUNCTION public.edit_pending_redemption(
  p_uid TEXT, p_account_id TEXT, p_period TEXT, p_old_request_id TEXT,
  p_new_request_id TEXT, p_items JSONB, p_contact_info TEXT DEFAULT ''
)
RETURNS JSONB LANGUAGE SQL SECURITY DEFINER SET search_path = public AS $$
  SELECT public.edit_project_pending_redemption(
    'mlt-global', p_uid, p_account_id, p_period, p_old_request_id,
    p_new_request_id, p_items, p_contact_info
  );
$$;

COMMIT;
