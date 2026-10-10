BEGIN;

CREATE OR REPLACE FUNCTION public.resolve_project_creator(
  p_project_key TEXT, p_uid TEXT, p_account_id TEXT
)
RETURNS TABLE (creator_id UUID, project_id UUID, uid TEXT, discord_name TEXT, account_id TEXT)
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT creators.creator_id, creators.project_id, creators.uid, creators.discord_name, creators.account_id
  FROM public.kocs creators
  JOIN public.platform_projects projects ON projects.id = creators.project_id
  WHERE projects.project_key = p_project_key
    AND projects.status = 'active'
    AND creators.uid = p_uid
    AND creators.account_id = p_account_id
    AND creators.status = 'active';
$$;

REVOKE ALL ON FUNCTION public.resolve_project_creator(TEXT, TEXT, TEXT) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.submit_project_creator_work(
  p_project_key TEXT, p_uid TEXT, p_account_id TEXT, p_period TEXT,
  p_discord_name TEXT, p_server TEXT, p_links TEXT, p_feedback TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_creator RECORD;
  v_count INTEGER;
  v_submission_id BIGINT;
BEGIN
  IF p_uid IS NULL OR btrim(p_uid) = '' OR p_account_id !~ '^6\d{18}$' OR p_period !~ '^\d{4}-\d{2}$' THEN
    RAISE EXCEPTION 'valid creator credentials and period are required';
  END IF;
  SELECT * INTO v_creator FROM public.resolve_project_creator(p_project_key, p_uid, p_account_id);
  IF v_creator.creator_id IS NULL THEN RAISE EXCEPTION 'creator credentials do not match'; END IF;
  IF p_links IS NULL OR btrim(p_links) = '' THEN RAISE EXCEPTION 'submission links are required'; END IF;
  IF NOT public.is_project_campaign_window_open(p_project_key, p_period, 'submissions') THEN
    RAISE EXCEPTION 'submission window is closed';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('submission|' || v_creator.creator_id::TEXT || '|' || p_period));
  SELECT COUNT(*)::INTEGER INTO v_count FROM public.submissions
  WHERE creator_id = v_creator.creator_id AND period = p_period
    AND COALESCE(submission_type, 'work') <> 'showcase' AND status <> 'rejected';
  IF v_count >= 2 THEN RAISE EXCEPTION 'submission limit reached'; END IF;

  INSERT INTO public.submissions (
    project_id, creator_id, discord_name, uid, server, links_engagement,
    feedback, submission_type, status, period, created_at
  ) VALUES (
    v_creator.project_id, v_creator.creator_id, COALESCE(p_discord_name, ''),
    v_creator.uid, COALESCE(p_server, ''), p_links, COALESCE(p_feedback, ''),
    'work', 'pending', p_period, NOW()
  ) RETURNING id INTO v_submission_id;
  RETURN jsonb_build_object('ok', true, 'submission_id', v_submission_id, 'used', v_count + 1, 'remaining', 1 - v_count);
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_project_creator_showcase(
  p_project_key TEXT, p_uid TEXT, p_account_id TEXT, p_period TEXT,
  p_discord_name TEXT, p_server TEXT, p_link TEXT
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_creator RECORD;
  v_submission_id BIGINT;
BEGIN
  SELECT * INTO v_creator FROM public.resolve_project_creator(p_project_key, p_uid, p_account_id);
  IF v_creator.creator_id IS NULL THEN RAISE EXCEPTION 'creator credentials do not match'; END IF;
  IF p_period !~ '^\d{4}-\d{2}$' OR p_link IS NULL OR btrim(p_link) = '' THEN
    RAISE EXCEPTION 'valid period and showcase link are required';
  END IF;
  IF NOT public.is_project_campaign_window_open(p_project_key, p_period, 'submissions') THEN
    RAISE EXCEPTION 'submission window is closed';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('showcase|' || v_creator.creator_id::TEXT || '|' || p_period));
  IF EXISTS (SELECT 1 FROM public.submissions WHERE creator_id = v_creator.creator_id AND period = p_period AND submission_type = 'showcase') THEN
    RAISE EXCEPTION 'showcase already submitted';
  END IF;

  INSERT INTO public.submissions (
    project_id, creator_id, discord_name, uid, server, links_engagement,
    submission_type, status, period, created_at
  ) VALUES (
    v_creator.project_id, v_creator.creator_id, COALESCE(p_discord_name, ''),
    v_creator.uid, COALESCE(p_server, ''), p_link, 'showcase', 'pending', p_period, NOW()
  ) RETURNING id INTO v_submission_id;
  RETURN jsonb_build_object('ok', true, 'submission_id', v_submission_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.redeem_project_points(
  p_project_key TEXT, p_uid TEXT, p_account_id TEXT, p_period TEXT,
  p_items JSONB, p_contact_info TEXT DEFAULT '', p_request_id TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_creator RECORD;
  v_balance INTEGER := 0;
  v_reserved INTEGER := 0;
  v_total_cost INTEGER := 0;
  v_existing_count INTEGER := 0;
  v_existing_cost INTEGER := 0;
  v_order_count INTEGER := 0;
  v_item JSONB;
BEGIN
  SELECT * INTO v_creator FROM public.resolve_project_creator(p_project_key, p_uid, p_account_id);
  IF v_creator.creator_id IS NULL THEN RAISE EXCEPTION 'creator credentials do not match'; END IF;
  IF p_period !~ '^\d{4}-\d{2}$' THEN RAISE EXCEPTION 'valid period is required'; END IF;
  IF NOT public.is_project_campaign_window_open(p_project_key, p_period, 'redemption') THEN
    RAISE EXCEPTION 'redemption window is closed';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items must be a non-empty array';
  END IF;
  IF COALESCE(btrim(p_request_id), '') = '' THEN p_request_id := gen_random_uuid()::TEXT; END IF;

  PERFORM pg_advisory_xact_lock(hashtext('redemption|' || v_creator.creator_id::TEXT));
  SELECT COUNT(*), COALESCE(SUM(points_spent), 0)::INTEGER INTO v_existing_count, v_existing_cost
  FROM public.redemption_orders WHERE creator_id = v_creator.creator_id AND request_id = p_request_id;
  IF v_existing_count > 0 THEN
    SELECT COALESCE(SUM(change), 0)::INTEGER INTO v_balance FROM public.point_logs WHERE creator_id = v_creator.creator_id;
    SELECT COALESCE(SUM(points_spent), 0)::INTEGER INTO v_reserved FROM public.redemption_orders
    WHERE creator_id = v_creator.creator_id AND status IN ('pending', 'processing');
    RETURN jsonb_build_object('ok', true, 'idempotent', true, 'order_count', v_existing_count,
      'available_before', v_balance - v_reserved + v_existing_cost, 'total_cost', v_existing_cost,
      'available_after', v_balance - v_reserved);
  END IF;
  IF EXISTS (SELECT 1 FROM public.redemption_orders WHERE creator_id = v_creator.creator_id
    AND period = p_period AND status <> 'cancelled' AND points_spent > 0) THEN
    RAISE EXCEPTION 'a reward has already been selected for this redemption period';
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    IF COALESCE(v_item->>'option_type', '') NOT IN ('diamonds', 'gplay', 'merch') THEN RAISE EXCEPTION 'unsupported reward type'; END IF;
    IF COALESCE((v_item->>'points_spent')::INTEGER, 0) <= 0 THEN RAISE EXCEPTION 'points_spent must be positive'; END IF;
    v_total_cost := v_total_cost + (v_item->>'points_spent')::INTEGER;
  END LOOP;
  IF (SELECT COUNT(*) FROM jsonb_array_elements(p_items)) <>
     (SELECT COUNT(DISTINCT item->>'option_type') FROM jsonb_array_elements(p_items) item) THEN
    RAISE EXCEPTION 'duplicate reward types are not allowed';
  END IF;

  SELECT COALESCE(SUM(change), 0)::INTEGER INTO v_balance FROM public.point_logs WHERE creator_id = v_creator.creator_id;
  SELECT COALESCE(SUM(points_spent), 0)::INTEGER INTO v_reserved FROM public.redemption_orders
  WHERE creator_id = v_creator.creator_id AND status IN ('pending', 'processing');
  IF v_total_cost > v_balance - v_reserved THEN
    RAISE EXCEPTION 'insufficient points: available %, required %', v_balance - v_reserved, v_total_cost;
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    INSERT INTO public.redemption_orders (
      project_id, creator_id, uid, discord_name, koc_name, option_type, option_name,
      points_spent, reward_amount, contact_info, status, period, request_id, created_at
    ) VALUES (
      v_creator.project_id, v_creator.creator_id, v_creator.uid,
      COALESCE(v_item->>'discord_name', v_creator.discord_name), COALESCE(v_item->>'koc_name', ''),
      v_item->>'option_type', COALESCE(v_item->>'option_name', ''), (v_item->>'points_spent')::INTEGER,
      COALESCE(v_item->>'reward_amount', ''), COALESCE(NULLIF(v_item->>'contact_info', ''), p_contact_info),
      'pending', p_period, p_request_id, NOW()
    );
    v_order_count := v_order_count + 1;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'idempotent', false, 'order_count', v_order_count,
    'available_before', v_balance - v_reserved, 'total_cost', v_total_cost,
    'available_after', v_balance - v_reserved - v_total_cost);
END;
$$;

CREATE OR REPLACE FUNCTION public.edit_project_pending_redemption(
  p_project_key TEXT, p_uid TEXT, p_account_id TEXT, p_period TEXT,
  p_old_request_id TEXT, p_new_request_id TEXT, p_items JSONB, p_contact_info TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_creator RECORD;
  v_balance INTEGER := 0;
  v_reserved_other INTEGER := 0;
  v_old_points INTEGER := 0;
  v_new_points INTEGER := 0;
  v_existing_count INTEGER := 0;
  v_non_pending_count INTEGER := 0;
  v_old_items JSONB;
  v_item JSONB;
  v_order_count INTEGER := 0;
BEGIN
  SELECT * INTO v_creator FROM public.resolve_project_creator(p_project_key, p_uid, p_account_id);
  IF v_creator.creator_id IS NULL THEN RAISE EXCEPTION 'creator credentials do not match'; END IF;
  IF NOT public.is_project_campaign_window_open(p_project_key, p_period, 'redemption') THEN RAISE EXCEPTION 'redemption window is closed'; END IF;
  IF COALESCE(btrim(p_old_request_id), '') = '' THEN RAISE EXCEPTION 'the existing redemption request is required'; END IF;
  IF COALESCE(btrim(p_new_request_id), '') = '' THEN p_new_request_id := gen_random_uuid()::TEXT; END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN RAISE EXCEPTION 'p_items must be a non-empty array'; END IF;

  PERFORM pg_advisory_xact_lock(hashtext('redemption-edit|' || v_creator.creator_id::TEXT || '|' || p_period));
  SELECT COUNT(*), COUNT(*) FILTER (WHERE status <> 'pending'), COALESCE(SUM(points_spent), 0)::INTEGER,
    COALESCE(jsonb_agg(jsonb_build_object('id', id, 'option_type', option_type, 'option_name', option_name,
      'points_spent', points_spent, 'reward_amount', reward_amount, 'status', status, 'request_id', request_id) ORDER BY id), '[]'::JSONB)
  INTO v_existing_count, v_non_pending_count, v_old_points, v_old_items
  FROM public.redemption_orders
  WHERE creator_id = v_creator.creator_id AND period = p_period AND request_id = p_old_request_id
    AND points_spent > 0 AND status <> 'cancelled';
  IF v_existing_count = 0 THEN RAISE EXCEPTION 'pending redemption request not found'; END IF;
  IF v_non_pending_count > 0 THEN RAISE EXCEPTION 'only pending reward orders can be edited'; END IF;
  IF EXISTS (SELECT 1 FROM public.redemption_orders WHERE creator_id = v_creator.creator_id AND period = p_period
    AND points_spent > 0 AND status <> 'cancelled' AND request_id IS DISTINCT FROM p_old_request_id) THEN
    RAISE EXCEPTION 'multiple active redemption requests require admin review';
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    IF COALESCE(v_item->>'option_type', '') NOT IN ('diamonds', 'gplay', 'merch') THEN RAISE EXCEPTION 'unsupported reward type'; END IF;
    IF COALESCE((v_item->>'points_spent')::INTEGER, 0) <= 0 THEN RAISE EXCEPTION 'points_spent must be positive'; END IF;
    v_new_points := v_new_points + (v_item->>'points_spent')::INTEGER;
  END LOOP;
  IF (SELECT COUNT(*) FROM jsonb_array_elements(p_items)) <>
     (SELECT COUNT(DISTINCT item->>'option_type') FROM jsonb_array_elements(p_items) item) THEN
    RAISE EXCEPTION 'duplicate reward types are not allowed';
  END IF;

  SELECT COALESCE(SUM(change), 0)::INTEGER INTO v_balance FROM public.point_logs WHERE creator_id = v_creator.creator_id;
  SELECT COALESCE(SUM(points_spent), 0)::INTEGER INTO v_reserved_other FROM public.redemption_orders
  WHERE creator_id = v_creator.creator_id AND status IN ('pending', 'processing')
    AND NOT (period = p_period AND request_id = p_old_request_id AND points_spent > 0);
  IF v_new_points > v_balance - v_reserved_other THEN
    RAISE EXCEPTION 'insufficient points: available %, required %', v_balance - v_reserved_other, v_new_points;
  END IF;

  INSERT INTO public.redemption_order_edits (
    project_id, creator_id, uid, period, old_request_id, new_request_id,
    old_items, new_items, old_points, new_points
  ) VALUES (
    v_creator.project_id, v_creator.creator_id, v_creator.uid, p_period,
    p_old_request_id, p_new_request_id, v_old_items, p_items, v_old_points, v_new_points
  );
  DELETE FROM public.redemption_orders WHERE creator_id = v_creator.creator_id AND period = p_period
    AND request_id = p_old_request_id AND points_spent > 0 AND status = 'pending';

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    INSERT INTO public.redemption_orders (
      project_id, creator_id, uid, discord_name, koc_name, option_type, option_name,
      points_spent, reward_amount, contact_info, status, period, request_id, created_at
    ) VALUES (
      v_creator.project_id, v_creator.creator_id, v_creator.uid,
      COALESCE(v_item->>'discord_name', v_creator.discord_name), COALESCE(v_item->>'koc_name', ''),
      v_item->>'option_type', COALESCE(v_item->>'option_name', ''), (v_item->>'points_spent')::INTEGER,
      COALESCE(v_item->>'reward_amount', ''), COALESCE(NULLIF(v_item->>'contact_info', ''), p_contact_info),
      'pending', p_period, p_new_request_id, NOW()
    );
    v_order_count := v_order_count + 1;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'order_count', v_order_count, 'old_total', v_old_points,
    'new_total', v_new_points, 'difference', v_new_points - v_old_points,
    'available_after', v_balance - v_reserved_other - v_new_points, 'request_id', p_new_request_id);
END;
$$;

REVOKE ALL ON FUNCTION public.submit_project_creator_work(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.submit_project_creator_showcase(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.redeem_project_points(TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.edit_project_pending_redemption(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_project_creator_work(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.submit_project_creator_showcase(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.redeem_project_points(TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.edit_project_pending_redemption(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT) TO anon, authenticated;

COMMIT;
