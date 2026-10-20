ALTER TABLE public.reward_fulfillments
  DROP CONSTRAINT IF EXISTS reward_fulfillments_fulfillment_status_check;

ALTER TABLE public.reward_fulfillments
  ADD CONSTRAINT reward_fulfillments_fulfillment_status_check
  CHECK (fulfillment_status IN ('preparing', 'ready', 'delivered', 'shipped', 'undeliverable'));
