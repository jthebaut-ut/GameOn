-- =============================================================================
-- 20260883 — Featured events admin lifecycle flag (is_promoted)
-- =============================================================================
--
-- Distinguishes "Pause" (still in the Promoted lifecycle, app exposure off)
-- from "Remove from promotion" (definition returns to the Library, config and
-- history preserved).
--
-- CONSUMER EXPOSURE IS UNCHANGED. Clients still require:
--     enabled = true AND current_date BETWEEN start_date AND end_date
-- is_promoted is an ADMIN lifecycle field only. It is not referenced by any
-- RLS policy, view, or client query.
--
-- -----------------------------------------------------------------------------
-- PRODUCTION CLASSIFICATION USED FOR THIS BACKFILL
-- -----------------------------------------------------------------------------
-- The read-only production inspection found 12 rows: 9 enabled and 3 disabled.
-- The three disabled rows (roland_garros, fifa_world_cup, wimbledon) were
-- confirmed as existing promoted-lifecycle records. Any other disabled row
-- causes this migration to abort rather than being guessed.
--
-- Rows with enabled = true are classified automatically as is_promoted = true:
-- being enabled is provable evidence the row is, or was, part of the promoted
-- lifecycle (it is or has been consumer-visible inside its window).
--
-- Do NOT apply from an agent. Review and apply deliberately.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Preflight
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_default text;
  v_duplicates text;
BEGIN
  IF to_regclass('public.featured_events') IS NULL THEN
    RAISE EXCEPTION '20260883 preflight failed: table public.featured_events is missing'
      USING ERRCODE = 'P0001';
  END IF;

  -- Detect the earlier unsafe draft of this migration having been applied
  -- (is_promoted NOT NULL DEFAULT true, every row forced to Promoted).
  SELECT column_default INTO v_default
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'featured_events'
    AND column_name = 'is_promoted';

  IF v_default IS NOT NULL AND v_default ILIKE '%true%' THEN
    RAISE EXCEPTION
      '20260883 preflight failed: featured_events.is_promoted already exists with DEFAULT %. The unsafe draft was applied; reclassify rows manually and reset the default to false before re-running.',
      v_default
      USING ERRCODE = 'P0001';
  END IF;

  SELECT string_agg(slug, ', ' ORDER BY slug) INTO v_duplicates
  FROM (
    SELECT slug FROM public.featured_events GROUP BY slug HAVING count(*) > 1
  ) d;

  IF v_duplicates IS NOT NULL THEN
    RAISE EXCEPTION '20260883 preflight failed: duplicate featured_events slugs: %', v_duplicates
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;

-- Snapshot the consumer-visible set so we can prove the migration publishes nothing.
CREATE TEMP TABLE tmp_20260883_visible_before ON COMMIT DROP AS
SELECT id
FROM public.featured_events
WHERE enabled = true
  AND start_date <= current_date
  AND end_date >= current_date;

-- -----------------------------------------------------------------------------
-- Add the column as NULLABLE with NO default, so unclassified rows stay NULL
-- and the assertion below can catch them.
-- -----------------------------------------------------------------------------
ALTER TABLE public.featured_events
  ADD COLUMN IF NOT EXISTS is_promoted boolean;

COMMENT ON COLUMN public.featured_events.is_promoted IS
  'Admin lifecycle flag. true = Promoted (Scheduled / Live / Paused / Completed run); false = Library definition, not part of an active promotion. Does NOT grant app exposure: consumers still require enabled = true and a valid date window.';

-- -----------------------------------------------------------------------------
-- Explicit backfill
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  -- Production inspection classified all three existing disabled rows as
  -- promoted-lifecycle records. Any future disabled row not listed here remains
  -- NULL and causes this transaction to abort rather than being guessed.

  -- Confirmed real pauses / promotions that were disabled while still in the
  -- promoted lifecycle. These become is_promoted = true (Paused or Completed).
  -- They remain hidden from the app because enabled stays false.
  v_promoted_slugs text[] := ARRAY[
    'roland_garros',
    'fifa_world_cup',
    'wimbledon'
  ];

  -- Confirmed Library definitions: configured but never actually promoted, or
  -- deliberately withdrawn. These become is_promoted = false.
  v_library_slugs  text[] := ARRAY[]::text[];

  v_unclassified text;
  v_overlap text;
  v_unknown text;
  v_null_count integer;
  v_promoted_count integer;
  v_library_count integer;
BEGIN
  SELECT string_agg(s, ', ') INTO v_overlap
  FROM unnest(v_promoted_slugs) s
  WHERE s = ANY (v_library_slugs);

  IF v_overlap IS NOT NULL THEN
    RAISE EXCEPTION '20260883 backfill failed: slug(s) listed in both arrays: %', v_overlap
      USING ERRCODE = 'P0001';
  END IF;

  SELECT string_agg(s, ', ') INTO v_unknown
  FROM unnest(v_promoted_slugs || v_library_slugs) s
  WHERE NOT EXISTS (SELECT 1 FROM public.featured_events fe WHERE fe.slug = s);

  IF v_unknown IS NOT NULL THEN
    RAISE EXCEPTION '20260883 backfill failed: slug(s) not present in featured_events: %', v_unknown
      USING ERRCODE = 'P0001';
  END IF;

  -- Step 1: enabled = true is provable promoted lifecycle.
  --   in window        -> Live
  --   start_date ahead -> Scheduled
  --   end_date passed  -> Completed (a real run that finished)
  UPDATE public.featured_events
  SET is_promoted = true
  WHERE enabled = true
    AND is_promoted IS DISTINCT FROM true;

  -- Step 2: reviewer-confirmed pauses stay in the promoted lifecycle.
  UPDATE public.featured_events
  SET is_promoted = true
  WHERE slug = ANY (v_promoted_slugs)
    AND is_promoted IS DISTINCT FROM true;

  -- Step 3: reviewer-confirmed Library definitions.
  UPDATE public.featured_events
  SET is_promoted = false
  WHERE slug = ANY (v_library_slugs)
    AND is_promoted IS DISTINCT FROM false;

  -- Step 4: refuse to guess anything left over.
  SELECT string_agg(format('%s (enabled=%s, %s..%s)', slug, enabled, start_date, end_date), E'\n  ' ORDER BY slug)
    INTO v_unclassified
  FROM public.featured_events
  WHERE is_promoted IS NULL
     OR (
       enabled = false
       AND NOT (slug = ANY (v_promoted_slugs))
       AND NOT (slug = ANY (v_library_slugs))
     );

  IF v_unclassified IS NOT NULL THEN
    RAISE EXCEPTION E'20260883 backfill failed: % row(s) could not be classified safely.\n  %\nAdd each slug to v_promoted_slugs (real pause) or v_library_slugs (never promoted) and re-run. Nothing has been changed.',
      (
        SELECT count(*)
        FROM public.featured_events
        WHERE is_promoted IS NULL
           OR (
             enabled = false
             AND NOT (slug = ANY (v_promoted_slugs))
             AND NOT (slug = ANY (v_library_slugs))
           )
      ),
      v_unclassified
      USING ERRCODE = 'P0001';
  END IF;

  -- Assertion: zero NULLs remain.
  SELECT count(*) INTO v_null_count
  FROM public.featured_events
  WHERE is_promoted IS NULL;

  IF v_null_count > 0 THEN
    RAISE EXCEPTION '20260883 backfill failed: % NULL is_promoted value(s) remain', v_null_count
      USING ERRCODE = 'P0001';
  END IF;

  SELECT count(*) FILTER (WHERE is_promoted), count(*) FILTER (WHERE NOT is_promoted)
    INTO v_promoted_count, v_library_count
  FROM public.featured_events;

  RAISE NOTICE '20260883 backfill: % promoted, % library', v_promoted_count, v_library_count;
END;
$$;

-- -----------------------------------------------------------------------------
-- Lock in the constraint and the Library-by-default behaviour for future rows.
-- -----------------------------------------------------------------------------
ALTER TABLE public.featured_events
  ALTER COLUMN is_promoted SET NOT NULL;

ALTER TABLE public.featured_events
  ALTER COLUMN is_promoted SET DEFAULT false;

-- -----------------------------------------------------------------------------
-- Post-checks
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_before integer;
  v_after integer;
  v_gained integer;
  v_default text;
BEGIN
  SELECT count(*) INTO v_before FROM tmp_20260883_visible_before;

  SELECT count(*) INTO v_after
  FROM public.featured_events
  WHERE enabled = true
    AND start_date <= current_date
    AND end_date >= current_date;

  SELECT count(*) INTO v_gained
  FROM public.featured_events fe
  WHERE fe.enabled = true
    AND fe.start_date <= current_date
    AND fe.end_date >= current_date
    AND NOT EXISTS (SELECT 1 FROM tmp_20260883_visible_before b WHERE b.id = fe.id);

  IF v_before <> v_after OR v_gained > 0 THEN
    RAISE EXCEPTION '20260883 post-check failed: consumer-visible rows changed (% -> %, % newly visible)',
      v_before, v_after, v_gained
      USING ERRCODE = 'P0001';
  END IF;

  SELECT column_default INTO v_default
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'featured_events'
    AND column_name = 'is_promoted';

  IF v_default IS NULL OR v_default NOT ILIKE '%false%' THEN
    RAISE EXCEPTION '20260883 post-check failed: is_promoted default is % (expected false)', coalesce(v_default, 'NULL')
      USING ERRCODE = 'P0001';
  END IF;

  RAISE NOTICE '20260883 post-check ok: consumer-visible rows unchanged (%), default false', v_after;
END;
$$;

COMMIT;
