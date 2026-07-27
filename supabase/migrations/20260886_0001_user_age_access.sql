-- =============================================================================
-- 20260886 — Coarse age-access status for FanGeo 13+ policy
-- =============================================================================
--
-- STATUS: PREPARED ONLY — DO NOT APPLY from the agent. Apply manually after
-- review, on STAGING first. Never run supabase db push --linked against
-- production without the staging validation steps in the rollout doc.
--
-- This file has NEVER been applied anywhere (local-only / untracked). It is
-- corrected in place before first apply. Apply order:
--   20260886 → 20260887 → 20260888 → 20260889
--
-- Adds minimal coarse fields on public.user_profiles:
--   age_access_status   text  ('eligible' | 'blocked_under_13' | 'unknown')
--   age_policy_version  text
--   age_checked_at      timestamptz
--
-- Does NOT store:
--   exact date of birth, exact age, full Apple Declared Age Range payload,
--   guardian identity, or verification documents.
--
-- TRUST BOUNDARY (explicit — do not overclaim):
--   Apple Declared Age Range is evaluated on-device by the iOS client. FanGeo's
--   server receives only a client-asserted coarse status via
--   public.record_user_age_access_result(p_status). There is NO cryptographic
--   server-side verification of Apple's response in this design. Residual risk:
--   a modified client could claim 'eligible' while status is still 'unknown'.
--   Mitigations: (1) direct UPDATE of the three age columns is denied for
--   authenticated clients; (2) blocked_under_13 is sticky and cannot be cleared
--   by the client RPC; (3) require_eligible mode + policy-version match deny
--   unresolved/stale users once rollout flips.
--
-- Secure write path:
--   - Direct client UPDATE of age_access_status / age_policy_version /
--     age_checked_at is DENIED (freeze trigger).
--   - Authenticated clients must call
--     public.record_user_age_access_result(p_status text) which binds to
--     auth.uid() only, accepts coarse statuses only, stamps the authoritative
--     policy version + now(), and respects sticky blocked_under_13.
--   - service_role may UPDATE the columns directly (admin recovery / jobs).
--
-- Mode-aware social gate + policy-version matching land in 20260887.
-- =============================================================================

BEGIN;

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.user_profiles') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.user_profiles'];
  END IF;
  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION '20260886 preflight failed; missing: %', array_to_string(v_missing, ', ');
  END IF;
END $$;

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS age_access_status text;

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS age_policy_version text;

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS age_checked_at timestamptz;

UPDATE public.user_profiles
SET age_access_status = 'unknown'
WHERE age_access_status IS NULL
   OR btrim(age_access_status) = '';

ALTER TABLE public.user_profiles
  ALTER COLUMN age_access_status SET DEFAULT 'unknown';

ALTER TABLE public.user_profiles
  ALTER COLUMN age_access_status SET NOT NULL;

ALTER TABLE public.user_profiles
  DROP CONSTRAINT IF EXISTS user_profiles_age_access_status_check;

ALTER TABLE public.user_profiles
  ADD CONSTRAINT user_profiles_age_access_status_check
  CHECK (age_access_status IN ('eligible', 'blocked_under_13', 'unknown'));

COMMENT ON COLUMN public.user_profiles.age_access_status IS
  'Coarse FanGeo 13+ eligibility only: eligible | blocked_under_13 | unknown. Never store DOB/age/range payload. Client writes only via record_user_age_access_result.';

COMMENT ON COLUMN public.user_profiles.age_policy_version IS
  'Authoritative policy version stamped by record_user_age_access_result (not client-supplied).';

COMMENT ON COLUMN public.user_profiles.age_checked_at IS
  'Server timestamp of last coarse age-access status write (set by record_user_age_access_result).';

-- -----------------------------------------------------------------------------
-- Authoritative current policy version (stub; 20260887 reads config table).
-- Matches GameOn/AgeAccessModels.swift AgeAccessPolicy.policyVersion = "1".
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.age_access_current_policy_version()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT '1'::text;
$$;

COMMENT ON FUNCTION public.age_access_current_policy_version() IS
  'Authoritative Declared Age Range policy version. Overridden by 20260887 to read public.age_access_enforcement.current_policy_version.';

REVOKE ALL ON FUNCTION public.age_access_current_policy_version() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.age_access_current_policy_version() TO authenticated;
GRANT EXECUTE ON FUNCTION public.age_access_current_policy_version() TO service_role;

-- -----------------------------------------------------------------------------
-- Temporary allow helper (replaced by mode-aware version in 20260887).
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.age_access_allows_social(p_user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text := coalesce(auth.role(), current_setting('request.jwt.claim.role', true), '');
BEGIN
  IF v_role = 'service_role' THEN
    RETURN true;
  END IF;

  -- Authenticated callers may only inspect themselves (no cross-user probe).
  IF v_role IN ('authenticated', 'anon')
     AND p_user_id IS DISTINCT FROM auth.uid() THEN
    RETURN false;
  END IF;

  IF p_user_id IS NULL THEN
    RETURN false;
  END IF;

  RETURN NOT EXISTS (
    SELECT 1
    FROM public.user_profiles up
    WHERE up.id = p_user_id
      AND coalesce(up.age_access_status, 'unknown') = 'blocked_under_13'
  );
END;
$$;

COMMENT ON FUNCTION public.age_access_allows_social(uuid) IS
  'Temporary (pre-20260887): false when blocked_under_13. Authenticated callers bound to auth.uid().';

REVOKE ALL ON FUNCTION public.age_access_allows_social(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.age_access_allows_social(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.age_access_allows_social(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.assert_age_access_allows_social(p_user_id uuid DEFAULT auth.uid())
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text := coalesce(auth.role(), current_setting('request.jwt.claim.role', true), '');
BEGIN
  IF v_role IN ('authenticated', 'anon')
     AND p_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'age_access_forbidden_cross_user'
      USING ERRCODE = '42501';
  END IF;

  IF NOT public.age_access_allows_social(p_user_id) THEN
    RAISE EXCEPTION 'age_access_blocked_under_13'
      USING ERRCODE = '42501';
  END IF;
END;
$$;

COMMENT ON FUNCTION public.assert_age_access_allows_social(uuid) IS
  'Temporary (pre-20260887): raises if blocked_under_13. Authenticated callers bound to auth.uid().';

REVOKE ALL ON FUNCTION public.assert_age_access_allows_social(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.assert_age_access_allows_social(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.assert_age_access_allows_social(uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- Freeze: authenticated/anon cannot change age columns without GUC bypass.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.enforce_user_profiles_age_access_columns_client_freeze()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text := coalesce(auth.role(), current_setting('request.jwt.claim.role', true), '');
  v_bypass text := nullif(btrim(current_setting('gameon.age_access_write', true)), '');
BEGIN
  IF v_role = 'service_role' THEN
    RETURN NEW;
  END IF;

  IF NEW.age_access_status IS NOT DISTINCT FROM OLD.age_access_status
     AND NEW.age_policy_version IS NOT DISTINCT FROM OLD.age_policy_version
     AND NEW.age_checked_at IS NOT DISTINCT FROM OLD.age_checked_at THEN
    RETURN NEW;
  END IF;

  -- Only the guarded RPC may mutate these columns for authenticated clients.
  IF v_role IN ('authenticated', 'anon')
     AND v_bypass IS NOT NULL
     AND v_bypass = NEW.id::text
     AND NEW.id IS NOT DISTINCT FROM auth.uid() THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'age_access_direct_write_denied'
    USING ERRCODE = '42501',
          HINT = 'Use public.record_user_age_access_result(p_status).';
END;
$$;

COMMENT ON FUNCTION public.enforce_user_profiles_age_access_columns_client_freeze() IS
  'BEFORE UPDATE: denies authenticated/anon writes to age_access_status / age_policy_version / age_checked_at unless gameon.age_access_write GUC matches auth.uid(). service_role unrestricted.';

REVOKE ALL ON FUNCTION public.enforce_user_profiles_age_access_columns_client_freeze() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.enforce_user_profiles_age_access_columns_client_freeze() FROM anon;
REVOKE ALL ON FUNCTION public.enforce_user_profiles_age_access_columns_client_freeze() FROM authenticated;

DROP TRIGGER IF EXISTS trg_user_profiles_age_access_columns_freeze ON public.user_profiles;
CREATE TRIGGER trg_user_profiles_age_access_columns_freeze
  BEFORE UPDATE ON public.user_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_user_profiles_age_access_columns_client_freeze();

-- -----------------------------------------------------------------------------
-- Sticky blocked_under_13 (also enforced inside record_user_age_access_result).
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.enforce_user_profiles_age_access_sticky_block()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text := coalesce(auth.role(), current_setting('request.jwt.claim.role', true), '');
BEGIN
  IF v_role = 'service_role' THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE'
     AND OLD.age_access_status = 'blocked_under_13'
     AND NEW.age_access_status IS DISTINCT FROM 'blocked_under_13' THEN
    RAISE EXCEPTION 'age_access_blocked_status_sticky'
      USING ERRCODE = '42501';
  END IF;

  IF NEW.age_access_status IS NOT NULL
     AND NEW.age_access_status NOT IN ('eligible', 'blocked_under_13', 'unknown') THEN
    RAISE EXCEPTION 'age_access_status_invalid'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_profiles_age_access_sticky ON public.user_profiles;
CREATE TRIGGER trg_user_profiles_age_access_sticky
  BEFORE UPDATE OF age_access_status ON public.user_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_user_profiles_age_access_sticky_block();

-- -----------------------------------------------------------------------------
-- Guarded RPC: record coarse Declared Age Range result for auth.uid() only.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.record_user_age_access_result(p_status text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text := coalesce(auth.role(), current_setting('request.jwt.claim.role', true), '');
  v_status text := lower(btrim(coalesce(p_status, '')));
  v_current text;
  v_policy text;
BEGIN
  -- Clients only. Admin recovery uses service_role direct UPDATE.
  IF v_role = 'service_role' THEN
    RAISE EXCEPTION 'age_access_record_client_only'
      USING ERRCODE = '42501',
            HINT = 'service_role must UPDATE user_profiles age columns directly.';
  END IF;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'age_access_not_authenticated'
      USING ERRCODE = '42501';
  END IF;

  IF v_status NOT IN ('eligible', 'blocked_under_13', 'unknown') THEN
    RAISE EXCEPTION 'age_access_status_invalid'
      USING ERRCODE = '23514';
  END IF;

  v_policy := public.age_access_current_policy_version();

  SELECT up.age_access_status
  INTO v_current
  FROM public.user_profiles up
  WHERE up.id = v_uid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'age_access_profile_missing'
      USING ERRCODE = 'P0002';
  END IF;

  IF v_current = 'blocked_under_13' AND v_status IS DISTINCT FROM 'blocked_under_13' THEN
    RAISE EXCEPTION 'age_access_blocked_status_sticky'
      USING ERRCODE = '42501';
  END IF;

  PERFORM set_config('gameon.age_access_write', v_uid::text, true);

  UPDATE public.user_profiles
  SET
    age_access_status = v_status,
    age_policy_version = v_policy,
    age_checked_at = now()
  WHERE id = v_uid;
END;
$$;

COMMENT ON FUNCTION public.record_user_age_access_result(text) IS
  'Authenticated-only coarse age write for auth.uid(). Accepts eligible|blocked_under_13|unknown; stamps current policy version + now(); sticky blocked_under_13. No DOB/payload. Not cryptographically attested by Apple.';

REVOKE ALL ON FUNCTION public.record_user_age_access_result(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_user_age_access_result(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.record_user_age_access_result(text) TO authenticated;
-- Intentionally NOT granted to service_role (use direct UPDATE for admin recovery).

-- -----------------------------------------------------------------------------
-- Temporary profile social-field lock (expanded + mode-aware in 20260889).
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.enforce_user_profiles_age_access_social_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text := coalesce(auth.role(), current_setting('request.jwt.claim.role', true), '');
BEGIN
  IF v_role = 'service_role' THEN
    RETURN NEW;
  END IF;

  IF coalesce(OLD.age_access_status, 'unknown') <> 'blocked_under_13'
     AND coalesce(NEW.age_access_status, 'unknown') <> 'blocked_under_13' THEN
    RETURN NEW;
  END IF;

  IF NEW.display_name IS NOT DISTINCT FROM OLD.display_name
     AND NEW.username IS NOT DISTINCT FROM OLD.username
     AND NEW.bio IS NOT DISTINCT FROM OLD.bio
     AND NEW.avatar_url IS NOT DISTINCT FROM OLD.avatar_url
     AND NEW.avatar_thumbnail_url IS NOT DISTINCT FROM OLD.avatar_thumbnail_url
  THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'age_access_blocked_under_13'
    USING ERRCODE = '42501';
END;
$$;

DROP TRIGGER IF EXISTS trg_user_profiles_age_access_social_update ON public.user_profiles;
CREATE TRIGGER trg_user_profiles_age_access_social_update
  BEFORE UPDATE ON public.user_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_user_profiles_age_access_social_update();

COMMIT;
