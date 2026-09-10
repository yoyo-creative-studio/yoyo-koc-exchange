BEGIN;

ALTER TABLE public.redemption_orders
  DROP CONSTRAINT IF EXISTS redemption_orders_status_check;

ALTER TABLE public.redemption_orders
  ADD CONSTRAINT redemption_orders_status_check
  CHECK (status IN ('pending', 'processing', 'shipped', 'cancelled'));

CREATE OR REPLACE FUNCTION public.queue_redemption_order(p_order_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order public.redemption_orders%ROWTYPE;
BEGIN
  SELECT * INTO v_order
  FROM public.redemption_orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'order not found';
  END IF;
  IF v_order.status = 'cancelled' THEN
    RAISE EXCEPTION 'cancelled order cannot be queued';
  END IF;
  IF v_order.status = 'shipped' THEN
    RETURN jsonb_build_object('ok', true, 'already_completed', true, 'status', v_order.status);
  END IF;

  UPDATE public.redemption_orders
  SET status = 'processing', processed_by = 'admin_queue'
  WHERE id = p_order_id;

  RETURN jsonb_build_object('ok', true, 'already_completed', false, 'status', 'processing');
END;
$$;

REVOKE ALL ON FUNCTION public.queue_redemption_order(BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.queue_redemption_order(BIGINT) TO anon, authenticated;

COMMIT;
