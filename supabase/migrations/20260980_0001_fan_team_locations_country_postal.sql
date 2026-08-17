-- =============================================================================
-- 20260980_0001 — Fan Team Locations: postal_code + country_code (GLOBAL)
-- =============================================================================
-- Prepare-only: do NOT auto-apply.
-- Extends fan_team_locations with structured postal + ISO 3166-1 alpha-2 country.
-- Identity keys intentionally unchanged (backward-compatible dedupe).
-- Country display names are derived client-side via BusinessLocationCountryPolicy.
-- =============================================================================

DO $$
BEGIN
  IF to_regclass('public.fan_team_locations') IS NULL THEN
    RAISE EXCEPTION '20260980_0001 prerequisite missing: table public.fan_team_locations';
  END IF;
END $$;

BEGIN;

ALTER TABLE public.fan_team_locations
  ADD COLUMN IF NOT EXISTS postal_code text NULL,
  ADD COLUMN IF NOT EXISTS country_code text NULL;

ALTER TABLE public.fan_team_locations
  DROP CONSTRAINT IF EXISTS fan_team_locations_postal_code_len_ck;
ALTER TABLE public.fan_team_locations
  ADD CONSTRAINT fan_team_locations_postal_code_len_ck
  CHECK (postal_code IS NULL OR char_length(btrim(postal_code)) BETWEEN 1 AND 32);

ALTER TABLE public.fan_team_locations
  DROP CONSTRAINT IF EXISTS fan_team_locations_country_code_ck;
ALTER TABLE public.fan_team_locations
  ADD CONSTRAINT fan_team_locations_country_code_ck
  CHECK (
    country_code IS NULL
    OR char_length(btrim(country_code)) = 2
  );

COMMENT ON COLUMN public.fan_team_locations.postal_code IS
  'Postal / ZIP code (international; letters allowed). Nullable for legacy + countries without postal.';
COMMENT ON COLUMN public.fan_team_locations.country_code IS
  'ISO 3166-1 alpha-2 country code. Nullable for legacy rows; never invent from ambiguous addresses.';

-- -----------------------------------------------------------------------------
-- list_fan_team_locations — include postal + country
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_fan_team_locations(p_team_id uuid)
RETURNS TABLE (
  id uuid,
  team_id uuid,
  nickname text,
  place_name text,
  address text,
  city text,
  state text,
  postal_code text,
  country_code text,
  latitude double precision,
  longitude double precision,
  provider_place_id text,
  identity_key text,
  is_saved boolean,
  is_default boolean,
  usage_count integer,
  last_used_at timestamptz,
  created_by uuid,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  me uuid := (SELECT auth.uid());
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_team_id IS NULL OR NOT public.is_active_fan_team_member(p_team_id, me) THEN
    RAISE EXCEPTION 'Not allowed.';
  END IF;

  RETURN QUERY
  SELECT
    l.id,
    l.team_id,
    l.nickname,
    l.place_name,
    l.address,
    l.city,
    l.state,
    l.postal_code,
    l.country_code,
    l.latitude,
    l.longitude,
    l.provider_place_id,
    l.identity_key,
    l.is_saved,
    l.is_default,
    l.usage_count,
    l.last_used_at,
    l.created_by,
    l.created_at,
    l.updated_at
  FROM public.fan_team_locations l
  WHERE l.team_id = p_team_id
    AND l.deleted_at IS NULL
    AND (
      l.is_saved = true
      OR l.last_used_at IS NOT NULL
    )
  ORDER BY
    l.is_saved DESC,
    l.is_default DESC,
    l.last_used_at DESC NULLS LAST,
    l.usage_count DESC,
    l.updated_at DESC;
END;
$$;

-- -----------------------------------------------------------------------------
-- upsert_fan_team_location_usage — optional postal + country (fill blanks)
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.upsert_fan_team_location_usage(
  uuid, text, text, text, text, double precision, double precision, text
);
DROP FUNCTION IF EXISTS public.upsert_fan_team_location_usage(
  uuid, text, text, text, text, double precision, double precision, text, text, text
);

CREATE OR REPLACE FUNCTION public.upsert_fan_team_location_usage(
  p_team_id uuid,
  p_place_name text DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_state text DEFAULT NULL,
  p_latitude double precision DEFAULT NULL,
  p_longitude double precision DEFAULT NULL,
  p_provider_place_id text DEFAULT NULL,
  p_postal_code text DEFAULT NULL,
  p_country_code text DEFAULT NULL
)
RETURNS public.fan_team_locations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  me uuid := (SELECT auth.uid());
  v_place text := NULLIF(btrim(coalesce(p_place_name, '')), '');
  v_address text := NULLIF(btrim(coalesce(p_address, '')), '');
  v_city text := NULLIF(btrim(coalesce(p_city, '')), '');
  v_state text := NULLIF(btrim(coalesce(p_state, '')), '');
  v_postal text := NULLIF(btrim(coalesce(p_postal_code, '')), '');
  v_country text := upper(NULLIF(btrim(coalesce(p_country_code, '')), ''));
  v_provider text := NULLIF(btrim(coalesce(p_provider_place_id, '')), '');
  v_lat double precision := p_latitude;
  v_lon double precision := p_longitude;
  v_key text;
  v_row public.fan_team_locations;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_team_id IS NULL OR NOT public.fan_team_viewer_can_organize(p_team_id) THEN
    RAISE EXCEPTION 'Not allowed.';
  END IF;

  IF v_country IS NOT NULL AND char_length(v_country) <> 2 THEN
    v_country := NULL;
  END IF;

  IF NOT public.fan_team_location_coords_usable(v_lat, v_lon) THEN
    v_lat := NULL;
    v_lon := NULL;
  END IF;

  v_key := public.fan_team_location_identity_key(
    v_provider, v_lat, v_lon, v_address, v_city, v_state, v_place
  );
  IF v_key IS NULL THEN
    RAISE EXCEPTION 'Location is incomplete.';
  END IF;

  PERFORM public._fan_team_location_lock_team(p_team_id);

  SELECT * INTO v_row
  FROM public.fan_team_locations
  WHERE team_id = p_team_id
    AND identity_key = v_key
    AND deleted_at IS NULL
  FOR UPDATE;

  IF FOUND THEN
    UPDATE public.fan_team_locations
    SET
      place_name = COALESCE(place_name, v_place),
      address = COALESCE(address, v_address),
      city = COALESCE(city, v_city),
      state = COALESCE(state, v_state),
      postal_code = COALESCE(postal_code, v_postal),
      country_code = COALESCE(country_code, v_country),
      latitude = COALESCE(latitude, v_lat),
      longitude = COALESCE(longitude, v_lon),
      provider_place_id = COALESCE(provider_place_id, v_provider),
      usage_count = usage_count + 1,
      last_used_at = now(),
      updated_at = now()
    WHERE id = v_row.id
    RETURNING * INTO v_row;
    RETURN v_row;
  END IF;

  INSERT INTO public.fan_team_locations (
    team_id,
    nickname,
    place_name,
    address,
    city,
    state,
    postal_code,
    country_code,
    latitude,
    longitude,
    provider_place_id,
    identity_key,
    is_saved,
    is_default,
    usage_count,
    last_used_at,
    created_by
  ) VALUES (
    p_team_id,
    NULL,
    v_place,
    v_address,
    v_city,
    v_state,
    v_postal,
    v_country,
    v_lat,
    v_lon,
    v_provider,
    v_key,
    false,
    false,
    1,
    now(),
    me
  )
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

-- -----------------------------------------------------------------------------
-- save_fan_team_location — optional postal + country
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.save_fan_team_location(
  uuid, text, text, text, text, text, double precision, double precision, text, boolean, uuid
);
DROP FUNCTION IF EXISTS public.save_fan_team_location(
  uuid, text, text, text, text, text, double precision, double precision, text, boolean, uuid, boolean
);
DROP FUNCTION IF EXISTS public.save_fan_team_location(
  uuid, text, text, text, text, text, double precision, double precision, text, boolean, uuid, boolean, text, text
);

CREATE OR REPLACE FUNCTION public.save_fan_team_location(
  p_team_id uuid,
  p_nickname text DEFAULT NULL,
  p_place_name text DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_state text DEFAULT NULL,
  p_latitude double precision DEFAULT NULL,
  p_longitude double precision DEFAULT NULL,
  p_provider_place_id text DEFAULT NULL,
  p_set_default boolean DEFAULT false,
  p_location_id uuid DEFAULT NULL,
  p_replace_location boolean DEFAULT false,
  p_postal_code text DEFAULT NULL,
  p_country_code text DEFAULT NULL
)
RETURNS public.fan_team_locations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  me uuid := (SELECT auth.uid());
  v_nick text := NULLIF(btrim(coalesce(p_nickname, '')), '');
  v_place text := NULLIF(btrim(coalesce(p_place_name, '')), '');
  v_address text := NULLIF(btrim(coalesce(p_address, '')), '');
  v_city text := NULLIF(btrim(coalesce(p_city, '')), '');
  v_state text := NULLIF(btrim(coalesce(p_state, '')), '');
  v_postal text := NULLIF(btrim(coalesce(p_postal_code, '')), '');
  v_country text := upper(NULLIF(btrim(coalesce(p_country_code, '')), ''));
  v_provider text := NULLIF(btrim(coalesce(p_provider_place_id, '')), '');
  v_lat double precision := p_latitude;
  v_lon double precision := p_longitude;
  v_key text;
  v_row public.fan_team_locations;
  v_replace boolean := COALESCE(p_replace_location, false);
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_team_id IS NULL OR NOT public.fan_team_viewer_can_organize(p_team_id) THEN
    RAISE EXCEPTION 'Not allowed.';
  END IF;

  IF v_country IS NOT NULL AND char_length(v_country) <> 2 THEN
    v_country := NULL;
  END IF;

  IF NOT public.fan_team_location_coords_usable(v_lat, v_lon) THEN
    v_lat := NULL;
    v_lon := NULL;
  END IF;

  PERFORM public._fan_team_location_lock_team(p_team_id);

  IF p_location_id IS NOT NULL THEN
    SELECT * INTO v_row
    FROM public.fan_team_locations
    WHERE id = p_location_id
      AND team_id = p_team_id
      AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Location not found.';
    END IF;

    IF v_replace THEN
      UPDATE public.fan_team_locations
      SET
        nickname = COALESCE(v_nick, nickname),
        place_name = v_place,
        address = v_address,
        city = v_city,
        state = v_state,
        postal_code = v_postal,
        country_code = v_country,
        latitude = v_lat,
        longitude = v_lon,
        provider_place_id = v_provider,
        is_saved = true,
        updated_at = now()
      WHERE id = v_row.id
      RETURNING * INTO v_row;

      v_key := public.fan_team_location_identity_key(
        v_row.provider_place_id,
        v_row.latitude,
        v_row.longitude,
        v_row.address,
        v_row.city,
        v_row.state,
        v_row.place_name
      );
      IF v_key IS NULL THEN
        RAISE EXCEPTION 'Location is incomplete.';
      END IF;
      v_row := public._fan_team_location_rekey_or_merge(v_row.id, p_team_id, v_key);
    ELSE
      UPDATE public.fan_team_locations
      SET
        nickname = COALESCE(v_nick, nickname),
        postal_code = COALESCE(postal_code, v_postal),
        country_code = COALESCE(country_code, v_country),
        is_saved = true,
        updated_at = now()
      WHERE id = v_row.id
      RETURNING * INTO v_row;
    END IF;

    IF p_set_default OR v_row.is_default THEN
      PERFORM public._fan_team_location_clear_other_defaults(p_team_id, v_row.id);
      UPDATE public.fan_team_locations
      SET is_default = true, is_saved = true, updated_at = now()
      WHERE id = v_row.id
      RETURNING * INTO v_row;
    END IF;

    RETURN v_row;
  END IF;

  v_key := public.fan_team_location_identity_key(
    v_provider, v_lat, v_lon, v_address, v_city, v_state, v_place
  );
  IF v_key IS NULL THEN
    RAISE EXCEPTION 'Location is incomplete.';
  END IF;

  SELECT * INTO v_row
  FROM public.fan_team_locations
  WHERE team_id = p_team_id
    AND identity_key = v_key
    AND deleted_at IS NULL
  FOR UPDATE;

  IF FOUND THEN
    UPDATE public.fan_team_locations
    SET
      nickname = COALESCE(v_nick, nickname),
      place_name = COALESCE(place_name, v_place),
      address = COALESCE(address, v_address),
      city = COALESCE(city, v_city),
      state = COALESCE(state, v_state),
      postal_code = COALESCE(postal_code, v_postal),
      country_code = COALESCE(country_code, v_country),
      latitude = COALESCE(latitude, v_lat),
      longitude = COALESCE(longitude, v_lon),
      provider_place_id = COALESCE(provider_place_id, v_provider),
      is_saved = true,
      updated_at = now()
    WHERE id = v_row.id
    RETURNING * INTO v_row;

    IF p_set_default THEN
      PERFORM public._fan_team_location_clear_other_defaults(p_team_id, v_row.id);
      UPDATE public.fan_team_locations
      SET is_default = true, updated_at = now()
      WHERE id = v_row.id
      RETURNING * INTO v_row;
    END IF;
    RETURN v_row;
  END IF;

  IF p_set_default THEN
    PERFORM public._fan_team_location_clear_other_defaults(p_team_id, NULL);
  END IF;

  INSERT INTO public.fan_team_locations (
    team_id,
    nickname,
    place_name,
    address,
    city,
    state,
    postal_code,
    country_code,
    latitude,
    longitude,
    provider_place_id,
    identity_key,
    is_saved,
    is_default,
    usage_count,
    last_used_at,
    created_by
  ) VALUES (
    p_team_id,
    v_nick,
    v_place,
    v_address,
    v_city,
    v_state,
    v_postal,
    v_country,
    v_lat,
    v_lon,
    v_provider,
    v_key,
    true,
    COALESCE(p_set_default, false),
    0,
    NULL,
    me
  )
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

-- -----------------------------------------------------------------------------
-- update_fan_team_location — optional postal + country on replace / fill
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.update_fan_team_location(
  uuid, text, boolean, boolean, text, text, text, text, double precision, double precision, text
);
DROP FUNCTION IF EXISTS public.update_fan_team_location(
  uuid, text, boolean, boolean, text, text, text, text, double precision, double precision, text, boolean
);
DROP FUNCTION IF EXISTS public.update_fan_team_location(
  uuid, text, boolean, boolean, text, text, text, text, double precision, double precision, text, boolean, text, text
);

CREATE OR REPLACE FUNCTION public.update_fan_team_location(
  p_location_id uuid,
  p_nickname text DEFAULT NULL,
  p_clear_nickname boolean DEFAULT false,
  p_is_default boolean DEFAULT NULL,
  p_place_name text DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_state text DEFAULT NULL,
  p_latitude double precision DEFAULT NULL,
  p_longitude double precision DEFAULT NULL,
  p_provider_place_id text DEFAULT NULL,
  p_replace_location boolean DEFAULT false,
  p_postal_code text DEFAULT NULL,
  p_country_code text DEFAULT NULL
)
RETURNS public.fan_team_locations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  me uuid := (SELECT auth.uid());
  v_row public.fan_team_locations;
  v_team_id uuid;
  v_nick text := NULLIF(btrim(coalesce(p_nickname, '')), '');
  v_place text := NULLIF(btrim(coalesce(p_place_name, '')), '');
  v_address text := NULLIF(btrim(coalesce(p_address, '')), '');
  v_city text := NULLIF(btrim(coalesce(p_city, '')), '');
  v_state text := NULLIF(btrim(coalesce(p_state, '')), '');
  v_postal text := NULLIF(btrim(coalesce(p_postal_code, '')), '');
  v_country text := upper(NULLIF(btrim(coalesce(p_country_code, '')), ''));
  v_provider text := NULLIF(btrim(coalesce(p_provider_place_id, '')), '');
  v_lat double precision := p_latitude;
  v_lon double precision := p_longitude;
  v_new_key text;
  v_want_default boolean;
  v_replace boolean := COALESCE(p_replace_location, false);
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  IF v_country IS NOT NULL AND char_length(v_country) <> 2 THEN
    v_country := NULL;
  END IF;

  IF v_replace THEN
    IF NOT public.fan_team_location_coords_usable(v_lat, v_lon) THEN
      IF p_latitude IS NOT NULL AND p_longitude IS NOT NULL THEN
        RAISE EXCEPTION 'Location coordinates are invalid.';
      END IF;
      v_lat := NULL;
      v_lon := NULL;
    END IF;
  END IF;

  SELECT team_id INTO v_team_id
  FROM public.fan_team_locations
  WHERE id = p_location_id
    AND deleted_at IS NULL;
  IF v_team_id IS NULL THEN
    RAISE EXCEPTION 'Location not found.';
  END IF;
  IF NOT public.fan_team_viewer_can_organize(v_team_id) THEN
    RAISE EXCEPTION 'Not allowed.';
  END IF;

  PERFORM public._fan_team_location_lock_team(v_team_id);

  SELECT * INTO v_row
  FROM public.fan_team_locations
  WHERE id = p_location_id
    AND deleted_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Location not found.';
  END IF;
  IF v_row.is_saved IS NOT TRUE THEN
    RAISE EXCEPTION 'Only saved locations can be edited this way.';
  END IF;

  IF v_replace THEN
    UPDATE public.fan_team_locations
    SET
      nickname = CASE
        WHEN p_clear_nickname THEN NULL
        WHEN v_nick IS NOT NULL THEN v_nick
        ELSE nickname
      END,
      place_name = v_place,
      address = v_address,
      city = v_city,
      state = v_state,
      postal_code = v_postal,
      country_code = v_country,
      latitude = v_lat,
      longitude = v_lon,
      provider_place_id = v_provider,
      is_saved = true,
      updated_at = now()
    WHERE id = v_row.id
    RETURNING * INTO v_row;

    v_new_key := public.fan_team_location_identity_key(
      v_row.provider_place_id,
      v_row.latitude,
      v_row.longitude,
      v_row.address,
      v_row.city,
      v_row.state,
      v_row.place_name
    );
    IF v_new_key IS NULL THEN
      RAISE EXCEPTION 'Location is incomplete.';
    END IF;
    v_row := public._fan_team_location_rekey_or_merge(v_row.id, v_team_id, v_new_key);
  ELSE
    UPDATE public.fan_team_locations
    SET
      nickname = CASE
        WHEN p_clear_nickname THEN NULL
        WHEN v_nick IS NOT NULL THEN v_nick
        ELSE nickname
      END,
      postal_code = COALESCE(postal_code, v_postal),
      country_code = COALESCE(country_code, v_country),
      updated_at = now()
    WHERE id = v_row.id
    RETURNING * INTO v_row;
  END IF;

  IF p_is_default IS NOT NULL THEN
    v_want_default := p_is_default;
    IF v_want_default THEN
      PERFORM public._fan_team_location_clear_other_defaults(v_team_id, v_row.id);
      UPDATE public.fan_team_locations
      SET is_default = true, is_saved = true, updated_at = now()
      WHERE id = v_row.id
      RETURNING * INTO v_row;
    ELSE
      UPDATE public.fan_team_locations
      SET is_default = false, updated_at = now()
      WHERE id = v_row.id
      RETURNING * INTO v_row;
    END IF;
  END IF;

  RETURN v_row;
END;
$$;

DO $$
DECLARE
  fn text;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'list_fan_team_locations(uuid)',
    'upsert_fan_team_location_usage(uuid,text,text,text,text,double precision,double precision,text,text,text)',
    'save_fan_team_location(uuid,text,text,text,text,text,double precision,double precision,text,boolean,uuid,boolean,text,text)',
    'update_fan_team_location(uuid,text,boolean,boolean,text,text,text,text,double precision,double precision,text,boolean,text,text)',
    'remove_fan_team_saved_location(uuid)',
    'clear_fan_team_recent_locations(uuid)'
  ]
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC', fn);
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM anon', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO service_role', fn);
  END LOOP;
END $$;

COMMIT;
