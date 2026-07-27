-- =============================================================================
-- READ-ONLY inspection for migration 20260883 (featured_events.is_promoted)
-- =============================================================================
-- Run this in the Supabase SQL Editor BEFORE applying 20260883.
-- It performs no writes, no DDL, and no DML. Safe to run on production.
--
-- Purpose: classify every existing featured_events row so the backfill can be
-- written explicitly instead of blanket-setting is_promoted = true.
--
-- Pre-migration admin semantics this classification relies on:
--   * enabled = true  -> the row IS (or was) consumer-visible when in window.
--                        This is provable evidence of promoted lifecycle.
--   * enabled = false -> AMBIGUOUS. The old admin used enabled=false for BOTH
--                        "Pause Promotion" AND "saved with Active unchecked"
--                        (i.e. configured but never promoted = Library).
--                        The schema stores no evidence to tell these apart.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Row-by-row classification
-- ---------------------------------------------------------------------------
SELECT
  fe.id,
  fe.slug,
  fe.title,
  fe.enabled,
  fe.start_date,
  fe.end_date,
  fe.priority,
  fe.created_at,
  fe.updated_at,
  (fe.updated_at > fe.created_at)                              AS mutated_since_create,
  (fe.enabled
     AND fe.start_date <= current_date
     AND fe.end_date   >= current_date)                        AS consumer_visible_today,
  CASE
    WHEN fe.enabled AND fe.start_date <= current_date AND fe.end_date >= current_date
      THEN 'PROMOTED_LIVE'
    WHEN fe.enabled AND fe.start_date > current_date
      THEN 'PROMOTED_SCHEDULED'
    WHEN fe.enabled AND fe.end_date < current_date
      THEN 'COMPLETED'
    WHEN NOT fe.enabled
      THEN 'NEEDS_REVIEW'
    ELSE 'NEEDS_REVIEW'
  END                                                          AS recommendation,
  CASE
    WHEN fe.enabled AND fe.start_date <= current_date AND fe.end_date >= current_date
      THEN 'enabled=true and inside date window: currently exposed to the app. Provably promoted.'
    WHEN fe.enabled AND fe.start_date > current_date
      THEN 'enabled=true with a future window: will auto-expose on start_date. Provably promoted.'
    WHEN fe.enabled AND fe.end_date < current_date
      THEN 'enabled=true but window has passed: was exposed, now finished. Promoted lifecycle -> Completed.'
    WHEN NOT fe.enabled AND fe.end_date >= current_date AND fe.updated_at > fe.created_at
      THEN 'AMBIGUOUS: enabled=false, future/current window, edited after creation. Could be a real Pause OR an edit of a never-promoted definition. Decide manually.'
    WHEN NOT fe.enabled AND fe.end_date >= current_date
      THEN 'AMBIGUOUS: enabled=false and never modified after creation. Most likely created with "Active promotion" unchecked = Library, but not provable. Decide manually.'
    WHEN NOT fe.enabled AND fe.end_date < current_date
      THEN 'AMBIGUOUS: enabled=false and window already passed. Cannot tell whether it ran and was paused (Completed) or never ran (Library). Decide manually.'
    ELSE 'Unclassified state; decide manually.'
  END                                                          AS rationale,
  CASE
    WHEN fe.enabled THEN 'true'
    ELSE 'REVIEW (defaults to false / Library unless you list the slug in the migration)'
  END                                                          AS proposed_is_promoted
FROM public.featured_events fe
ORDER BY
  CASE
    WHEN fe.enabled AND fe.start_date <= current_date AND fe.end_date >= current_date THEN 1
    WHEN fe.enabled AND fe.start_date > current_date THEN 2
    WHEN fe.enabled THEN 3
    ELSE 0
  END,
  fe.start_date NULLS LAST,
  fe.slug;

-- ---------------------------------------------------------------------------
-- 2. Summary counts
-- ---------------------------------------------------------------------------
SELECT
  count(*)                                                                          AS total_rows,
  count(*) FILTER (WHERE enabled)                                                   AS enabled_true_auto_promoted,
  count(*) FILTER (WHERE NOT enabled)                                               AS enabled_false_needs_review,
  count(*) FILTER (WHERE enabled AND start_date <= current_date
                     AND end_date >= current_date)                                  AS consumer_visible_today,
  count(*) FILTER (WHERE NOT enabled AND end_date >= current_date)                  AS review_future_window,
  count(*) FILTER (WHERE NOT enabled AND end_date <  current_date)                  AS review_past_window
FROM public.featured_events;

-- ---------------------------------------------------------------------------
-- 3. Integrity preconditions (both must return zero rows)
-- ---------------------------------------------------------------------------
SELECT slug, count(*) AS duplicate_count
FROM public.featured_events
GROUP BY slug
HAVING count(*) > 1;

SELECT id, slug, start_date, end_date
FROM public.featured_events
WHERE start_date IS NULL
   OR end_date IS NULL
   OR end_date < start_date;

-- ---------------------------------------------------------------------------
-- 4. Does the column already exist? (detects a partial / unsafe prior apply)
-- ---------------------------------------------------------------------------
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name   = 'featured_events'
  AND column_name  = 'is_promoted';
