-- =============================================================================
-- 20260887 — Age-access server enforcement core (13+ social gate)
-- =============================================================================
--
-- STATUS: PREPARED ONLY — DO NOT APPLY from the agent. Apply manually after
-- review, on STAGING first. Never run supabase db push --linked against
-- production without the staging validation steps in the rollout doc.
--
-- Never applied anywhere — corrected in place before first apply.
-- Depends on: 20260886_0001_user_age_access.sql
-- Apply order: 20260886 → 20260887 → 20260888 → 20260889
--
-- What this adds / replaces:
--   1. public.age_access_enforcement — single-row config:
--        mode                   ('block_under_13_only' | 'require_eligible')
--        current_policy_version (authoritative; default '1')
--   2. public.age_access_current_policy_version() reads the config row.
--   3. Mode-aware + policy-version-aware public.age_access_allows_social(uuid).
--   4. public.assert_age_access_allows_social(uuid) with sentinels:
--         'age_access_blocked_under_13' (ERRCODE 42501)
--         'age_access_unresolved'       (ERRCODE 42501)
--   5. public.enforce_age_access_social_write() trigger body for 20260888.
--
-- require_eligible eligibility rule (single authoritative definition):
--   age_access_status = 'eligible'
--   AND age_policy_version = public.age_access_current_policy_version()
--   AND age_checked_at IS NOT NULL
-- Stale policy version => unresolved (NOT eligible).
--
-- ENFORCEMENT MODES:
--   'block_under_13_only'  (DEFAULT at rollout — TEMPORARY)
--       Only blocked_under_13 denied. unknown/eligible keep working.
--   'require_eligible'     (TARGET / strict)
--       Must satisfy the eligibility rule above. unknown/missing/stale denied.
--
-- REMOVAL PLAN for rollout mode:
--   UPDATE public.age_access_enforcement
--   SET mode = 'require_eligible', updated_at = now()
--   WHERE id = 1;
--
-- Cross-user probing: authenticated/anon may only pass auth.uid() as p_user_id.
-- service_role may inspect any user (jobs / admin).
--
-- ALLOWED FOR BLOCKED / UNRESOLVED (never gated by social triggers):
--   - Own age status read; record_user_age_access_result; sign-out
--   - Account deletion / support / safety reports / blocked_users
--   - DELETE of own social rows (cleanup)
-- =============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regclass('public.user_profiles') IS NULL THEN
    RAISE EXCEPTION '20260887 preflight failed: public.user_profiles missing';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'user_profiles'
      AND column_name = 'age_access_status'
  ) THEN
    RAISE EXCEPTION '20260887 preflight failed: apply 20260886_0001_user_age_access.sql first';
  END IF;
  IF to_regprocedure('public.record_user_age_access_result(text)') IS NULL THEN
    RAISE EXCEPTION '20260887 preflight failed: record_user_age_access_result missing (20260886)';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 1. Enforcement config (mode + authoritative policy version)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.age_access_enforcement (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  mode text NOT NULL DEFAULT 'block_under_13_only'
    CHECK (mode IN ('block_under_13_only', 'require_eligible')),
  current_policy_version text NOT NULL DEFAULT '1',
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Forward-compatible if table already existed without the column.
ALTER TABLE public.age_access_enforcement
  ADD COLUMN IF NOT EXISTS current_policy_version text;

UPDATE public.age_access_enforcement
SET current_policy_version = '1'
WHERE current_policy_version IS NULL OR btrim(current_policy_version) = '';

ALTER TABLE public.age_access_enforcement
  ALTER COLUMN current_policy_version SET DEFAULT '1';

ALTER TABLE public.age_access_enforcement
  ALTER COLUMN current_policy_version SET NOT NULL;

COMMENT ON TABLE public.age_access_enforcement IS
  'Single-row 13+ enforcement switch. mode is TEMPORARY at block_under_13_only; current_policy_version is the authoritative Declared Age Range policy stamp.';

COMMENT ON COLUMN public.age_access_enforcement.current_policy_version IS
  'Authoritative policy version. Must match user_profiles.age_policy_version for require_eligible. Bump deliberately when Apple/FanGeo policy changes.';

INSERT INTO public.age_access_enforcement (id, mode, current_policy_version)
VALUES (1, 'block_under_13_only', '1')
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.age_access_enforcement ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.age_access_enforcement FROM PUBLIC;
REVOKE ALL ON public.age_access_enforcement FROM anon;
REVOKE ALL ON public.age_access_enforcement FROM authenticated;
GRANT SELECT, INSERT, UPDATE ON public.age_access_enforcement TO service_role;

CREATE OR REPLACE FUNCTION public.age_access_enforcement_mode()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (SELECT mode FROM public.age_access_enforcement WHERE id = 1),
    'block_under_13_only'
  );
$$;

REVOKE ALL ON FUNCTION public.age_access_enforcement_mode() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.age_access_enforcement_mode() TO authenticated;
GRANT EXECUTE ON FUNCTION public.age_access_enforcement_mode() TO service_role;

CREATE OR REPLACE FUNCTION public.age_access_current_policy_version()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    nullif(btrim((SELECT current_policy_version FROM public.age_access_enforcement WHERE id = 1)), ''),
    '1'
  );
$$;

COMMENT ON FUNCTION public.age_access_current_policy_version() IS
  'Authoritative Declared Age Range policy version from public.age_access_enforcement.';

REVOKE ALL ON FUNCTION public.age_access_current_policy_version() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.age_access_current_policy_version() TO authenticated;
GRANT EXECUTE ON FUNCTION public.age_access_current_policy_version() TO service_role;

-- -----------------------------------------------------------------------------
-- 2. Mode-aware + policy-version-aware eligibility
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
  v_status text;
  v_policy text;
  v_checked_at timestamptz;
  v_mode text;
  v_current_policy text;
BEGIN
  IF v_role = 'service_role' THEN
    RETURN true;
  END IF;

  -- Clients may only evaluate themselves.
  IF v_role IN ('authenticated', 'anon')
     AND p_user_id IS DISTINCT FROM auth.uid() THEN
    RETURN false;
  END IF;

  IF p_user_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT
    coalesce(up.age_access_status, 'unknown'),
    nullif(btrim(coalesce(up.age_policy_version, '')), ''),
    up.age_checked_at
  INTO v_status, v_policy, v_checked_at
  FROM public.user_profiles up
  WHERE up.id = p_user_id;

  v_mode := public.age_access_enforcement_mode();

  -- No profile row yet.
  IF NOT FOUND THEN
    -- Mid-signup under rollout mode: do not hard-block table triggers.
    -- Strict mode: unresolved.
    RETURN v_mode <> 'require_eligible';
  END IF;

  IF v_status = 'blocked_under_13' THEN
    RETURN false;
  END IF;

  IF v_mode = 'require_eligible' THEN
    v_current_policy := public.age_access_current_policy_version();
    RETURN v_status = 'eligible'
       AND v_policy IS NOT NULL
       AND v_policy = v_current_policy
       AND v_checked_at IS NOT NULL;
  END IF;

  -- block_under_13_only: unknown/eligible allowed (explicit temporary rollout).
  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.age_access_allows_social(uuid) IS
  'Mode-aware 13+ social gate. blocked always denied. require_eligible needs status=eligible AND policy_version=current AND checked_at set. Authenticated callers bound to auth.uid().';

REVOKE ALL ON FUNCTION public.age_access_allows_social(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.age_access_allows_social(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.age_access_allows_social(uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 3. Assertion with consistent client-detectable sentinels
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.assert_age_access_allows_social(p_user_id uuid DEFAULT auth.uid())
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text := coalesce(auth.role(), current_setting('request.jwt.claim.role', true), '');
  v_status text;
BEGIN
  IF v_role IN ('authenticated', 'anon')
     AND p_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'age_access_forbidden_cross_user'
      USING ERRCODE = '42501';
  END IF;

  IF public.age_access_allows_social(p_user_id) THEN
    RETURN;
  END IF;

  SELECT coalesce(up.age_access_status, 'unknown')
  INTO v_status
  FROM public.user_profiles up
  WHERE up.id = p_user_id;

  IF coalesce(v_status, 'unknown') = 'blocked_under_13' THEN
    RAISE EXCEPTION 'age_access_blocked_under_13'
      USING ERRCODE = '42501',
            HINT = 'Social features require age eligibility.';
  END IF;

  -- Includes unknown, missing profile (strict), stale policy, missing checked_at.
  RAISE EXCEPTION 'age_access_unresolved'
    USING ERRCODE = '42501',
          HINT = 'Age eligibility must be confirmed under the current policy version before using social features.';
END;
$$;

COMMENT ON FUNCTION public.assert_age_access_allows_social(uuid) IS
  'Raises age_access_blocked_under_13 / age_access_unresolved (42501). Authenticated callers bound to auth.uid().';

REVOKE ALL ON FUNCTION public.assert_age_access_allows_social(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.assert_age_access_allows_social(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.assert_age_access_allows_social(uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 4. Generic social-write trigger body (attached by 20260888)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.enforce_age_access_social_write()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RETURN NEW;
  END IF;
  IF coalesce(auth.role(), current_setting('request.jwt.claim.role', true), '') = 'service_role' THEN
    RETURN NEW;
  END IF;

  PERFORM public.assert_age_access_allows_social(v_uid);
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.enforce_age_access_social_write() IS
  'BEFORE INSERT/UPDATE trigger body for social tables; attached by 20260888. Raises 42501 sentinels for blocked/unresolved users.';

COMMIT;
