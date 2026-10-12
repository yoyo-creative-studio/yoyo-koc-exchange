BEGIN;

CREATE OR REPLACE FUNCTION public.validate_default_project_reward_order()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_unit_cost INTEGER;
  v_display_name TEXT;
  v_amount_text TEXT;
  v_quantity INTEGER;
BEGIN
  IF COALESCE(NEW.points_spent, 0) <= 0 OR NEW.status <> 'pending' THEN
    RETURN NEW;
  END IF;
  IF NEW.project_id IS NULL THEN RAISE EXCEPTION 'reward order project is required'; END IF;

  SELECT rewards.points_cost, rewards.display_name, rewards.amount_text
  INTO v_unit_cost, v_display_name, v_amount_text
  FROM public.project_reward_options rewards
  WHERE rewards.project_id = NEW.project_id
    AND rewards.is_active = true
    AND rewards.reward_key = NEW.option_type;
  IF v_unit_cost IS NULL THEN RAISE EXCEPTION 'reward option is not active for this project'; END IF;
  IF NEW.points_spent % v_unit_cost <> 0 THEN
    RAISE EXCEPTION 'reward points do not match the configured unit cost';
  END IF;

  v_quantity := NEW.points_spent / v_unit_cost;
  NEW.option_name := v_display_name || ' ×' || v_quantity;
  NEW.reward_amount := v_quantity || 'x ' || v_amount_text;
  RETURN NEW;
END;
$$;

COMMIT;
