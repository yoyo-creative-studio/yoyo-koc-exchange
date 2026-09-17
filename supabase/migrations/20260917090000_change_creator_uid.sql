BEGIN;

DO $$
DECLARE
  fk RECORD;
  definition TEXT;
BEGIN
  FOR fk IN
    SELECT c.conname, c.conrelid::regclass AS table_name, pg_get_constraintdef(c.oid) AS definition
    FROM pg_constraint c
    WHERE c.contype = 'f' AND c.confrelid = 'public.kocs'::regclass
      AND EXISTS (
        SELECT 1 FROM unnest(c.confkey) AS key(attnum)
        JOIN pg_attribute a ON a.attrelid = c.confrelid AND a.attnum = key.attnum
        WHERE a.attname = 'uid'
      )
      AND c.confupdtype <> 'c'
  LOOP
    definition := regexp_replace(fk.definition, ' ON UPDATE (NO ACTION|RESTRICT|SET NULL|SET DEFAULT)', '');
    definition := regexp_replace(definition, ' ON DELETE ', ' ON UPDATE CASCADE ON DELETE ');
    IF definition NOT LIKE '%ON UPDATE CASCADE%' THEN
      definition := definition || ' ON UPDATE CASCADE';
    END IF;
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', fk.table_name, fk.conname);
    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s', fk.table_name, fk.conname, definition);
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.change_creator_uid(p_old_uid TEXT, p_new_uid TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  p_old_uid := btrim(p_old_uid);
  p_new_uid := btrim(p_new_uid);
  IF p_old_uid = '' OR p_new_uid = '' OR p_new_uid !~ '^[A-Za-z0-9]+$' THEN
    RAISE EXCEPTION 'Invalid creator UID';
  END IF;
  IF p_old_uid = p_new_uid THEN RETURN; END IF;
  IF EXISTS (SELECT 1 FROM public.kocs WHERE uid = p_new_uid) THEN
    RAISE EXCEPTION 'Target UID is already registered';
  END IF;
  UPDATE public.kocs SET uid = p_new_uid WHERE uid = p_old_uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'Creator UID not found'; END IF;
  UPDATE public.registration_applications SET uid = p_new_uid
  WHERE uid = p_old_uid AND status = 'approved';
END;
$$;

REVOKE ALL ON FUNCTION public.change_creator_uid(TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.change_creator_uid(TEXT, TEXT) TO service_role;

COMMIT;
