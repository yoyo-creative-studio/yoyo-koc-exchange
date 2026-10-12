BEGIN;

CREATE OR REPLACE FUNCTION public.get_public_project_portal_config(p_project_key TEXT DEFAULT 'mlt-global')
RETURNS TABLE (
  project_id UUID,
  project_key TEXT,
  name TEXT,
  default_locale TEXT,
  default_timezone TEXT,
  branding JSONB
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    projects.id,
    projects.project_key,
    projects.name,
    projects.default_locale,
    projects.default_timezone,
    jsonb_build_object(
      'brand_name', COALESCE(NULLIF(projects.settings->>'brand_name', ''), projects.name),
      'portal_tagline', COALESCE(NULLIF(projects.settings->>'portal_tagline', ''), 'Check your points & redeem rewards'),
      'studio_name', COALESCE(NULLIF(projects.settings->>'studio_name', ''), 'Yoyo Creative Studio'),
      'support_channel', COALESCE(NULLIF(projects.settings->>'support_channel', ''), 'town-service-station'),
      'primary_color', COALESCE(NULLIF(projects.settings->>'primary_color', ''), '#d4749a'),
      'accent_color', COALESCE(NULLIF(projects.settings->>'accent_color', ''), '#8e6fd8'),
      'background_color', COALESCE(NULLIF(projects.settings->>'background_color', ''), '#fff3f6')
    )
  FROM public.platform_projects projects
  WHERE projects.project_key = p_project_key
    AND projects.status = 'active';
$$;

REVOKE ALL ON FUNCTION public.get_public_project_portal_config(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_project_portal_config(TEXT) TO anon, authenticated;

COMMIT;
