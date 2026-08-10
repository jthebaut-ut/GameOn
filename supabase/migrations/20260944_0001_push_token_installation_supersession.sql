-- =============================================================================
-- 20260944_0001 — APNs token installation supersession
-- =============================================================================
-- Production evidence:
--   Push workers can mark deliveries sent (APNs HTTP 200) while the recipient
--   sees nothing, because an OLDER active sandbox token remains the sole active
--   destination after APNs rotated the install token. claim_push_token activated
--   the new token but never deactivated the prior token string for that install.
--
-- Fix:
--   • Add installation_id (stable per app install) on user_push_tokens
--   • claim_push_token(..., p_installation_id) supersedes OTHER active tokens for
--     the same (user_id, installation_id, environment)
--   • Other installations (other phones/tablets) keep their active tokens
--
-- Multi-device: preserved (different installation_id).
-- Account switch: still steals (token, environment) ownership for auth.uid().
--
-- Do NOT apply from the agent. Apply manually after 20260943.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Column
-- ---------------------------------------------------------------------------
ALTER TABLE public.user_push_tokens
  ADD COLUMN IF NOT EXISTS installation_id uuid;

COMMENT ON COLUMN public.user_push_tokens.installation_id IS
  'Stable per-app-install identifier from the client. Used to supersede rotated '
  'APNs tokens for the same install without deactivating other devices.';

CREATE INDEX IF NOT EXISTS user_push_tokens_user_install_env_active_idx
  ON public.user_push_tokens (user_id, installation_id, environment)
  WHERE is_active = true AND installation_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2) claim_push_token — optional installation_id supersession
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.claim_push_token(text, text, text);
DROP FUNCTION IF EXISTS public.claim_push_token(text, text, text, uuid);

CREATE FUNCTION public.claim_push_token(
  p_token text,
  p_environment text,
  p_platform text DEFAULT 'ios',
  p_installation_id uuid DEFAULT NULL
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
  v_install uuid := p_installation_id;
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

  -- Steal ownership: deactivate any other user's active row for this token+env.
  UPDATE public.user_push_tokens
  SET
    is_active = false,
    invalidated_at = coalesce(invalidated_at, now()),
    updated_at = now()
  WHERE token = v_token
    AND environment = v_env
    AND is_active = true
    AND user_id IS DISTINCT FROM v_uid;

  -- Same physical token must not stay active under a mismatched environment.
  UPDATE public.user_push_tokens
  SET
    is_active = false,
    invalidated_at = coalesce(invalidated_at, now()),
    updated_at = now()
  WHERE user_id = v_uid
    AND token = v_token
    AND environment IS DISTINCT FROM v_env
    AND is_active = true;

  -- Same install + environment: supersede rotated prior APNs token strings.
  -- Does NOT touch other devices (different non-null installation_id).
  IF v_install IS NOT NULL THEN
    UPDATE public.user_push_tokens
    SET
      is_active = false,
      invalidated_at = coalesce(invalidated_at, now()),
      updated_at = now()
    WHERE user_id = v_uid
      AND installation_id = v_install
      AND environment = v_env
      AND token IS DISTINCT FROM v_token
      AND is_active = true;

    -- Legacy rows (pre-installation_id): cannot be attributed to another upgraded
    -- device. Supersede them for this user+env so a stale rotated sandbox token
    -- cannot remain the sole active destination. Other devices that already have
    -- their own installation_id are preserved; not-yet-upgraded second devices
    -- re-claim on next app open.
    UPDATE public.user_push_tokens
    SET
      is_active = false,
      invalidated_at = coalesce(invalidated_at, now()),
      updated_at = now()
    WHERE user_id = v_uid
      AND installation_id IS NULL
      AND environment = v_env
      AND token IS DISTINCT FROM v_token
      AND is_active = true;
  END IF;

  INSERT INTO public.user_push_tokens (
    user_id,
    token,
    platform,
    environment,
    installation_id,
    is_active,
    invalidated_at,
    last_seen_at
  )
  VALUES (
    v_uid,
    v_token,
    v_platform,
    v_env,
    v_install,
    true,
    NULL,
    now()
  )
  ON CONFLICT (user_id, token, environment)
  DO UPDATE SET
    platform = EXCLUDED.platform,
    installation_id = coalesce(EXCLUDED.installation_id, public.user_push_tokens.installation_id),
    is_active = true,
    invalidated_at = NULL,
    last_seen_at = now(),
    updated_at = now()
  RETURNING id INTO v_id;

  -- After upsert/reactivation, ensure this install+env has only this token active
  -- (and legacy NULL installation_id siblings for this env remain superseded).
  IF v_install IS NOT NULL THEN
    UPDATE public.user_push_tokens
    SET
      is_active = false,
      invalidated_at = coalesce(invalidated_at, now()),
      updated_at = now()
    WHERE user_id = v_uid
      AND environment = v_env
      AND token IS DISTINCT FROM v_token
      AND is_active = true
      AND (
        installation_id = v_install
        OR installation_id IS NULL
      );
  END IF;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.claim_push_token(text, text, text, uuid) IS
  'Exclusive APNs token claim for auth.uid(). Steals (token,environment) from other '
  'users, upserts/reactivates caller row, and when p_installation_id is set supersedes '
  'other active tokens for the same user+installation+environment (token rotation). '
  'Multi-device: other installation_id rows remain active.';

REVOKE ALL ON FUNCTION public.claim_push_token(text, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.claim_push_token(text, text, text, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.claim_push_token(text, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.claim_push_token(text, text, text, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Logout / rotate: deactivate current token (+ optional install-wide)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.deactivate_current_push_token(text, text);
DROP FUNCTION IF EXISTS public.deactivate_current_push_token(text, text, uuid);

CREATE FUNCTION public.deactivate_current_push_token(
  p_token text,
  p_environment text,
  p_installation_id uuid DEFAULT NULL
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
  v_count int := 0;
  v_n int := 0;
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

  IF p_installation_id IS NOT NULL THEN
    UPDATE public.user_push_tokens
    SET
      is_active = false,
      invalidated_at = coalesce(invalidated_at, now()),
      updated_at = now()
    WHERE user_id = v_uid
      AND installation_id = p_installation_id
      AND environment = v_env
      AND is_active = true;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_count := v_count + v_n;
  END IF;

  -- Explicit token (covers legacy rows with NULL installation_id).
  UPDATE public.user_push_tokens
  SET
    is_active = false,
    invalidated_at = coalesce(invalidated_at, now()),
    updated_at = now()
  WHERE user_id = v_uid
    AND token = v_token
    AND environment = v_env
    AND is_active = true;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_count := v_count + v_n;

  RETURN v_count > 0;
END;
$$;

COMMENT ON FUNCTION public.deactivate_current_push_token(text, text, uuid) IS
  'Deactivates the current installation APNs token(s) for auth.uid(). When '
  'p_installation_id is set, deactivates all active tokens for that install+env, '
  'plus the explicit token row. Other devices untouched.';

REVOKE ALL ON FUNCTION public.deactivate_current_push_token(text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.deactivate_current_push_token(text, text, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.deactivate_current_push_token(text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.deactivate_current_push_token(text, text, uuid) TO service_role;

COMMIT;

-- Manual verification (do not run from agent):
--   SELECT column_name FROM information_schema.columns
--   WHERE table_name='user_push_tokens' AND column_name='installation_id';
--   SELECT proname, oidvectortypes(proargtypes)
--   FROM pg_proc WHERE proname IN ('claim_push_token','deactivate_current_push_token');
