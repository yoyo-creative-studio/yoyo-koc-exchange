BEGIN;

WITH expected_periods AS (
  SELECT
    id,
    to_char(created_at AT TIME ZONE 'America/Los_Angeles', 'YYYY-MM') AS expected_period
  FROM public.redemption_orders
  WHERE option_type = 'merch'
    AND lower(concat_ws(' ', option_name, admin_notes, reward_amount)) ~ '(welcome|new creator|新人|入职)'
)
UPDATE public.redemption_orders AS orders
SET period = expected.expected_period
FROM expected_periods AS expected
WHERE orders.id = expected.id
  AND orders.period IS DISTINCT FROM expected.expected_period;

UPDATE public.reward_fulfillments AS fulfillments
SET period = orders.period,
    updated_at = NOW(),
    updated_by = 'welcome-gift-period-repair'
FROM public.redemption_orders AS orders
WHERE fulfillments.order_id = orders.id
  AND orders.option_type = 'merch'
  AND lower(concat_ws(' ', orders.option_name, orders.admin_notes, orders.reward_amount)) ~ '(welcome|new creator|新人|入职)'
  AND fulfillments.period IS DISTINCT FROM orders.period;

COMMIT;
