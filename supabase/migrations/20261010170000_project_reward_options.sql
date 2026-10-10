BEGIN;

CREATE TABLE IF NOT EXISTS public.project_reward_options (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID NOT NULL REFERENCES public.platform_projects(id) ON DELETE CASCADE,
  reward_key TEXT NOT NULL CHECK (reward_key ~ '^[a-z0-9][a-z0-9_-]{1,62}$'),
  fulfillment_type TEXT NOT NULL CHECK (fulfillment_type IN ('diamonds', 'gplay', 'merch')),
  display_name TEXT NOT NULL,
  points_cost INTEGER NOT NULL CHECK (points_cost > 0),
  description TEXT NOT NULL DEFAULT '',
  amount_text TEXT NOT NULL DEFAULT '',
  currency TEXT NOT NULL DEFAULT '',
  is_active BOOLEAN NOT NULL DEFAULT true,
  sort_order INTEGER NOT NULL DEFAULT 0,
  settings JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(project_id, reward_key)
);

CREATE INDEX IF NOT EXISTS idx_project_reward_options_project
  ON public.project_reward_options(project_id, is_active, sort_order);

ALTER TABLE public.project_reward_options ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.project_reward_options FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.seed_default_project_rewards()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.project_reward_options (
    project_id, reward_key, fulfillment_type, display_name, points_cost,
    description, amount_text, currency, sort_order
  ) VALUES
    (NEW.id, 'diamonds', 'diamonds', '450 Diamonds', 1, '1 Point = 450 Diamonds', '450 Diamonds', '', 10),
    (NEW.id, 'gplay', 'gplay', 'Google Play $10', 2, '2 Points = $10 Gift Card', '$10 Google Play', 'USD', 20),
    (NEW.id, 'merch', 'merch', 'Merch Pack', 5, '5 Points = 3 random items', 'Random Merch ×3', '', 30)
  ON CONFLICT (project_id, reward_key) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_seed_default_project_rewards ON public.platform_projects;
CREATE TRIGGER trg_seed_default_project_rewards
AFTER INSERT ON public.platform_projects
FOR EACH ROW EXECUTE FUNCTION public.seed_default_project_rewards();

INSERT INTO public.project_reward_options (
  project_id, reward_key, fulfillment_type, display_name, points_cost,
  description, amount_text, currency, sort_order
)
SELECT projects.id, rewards.reward_key, rewards.fulfillment_type, rewards.display_name,
       rewards.points_cost, rewards.description, rewards.amount_text, rewards.currency, rewards.sort_order
FROM public.platform_projects AS projects
CROSS JOIN (VALUES
  ('diamonds', 'diamonds', '450 Diamonds', 1, '1 Point = 450 Diamonds', '450 Diamonds', '', 10),
  ('gplay', 'gplay', 'Google Play $10', 2, '2 Points = $10 Gift Card', '$10 Google Play', 'USD', 20),
  ('merch', 'merch', 'Merch Pack', 5, '5 Points = 3 random items', 'Random Merch ×3', '', 30)
) AS rewards(reward_key, fulfillment_type, display_name, points_cost, description, amount_text, currency, sort_order)
WHERE projects.project_key = 'mlt-global'
ON CONFLICT (project_id, reward_key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.get_project_reward_options(p_project_key TEXT DEFAULT 'mlt-global')
RETURNS TABLE (
  reward_key TEXT,
  fulfillment_type TEXT,
  display_name TEXT,
  points_cost INTEGER,
  description TEXT,
  amount_text TEXT,
  currency TEXT,
  sort_order INTEGER
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT rewards.reward_key, rewards.fulfillment_type, rewards.display_name,
         rewards.points_cost, rewards.description, rewards.amount_text,
         rewards.currency, rewards.sort_order
  FROM public.project_reward_options AS rewards
  JOIN public.platform_projects AS projects ON projects.id = rewards.project_id
  WHERE projects.project_key = p_project_key
    AND projects.status = 'active'
    AND rewards.is_active = true
  ORDER BY rewards.sort_order, rewards.created_at;
$$;

REVOKE ALL ON FUNCTION public.get_project_reward_options(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_project_reward_options(TEXT) TO anon, authenticated;

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
  SELECT rewards.points_cost, rewards.display_name, rewards.amount_text
  INTO v_unit_cost, v_display_name, v_amount_text
  FROM public.project_reward_options AS rewards
  JOIN public.platform_projects AS projects ON projects.id = rewards.project_id
  WHERE projects.project_key = 'mlt-global'
    AND projects.status = 'active'
    AND rewards.is_active = true
    AND rewards.reward_key = NEW.option_type;
  IF v_unit_cost IS NULL THEN
    RAISE EXCEPTION 'reward option is not active for this project';
  END IF;
  IF NEW.points_spent % v_unit_cost <> 0 THEN
    RAISE EXCEPTION 'reward points do not match the configured unit cost';
  END IF;
  v_quantity := NEW.points_spent / v_unit_cost;
  NEW.option_name := v_display_name || ' ×' || v_quantity;
  NEW.reward_amount := v_quantity || 'x ' || v_amount_text;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_default_project_reward_order ON public.redemption_orders;
CREATE TRIGGER trg_validate_default_project_reward_order
BEFORE INSERT OR UPDATE OF option_type, points_spent, status ON public.redemption_orders
FOR EACH ROW EXECUTE FUNCTION public.validate_default_project_reward_order();

COMMIT;
