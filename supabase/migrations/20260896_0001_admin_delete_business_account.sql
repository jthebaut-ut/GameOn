-- SUPERSEDED — do not use as the permanent Admin "Delete Business Account" path.
--
-- 20260896 originally shipped a SOFT-ONLY admin business deletion
-- (business tombstone + venue/claim cleanup + storage finalize) that
-- intentionally preserved auth.users and public.account_identities so the
-- account stayed reactivatable.
--
-- FanGeo Admin now requires PERMANENT, non-reactivatable business account
-- deletion (business tombstone + owner ownership detach + fan-side user
-- cleanup + account_identities retirement + Auth delete + storage cleanup).
-- That is implemented by:
--
--   20260898_0001_admin_permanent_delete_business_account.sql
--   (apply 20260897_0001_fix_account_deletion_pickup_request_cleanup.sql first)
--
-- This file is reduced to a stub that removes the soft-only admin RPCs so the
-- two names cannot be called with the old semantics. 20260898 recreates both
-- names with permanent semantics, and also re-applies the
-- gameon_business_deletion_assert_owner / gameon_business_deletion_soft_delete_core
-- service_role patches that used to live here.
--
-- Forward-only. PREPARED ONLY — manual apply.

DROP FUNCTION IF EXISTS public.admin_delete_business_account_eligibility(uuid);
DROP FUNCTION IF EXISTS public.admin_delete_business_account(uuid, text, text, text, boolean);

DO $$
BEGIN
  RAISE NOTICE 'SUPERSEDED: 20260896 soft-only admin business deletion RPCs dropped.';
  RAISE NOTICE 'Permanent Admin Delete Business Account path = 20260898_0001_admin_permanent_delete_business_account.sql (requires 20260897 applied first).';
END;
$$;
