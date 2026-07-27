-- =============================================================================
-- 20260891 — Durable Featured Promotion Library (admin catalog store)
-- =============================================================================
--
-- STATUS: PREPARED ONLY — DO NOT APPLY until reviewed.
--
-- Why this exists:
--   The 125+ global event definitions currently live in Admin TypeScript.
--   featured_events cannot store TBD library rows (start_date/end_date are NOT NULL)
--   and must not be used as the catalog store (that would blur Library vs Promoted).
--
-- This table stores reusable library definitions only:
--   - nullable dates (TBD allowed)
--   - geography / edition / provenance / date_confidence
--   - NEVER implies FanGeo publication
--
-- Update Event Library upserts here. Promote still writes featured_events.
-- Consumer exposure is unchanged: enabled + date window on featured_events.
--
-- =============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regclass('public.featured_events') IS NULL THEN
    RAISE EXCEPTION
      '20260891 preflight failed: public.featured_events is missing'
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS public.featured_promotion_library (
  definition_slug text PRIMARY KEY,
  slug text NOT NULL,
  title text NOT NULL,
  short_title text NOT NULL,
  icon text NULL,
  sport text NULL,
  event_type text NULL,
  region text NULL,
  host_countries text[] NOT NULL DEFAULT '{}'::text[],
  host_cities text[] NOT NULL DEFAULT '{}'::text[],
  edition_label text NULL,
  edition_year integer NULL,
  start_date date NULL,
  end_date date NULL,
  date_confidence text NOT NULL DEFAULT 'tbd',
  include_keywords text[] NOT NULL DEFAULT '{}'::text[],
  exclude_keywords text[] NOT NULL DEFAULT '{}'::text[],
  priority integer NOT NULL DEFAULT 0,
  governing_body text NULL,
  official_event_name text NULL,
  source_url text NULL,
  last_verified_at timestamptz NULL,
  needs_provider_mapping boolean NOT NULL DEFAULT false,
  no_provider_mapping boolean NOT NULL DEFAULT false,
  review_flags text[] NOT NULL DEFAULT '{}'::text[],
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT featured_promotion_library_slug_not_blank CHECK (btrim(slug) <> ''),
  CONSTRAINT featured_promotion_library_definition_slug_not_blank CHECK (btrim(definition_slug) <> ''),
  CONSTRAINT featured_promotion_library_title_not_blank CHECK (btrim(title) <> ''),
  CONSTRAINT featured_promotion_library_short_title_not_blank CHECK (btrim(short_title) <> ''),
  CONSTRAINT featured_promotion_library_date_confidence_check
    CHECK (date_confidence IN ('confirmed', 'estimated', 'tbd')),
  CONSTRAINT featured_promotion_library_region_check
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
    ),
  CONSTRAINT featured_promotion_library_event_type_check
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
    ),
  CONSTRAINT featured_promotion_library_valid_date_range
    CHECK (
      start_date IS NULL
      OR end_date IS NULL
      OR end_date >= start_date
    )
);

CREATE UNIQUE INDEX IF NOT EXISTS featured_promotion_library_slug_uidx
  ON public.featured_promotion_library (slug);

CREATE INDEX IF NOT EXISTS featured_promotion_library_region_idx
  ON public.featured_promotion_library (region);

CREATE INDEX IF NOT EXISTS featured_promotion_library_sport_idx
  ON public.featured_promotion_library (sport);

CREATE OR REPLACE FUNCTION public.set_featured_promotion_library_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS set_featured_promotion_library_updated_at
  ON public.featured_promotion_library;

CREATE TRIGGER set_featured_promotion_library_updated_at
BEFORE UPDATE ON public.featured_promotion_library
FOR EACH ROW
EXECUTE FUNCTION public.set_featured_promotion_library_updated_at();

COMMENT ON TABLE public.featured_promotion_library IS
  'Admin-only reusable global promotion catalog. Publication-neutral: never grants FanGeo exposure. Update Event Library upserts here; Promote writes featured_events.';

ALTER TABLE public.featured_promotion_library ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'featured_promotion_library'
      AND policyname = 'Service role can manage featured promotion library'
  ) THEN
    CREATE POLICY "Service role can manage featured promotion library"
      ON public.featured_promotion_library
      FOR ALL
      TO service_role
      USING (true)
      WITH CHECK (true);
  END IF;
END;
$$;

REVOKE ALL ON TABLE public.featured_promotion_library FROM PUBLIC;
REVOKE ALL ON TABLE public.featured_promotion_library FROM anon;
REVOKE ALL ON TABLE public.featured_promotion_library FROM authenticated;
GRANT ALL ON TABLE public.featured_promotion_library TO service_role;

-- Post-check: table exists and grants no consumer exposure path.
DO $$
BEGIN
  IF to_regclass('public.featured_promotion_library') IS NULL THEN
    RAISE EXCEPTION '20260891 post-check failed: featured_promotion_library missing' USING ERRCODE = 'P0001';
  END IF;
END;
$$;

COMMIT;
