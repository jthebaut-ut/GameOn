-- Preflight for 20260892 — run before applying the migration.
-- Expect: featured_promotion_library exists; discovery columns/tables may be absent.

SELECT
  to_regclass('public.featured_promotion_library') IS NOT NULL AS library_exists,
  to_regclass('public.featured_promotion_library_reviews') IS NOT NULL AS reviews_exist,
  to_regclass('public.featured_promotion_library_jobs') IS NOT NULL AS jobs_exist,
  EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'featured_promotion_library'
      AND column_name = 'manual_override'
  ) AS has_manual_override;
