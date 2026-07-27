-- =============================================================================
-- 20260889 — Mode-aware profile social-field lock
-- =============================================================================
--
-- STATUS: PREPARED ONLY — DO NOT APPLY from the agent. Apply on STAGING after
-- 20260886 / 20260887 / 20260888. Never applied anywhere — corrected in place.
--
-- Replaces public.enforce_user_profiles_age_access_social_update so that:
--   - Age-column-only updates (via record_user_age_access_result GUC) always
--     pass, including first blocked write / sticky reaffirm.
--   - Any social-facing profile mutation calls the SAME central assertion as
--     other social tables: public.assert_age_access_allows_social(auth.uid()).
--   - In require_eligible mode, unknown / missing / stale-policy users cannot
--     edit social-facing profile fields (not only blocked_under_13).
--   - service_role is unrestricted (admin recovery / jobs).
--
-- Social-facing columns covered (jsonb ? so older schemas without a column
-- are ignored safely):
--   display_name, username, bio, avatar_url, avatar_thumbnail_url,
--   home_crowd_venue_id, national_team_id, national_team_favorite_team_id,
--   profile_background_key, activity_status_visible
--
-- Legally required / account-management fields (deletion flags, admin, etc.)
-- are NOT listed here; they remain under privileged-column protection and
-- dedicated RPCs, and are not age-gated.
-- =============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regprocedure('public.assert_age_access_allows_social(uuid)') IS NULL THEN
    RAISE EXCEPTION '20260889 preflight failed: apply 20260887 first (assert_age_access_allows_social)';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.enforce_user_profiles_age_access_social_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text := coalesce(auth.role(), current_setting('request.jwt.claim.role', true), '');
  v_social_changed boolean := false;
BEGIN
  IF v_role = 'service_role' THEN
    RETURN NEW;
  END IF;

  -- Detect social-facing mutations (ignore missing columns via jsonb ?).
  IF NEW.display_name IS DISTINCT FROM OLD.display_name
     OR NEW.username IS DISTINCT FROM OLD.username
     OR NEW.bio IS DISTINCT FROM OLD.bio
     OR NEW.avatar_url IS DISTINCT FROM OLD.avatar_url
     OR NEW.avatar_thumbnail_url IS DISTINCT FROM OLD.avatar_thumbnail_url
     OR (
       (to_jsonb(NEW) ? 'home_crowd_venue_id')
       AND (to_jsonb(NEW) -> 'home_crowd_venue_id')
           IS DISTINCT FROM (to_jsonb(OLD) -> 'home_crowd_venue_id')
     )
     OR (
       (to_jsonb(NEW) ? 'national_team_id')
       AND (to_jsonb(NEW) -> 'national_team_id')
           IS DISTINCT FROM (to_jsonb(OLD) -> 'national_team_id')
     )
     OR (
       (to_jsonb(NEW) ? 'national_team_favorite_team_id')
       AND (to_jsonb(NEW) -> 'national_team_favorite_team_id')
           IS DISTINCT FROM (to_jsonb(OLD) -> 'national_team_favorite_team_id')
     )
     OR (
       (to_jsonb(NEW) ? 'profile_background_key')
       AND (to_jsonb(NEW) -> 'profile_background_key')
           IS DISTINCT FROM (to_jsonb(OLD) -> 'profile_background_key')
     )
     OR (
       (to_jsonb(NEW) ? 'activity_status_visible')
       AND (to_jsonb(NEW) -> 'activity_status_visible')
           IS DISTINCT FROM (to_jsonb(OLD) -> 'activity_status_visible')
     )
  THEN
    v_social_changed := true;
  END IF;

  -- Age-column-only writes (record_user_age_access_result) must always pass,
  -- including for blocked users receiving their first blocked stamp.
  IF NOT v_social_changed THEN
    RETURN NEW;
  END IF;

  -- Social personalization uses the same central mode-aware rule as other
  -- social tables (blocked always; unknown/stale denied in require_eligible).
  PERFORM public.assert_age_access_allows_social(auth.uid());
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.enforce_user_profiles_age_access_social_update() IS
  'BEFORE UPDATE on user_profiles: age-only writes pass; social-facing field changes require assert_age_access_allows_social(auth.uid()). Mode-aware (blocked + require_eligible unresolved/stale). service_role unrestricted.';

-- Ensure trigger exists (created in 20260886; recreate for safety).
DROP TRIGGER IF EXISTS trg_user_profiles_age_access_social_update ON public.user_profiles;
CREATE TRIGGER trg_user_profiles_age_access_social_update
  BEFORE UPDATE ON public.user_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_user_profiles_age_access_social_update();

COMMIT;
