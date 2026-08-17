-- =============================================================================
-- 20260978_0001 — Fan Team Saved + Recent Locations (review-ready; do NOT auto-apply)
-- =============================================================================
-- Unified team_locations table (is_saved + usage metadata) scoped by team_id.
-- Mutations via SECURITY DEFINER RPCs. Organizers may read + record usage;
-- save/edit/default/clear require fan_team_viewer_can_organize (owner/manager/head_coach).
-- Does not alter pickup_games schema or Team event change-notification behavior.
--
-- Hardening notes (FINAL):
-- - SECURITY DEFINER search_path = pg_catalog, public
-- - identity helper is STABLE (to_char(numeric) is STABLE / lc_numeric)
-- - ONE locking model: team-scoped pg_advisory_xact_lock BEFORE any FOR UPDATE
-- - rekey/merge soft-deletes conflicting active B BEFORE assigning A's new key
-- - soft-deleted identities are not revived; later use/save creates a NEW active row
-- - (0,0) / Infinity / out-of-range coords rejected for identity
-- - IEEE float8 NaN rejected via x = x (NaN is not equal to itself)
-- - save/update: p_replace_location distinguishes metadata patch vs full location replace
-- =============================================================================

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.fan_teams') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_teams'];
  END IF;
  IF to_regclass('public.fan_team_members') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_team_members'];
  END IF;
  IF to_regprocedure('public.is_active_fan_team_member(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.is_active_fan_team_member(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.fan_team_viewer_can_organize(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.fan_team_viewer_can_organize(uuid)'];
  END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION
      '20260978_0001 prerequisites missing: %',
      array_to_string(v_missing, ', ');
  END IF;
END $$;

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Text / coordinate normalization + identity helper
-- -----------------------------------------------------------------------------
-- Whitespace collapsed; empty → NULL. IMMUTABLE (lower/btrim/regexp_replace/coalesce only).
CREATE OR REPLACE FUNCTION public.fan_team_location_normalize_text(p_raw text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT NULLIF(
    lower(btrim(regexp_replace(coalesce(p_raw, ''), '\s+', ' ', 'g'))),
    ''
  );
$$;

REVOKE ALL ON FUNCTION public.fan_team_location_normalize_text(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fan_team_location_normalize_text(text) FROM anon;
REVOKE ALL ON FUNCTION public.fan_team_location_normalize_text(text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_location_normalize_text(text) TO service_role;

-- Valid finite lat/lon, rejecting Null-Island (0,0) as non-authoritative.
-- float8 NaN: in PostgreSQL, NaN = NaN is FALSE, so `x = x` rejects NaN.
-- ±Infinity fails the BETWEEN range checks (not accepted as usable coords).
CREATE OR REPLACE FUNCTION public.fan_team_location_coords_usable(
  p_latitude double precision,
  p_longitude double precision
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT
    p_latitude IS NOT NULL
    AND p_longitude IS NOT NULL
    AND p_latitude = p_latitude
    AND p_longitude = p_longitude
    AND p_latitude BETWEEN -90::double precision AND 90::double precision
    AND p_longitude BETWEEN -180::double precision AND 180::double precision
    AND NOT (
      p_latitude = 0::double precision
      AND p_longitude = 0::double precision
    );
$$;

REVOKE ALL ON FUNCTION public.fan_team_location_coords_usable(double precision, double precision) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fan_team_location_coords_usable(double precision, double precision) FROM anon;
REVOKE ALL ON FUNCTION public.fan_team_location_coords_usable(double precision, double precision) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_location_coords_usable(double precision, double precision) TO service_role;

-- Identity: provider → geo+address → geo+name → geo → addr → name.
-- VOLATILITY: STABLE — uses to_char(numeric, text), which PostgreSQL marks STABLE
-- because numeric formatting can depend on lc_numeric. Cannot be IMMUTABLE.
CREATE OR REPLACE FUNCTION public.fan_team_location_identity_key(
  p_provider_place_id text,
  p_latitude double precision,
  p_longitude double precision,
  p_address text,
  p_city text,
  p_state text,
  p_place_name text
)
RETURNS text
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_provider text := public.fan_team_location_normalize_text(p_provider_place_id);
  v_address text := public.fan_team_location_normalize_text(p_address);
  v_city text := public.fan_team_location_normalize_text(p_city);
  v_state text := public.fan_team_location_normalize_text(p_state);
  v_place text := public.fan_team_location_normalize_text(p_place_name);
  v_lat text;
  v_lon text;
BEGIN
  IF v_provider IS NOT NULL THEN
    RETURN 'provider:' || v_provider;
  END IF;

  IF public.fan_team_location_coords_usable(p_latitude, p_longitude) THEN
    -- to_char(numeric) is STABLE (lc_numeric) → this helper must be STABLE.
    v_lat := to_char(round(p_latitude::numeric, 5), 'FM999990.00000');
    v_lon := to_char(round(p_longitude::numeric, 5), 'FM999990.00000');
    IF v_address IS NOT NULL OR v_city IS NOT NULL OR v_state IS NOT NULL THEN
      RETURN 'geoaddr:' || v_lat || ',' || v_lon || '|'
        || coalesce(v_address, '') || '|'
        || coalesce(v_city, '') || '|'
        || coalesce(v_state, '');
    END IF;
    IF v_place IS NOT NULL THEN
      RETURN 'geoname:' || v_lat || ',' || v_lon || '|' || v_place;
    END IF;
    RETURN 'geo:' || v_lat || ',' || v_lon;
  END IF;

  IF v_address IS NOT NULL OR v_city IS NOT NULL OR v_state IS NOT NULL THEN
    RETURN 'addr:'
      || coalesce(v_address, '') || '|'
      || coalesce(v_city, '') || '|'
      || coalesce(v_state, '') || '|'
      || coalesce(v_place, '');
  END IF;

  IF v_place IS NOT NULL THEN
    RETURN 'name:' || v_place;
  END IF;

  RETURN NULL;
END;
$$;

-- Internal helper — not a public RPC.
REVOKE ALL ON FUNCTION public.fan_team_location_identity_key(text, double precision, double precision, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fan_team_location_identity_key(text, double precision, double precision, text, text, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.fan_team_location_identity_key(text, double precision, double precision, text, text, text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_location_identity_key(text, double precision, double precision, text, text, text, text) TO service_role;

-- -----------------------------------------------------------------------------
-- 2) Table
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.fan_team_locations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id uuid NOT NULL,
  nickname text NULL,
  place_name text NULL,
  address text NULL,
  city text NULL,
  state text NULL,
  latitude double precision NULL,
  longitude double precision NULL,
  provider_place_id text NULL,
  identity_key text NOT NULL,
  is_saved boolean NOT NULL DEFAULT false,
  is_default boolean NOT NULL DEFAULT false,
  usage_count integer NOT NULL DEFAULT 0,
  last_used_at timestamptz NULL,
  created_by uuid NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz NULL,
  CONSTRAINT fan_team_locations_usage_count_ck CHECK (usage_count >= 0),
  CONSTRAINT fan_team_locations_nickname_len_ck
    CHECK (nickname IS NULL OR char_length(btrim(nickname)) BETWEEN 1 AND 80),
  CONSTRAINT fan_team_locations_place_name_len_ck
    CHECK (place_name IS NULL OR char_length(btrim(place_name)) BETWEEN 1 AND 200),
  CONSTRAINT fan_team_locations_coords_ck
    CHECK (
      (latitude IS NULL AND longitude IS NULL)
      OR (
        latitude IS NOT NULL AND longitude IS NOT NULL
        AND latitude BETWEEN -90 AND 90
        AND longitude BETWEEN -180 AND 180
      )
    ),
  CONSTRAINT fan_team_locations_default_implies_saved_ck
    CHECK (is_default = false OR is_saved = true),
  CONSTRAINT fan_team_locations_identity_key_len_ck
    CHECK (char_length(identity_key) BETWEEN 1 AND 512)
);

DO $$
BEGIN
  ALTER TABLE public.fan_team_locations
    DROP CONSTRAINT IF EXISTS fan_team_locations_team_id_fkey;
  ALTER TABLE public.fan_team_locations
    ADD CONSTRAINT fan_team_locations_team_id_fkey
    FOREIGN KEY (team_id) REFERENCES public.fan_teams (id) ON DELETE CASCADE;

  ALTER TABLE public.fan_team_locations
    DROP CONSTRAINT IF EXISTS fan_team_locations_created_by_fkey;
  ALTER TABLE public.fan_team_locations
    ADD CONSTRAINT fan_team_locations_created_by_fkey
    FOREIGN KEY (created_by) REFERENCES auth.users (id) ON DELETE SET NULL;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS fan_team_locations_team_identity_uq
  ON public.fan_team_locations (team_id, identity_key)
  WHERE deleted_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS fan_team_locations_one_default_uq
  ON public.fan_team_locations (team_id)
  WHERE is_default = true AND deleted_at IS NULL AND is_saved = true;

CREATE INDEX IF NOT EXISTS fan_team_locations_team_saved_idx
  ON public.fan_team_locations (team_id, is_default DESC, updated_at DESC)
  WHERE deleted_at IS NULL AND is_saved = true;

CREATE INDEX IF NOT EXISTS fan_team_locations_team_recent_idx
  ON public.fan_team_locations (team_id, last_used_at DESC, usage_count DESC)
  WHERE deleted_at IS NULL AND last_used_at IS NOT NULL;

COMMENT ON TABLE public.fan_team_locations IS
  'Team-scoped saved + recent schedule locations. identity_key dedupes physical places. One default saved location per team.';

-- Defense-in-depth: soft-deleted rows cannot remain default; unsaved cannot be default.
CREATE OR REPLACE FUNCTION public.fan_team_locations_before_write_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NEW.deleted_at IS NOT NULL THEN
    NEW.is_default := false;
  END IF;
  IF NEW.is_saved IS NOT TRUE THEN
    NEW.is_default := false;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS fan_team_locations_before_write_guard_trg ON public.fan_team_locations;
CREATE TRIGGER fan_team_locations_before_write_guard_trg
  BEFORE INSERT OR UPDATE ON public.fan_team_locations
  FOR EACH ROW
  EXECUTE FUNCTION public.fan_team_locations_before_write_guard();

REVOKE ALL ON FUNCTION public.fan_team_locations_before_write_guard() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fan_team_locations_before_write_guard() FROM anon;
REVOKE ALL ON FUNCTION public.fan_team_locations_before_write_guard() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_locations_before_write_guard() TO service_role;

-- -----------------------------------------------------------------------------
-- 3) RLS (select for active members; writes via RPCs only)
-- -----------------------------------------------------------------------------
ALTER TABLE public.fan_team_locations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS fan_team_locations_select ON public.fan_team_locations;
CREATE POLICY fan_team_locations_select
  ON public.fan_team_locations
  FOR SELECT
  TO authenticated
  USING (
    deleted_at IS NULL
    AND public.is_active_fan_team_member(team_id, (SELECT auth.uid()))
  );

REVOKE ALL ON TABLE public.fan_team_locations FROM PUBLIC;
REVOKE ALL ON TABLE public.fan_team_locations FROM anon;
GRANT SELECT ON TABLE public.fan_team_locations TO authenticated;
GRANT ALL ON TABLE public.fan_team_locations TO service_role;

-- -----------------------------------------------------------------------------
-- 4) Internal: team mutation lock / clear defaults / rekey-or-merge
-- -----------------------------------------------------------------------------
-- FINAL LOCKING MODEL (single strategy):
-- Every organizer mutation RPC that touches fan_team_locations acquires
--   public._fan_team_location_lock_team(team_id)
-- BEFORE any SELECT … FOR UPDATE / INSERT / multi-row default changes.
--
-- Key derivation (transaction-scoped, two-int form):
--   key1 = hashtext('fan_team_locations.v1')   -- feature namespace
--   key2 = hashtext(team_id::text)             -- Team scope
-- Different teams do not share the same (key1,key2) pair → no cross-team blocking.
-- Same team mutations serialize for the duration of the transaction.
--
-- Callers MUST NOT take row FOR UPDATE locks before this advisory lock.
CREATE OR REPLACE FUNCTION public._fan_team_location_lock_team(p_team_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF p_team_id IS NULL THEN
    RAISE EXCEPTION 'Not allowed.';
  END IF;
  PERFORM pg_advisory_xact_lock(
    hashtext('fan_team_locations.v1'),
    hashtext(p_team_id::text)
  );
END;
$$;

REVOKE ALL ON FUNCTION public._fan_team_location_lock_team(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._fan_team_location_lock_team(uuid) FROM anon;
REVOKE ALL ON FUNCTION public._fan_team_location_lock_team(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public._fan_team_location_lock_team(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public._fan_team_location_clear_other_defaults(
  p_team_id uuid,
  p_keep_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  -- Caller must already hold _fan_team_location_lock_team(p_team_id).
  UPDATE public.fan_team_locations
  SET is_default = false, updated_at = now()
  WHERE team_id = p_team_id
    AND deleted_at IS NULL
    AND is_default = true
    AND id IS DISTINCT FROM p_keep_id;
END;
$$;

REVOKE ALL ON FUNCTION public._fan_team_location_clear_other_defaults(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._fan_team_location_clear_other_defaults(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public._fan_team_location_clear_other_defaults(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public._fan_team_location_clear_other_defaults(uuid, uuid) TO service_role;

-- Merge collision helper. Assumes caller already holds the Team advisory lock
-- and has NOT left a conflicting active (team_id, identity_key) pair.
-- Unique order: soft-delete active conflict B FIRST, then assign p_new_key to A.
CREATE OR REPLACE FUNCTION public._fan_team_location_rekey_or_merge(
  p_row_id uuid,
  p_team_id uuid,
  p_new_key text
)
RETURNS public.fan_team_locations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_row public.fan_team_locations;
  v_other public.fan_team_locations;
  v_keep_default boolean;
  v_keep_saved boolean;
  v_nick text;
BEGIN
  IF p_new_key IS NULL OR btrim(p_new_key) = '' THEN
    RAISE EXCEPTION 'Location is incomplete.';
  END IF;

  SELECT * INTO v_row
  FROM public.fan_team_locations
  WHERE id = p_row_id
    AND team_id = p_team_id
    AND deleted_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Location not found.';
  END IF;

  IF v_row.identity_key IS NOT DISTINCT FROM p_new_key THEN
    RETURN v_row;
  END IF;

  SELECT * INTO v_other
  FROM public.fan_team_locations
  WHERE team_id = p_team_id
    AND identity_key = p_new_key
    AND deleted_at IS NULL
    AND id <> p_row_id
  FOR UPDATE;

  IF FOUND THEN
    v_keep_saved := (v_row.is_saved OR v_other.is_saved);
    v_keep_default := v_keep_saved AND (v_row.is_default OR v_other.is_default);
    -- Prefer survivor (edited) nickname when non-empty; else absorb B.
    v_nick := NULLIF(btrim(coalesce(v_row.nickname, '')), '');
    IF v_nick IS NULL THEN
      v_nick := NULLIF(btrim(coalesce(v_other.nickname, '')), '');
    END IF;

    -- 1) Soft-delete B FIRST (frees active identity unique index).
    UPDATE public.fan_team_locations
    SET
      is_default = false,
      is_saved = false,
      deleted_at = now(),
      updated_at = now()
    WHERE id = v_other.id;

    -- 2) Assign new key + merge into survivor A.
    -- Place fields: prefer non-null A (already holds the edit); fill gaps from B.
    -- created_by / created_at: preserve survivor A provenance.
    UPDATE public.fan_team_locations
    SET
      nickname = v_nick,
      place_name = coalesce(v_row.place_name, v_other.place_name),
      address = coalesce(v_row.address, v_other.address),
      city = coalesce(v_row.city, v_other.city),
      state = coalesce(v_row.state, v_other.state),
      latitude = coalesce(v_row.latitude, v_other.latitude),
      longitude = coalesce(v_row.longitude, v_other.longitude),
      provider_place_id = coalesce(v_row.provider_place_id, v_other.provider_place_id),
      is_saved = v_keep_saved,
      is_default = false,
      usage_count = coalesce(v_row.usage_count, 0) + coalesce(v_other.usage_count, 0),
      last_used_at = GREATEST(v_row.last_used_at, v_other.last_used_at),
      identity_key = p_new_key,
      updated_at = now()
    WHERE id = v_row.id
    RETURNING * INTO v_row;

    IF v_keep_default THEN
      PERFORM public._fan_team_location_clear_other_defaults(p_team_id, v_row.id);
      UPDATE public.fan_team_locations
      SET is_default = true, is_saved = true, updated_at = now()
      WHERE id = v_row.id
      RETURNING * INTO v_row;
    END IF;

    RETURN v_row;
  END IF;

  UPDATE public.fan_team_locations
  SET identity_key = p_new_key, updated_at = now()
  WHERE id = v_row.id
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public._fan_team_location_rekey_or_merge(uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._fan_team_location_rekey_or_merge(uuid, uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public._fan_team_location_rekey_or_merge(uuid, uuid, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public._fan_team_location_rekey_or_merge(uuid, uuid, text) TO service_role;

-- -----------------------------------------------------------------------------
-- 5) list_fan_team_locations (read-only; no Team mutation lock)
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
-- 6) upsert_fan_team_location_usage
-- -----------------------------------------------------------------------------
-- Soft-delete policy: never revive deleted rows. Under the Team lock, SELECT
-- active → UPDATE, else INSERT a NEW active row.
CREATE OR REPLACE FUNCTION public.upsert_fan_team_location_usage(
  p_team_id uuid,
  p_place_name text DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_state text DEFAULT NULL,
  p_latitude double precision DEFAULT NULL,
  p_longitude double precision DEFAULT NULL,
  p_provider_place_id text DEFAULT NULL
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
      -- Fill blanks only; never wipe nickname / is_saved / is_default.
      place_name = COALESCE(place_name, v_place),
      address = COALESCE(address, v_address),
      city = COALESCE(city, v_city),
      state = COALESCE(state, v_state),
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
-- 7) save_fan_team_location
-- -----------------------------------------------------------------------------
-- p_replace_location (default false):
--   false + p_location_id → metadata-only (nickname / default); identity fields preserved
--   true  + p_location_id → full location replacement; NULLs clear old identity fields
--   no p_location_id      → insert or merge-by-identity (fill blanks only on merge)
DROP FUNCTION IF EXISTS public.save_fan_team_location(
  uuid, text, text, text, text, text, double precision, double precision, text, boolean, uuid
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
  p_replace_location boolean DEFAULT false
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

  IF NOT public.fan_team_location_coords_usable(v_lat, v_lon) THEN
    v_lat := NULL;
    v_lon := NULL;
  END IF;

  -- Team lock BEFORE any row FOR UPDATE / INSERT / default clear.
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
      -- Full location replacement: assign normalized inputs INCLUDING NULL.
      -- Do NOT COALESCE — old provider/address/coords must be clearable.
      UPDATE public.fan_team_locations
      SET
        nickname = COALESCE(v_nick, nickname),
        place_name = v_place,
        address = v_address,
        city = v_city,
        state = v_state,
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
      -- Metadata-only: nickname / saved / default. Identity fields untouched.
      UPDATE public.fan_team_locations
      SET
        nickname = COALESCE(v_nick, nickname),
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

  -- Under Team lock: concurrent save of the same place cannot double-insert.
  SELECT * INTO v_row
  FROM public.fan_team_locations
  WHERE team_id = p_team_id
    AND identity_key = v_key
    AND deleted_at IS NULL
  FOR UPDATE;

  IF FOUND THEN
    -- Same identity: fill blanks only (never wipe existing richer fields / nickname).
    UPDATE public.fan_team_locations
    SET
      nickname = COALESCE(v_nick, nickname),
      place_name = COALESCE(place_name, v_place),
      address = COALESCE(address, v_address),
      city = COALESCE(city, v_city),
      state = COALESCE(state, v_state),
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

  -- Soft-deleted sibling (if any) is ignored → NEW active row (no revival).
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
-- 8) update_fan_team_location (nickname / default / optional full location replace)
-- -----------------------------------------------------------------------------
-- p_replace_location (default false):
--   false → metadata-only (nickname / default); identity fields + identity_key preserved
--   true  → replace place_name/address/city/state/lat/lon/provider INCLUDING NULL clears
DROP FUNCTION IF EXISTS public.update_fan_team_location(
  uuid, text, boolean, boolean, text, text, text, text, double precision, double precision, text
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
  p_replace_location boolean DEFAULT false
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

  IF v_replace THEN
    IF NOT public.fan_team_location_coords_usable(v_lat, v_lon) THEN
      -- Replacement may intentionally clear coords (both NULL after normalize).
      IF p_latitude IS NOT NULL AND p_longitude IS NOT NULL THEN
        RAISE EXCEPTION 'Location coordinates are invalid.';
      END IF;
      v_lat := NULL;
      v_lon := NULL;
    END IF;
  END IF;

  -- Resolve team WITHOUT row lock, then Team advisory lock, THEN FOR UPDATE.
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
    v_row := public._fan_team_location_rekey_or_merge(v_row.id, v_row.team_id, v_new_key);
  ELSE
    -- Metadata-only: do not touch identity-defining columns; do not rekey.
    UPDATE public.fan_team_locations
    SET
      nickname = CASE
        WHEN p_clear_nickname THEN NULL
        WHEN v_nick IS NOT NULL THEN v_nick
        ELSE nickname
      END,
      is_saved = true,
      updated_at = now()
    WHERE id = v_row.id
    RETURNING * INTO v_row;
  END IF;

  v_want_default := CASE
    WHEN p_is_default IS NULL THEN v_row.is_default
    ELSE p_is_default
  END;

  IF v_want_default THEN
    PERFORM public._fan_team_location_clear_other_defaults(v_row.team_id, v_row.id);
    UPDATE public.fan_team_locations
    SET is_default = true, is_saved = true, updated_at = now()
    WHERE id = v_row.id
    RETURNING * INTO v_row;
  ELSIF p_is_default IS NOT NULL THEN
    UPDATE public.fan_team_locations
    SET is_default = false, updated_at = now()
    WHERE id = v_row.id
    RETURNING * INTO v_row;
  END IF;

  RETURN v_row;
END;
$$;

-- -----------------------------------------------------------------------------
-- 9) remove_fan_team_saved_location
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.remove_fan_team_saved_location(p_location_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  me uuid := (SELECT auth.uid());
  v_team_id uuid;
  v_row public.fan_team_locations;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  SELECT team_id INTO v_team_id
  FROM public.fan_team_locations
  WHERE id = p_location_id
    AND deleted_at IS NULL;
  IF v_team_id IS NULL THEN
    RETURN;
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
    RETURN;
  END IF;

  IF v_row.usage_count > 0 OR v_row.last_used_at IS NOT NULL THEN
    -- Keep recent history row; clear saved/default/nickname.
    UPDATE public.fan_team_locations
    SET
      is_saved = false,
      is_default = false,
      nickname = NULL,
      updated_at = now()
    WHERE id = v_row.id;
  ELSE
    UPDATE public.fan_team_locations
    SET
      is_saved = false,
      is_default = false,
      nickname = NULL,
      deleted_at = now(),
      updated_at = now()
    WHERE id = v_row.id;
  END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- 10) clear_fan_team_recent_locations (does not delete saved)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.clear_fan_team_recent_locations(p_team_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  me uuid := (SELECT auth.uid());
  v_cleared integer := 0;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_team_id IS NULL OR NOT public.fan_team_viewer_can_organize(p_team_id) THEN
    RAISE EXCEPTION 'Not allowed.';
  END IF;

  PERFORM public._fan_team_location_lock_team(p_team_id);

  UPDATE public.fan_team_locations
  SET
    usage_count = 0,
    last_used_at = NULL,
    updated_at = now(),
    -- Unsaved recent-only rows soft-delete; saved rows keep membership (default untouched).
    deleted_at = CASE WHEN is_saved THEN deleted_at ELSE now() END,
    is_default = CASE WHEN is_saved THEN is_default ELSE false END
  WHERE team_id = p_team_id
    AND deleted_at IS NULL
    AND last_used_at IS NOT NULL;

  GET DIAGNOSTICS v_cleared = ROW_COUNT;
  RETURN v_cleared;
END;
$$;

-- -----------------------------------------------------------------------------
-- Grants (public RPCs only)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  fn text;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'list_fan_team_locations(uuid)',
    'upsert_fan_team_location_usage(uuid,text,text,text,text,double precision,double precision,text)',
    'save_fan_team_location(uuid,text,text,text,text,text,double precision,double precision,text,boolean,uuid,boolean)',
    'update_fan_team_location(uuid,text,boolean,boolean,text,text,text,text,double precision,double precision,text,boolean)',
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
