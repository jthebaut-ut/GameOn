-- =============================================================================
-- 20260879 — Activity status privacy + visible last_seen helper for public profiles
-- =============================================================================
--
-- Adds:
--   user_profiles.activity_status_visible (default true)
--   get_visible_activity_last_seen(uuid) — returns last_seen_at only when:
--     authenticated viewer, target allows activity status, neither side blocked
--
-- Does NOT clear last_seen_at when privacy is off (operational metrics continue).
-- Do NOT apply from the agent against the linked (production) project.
-- =============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regclass('public.user_profiles') IS NULL THEN
    RAISE EXCEPTION 'preflight failed: public.user_profiles missing';
  END IF;
END;
$$;

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS activity_status_visible boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.user_profiles.activity_status_visible IS
  'When false, other users must not receive last_seen_at for activity UI. Heartbeats may still update last_seen_at for operational metrics.';

CREATE OR REPLACE FUNCTION public.get_visible_activity_last_seen(p_user_id uuid)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_visible boolean;
  v_last timestamptz;
  v_blocked boolean := false;
BEGIN
  IF me IS NULL OR p_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  -- Self may always read own last_seen_at for settings/debug surfaces.
  IF me = p_user_id THEN
    SELECT up.last_seen_at
    INTO v_last
    FROM public.user_profiles up
    WHERE up.id = p_user_id;
    RETURN v_last;
  END IF;

  SELECT
    COALESCE(up.activity_status_visible, true),
    up.last_seen_at
  INTO v_visible, v_last
  FROM public.user_profiles up
  WHERE up.id = p_user_id
    AND COALESCE(up.is_deleted, false) = false;

  IF NOT FOUND OR v_visible IS NOT TRUE THEN
    RETURN NULL;
  END IF;

  IF to_regclass('public.blocked_users') IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.blocked_users b
      WHERE (b.blocker_user_id = me AND b.blocked_user_id = p_user_id)
         OR (b.blocker_user_id = p_user_id AND b.blocked_user_id = me)
    ) INTO v_blocked;
  END IF;

  IF v_blocked THEN
    RETURN NULL;
  END IF;

  RETURN v_last;
END;
$$;

COMMENT ON FUNCTION public.get_visible_activity_last_seen(uuid) IS
  'Returns target last_seen_at for activity UI only when activity_status_visible and not blocked; null otherwise.';

REVOKE ALL ON FUNCTION public.get_visible_activity_last_seen(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_visible_activity_last_seen(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_visible_activity_last_seen(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_visible_activity_last_seen(uuid) TO service_role;

COMMIT;

-- Post-apply (SELECT only):
-- SELECT column_name FROM information_schema.columns
--  WHERE table_schema='public' AND table_name='user_profiles' AND column_name='activity_status_visible';
-- SELECT has_function_privilege('anon','public.get_visible_activity_last_seen(uuid)'::regprocedure,'EXECUTE');
-- -- expect false
