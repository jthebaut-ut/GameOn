-- Authoritative business lifecycle lookup for authenticated clients.
-- SECURITY DEFINER bypasses businesses RLS that hides is_deleted tombstones from SELECT.
-- Does not weaken fan deletion, business deletion jobs, or broad RLS.

CREATE OR REPLACE FUNCTION public.get_my_business_lifecycle_state()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_email text := lower(btrim(coalesce(auth.jwt() ->> 'email', '')));
  v_row public.businesses%ROWTYPE;
  v_lifecycle text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated'
      USING ERRCODE = '28000';
  END IF;

  IF v_email = '' THEN
    SELECT lower(btrim(coalesce(u.email, '')))
      INTO v_email
    FROM auth.users u
    WHERE u.id = v_uid;
  END IF;

  SELECT b.*
    INTO v_row
  FROM public.businesses b
  WHERE b.owner_user_id = v_uid
    AND lower(btrim(coalesce(b.business_origin, 'owned_account'))) IN ('owned_account', 'claimed_community')
  ORDER BY b.created_at DESC
  LIMIT 1;

  IF NOT FOUND AND v_email <> '' THEN
    SELECT b.*
      INTO v_row
    FROM public.businesses b
    WHERE lower(btrim(coalesce(b.owner_email, ''))) = v_email
      AND lower(btrim(coalesce(b.business_origin, 'owned_account'))) IN ('owned_account', 'claimed_community')
    ORDER BY b.created_at DESC
  LIMIT 1;
  END IF;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'business_id', NULL,
      'lifecycle_state', 'missing',
      'is_deleted', false,
      'deleted_at', NULL,
      'anonymized_at', NULL,
      'deletion_requested_at', NULL,
      'admin_status', NULL
    );
  END IF;

  IF coalesce(v_row.is_deleted, false)
     OR v_row.deleted_at IS NOT NULL
     OR v_row.anonymized_at IS NOT NULL
     OR lower(btrim(coalesce(v_row.owner_email, ''))) LIKE '%@deleted.fangeo.local'
  THEN
    v_lifecycle := 'deleted';
  ELSE
    v_lifecycle := CASE lower(btrim(coalesce(v_row.admin_status, '')))
      WHEN 'active' THEN 'active'
      WHEN 'archived' THEN 'archived'
      WHEN 'disabled' THEN 'disabled'
      ELSE 'unknown'
    END;
  END IF;

  RETURN jsonb_build_object(
    'business_id', v_row.id,
    'lifecycle_state', v_lifecycle,
    'is_deleted', coalesce(v_row.is_deleted, false),
    'deleted_at', v_row.deleted_at,
    'anonymized_at', v_row.anonymized_at,
    'deletion_requested_at', v_row.deletion_requested_at,
    'admin_status', v_row.admin_status
  );
END;
$$;

COMMENT ON FUNCTION public.get_my_business_lifecycle_state() IS
  'Returns lifecycle-safe business tombstone state for auth.uid(). Used by iOS deleted-business login gate.';

-- Supabase default ACLs grant EXECUTE to anon directly (not only via PUBLIC).
-- REVOKE FROM PUBLIC alone leaves anon able to call the RPC at the PostgREST layer.
REVOKE ALL ON FUNCTION public.get_my_business_lifecycle_state() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_business_lifecycle_state() FROM anon;
REVOKE ALL ON FUNCTION public.get_my_business_lifecycle_state() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_business_lifecycle_state() TO authenticated;

DO $$
BEGIN
  IF to_regprocedure('public.get_my_business_lifecycle_state()') IS NULL THEN
    RAISE EXCEPTION 'Integrity fail: get_my_business_lifecycle_state missing';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.get_my_business_lifecycle_state()', 'EXECUTE') THEN
    RAISE EXCEPTION 'Integrity fail: authenticated cannot EXECUTE get_my_business_lifecycle_state';
  END IF;

  IF has_function_privilege('anon', 'public.get_my_business_lifecycle_state()', 'EXECUTE') THEN
    RAISE WARNING 'Notice: anon still has EXECUTE on get_my_business_lifecycle_state after explicit REVOKE; RPC remains auth-gated via auth.uid() inside SECURITY DEFINER body';
  ELSE
    RAISE NOTICE 'PASS: anon cannot EXECUTE get_my_business_lifecycle_state';
  END IF;

  RAISE NOTICE 'PASS: get_my_business_lifecycle_state present and executable by authenticated';
END;
$$;

-- Post-apply verification (run manually after migration succeeds):
--
-- 1) Function exists
-- SELECT to_regprocedure('public.get_my_business_lifecycle_state()');
--
-- 2) Privileges (authenticated yes, anon ideally no)
-- SELECT
--   has_function_privilege('authenticated', 'public.get_my_business_lifecycle_state()', 'EXECUTE') AS authenticated_can_execute,
--   has_function_privilege('anon', 'public.get_my_business_lifecycle_state()', 'EXECUTE') AS anon_can_execute;
--
-- 3) ACL detail
-- SELECT grantee, privilege_type
-- FROM aclexplode((SELECT proacl FROM pg_proc WHERE proname = 'get_my_business_lifecycle_state' AND pronamespace = 'public'::regnamespace)) acl
-- JOIN pg_roles r ON r.oid = acl.grantee
-- ORDER BY grantee::text, privilege_type;
--
-- 4) Authenticated smoke (requires a signed-in JWT in SQL editor or app)
-- SELECT public.get_my_business_lifecycle_state();
