-- Discover global search: privacy-safe fan lookup by display name / handle.
-- Includes accepted-friend exception when discoverable_by_fans = false
-- (matches get_public_fan_identity_profile).
-- Suggested Fans / Nearby remain discoverable-only.
-- Local migration only — do not apply remotely unless explicitly authorized.

CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA extensions;

CREATE OR REPLACE FUNCTION public.search_discoverable_fans(
  p_query text,
  p_limit int DEFAULT 10
)
RETURNS TABLE (
  user_id uuid,
  display_name text,
  handle text,
  avatar_url text,
  is_friend boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  me uuid := auth.uid();
  q text := lower(btrim(coalesce(p_query, '')));
  handle_q text;
  lim int := least(greatest(coalesce(p_limit, 10), 1), 20);
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  -- Normalize the query for display-name comparisons:
  -- trim, remove leading @, collapse whitespace, and ignore common accents.
  q := regexp_replace(q, '^@+', '');
  q := regexp_replace(q, '\s+', ' ', 'g');
  q := extensions.unaccent(q);

  IF length(q) < 2 THEN
    RETURN;
  END IF;

  -- Preserve the existing handle normalization behavior.
  handle_q := public.fangeo_normalize_handle(q);

  RETURN QUERY
  WITH normalized_profiles AS (
    SELECT
      up.*,
      nullif(
        regexp_replace(
          lower(btrim(coalesce(up.display_name, ''))),
          '\s+',
          ' ',
          'g'
        ),
        ''
      ) AS normalized_display_name,
      nullif(
        public.fangeo_normalize_handle(coalesce(up.handle, up.username)),
        ''
      ) AS normalized_handle
    FROM public.user_profiles up
  ),
  candidates AS (
    SELECT
      up.id,
      nullif(btrim(coalesce(up.display_name, '')), '') AS safe_display_name,
      up.normalized_handle AS safe_handle,
      nullif(
        btrim(coalesce(up.avatar_thumbnail_url, up.avatar_url, '')),
        ''
      ) AS safe_avatar_url,
      EXISTS (
        SELECT 1
        FROM public.friendships f
        WHERE f.status = 'accepted'
          AND coalesce(f.requester_entity_type, 'user') = 'user'
          AND coalesce(f.addressee_entity_type, 'user') = 'user'
          AND (
            (f.requester_id = me AND f.addressee_id = up.id)
            OR
            (f.requester_id = up.id AND f.addressee_id = me)
          )
      ) AS friend_match,
      CASE
        WHEN handle_q IS NOT NULL
          AND up.normalized_handle = handle_q
          THEN 0

        WHEN handle_q IS NOT NULL
          AND up.normalized_handle LIKE handle_q || '%'
          THEN 1

        WHEN extensions.unaccent(up.normalized_display_name) = q
          THEN 2

        WHEN extensions.unaccent(up.normalized_display_name) LIKE q || '%'
          THEN 3

        WHEN handle_q IS NOT NULL
          AND up.normalized_handle LIKE '%' || handle_q || '%'
          THEN 4

        ELSE 5
      END AS rank_order
    FROM normalized_profiles up
    WHERE up.id <> me
      AND coalesce(lower(trim(up.admin_status)), 'active') = 'active'
      AND up.admin_disabled_at IS NULL
      AND coalesce(up.is_deleted, false) = false
      AND coalesce(up.is_business_account, false) = false
      AND NOT lower(trim(coalesce(up.email, '')))
        LIKE '%@deleted.fangeo.local'

      AND NOT EXISTS (
        SELECT 1
        FROM public.user_bans ub
        WHERE ub.user_id = up.id
          AND public.is_user_ban_active(
            ub.expires_at,
            ub.lifted_at
          )
      )

      AND public.pickup_invite_users_are_unblocked(me, up.id)

      AND (
        coalesce(up.discoverable_by_fans, true) = true
        OR public.pickup_invite_users_are_friends(me, up.id)
      )

      AND (
        (
          handle_q IS NOT NULL
          AND up.normalized_handle LIKE '%' || handle_q || '%'
        )
        OR extensions.unaccent(up.normalized_display_name)
          LIKE '%' || q || '%'
      )
  )
  SELECT
    c.id AS user_id,
    coalesce(c.safe_display_name, c.safe_handle, 'Fan') AS display_name,
    c.safe_handle AS handle,
    c.safe_avatar_url AS avatar_url,
    c.friend_match AS is_friend
  FROM candidates c
  ORDER BY
    c.rank_order ASC,
    lower(
      coalesce(c.safe_display_name, c.safe_handle, 'fan')
    ) ASC,
    coalesce(c.safe_handle, '') ASC,
    c.id ASC
  LIMIT lim;
END;
$$;

REVOKE ALL
ON FUNCTION public.search_discoverable_fans(text, int)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION public.search_discoverable_fans(text, int)
TO authenticated;

COMMENT ON FUNCTION public.search_discoverable_fans(text, int) IS
  'Discover search: authenticated privacy-safe fan lookup by handle/display name. Excludes self, blocked, banned, deleted, disabled, and business accounts. Strangers require discoverable_by_fans; accepted friends remain searchable when Discovery is OFF.';