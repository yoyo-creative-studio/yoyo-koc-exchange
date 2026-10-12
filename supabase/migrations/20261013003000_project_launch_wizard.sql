BEGIN;

CREATE OR REPLACE FUNCTION public.force_new_projects_paused()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.project_key <> 'mlt-global' THEN NEW.status := 'paused'; END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_force_new_projects_paused ON public.platform_projects;
CREATE TRIGGER trg_force_new_projects_paused BEFORE INSERT ON public.platform_projects
FOR EACH ROW EXECUTE FUNCTION public.force_new_projects_paused();

CREATE OR REPLACE FUNCTION public.get_project_launch_readiness(p_project_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_project public.platform_projects%ROWTYPE;
  v_reward_count INTEGER;
  v_campaign_count INTEGER;
  v_rules_ready BOOLEAN;
  v_checks JSONB;
BEGIN
  SELECT * INTO v_project FROM public.platform_projects WHERE id = p_project_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'project not found'; END IF;
  SELECT count(*) INTO v_reward_count FROM public.project_reward_options
  WHERE project_id = p_project_id AND is_active = true;
  SELECT count(*), COALESCE(bool_and(NULLIF(rules_json, '') IS NOT NULL AND rules_json::JSONB <> '{}'::JSONB), false)
  INTO v_campaign_count, v_rules_ready FROM public.campaign_config
  WHERE project_id = p_project_id AND is_current_period = true AND is_active = true;
  v_checks := jsonb_build_array(
    jsonb_build_object('key','branding','label','Brand and portal copy','ready',COALESCE(v_project.settings->>'brand_name','') <> '' AND COALESCE(v_project.settings->>'portal_tagline','') <> ''),
    jsonb_build_object('key','region','label','Locale, timezone and operating region','ready',v_project.default_locale <> '' AND v_project.default_timezone <> '' AND COALESCE(v_project.settings->>'operating_region','') <> ''),
    jsonb_build_object('key','discord','label','Discord Server ID','ready',COALESCE(v_project.settings->>'discord_guild_id','') ~ '^\d{17,20}$'),
    jsonb_build_object('key','rewards','label','At least one active reward','ready',v_reward_count > 0),
    jsonb_build_object('key','campaign','label','Current campaign period','ready',v_campaign_count = 1),
    jsonb_build_object('key','rules','label','Scoring and tier rules','ready',v_campaign_count = 1 AND v_rules_ready)
  );
  RETURN jsonb_build_object(
    'project_id',v_project.id,'project_key',v_project.project_key,'status',v_project.status,
    'ready',NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_checks) item WHERE NOT (item->>'ready')::BOOLEAN),
    'checks',v_checks,
    'portal_url','https://yoyo-creative-studio.github.io/yoyo-koc-exchange/index.html?project=' || v_project.project_key
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.launch_platform_project(p_project_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_readiness JSONB;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('launch-project|' || p_project_id::TEXT));
  v_readiness := public.get_project_launch_readiness(p_project_id);
  IF NOT COALESCE((v_readiness->>'ready')::BOOLEAN, false) THEN RAISE EXCEPTION 'project launch checklist is incomplete'; END IF;
  UPDATE public.platform_projects SET status='active',settings=settings || jsonb_build_object('launched_at',NOW()),updated_at=NOW()
  WHERE id=p_project_id AND status <> 'archived';
  IF NOT FOUND THEN RAISE EXCEPTION 'project is archived or missing'; END IF;
  RETURN v_readiness || jsonb_build_object('status','active','launched',true);
END;
$$;

DROP FUNCTION IF EXISTS public.get_project_campaign_periods(TEXT);
CREATE FUNCTION public.get_project_campaign_periods(p_project_key TEXT DEFAULT 'mlt-global')
RETURNS TABLE (period TEXT, is_current_period BOOLEAN)
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT campaigns.period,campaigns.is_current_period FROM public.campaign_config campaigns
  JOIN public.platform_projects projects ON projects.id=campaigns.project_id
  WHERE projects.project_key=p_project_key AND projects.status IN ('active','paused') ORDER BY campaigns.period;
$$;

CREATE OR REPLACE FUNCTION public.publish_project_campaign_period(p_project_key TEXT,p_period TEXT,p_rules_json TEXT,p_points_cap INTEGER)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_project_id UUID;
BEGIN
  IF p_period IS NULL OR p_period !~ '^\d{4}-\d{2}$' THEN RAISE EXCEPTION 'invalid campaign period'; END IF;
  SELECT id INTO v_project_id FROM public.platform_projects WHERE project_key=p_project_key AND status IN ('active','paused');
  IF v_project_id IS NULL THEN RAISE EXCEPTION 'configurable project not found'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('campaign|' || v_project_id::TEXT));
  UPDATE public.campaign_config SET is_current_period=false,updated_at=NOW() WHERE project_id=v_project_id AND is_current_period=true AND period<>p_period;
  INSERT INTO public.campaign_config (project_id,period,name,rules_json,points_cap,is_active,is_current_period,updated_at)
  VALUES (v_project_id,p_period,p_period || ' Settlement',COALESCE(NULLIF(p_rules_json,''),'{}'),p_points_cap,true,true,NOW())
  ON CONFLICT (project_id,period) DO UPDATE SET rules_json=EXCLUDED.rules_json,points_cap=EXCLUDED.points_cap,is_active=true,is_current_period=true,updated_at=NOW();
  RETURN jsonb_build_object('ok',true,'project_key',p_project_key,'period',p_period);
END;
$$;

REVOKE ALL ON FUNCTION public.get_project_launch_readiness(UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.launch_platform_project(UUID) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_project_launch_readiness(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.launch_platform_project(UUID) TO service_role;
REVOKE ALL ON FUNCTION public.get_project_campaign_periods(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_project_campaign_periods(TEXT) TO anon,authenticated;
REVOKE ALL ON FUNCTION public.publish_project_campaign_period(TEXT,TEXT,TEXT,INTEGER) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.publish_project_campaign_period(TEXT,TEXT,TEXT,INTEGER) TO service_role;
COMMIT;
