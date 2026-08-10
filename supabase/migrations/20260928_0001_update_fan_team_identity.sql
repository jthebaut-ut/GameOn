-- =============================================================================
-- 20260928_0001 — update_fan_team_identity + fan-team-logos storage
-- =============================================================================
-- Allows Owner/Manager to update Team name, sport, color_hex, and logo URLs.
-- Reuses fan_team_viewer_can_manage. Does NOT change roster/chat/games RPCs.
--
-- Storage path: fan-team-logos/{team_id}/logo-<uuid>.jpg (+ _thumb companion)
-- Write policies require active Owner/Manager for that team_id path segment.
--
-- Logo URL trust:
--   Non-empty p_logo_url / p_logo_thumbnail_url MUST resolve via
--   public.gameon_storage_path_from_public_url(..., 'fan-team-logos') to an
--   object key under {p_team_id}/... . Arbitrary external https URLs are rejected.
--   NULL/empty clears the Team photo.
--
-- Do NOT apply from the agent; review and apply deliberately in Supabase.
-- Apply AFTER 20260926 (fan_teams) and preferably AFTER 20260927 (rate-limit).
-- Requires existing helper: public.gameon_storage_path_from_public_url(text, text)
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Safe UUID parse for storage RLS (never throws on malformed path segments)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gameon_uuid_or_null(p_text text)
RETURNS uuid
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v text := lower(btrim(coalesce(p_text, '')));
BEGIN
  IF v = '' THEN
    RETURN NULL;
  END IF;
  -- Canonical UUID text form only (matches iOS uuidString.lowercased()).
  IF v !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RETURN NULL;
  END IF;
  RETURN v::uuid;
EXCEPTION
  WHEN invalid_text_representation THEN
    RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.gameon_uuid_or_null(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gameon_uuid_or_null(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gameon_uuid_or_null(text) TO service_role;

COMMENT ON FUNCTION public.gameon_uuid_or_null(text) IS
  'Return uuid when input is a canonical UUID string; otherwise NULL (never throws).';

-- ---------------------------------------------------------------------------
-- Team-logo public URL trust check (bucket + team_id folder ownership)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gameon_is_fan_team_logo_public_url(
  p_team_id uuid,
  p_public_url text
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_url text := btrim(coalesce(p_public_url, ''));
  v_path text;
  v_folder text;
  v_object text;
BEGIN
  IF p_team_id IS NULL THEN
    RETURN false;
  END IF;

  -- Empty/NULL means “clear logo” at the RPC layer; this helper is for non-empty URLs.
  IF v_url = '' THEN
    RETURN false;
  END IF;

  IF char_length(v_url) > 2048 THEN
    RETURN false;
  END IF;

  -- Project-proven path extractor: host-agnostic; requires
  -- /storage/v1/object/public/fan-team-logos/{path}
  v_path := public.gameon_storage_path_from_public_url(v_url, 'fan-team-logos');
  IF v_path IS NULL OR v_path = '' THEN
    RETURN false;
  END IF;

  -- Must be exactly {team_id}/{object} (no deeper nesting required; reject empty object).
  v_folder := split_part(v_path, '/', 1);
  v_object := substr(v_path, char_length(v_folder) + 2); -- after "folder/"

  IF public.gameon_uuid_or_null(v_folder) IS DISTINCT FROM p_team_id THEN
    RETURN false;
  END IF;

  IF v_object IS NULL OR btrim(v_object) = '' THEN
    RETURN false;
  END IF;

  -- Reject traversal / absolute leftovers already mostly handled by path helper;
  -- keep a belt-and-suspenders check on the object segment.
  IF v_object LIKE '/%' OR v_object LIKE '%..%' THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.gameon_is_fan_team_logo_public_url(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gameon_is_fan_team_logo_public_url(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gameon_is_fan_team_logo_public_url(uuid, text) TO service_role;

COMMENT ON FUNCTION public.gameon_is_fan_team_logo_public_url(uuid, text) IS
  'True when URL is a FanGeo public Storage URL for fan-team-logos/{team_id}/...';

-- ---------------------------------------------------------------------------
-- Bucket (public read; writes gated by storage.objects policies below)
-- ---------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'fan-team-logos',
  'fan-team-logos',
  true,
  5242880,
  ARRAY['image/jpeg', 'image/jpg', 'image/png', 'image/webp']::text[]
)
ON CONFLICT (id) DO UPDATE
SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS "fan_team_logos_select_public" ON storage.objects;
DROP POLICY IF EXISTS "fan_team_logos_insert_manager" ON storage.objects;
DROP POLICY IF EXISTS "fan_team_logos_update_manager" ON storage.objects;
DROP POLICY IF EXISTS "fan_team_logos_delete_manager" ON storage.objects;

CREATE POLICY "fan_team_logos_select_public"
  ON storage.objects FOR SELECT
  TO public
  USING (bucket_id = 'fan-team-logos');

-- UUID cast is behind gameon_uuid_or_null (NULL on malformed segments).
-- fan_team_viewer_can_manage(NULL) is false via EXISTS, so policy rejects safely.
CREATE POLICY "fan_team_logos_insert_manager"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'fan-team-logos'
    AND public.fan_team_viewer_can_manage(
      public.gameon_uuid_or_null(split_part(name, '/', 1))
    )
  );

CREATE POLICY "fan_team_logos_update_manager"
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'fan-team-logos'
    AND public.fan_team_viewer_can_manage(
      public.gameon_uuid_or_null(split_part(name, '/', 1))
    )
  )
  WITH CHECK (
    bucket_id = 'fan-team-logos'
    AND public.fan_team_viewer_can_manage(
      public.gameon_uuid_or_null(split_part(name, '/', 1))
    )
  );

CREATE POLICY "fan_team_logos_delete_manager"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'fan-team-logos'
    AND public.fan_team_viewer_can_manage(
      public.gameon_uuid_or_null(split_part(name, '/', 1))
    )
  );

-- ---------------------------------------------------------------------------
-- Identity update RPC
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_fan_team_identity(
  p_team_id uuid,
  p_name text,
  p_sport text DEFAULT '',
  p_color_hex text DEFAULT NULL,
  p_logo_url text DEFAULT NULL,
  p_logo_thumbnail_url text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_name text := btrim(coalesce(p_name, ''));
  v_sport text := btrim(coalesce(p_sport, ''));
  v_color text := nullif(btrim(coalesce(p_color_hex, '')), '');
  v_logo text := nullif(btrim(coalesce(p_logo_url, '')), '');
  v_logo_thumb text := nullif(btrim(coalesce(p_logo_thumbnail_url, '')), '');
  v_conversation_id uuid;
  v_prev_name text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  IF p_team_id IS NULL THEN
    RAISE EXCEPTION 'Team is required.';
  END IF;

  IF NOT public.fan_team_viewer_can_manage(p_team_id) THEN
    RAISE EXCEPTION 'Only the team owner or a manager can edit team identity.';
  END IF;

  IF char_length(v_name) < 1 OR char_length(v_name) > 60 THEN
    RAISE EXCEPTION 'Team name must be between 1 and 60 characters.';
  END IF;

  IF char_length(v_sport) > 40 THEN
    RAISE EXCEPTION 'Sport label is too long.';
  END IF;

  IF v_color IS NOT NULL AND v_color !~* '^#?[0-9A-Fa-f]{6}$' THEN
    RAISE EXCEPTION 'Invalid team color.';
  END IF;
  IF v_color IS NOT NULL AND left(v_color, 1) <> '#' THEN
    v_color := '#' || upper(v_color);
  ELSIF v_color IS NOT NULL THEN
    v_color := '#' || upper(substr(v_color, 2));
  END IF;

  -- Clearing full logo also clears thumbnail.
  IF v_logo IS NULL THEN
    v_logo_thumb := NULL;
  END IF;

  -- Trust boundary: only FanGeo Storage public URLs under this team's folder.
  IF v_logo IS NOT NULL
     AND NOT public.gameon_is_fan_team_logo_public_url(p_team_id, v_logo) THEN
    RAISE EXCEPTION 'Invalid team logo URL.';
  END IF;

  IF v_logo_thumb IS NOT NULL
     AND NOT public.gameon_is_fan_team_logo_public_url(p_team_id, v_logo_thumb) THEN
    RAISE EXCEPTION 'Invalid team logo thumbnail URL.';
  END IF;

  SELECT t.group_conversation_id, t.name
  INTO v_conversation_id, v_prev_name
  FROM public.fan_teams t
  WHERE t.id = p_team_id
    AND t.is_active = true;

  IF v_conversation_id IS NULL THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  UPDATE public.fan_teams
  SET
    name = v_name,
    sport = v_sport,
    color_hex = v_color,
    logo_url = v_logo,
    logo_thumbnail_url = v_logo_thumb,
    updated_at = now()
  WHERE id = p_team_id
    AND is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  -- Keep linked Team Chat title aligned with Team name (presentation only).
  IF v_prev_name IS DISTINCT FROM v_name THEN
    UPDATE public.group_conversations
    SET
      title = v_name,
      updated_at = now()
    WHERE id = v_conversation_id;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.update_fan_team_identity(uuid, text, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_fan_team_identity(uuid, text, text, text, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.update_fan_team_identity(uuid, text, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_fan_team_identity(uuid, text, text, text, text, text) TO service_role;

COMMENT ON FUNCTION public.update_fan_team_identity(uuid, text, text, text, text, text) IS
  'Owner/Manager: update Fan Team name, sport, color, and logo URLs. Logo URLs must be fan-team-logos/{team_id}/… public Storage URLs; empty clears the Team photo.';

COMMIT;
