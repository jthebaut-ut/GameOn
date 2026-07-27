-- =============================================================================
-- 20260890 — Global promotion library metadata + promotion run history
-- =============================================================================
--
-- Formerly drafted as 20260884_0001_global_promotion_library.sql.
-- Renumbered to 20260890 because GameOn already uses:
--   20260884 → national_team_favorite_team_id
--   20260885 → profile_background_key
-- Apply this file manually in Supabase SQL Editor after 20260883.
--
-- Extends featured_events with structured geography, edition, date confidence,
-- and provenance fields used by the Admin Promotion Library.
--
-- Adds featured_promotion_runs to preserve historical promotion windows when a
-- definition is re-promoted (definition slug stays stable; runs are append-only).
--
-- SAFETY GUARANTEES
-- -----------------
-- * Does NOT insert the 125 TypeScript catalog definitions into featured_events.
-- * Does NOT change enabled, start_date, end_date, priority, keywords, or
--   is_promoted for existing rows.
-- * Does NOT fabricate promotion-run history for the current 12 production rows.
-- * Consumer exposure remains: enabled = true AND valid date window.
-- * Requires 20260883 (is_promoted) already applied.
--
-- Existing-row backfill is intentionally minimal:
--   definition_slug := slug
-- All other new columns stay NULL until an admin Promote/Configure writes them
-- (or a separate reviewed enrichment migration).
--
-- Do NOT apply from the agent; review and apply deliberately.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Preflight
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_is_promoted_exists boolean;
  v_is_promoted_default text;
  v_null_promoted integer;
  v_duplicates text;
BEGIN
  IF to_regclass('public.featured_events') IS NULL THEN
    RAISE EXCEPTION
      '20260890 preflight failed: table public.featured_events is missing'
      USING ERRCODE = 'P0001';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'featured_events'
      AND column_name = 'is_promoted'
  )
  INTO v_is_promoted_exists;

  IF NOT v_is_promoted_exists THEN
    RAISE EXCEPTION
      '20260890 preflight failed: public.featured_events.is_promoted is missing. Apply 20260883 first.'
      USING ERRCODE = 'P0001';
  END IF;

  SELECT column_default
  INTO v_is_promoted_default
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'featured_events'
    AND column_name = 'is_promoted';

  IF v_is_promoted_default IS NULL OR v_is_promoted_default NOT ILIKE '%false%' THEN
    RAISE EXCEPTION
      '20260890 preflight failed: is_promoted default is % (expected false from 20260883)',
      coalesce(v_is_promoted_default, 'NULL')
      USING ERRCODE = 'P0001';
  END IF;

  SELECT count(*)
  INTO v_null_promoted
  FROM public.featured_events
  WHERE is_promoted IS NULL;

  IF v_null_promoted > 0 THEN
    RAISE EXCEPTION
      '20260890 preflight failed: % featured_events row(s) still have NULL is_promoted',
      v_null_promoted
      USING ERRCODE = 'P0001';
  END IF;

  SELECT string_agg(slug, ', ' ORDER BY slug)
  INTO v_duplicates
  FROM (
    SELECT slug
    FROM public.featured_events
    GROUP BY slug
    HAVING count(*) > 1
  ) d;

  IF v_duplicates IS NOT NULL THEN
    RAISE EXCEPTION
      '20260890 preflight failed: duplicate featured_events slugs: %',
      v_duplicates
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;

-- Snapshot consumer-visible IDs and lifecycle flags so we can prove this
-- migration publishes nothing and does not rewrite 20260883 state.
CREATE TEMP TABLE tmp_20260890_visible_before ON COMMIT DROP AS
SELECT id
FROM public.featured_events
WHERE enabled = true
  AND start_date <= current_date
  AND end_date >= current_date;

CREATE TEMP TABLE tmp_20260890_lifecycle_before ON COMMIT DROP AS
SELECT
  id,
  slug,
  enabled,
  is_promoted,
  start_date,
  end_date,
  priority
FROM public.featured_events;

CREATE TEMP TABLE tmp_20260890_runs_before (
  run_count integer NOT NULL
) ON COMMIT DROP;

DO $$
BEGIN
  IF to_regclass('public.featured_promotion_runs') IS NOT NULL THEN
    INSERT INTO tmp_20260890_runs_before(run_count)
    SELECT count(*)::integer FROM public.featured_promotion_runs;
  ELSE
    INSERT INTO tmp_20260890_runs_before(run_count) VALUES (0);
  END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- New nullable metadata columns (existing 12 rows remain valid with NULLs)
-- -----------------------------------------------------------------------------
ALTER TABLE public.featured_events
  ADD COLUMN IF NOT EXISTS definition_slug text NULL,
  ADD COLUMN IF NOT EXISTS edition_label text NULL,
  ADD COLUMN IF NOT EXISTS edition_year integer NULL,
  ADD COLUMN IF NOT EXISTS event_type text NULL,
  ADD COLUMN IF NOT EXISTS region text NULL,
  ADD COLUMN IF NOT EXISTS host_countries text[] NULL,
  ADD COLUMN IF NOT EXISTS host_cities text[] NULL,
  ADD COLUMN IF NOT EXISTS date_confidence text NULL,
  ADD COLUMN IF NOT EXISTS governing_body text NULL,
  ADD COLUMN IF NOT EXISTS official_event_name text NULL,
  ADD COLUMN IF NOT EXISTS source_url text NULL,
  ADD COLUMN IF NOT EXISTS last_verified_at timestamptz NULL;

-- Only safe automatic backfill: stable identity defaults to current slug.
-- Do NOT invent date_confidence, region, hosts, or provenance for existing rows.
UPDATE public.featured_events
SET definition_slug = slug
WHERE definition_slug IS NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'featured_events_date_confidence_check'
  ) THEN
    ALTER TABLE public.featured_events
      ADD CONSTRAINT featured_events_date_confidence_check
      CHECK (
        date_confidence IS NULL
        OR date_confidence IN ('confirmed', 'estimated', 'tbd')
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'featured_events_region_check'
  ) THEN
    ALTER TABLE public.featured_events
      ADD CONSTRAINT featured_events_region_check
      CHECK (
        region IS NULL
        OR region IN (
          'North America',
          'South America',
          'Europe',
          'Africa',
          'Asia',
          'Oceania',
          'Global'
        )
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'featured_events_event_type_check'
  ) THEN
    ALTER TABLE public.featured_events
      ADD CONSTRAINT featured_events_event_type_check
      CHECK (
        event_type IS NULL
        OR event_type IN (
          'tournament',
          'championship',
          'final',
          'annual_event',
          'recurring_series',
          'season',
          'multi_sport'
        )
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'featured_events_definition_slug_not_blank'
  ) THEN
    ALTER TABLE public.featured_events
      ADD CONSTRAINT featured_events_definition_slug_not_blank
      CHECK (definition_slug IS NULL OR btrim(definition_slug) <> '');
  END IF;
END;
$$;

COMMENT ON COLUMN public.featured_events.definition_slug IS
  'Stable reusable catalog identity; usually matches slug. Edition/year live in edition_* fields, not the slug.';
COMMENT ON COLUMN public.featured_events.edition_label IS
  'Human edition label (e.g. 2026, 2026–27). Optional until configured.';
COMMENT ON COLUMN public.featured_events.edition_year IS
  'Primary edition year when known. Optional.';
COMMENT ON COLUMN public.featured_events.event_type IS
  'tournament | championship | final | annual_event | recurring_series | season | multi_sport';
COMMENT ON COLUMN public.featured_events.region IS
  'Canonical region for admin filtering; Global for worldwide seasons/events.';
COMMENT ON COLUMN public.featured_events.host_countries IS
  'ISO-style host country codes (text[]). Empty/NULL means Global / multiple countries.';
COMMENT ON COLUMN public.featured_events.host_cities IS
  'Optional host city names. Multi-city events use an array.';
COMMENT ON COLUMN public.featured_events.date_confidence IS
  'confirmed | estimated | tbd — suggested dates are metadata until admin confirms. Existing rows may remain NULL.';
COMMENT ON COLUMN public.featured_events.governing_body IS
  'Optional provenance: governing body name.';
COMMENT ON COLUMN public.featured_events.official_event_name IS
  'Optional provenance: official event name.';
COMMENT ON COLUMN public.featured_events.source_url IS
  'Optional provenance: authoritative source URL.';
COMMENT ON COLUMN public.featured_events.last_verified_at IS
  'Optional provenance: when catalog metadata was last verified.';

-- -----------------------------------------------------------------------------
-- Append-only promotion run history (empty on apply; no fabricated backfill)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.featured_promotion_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  definition_slug text NOT NULL,
  featured_event_id uuid NULL REFERENCES public.featured_events(id) ON DELETE SET NULL,
  edition_label text NULL,
  edition_year integer NULL,
  title text NOT NULL,
  sport text NULL,
  region text NULL,
  host_countries text[] NULL,
  start_date date NULL,
  end_date date NULL,
  date_confidence text NULL,
  promoted_at timestamptz NULL,
  completed_at timestamptz NULL,
  removed_at timestamptz NULL,
  snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- If an older draft created the table without checks, add them safely now.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'featured_promotion_runs_definition_slug_not_blank'
  ) THEN
    ALTER TABLE public.featured_promotion_runs
      ADD CONSTRAINT featured_promotion_runs_definition_slug_not_blank
      CHECK (btrim(definition_slug) <> '');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'featured_promotion_runs_title_not_blank'
  ) THEN
    ALTER TABLE public.featured_promotion_runs
      ADD CONSTRAINT featured_promotion_runs_title_not_blank
      CHECK (btrim(title) <> '');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'featured_promotion_runs_date_confidence_check'
  ) THEN
    ALTER TABLE public.featured_promotion_runs
      ADD CONSTRAINT featured_promotion_runs_date_confidence_check
      CHECK (
        date_confidence IS NULL
        OR date_confidence IN ('confirmed', 'estimated', 'tbd')
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'featured_promotion_runs_region_check'
  ) THEN
    ALTER TABLE public.featured_promotion_runs
      ADD CONSTRAINT featured_promotion_runs_region_check
      CHECK (
        region IS NULL
        OR region IN (
          'North America',
          'South America',
          'Europe',
          'Africa',
          'Asia',
          'Oceania',
          'Global'
        )
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'featured_promotion_runs_valid_date_range'
  ) THEN
    ALTER TABLE public.featured_promotion_runs
      ADD CONSTRAINT featured_promotion_runs_valid_date_range
      CHECK (
        start_date IS NULL
        OR end_date IS NULL
        OR end_date >= start_date
      );
  END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS featured_promotion_runs_definition_slug_idx
  ON public.featured_promotion_runs (definition_slug, created_at DESC);

CREATE INDEX IF NOT EXISTS featured_promotion_runs_featured_event_id_idx
  ON public.featured_promotion_runs (featured_event_id);

COMMENT ON TABLE public.featured_promotion_runs IS
  'Append-only history of promotion runs for reusable featured event definitions. Re-promoting must INSERT a new run; never overwrite prior runs. This migration intentionally does NOT backfill runs for pre-existing promotions.';

COMMENT ON COLUMN public.featured_promotion_runs.featured_event_id IS
  'Optional link to the live featured_events row. ON DELETE SET NULL preserves history if the live row is removed.';
COMMENT ON COLUMN public.featured_promotion_runs.snapshot IS
  'Immutable JSON snapshot of the promotion configuration at run time.';

ALTER TABLE public.featured_promotion_runs ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'featured_promotion_runs'
      AND policyname = 'Service role can manage featured promotion runs'
  ) THEN
    CREATE POLICY "Service role can manage featured promotion runs"
      ON public.featured_promotion_runs
      FOR ALL
      TO service_role
      USING (true)
      WITH CHECK (true);
  END IF;
END;
$$;

REVOKE ALL ON TABLE public.featured_promotion_runs FROM PUBLIC;
REVOKE ALL ON TABLE public.featured_promotion_runs FROM anon;
REVOKE ALL ON TABLE public.featured_promotion_runs FROM authenticated;
GRANT ALL ON TABLE public.featured_promotion_runs TO service_role;

-- -----------------------------------------------------------------------------
-- Post-checks: no consumer visibility change, no 20260883 lifecycle rewrite
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_before integer;
  v_after integer;
  v_gained integer;
  v_lifecycle_drift integer;
  v_missing_definition_slug integer;
  v_run_count integer;
  v_is_promoted_default text;
BEGIN
  SELECT count(*) INTO v_before FROM tmp_20260890_visible_before;

  SELECT count(*)
  INTO v_after
  FROM public.featured_events
  WHERE enabled = true
    AND start_date <= current_date
    AND end_date >= current_date;

  SELECT count(*)
  INTO v_gained
  FROM public.featured_events fe
  WHERE fe.enabled = true
    AND fe.start_date <= current_date
    AND fe.end_date >= current_date
    AND NOT EXISTS (
      SELECT 1
      FROM tmp_20260890_visible_before b
      WHERE b.id = fe.id
    );

  IF v_before <> v_after OR v_gained > 0 THEN
    RAISE EXCEPTION
      '20260890 post-check failed: consumer-visible rows changed (% -> %, % newly visible)',
      v_before, v_after, v_gained
      USING ERRCODE = 'P0001';
  END IF;

  SELECT count(*)
  INTO v_lifecycle_drift
  FROM public.featured_events fe
  JOIN tmp_20260890_lifecycle_before before_row
    ON before_row.id = fe.id
  WHERE fe.enabled IS DISTINCT FROM before_row.enabled
     OR fe.is_promoted IS DISTINCT FROM before_row.is_promoted
     OR fe.start_date IS DISTINCT FROM before_row.start_date
     OR fe.end_date IS DISTINCT FROM before_row.end_date
     OR fe.priority IS DISTINCT FROM before_row.priority;

  IF v_lifecycle_drift > 0 THEN
    RAISE EXCEPTION
      '20260890 post-check failed: % row(s) changed enabled/is_promoted/dates/priority',
      v_lifecycle_drift
      USING ERRCODE = 'P0001';
  END IF;

  SELECT count(*)
  INTO v_missing_definition_slug
  FROM public.featured_events
  WHERE definition_slug IS NULL OR btrim(definition_slug) = '';

  IF v_missing_definition_slug > 0 THEN
    RAISE EXCEPTION
      '20260890 post-check failed: % row(s) missing definition_slug',
      v_missing_definition_slug
      USING ERRCODE = 'P0001';
  END IF;

  SELECT count(*) INTO v_run_count FROM public.featured_promotion_runs;
  IF v_run_count <> (SELECT run_count FROM tmp_20260890_runs_before) THEN
    RAISE EXCEPTION
      '20260890 post-check failed: promotion run count changed (% -> %); this migration must not insert history',
      (SELECT run_count FROM tmp_20260890_runs_before),
      v_run_count
      USING ERRCODE = 'P0001';
  END IF;

  SELECT column_default
  INTO v_is_promoted_default
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'featured_events'
    AND column_name = 'is_promoted';

  IF v_is_promoted_default IS NULL OR v_is_promoted_default NOT ILIKE '%false%' THEN
    RAISE EXCEPTION
      '20260890 post-check failed: is_promoted default drifted to %',
      coalesce(v_is_promoted_default, 'NULL')
      USING ERRCODE = 'P0001';
  END IF;

  RAISE NOTICE
    '20260890 ok: metadata columns added, % featured_events rows preserved, consumer-visible=% , promotion_runs=%',
    (SELECT count(*) FROM public.featured_events),
    v_after,
    v_run_count;
END;
$$;

COMMIT;
