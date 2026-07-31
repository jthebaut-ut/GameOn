-- MANUAL recovery for fan account_deletion_jobs stuck after DB commit.
-- DO NOT run blindly against production without review.
-- Prerequisites:
--   1) Deploy updated finalize-account-deletion Edge Function
--   2) Optionally apply 20260899_0001_account_deletion_finalize_attempt_tracking.sql
-- This script only RESUMES finalization (queue Edge). It never re-runs DB cleanup.
--
-- Eligible jobs:
--   status IN ('db_committed', 'storage_pending')
--   soft deletion already committed (profiles anonymized)
--
-- Existing Admin UI path (preferred for one-off):
--   Deleted Accounts → job → "Retry finalization"
--   → queue_account_deletion_finalize(job_id)
--
-- Bulk resume (service_role / SQL editor):

-- 1) Inventory (read-only)
SELECT
  j.id AS job_id,
  j.subject_user_id,
  j.status,
  j.stage,
  j.request_source,
  j.created_at,
  j.updated_at,
  coalesce(cardinality(j.avatar_storage_paths), 0) AS avatar_path_count,
  j.error_code,
  left(coalesce(j.error_detail, ''), 200) AS error_detail,
  up.is_deleted,
  up.anonymized_at IS NOT NULL AS profile_anonymized
FROM public.account_deletion_jobs j
LEFT JOIN public.user_profiles up ON up.id = j.subject_user_id
WHERE j.status IN ('db_committed', 'storage_pending')
ORDER BY j.updated_at DESC;

-- 2) Resume ONE job (replace uuid):
-- SELECT public.queue_account_deletion_finalize('xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'::uuid);

-- 3) Resume ALL currently stuck jobs (review inventory first):
-- DO $$
-- DECLARE
--   r record;
--   v_result jsonb;
-- BEGIN
--   FOR r IN
--     SELECT id
--     FROM public.account_deletion_jobs
--     WHERE status IN ('db_committed', 'storage_pending')
--     ORDER BY updated_at ASC
--   LOOP
--     v_result := public.queue_account_deletion_finalize(r.id);
--     RAISE NOTICE 'queued job=% result=%', r.id, v_result;
--   END LOOP;
-- END;
-- $$;

-- 4) Verify:
-- SELECT status, stage, count(*)
-- FROM public.account_deletion_jobs
-- GROUP BY 1, 2
-- ORDER BY 1, 2;
--
-- Expected after successful finalize:
--   status=completed, stage=completed
--
-- Notes:
-- - Zero avatar_storage_paths jobs should complete idempotently after Edge fix.
-- - Missing storage objects are treated as success by the Edge Function.
-- - Jobs with remaining avatar objects should delete only subject-owned paths.
-- - If queue returns skipped_pg_net_unavailable / skipped_missing_secrets,
--   invoke Edge directly with service-role bearer instead of pg_net.
