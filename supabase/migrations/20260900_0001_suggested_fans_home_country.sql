-- Batch privacy-safe home countries for Suggested Fans cards.
-- Same public-profile Location gate: show_home_city + non-empty home_city.
-- Returns profile home_country only (never GPS / coarse nearby coords).

CREATE OR REPLACE FUNCTION public.get_profile_friend_suggestion_home_countries(
  p_user_ids uuid[]
)
RETURNS TABLE (
  user_id uuid,
  home_country text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    up.id AS user_id,
    CASE
      WHEN COALESCE(up.show_home_city, false) = true
           AND nullif(trim(coalesce(up.home_city, '')), '') IS NOT NULL
           AND nullif(trim(coalesce(up.home_country, '')), '') IS NOT NULL
      THEN nullif(trim(up.home_country), '')
      ELSE NULL
    END AS home_country
  FROM public.user_profiles up
  WHERE auth.uid() IS NOT NULL
    AND p_user_ids IS NOT NULL
    AND cardinality(p_user_ids) > 0
    AND up.id = ANY (p_user_ids)
    AND COALESCE(up.is_business_account, false) = false
    AND COALESCE(up.is_deleted, false) = false
    AND COALESCE(lower(trim(up.admin_status)), '') = 'active'
    AND up.admin_disabled_at IS NULL;
$$;

REVOKE ALL ON FUNCTION public.get_profile_friend_suggestion_home_countries(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_profile_friend_suggestion_home_countries(uuid[]) TO authenticated;

COMMENT ON FUNCTION public.get_profile_friend_suggestion_home_countries(uuid[]) IS
  'Batch home_country for Suggested Fans. Privacy-gated like public profile Location: returned only when show_home_city=true and home_city is set. Never GPS.';
