BEGIN;

CREATE OR REPLACE FUNCTION public.redeem_points(
  p_uid TEXT,
  p_account_id TEXT,
  p_period TEXT,
  p_items JSONB,
  p_contact_info TEXT DEFAULT '',
  p_request_id TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_available INTEGER;
  v_pending INTEGER;
  v_total_cost INTEGER := 0;
  v_item JSONB;
  v_order_count INTEGER := 0;
  v_existing_count INTEGER := 0;
  v_existing_cost INTEGER := 0;
BEGIN
  IF p_uid IS NULL OR btrim(p_uid) = '' OR p_account_id !~ '^\d{19}$' THEN
    RAISE EXCEPTION 'valid creator credentials are required';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.kocs
    WHERE uid = p_uid AND account_id = p_account_id AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'creator credentials do not match';
  END IF;
  IF p_period IS NULL OR btrim(p_period) = '' THEN
    RAISE EXCEPTION 'p_period is required';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.campaign_config
    WHERE period = p_period
      AND is_current_period = true
      AND redemption_open = true
      AND (redemption_close_at IS NULL OR NOW() < redemption_close_at)
  ) THEN
    RAISE EXCEPTION 'redemption window is closed';
  END IF;
  IF p_request_id IS NULL OR btrim(p_request_id) = '' THEN
    p_request_id := gen_random_uuid()::TEXT;
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items must be a non-empty array';
  END IF;
  IF (
    SELECT COUNT(DISTINCT item->>'option_type')
    FROM jsonb_array_elements(p_items) AS item
  ) > 1 THEN
    RAISE EXCEPTION 'only one reward type may be selected per redemption period';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_uid));

  SELECT COUNT(*), COALESCE(SUM(points_spent), 0)::INTEGER
  INTO v_existing_count, v_existing_cost
  FROM public.redemption_orders
  WHERE uid = p_uid AND request_id = p_request_id;

  IF v_existing_count > 0 THEN
    SELECT COALESCE(SUM(change), 0)::INTEGER INTO v_available
    FROM public.point_logs WHERE uid = p_uid;
    SELECT COALESCE(SUM(points_spent), 0)::INTEGER INTO v_pending
    FROM public.redemption_orders WHERE uid = p_uid AND status = 'pending';
    RETURN jsonb_build_object(
      'ok', true, 'idempotent', true, 'order_count', v_existing_count,
      'available_before', v_available - v_pending + v_existing_cost,
      'total_cost', v_existing_cost, 'available_after', v_available - v_pending
    );
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.redemption_orders
    WHERE uid = p_uid
      AND period = p_period
      AND status <> 'cancelled'
      AND points_spent > 0
  ) THEN
    RAISE EXCEPTION 'a reward has already been selected for this redemption period';
  END IF;

  SELECT COALESCE(SUM(change), 0)::INTEGER INTO v_available
  FROM public.point_logs WHERE uid = p_uid;
  SELECT COALESCE(SUM(points_spent), 0)::INTEGER INTO v_pending
  FROM public.redemption_orders WHERE uid = p_uid AND status = 'pending';
  v_available := v_available - v_pending;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    IF COALESCE(NULLIF(v_item->>'option_type', ''), '') = '' THEN
      RAISE EXCEPTION 'option_type is required';
    END IF;
    IF COALESCE(NULLIF(v_item->>'option_name', ''), '') = '' THEN
      RAISE EXCEPTION 'option_name is required';
    END IF;
    IF COALESCE((v_item->>'points_spent')::INTEGER, 0) <= 0 THEN
      RAISE EXCEPTION 'points_spent must be positive';
    END IF;
    v_total_cost := v_total_cost + COALESCE((v_item->>'points_spent')::INTEGER, 0);
  END LOOP;

  IF v_total_cost > v_available THEN
    RAISE EXCEPTION 'insufficient points: available %, required %', v_available, v_total_cost;
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    INSERT INTO public.redemption_orders (
      uid, discord_name, koc_name, option_type, option_name, points_spent,
      reward_amount, contact_info, status, period, request_id, created_at
    ) VALUES (
      p_uid, COALESCE(v_item->>'discord_name', ''), COALESCE(v_item->>'koc_name', ''),
      v_item->>'option_type', v_item->>'option_name', (v_item->>'points_spent')::INTEGER,
      COALESCE(v_item->>'reward_amount', ''),
      COALESCE(NULLIF(v_item->>'contact_info', ''), p_contact_info),
      'pending', p_period, p_request_id, NOW()
    );
    v_order_count := v_order_count + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true, 'idempotent', false, 'order_count', v_order_count,
    'available_before', v_available, 'total_cost', v_total_cost,
    'available_after', v_available - v_total_cost
  );
END;
$$;

REVOKE ALL ON FUNCTION public.redeem_points(TEXT, TEXT, TEXT, JSONB, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.redeem_points(TEXT, TEXT, TEXT, JSONB, TEXT, TEXT) TO anon, authenticated;

COMMIT;
