-- Exclusive APNs token ownership: one active (token, environment) → at most one user.
-- Multi-device remains allowed: one user may have many active tokens.
-- Client must call claim_push_token (auth.uid()); never trust client-supplied user_id for ownership.

BEGIN;

-- =============================================================================
-- 1) Cleanup: duplicate active owners for the same token + environment
--    Keep the most recently touched active row; deactivate older conflicts.
-- =============================================================================
WITH ranked AS (
  SELECT
    id,
    row_number() OVER (
      PARTITION BY token, environment
      ORDER BY
        greatest(coalesce(updated_at, created_at), coalesce(last_seen_at, created_at)) DESC,
        created_at DESC,
        id DESC
    ) AS rn
  FROM public.user_push_tokens
  WHERE is_active = true
)
UPDATE public.user_push_tokens t
SET
  is_active = false,
  invalidated_at = coalesce(t.invalidated_at, now()),
  updated_at = now()
FROM ranked r
WHERE t.id = r.id
  AND r.rn > 1;

-- =============================================================================
-- 2) Atomic claim for current auth.uid()
-- =============================================================================
CREATE OR REPLACE FUNCTION public.claim_push_token(
  p_token text,
  p_environment text,
  p_platform text DEFAULT 'ios'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_token text;
  v_env text;
  v_platform text;
  v_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '42501';
  END IF;

  v_token := trim(both FROM coalesce(p_token, ''));
  IF v_token = '' OR char_length(v_token) < 16 THEN
    RAISE EXCEPTION 'invalid_token' USING ERRCODE = '22023';
  END IF;

  v_env := lower(trim(both FROM coalesce(p_environment, '')));
  IF v_env NOT IN ('sandbox', 'production') THEN
    RAISE EXCEPTION 'invalid_environment' USING ERRCODE = '22023';
  END IF;

  v_platform := lower(trim(both FROM coalesce(p_platform, 'ios')));
  IF v_platform <> 'ios' THEN
    RAISE EXCEPTION 'invalid_platform' USING ERRCODE = '22023';
  END IF;

  -- Steal ownership: deactivate any other user's active row for this install token.
  UPDATE public.user_push_tokens
  SET
    is_active = false,
    invalidated_at = coalesce(invalidated_at, now()),
    updated_at = now()
  WHERE token = v_token
    AND environment = v_env
    AND is_active = true
    AND user_id IS DISTINCT FROM v_uid;

  -- Same physical token must not stay active under a mismatched APNs environment for this user.
  UPDATE public.user_push_tokens
  SET
    is_active = false,
    invalidated_at = coalesce(invalidated_at, now()),
    updated_at = now()
  WHERE user_id = v_uid
    AND token = v_token
    AND environment IS DISTINCT FROM v_env
    AND is_active = true;

  INSERT INTO public.user_push_tokens (
    user_id,
    token,
    platform,
    environment,
    is_active,
    invalidated_at,
    last_seen_at
  )
  VALUES (
    v_uid,
    v_token,
    v_platform,
    v_env,
    true,
    NULL,
    now()
  )
  ON CONFLICT (user_id, token, environment)
  DO UPDATE SET
    platform = EXCLUDED.platform,
    is_active = true,
    invalidated_at = NULL,
    last_seen_at = now(),
    updated_at = now()
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.claim_push_token(text, text, text) IS
  'Exclusive APNs token claim for auth.uid(): deactivates other users'' active rows for the same token+environment, then upserts/reactivates the caller''s row. Never accepts user_id from the client.';

REVOKE ALL ON FUNCTION public.claim_push_token(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.claim_push_token(text, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.claim_push_token(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.claim_push_token(text, text, text) TO service_role;

-- =============================================================================
-- 3) Logout: deactivate only this installation token for auth.uid()
-- =============================================================================
CREATE OR REPLACE FUNCTION public.deactivate_current_push_token(
  p_token text,
  p_environment text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_token text;
  v_env text;
  v_updated int := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '42501';
  END IF;

  v_token := trim(both FROM coalesce(p_token, ''));
  IF v_token = '' THEN
    RETURN false;
  END IF;

  v_env := lower(trim(both FROM coalesce(p_environment, '')));
  IF v_env NOT IN ('sandbox', 'production') THEN
    RAISE EXCEPTION 'invalid_environment' USING ERRCODE = '22023';
  END IF;

  UPDATE public.user_push_tokens
  SET
    is_active = false,
    invalidated_at = coalesce(invalidated_at, now()),
    updated_at = now()
  WHERE user_id = v_uid
    AND token = v_token
    AND environment = v_env
    AND is_active = true;

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated > 0;
END;
$$;

COMMENT ON FUNCTION public.deactivate_current_push_token(text, text) IS
  'Deactivates the current installation APNs token for auth.uid() only. Does not touch other devices for the same user.';

REVOKE ALL ON FUNCTION public.deactivate_current_push_token(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.deactivate_current_push_token(text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.deactivate_current_push_token(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.deactivate_current_push_token(text, text) TO service_role;

-- =============================================================================
-- 4) Uniqueness guard: one active owner per token + environment
-- =============================================================================
CREATE UNIQUE INDEX IF NOT EXISTS user_push_tokens_active_token_env_uidx
  ON public.user_push_tokens (token, environment)
  WHERE is_active = true;

COMMENT ON INDEX public.user_push_tokens_active_token_env_uidx IS
  'Ensures a single APNs token string cannot be active for multiple users within the same APNs environment (sandbox|production). Multi-device users keep multiple active tokens.';

COMMIT;

-- =============================================================================
-- PRE-DEPLOYMENT CHECKS (run manually)
-- =============================================================================
-- -- Duplicate active ownership (should be reviewed before apply; migration cleans these):
-- SELECT token, environment, count(*) AS active_owners, array_agg(user_id::text) AS user_ids
-- FROM public.user_push_tokens
-- WHERE is_active = true
-- GROUP BY token, environment
-- HAVING count(*) > 1
-- ORDER BY active_owners DESC;
--
-- SELECT to_regclass('public.user_push_tokens') IS NOT NULL AS tokens_table_ready;
-- SELECT EXISTS (
--   SELECT 1 FROM pg_constraint
--   WHERE conname = 'user_push_tokens_user_token_env_unique'
-- ) AS legacy_per_user_unique_ready;
--
-- POST-DEPLOYMENT CHECKS (run manually)
-- =============================================================================
-- SELECT to_regprocedure('public.claim_push_token(text, text, text)') IS NOT NULL;
-- SELECT to_regprocedure('public.deactivate_current_push_token(text, text)') IS NOT NULL;
-- SELECT indexname FROM pg_indexes
--  WHERE schemaname = 'public' AND indexname = 'user_push_tokens_active_token_env_uidx';
--
-- -- Must return 0 rows:
-- SELECT token, environment, count(*) AS active_owners
-- FROM public.user_push_tokens
-- WHERE is_active = true
-- GROUP BY token, environment
-- HAVING count(*) > 1;
--
-- -- Spot-check known duplicate pattern (parameterize; do not hard-code in migrations):
-- -- SELECT user_id, is_active, environment, updated_at, last_seen_at
-- -- FROM public.user_push_tokens
-- -- WHERE token = :token
-- -- ORDER BY is_active DESC, updated_at DESC;
-- =============================================================================
