-- =============================================================================
-- 20260884 — Optional catalog national-team ID (independent of My Team)
-- =============================================================================
--
-- STATUS: PREPARED ONLY — DO NOT APPLY until product ships catalog-based
-- national-team selection in the iOS client.
--
-- Context:
--   FanGeo already persists a country-level national identity on user_profiles:
--     national_team_country_code / name / flag / supporter_label / updated_at
--   That selection is independent of My Team (user_favorite_teams.is_primary).
--
--   Sport-specific national subtitles (e.g. "National Soccer Team" for France
--   while My Team is Lakers basketball) require a catalog national-team entry
--   that embeds both country and sport. Prefer one nullable catalog ID over
--   inventing separate country+sport columns.
--
-- This migration adds:
--   user_profiles.national_team_favorite_team_id text NULL
--
-- Rules:
--   - Independent of primary favorite / My Team
--   - Nullable (no selection → neutral country identity only)
--   - Owner writes only via existing user_profiles RLS (auth.uid() = id)
--   - Does not alter My Team / favorite-team tables
--   - Does not change public profile RPC bodies in this file (wire-up is a
--     deliberate follow-up once client selection ships)
--
-- Rollback: DROP COLUMN national_team_favorite_team_id
-- =============================================================================

BEGIN;

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS national_team_favorite_team_id text;

COMMENT ON COLUMN public.user_profiles.national_team_favorite_team_id IS
  'Optional favorite-team catalog ID for the user-selected national team (country+sport). Independent of My Team / is_primary. Nullable.';

-- Soft validation: empty string → NULL; reject whitespace-only.
CREATE OR REPLACE FUNCTION public.normalize_national_team_favorite_team_id()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.national_team_favorite_team_id IS NOT NULL THEN
    NEW.national_team_favorite_team_id := nullif(btrim(NEW.national_team_favorite_team_id), '');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_normalize_national_team_favorite_team_id ON public.user_profiles;
CREATE TRIGGER trg_normalize_national_team_favorite_team_id
  BEFORE INSERT OR UPDATE OF national_team_favorite_team_id
  ON public.user_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.normalize_national_team_favorite_team_id();

COMMIT;

-- =============================================================================
-- ROLLBACK (manual; do not run with apply)
-- =============================================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS trg_normalize_national_team_favorite_team_id ON public.user_profiles;
-- DROP FUNCTION IF EXISTS public.normalize_national_team_favorite_team_id();
-- ALTER TABLE public.user_profiles DROP COLUMN IF EXISTS national_team_favorite_team_id;
-- COMMIT;
