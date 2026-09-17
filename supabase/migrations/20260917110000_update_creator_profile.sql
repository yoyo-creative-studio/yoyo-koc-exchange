BEGIN;

CREATE OR REPLACE FUNCTION public.update_creator_profile(p_uid TEXT, p_changes JSONB)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_creator public.kocs%ROWTYPE;
  v_allowed TEXT[] := ARRAY['discord_name','name','region','account_id','server','address','city','state','postal_code','country','phone','notes','channel_tag'];
BEGIN
  IF p_uid IS NULL OR p_changes IS NULL OR jsonb_typeof(p_changes) <> 'object'
     OR p_changes = '{}'::jsonb OR EXISTS (
       SELECT 1 FROM jsonb_object_keys(p_changes) AS key WHERE key <> ALL(v_allowed)
     ) THEN
    RAISE EXCEPTION 'Invalid profile fields';
  END IF;
  SELECT * INTO v_creator FROM public.kocs WHERE uid = p_uid FOR UPDATE;
  IF NOT FOUND OR p_uid = '__config__' THEN RAISE EXCEPTION 'Creator not found'; END IF;
  IF p_changes ? 'account_id' AND (p_changes->>'account_id') !~ '^6[0-9]{18}$' THEN
    RAISE EXCEPTION 'Account ID must start with 6 and contain exactly 19 digits';
  END IF;
  IF p_changes ? 'discord_name' AND btrim(p_changes->>'discord_name') = '' THEN
    RAISE EXCEPTION 'Discord name cannot be empty';
  END IF;

  UPDATE public.kocs SET
    discord_name = CASE WHEN p_changes ? 'discord_name' THEN btrim(p_changes->>'discord_name') ELSE discord_name END,
    name = CASE WHEN p_changes ? 'name' THEN btrim(p_changes->>'name') ELSE name END,
    region = CASE WHEN p_changes ? 'region' THEN btrim(p_changes->>'region') ELSE region END,
    account_id = CASE WHEN p_changes ? 'account_id' THEN btrim(p_changes->>'account_id') ELSE account_id END,
    server = CASE WHEN p_changes ? 'server' THEN btrim(p_changes->>'server') ELSE server END,
    address = CASE WHEN p_changes ? 'address' THEN btrim(p_changes->>'address') ELSE address END,
    city = CASE WHEN p_changes ? 'city' THEN btrim(p_changes->>'city') ELSE city END,
    state = CASE WHEN p_changes ? 'state' THEN btrim(p_changes->>'state') ELSE state END,
    postal_code = CASE WHEN p_changes ? 'postal_code' THEN btrim(p_changes->>'postal_code') ELSE postal_code END,
    country = CASE WHEN p_changes ? 'country' THEN btrim(p_changes->>'country') ELSE country END,
    phone = CASE WHEN p_changes ? 'phone' THEN btrim(p_changes->>'phone') ELSE phone END,
    notes = CASE WHEN p_changes ? 'notes' THEN p_changes->>'notes' ELSE notes END,
    channel_tag = CASE WHEN p_changes ? 'channel_tag' THEN btrim(p_changes->>'channel_tag') ELSE channel_tag END
  WHERE uid = p_uid
  RETURNING * INTO v_creator;

  IF p_changes ? 'discord_name' THEN
    UPDATE public.submissions SET discord_name = v_creator.discord_name WHERE uid = p_uid;
    UPDATE public.redemption_orders SET discord_name = v_creator.discord_name WHERE uid = p_uid;
  END IF;
  IF p_changes ? 'server' THEN
    UPDATE public.submissions SET server = v_creator.server WHERE uid = p_uid;
  END IF;
  IF p_changes ? 'name' THEN
    UPDATE public.redemption_orders SET koc_name = v_creator.name WHERE uid = p_uid;
  END IF;
  IF p_changes ?| ARRAY['address','city','state','postal_code','country','phone','name'] THEN
    UPDATE public.redemption_orders SET contact_info = concat_ws(E'\n',
      NULLIF(v_creator.name, ''), NULLIF(v_creator.address, ''),
      NULLIF(v_creator.city, ''), NULLIF(v_creator.state, ''),
      NULLIF(v_creator.postal_code, ''), NULLIF(v_creator.country, ''), NULLIF(v_creator.phone, ''))
    WHERE uid = p_uid AND option_type = 'merch' AND status IN ('pending','processing');
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.update_creator_profile(TEXT, JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.update_creator_profile(TEXT, JSONB) TO service_role;

COMMIT;
