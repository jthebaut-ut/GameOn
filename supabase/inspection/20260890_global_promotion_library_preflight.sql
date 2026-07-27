-- =============================================================================
-- READ-ONLY preflight for 20260890 (formerly drafted as 20260884 / briefly 20260885)
-- Global promotion library metadata + featured_promotion_runs
-- =============================================================================
-- Safe to run in Supabase SQL Editor. No writes. No DDL.
-- Run AFTER 20260883 has been applied. Do NOT apply 20260890 until this passes.
-- =============================================================================

-- 1. Current featured_events column inventory
SELECT
  column_name,
  data_type,
  udt_name,
  is_nullable,
  column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'featured_events'
ORDER BY ordinal_position;

-- 2. Row counts + lifecycle distribution from 20260883
SELECT
  count(*) AS total_rows,
  count(*) FILTER (WHERE enabled) AS enabled_true,
  count(*) FILTER (WHERE NOT enabled) AS enabled_false,
  count(*) FILTER (WHERE is_promoted) AS is_promoted_true,
  count(*) FILTER (WHERE NOT is_promoted) AS is_promoted_false,
  count(*) FILTER (WHERE is_promoted IS NULL) AS is_promoted_null,
  count(*) FILTER (
    WHERE enabled
      AND start_date <= current_date
      AND end_date >= current_date
  ) AS consumer_visible_today
FROM public.featured_events;

-- 3. Full current row state (for review before metadata migration)
SELECT
  id,
  slug,
  title,
  enabled,
  is_promoted,
  start_date,
  end_date,
  CASE
    WHEN NOT is_promoted THEN 'LIBRARY'
    WHEN end_date < current_date THEN 'COMPLETED'
    WHEN NOT enabled THEN 'PAUSED'
    WHEN start_date > current_date THEN 'SCHEDULED'
    WHEN start_date <= current_date AND end_date >= current_date THEN 'LIVE'
    ELSE 'NEEDS_REVIEW'
  END AS derived_admin_state,
  (enabled AND start_date <= current_date AND end_date >= current_date) AS consumer_visible_today
FROM public.featured_events
ORDER BY slug;

-- 4. Confirm the three known disabled promoted rows still classify correctly
SELECT
  slug,
  enabled,
  is_promoted,
  start_date,
  end_date,
  CASE
    WHEN slug = 'fifa_world_cup'
      AND enabled = false
      AND is_promoted = true
      AND start_date <= current_date
      AND end_date >= current_date
      THEN 'OK_PAUSED'
    WHEN slug IN ('roland_garros', 'wimbledon')
      AND enabled = false
      AND is_promoted = true
      AND end_date < current_date
      THEN 'OK_COMPLETED'
    ELSE 'UNEXPECTED'
  END AS expected_check
FROM public.featured_events
WHERE slug IN ('roland_garros', 'fifa_world_cup', 'wimbledon')
ORDER BY slug;

-- 5. Integrity blockers (must return zero rows)
SELECT slug, count(*) AS duplicate_count
FROM public.featured_events
GROUP BY slug
HAVING count(*) > 1;

SELECT id, slug, start_date, end_date
FROM public.featured_events
WHERE start_date IS NULL
   OR end_date IS NULL
   OR end_date < start_date;

-- 6. Which 20260890 columns already exist? (detect partial apply)
SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'featured_events'
  AND column_name IN (
    'definition_slug',
    'edition_label',
    'edition_year',
    'event_type',
    'region',
    'host_countries',
    'host_cities',
    'date_confidence',
    'governing_body',
    'official_event_name',
    'source_url',
    'last_verified_at'
  )
ORDER BY column_name;

-- 7. Does featured_promotion_runs already exist?
SELECT
  to_regclass('public.featured_promotion_runs') AS featured_promotion_runs_regclass;

SELECT
  column_name,
  data_type,
  is_nullable,
  column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'featured_promotion_runs'
ORDER BY ordinal_position;

-- 8. is_promoted default must remain false (Library default for future inserts)
SELECT column_name, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'featured_events'
  AND column_name = 'is_promoted';

-- 9. Summary readiness gates
SELECT
  (to_regclass('public.featured_events') IS NOT NULL) AS featured_events_exists,
  EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'featured_events'
      AND column_name = 'is_promoted'
  ) AS is_promoted_exists,
  (
    SELECT column_default
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'featured_events'
      AND column_name = 'is_promoted'
  ) ILIKE '%false%' AS is_promoted_defaults_false,
  NOT EXISTS (
    SELECT 1 FROM public.featured_events WHERE is_promoted IS NULL
  ) AS no_null_is_promoted,
  NOT EXISTS (
    SELECT 1
    FROM public.featured_events
    GROUP BY slug
    HAVING count(*) > 1
  ) AS no_duplicate_slugs,
  NOT EXISTS (
    SELECT 1
    FROM public.featured_events
    WHERE start_date IS NULL
       OR end_date IS NULL
       OR end_date < start_date
  ) AS no_invalid_date_ranges,
  (
    SELECT count(*) = 12 FROM public.featured_events
  ) AS has_expected_12_rows;
