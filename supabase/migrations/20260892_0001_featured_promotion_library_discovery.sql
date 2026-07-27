-- =============================================================================
-- 20260892 — Featured Promotion Library discovery (override, archive, review, jobs)
-- =============================================================================
--
-- STATUS: PREPARED ONLY — DO NOT APPLY until reviewed.
--
-- Depends on: 20260891 (featured_promotion_library)
--
-- Extends the durable Event Library for:
--   - manual override / locked fields (auto refresh must not silently overwrite)
--   - soft archive (no hard delete when history may reference definitions)
--   - source_type / aliases / external_source_ids for matching provenance
--   - review queue for ambiguous/material updates and new candidates
--   - refresh jobs for manual Update Event Library + future weekly cron
--
-- NEVER mutates featured_events publication (enabled / is_promoted / windows).
-- =============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regclass('public.featured_promotion_library') IS NULL THEN
    RAISE EXCEPTION
      '20260892 preflight failed: public.featured_promotion_library is missing (apply 20260891 first)'
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Library column extensions
-- ---------------------------------------------------------------------------

ALTER TABLE public.featured_promotion_library
  ADD COLUMN IF NOT EXISTS manual_override boolean NOT NULL DEFAULT false;

ALTER TABLE public.featured_promotion_library
  ADD COLUMN IF NOT EXISTS archived_at timestamptz NULL;

ALTER TABLE public.featured_promotion_library
  ADD COLUMN IF NOT EXISTS source_type text NULL;

ALTER TABLE public.featured_promotion_library
  ADD COLUMN IF NOT EXISTS aliases text[] NOT NULL DEFAULT '{}'::text[];

ALTER TABLE public.featured_promotion_library
  ADD COLUMN IF NOT EXISTS external_source_ids jsonb NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE public.featured_promotion_library
  ADD COLUMN IF NOT EXISTS locked_fields text[] NOT NULL DEFAULT '{}'::text[];

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'featured_promotion_library_source_type_check'
  ) THEN
    ALTER TABLE public.featured_promotion_library
      ADD CONSTRAINT featured_promotion_library_source_type_check
      CHECK (
        source_type IS NULL
        OR source_type IN ('manual', 'official', 'provider', 'curated')
      );
  END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS featured_promotion_library_archived_at_idx
  ON public.featured_promotion_library (archived_at)
  WHERE archived_at IS NULL;

COMMENT ON COLUMN public.featured_promotion_library.manual_override IS
  'When true, automatic refresh detects changes but enqueues Review instead of overwriting curated values.';
COMMENT ON COLUMN public.featured_promotion_library.archived_at IS
  'Soft-archive timestamp. Archived definitions are hidden from normal library browsing; history preserved.';
COMMENT ON COLUMN public.featured_promotion_library.source_type IS
  'Provenance class: manual | official | provider | curated.';
COMMENT ON COLUMN public.featured_promotion_library.aliases IS
  'Alternate names used by the matching engine.';
COMMENT ON COLUMN public.featured_promotion_library.external_source_ids IS
  'Map of adapter id → external identifier for stable matching.';
COMMENT ON COLUMN public.featured_promotion_library.locked_fields IS
  'Field names that automatic refresh must not overwrite (field-level protection).';

-- ---------------------------------------------------------------------------
-- Review queue
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.featured_promotion_library_reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind text NOT NULL,
  definition_slug text NULL,
  candidate jsonb NOT NULL DEFAULT '{}'::jsonb,
  current jsonb NOT NULL DEFAULT '{}'::jsonb,
  proposed jsonb NOT NULL DEFAULT '{}'::jsonb,
  reason text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'pending',
  source_adapter text NULL,
  job_id uuid NULL,
  resolved_at timestamptz NULL,
  resolved_by text NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT featured_promotion_library_reviews_kind_check
    CHECK (kind IN ('date_update', 'host_update', 'field_update', 'new_candidate', 'conflict')),
  CONSTRAINT featured_promotion_library_reviews_status_check
    CHECK (status IN ('pending', 'accepted', 'kept', 'ignored', 'added'))
);

CREATE INDEX IF NOT EXISTS featured_promotion_library_reviews_status_idx
  ON public.featured_promotion_library_reviews (status, created_at DESC);

CREATE INDEX IF NOT EXISTS featured_promotion_library_reviews_definition_slug_idx
  ON public.featured_promotion_library_reviews (definition_slug)
  WHERE definition_slug IS NOT NULL;

COMMENT ON TABLE public.featured_promotion_library_reviews IS
  'Admin review queue for ambiguous library updates and new discovery candidates. Never auto-promotes.';

ALTER TABLE public.featured_promotion_library_reviews ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'featured_promotion_library_reviews'
      AND policyname = 'Service role can manage featured promotion library reviews'
  ) THEN
    CREATE POLICY "Service role can manage featured promotion library reviews"
      ON public.featured_promotion_library_reviews
      FOR ALL
      TO service_role
      USING (true)
      WITH CHECK (true);
  END IF;
END;
$$;

REVOKE ALL ON TABLE public.featured_promotion_library_reviews FROM PUBLIC;
REVOKE ALL ON TABLE public.featured_promotion_library_reviews FROM anon;
REVOKE ALL ON TABLE public.featured_promotion_library_reviews FROM authenticated;
GRANT ALL ON TABLE public.featured_promotion_library_reviews TO service_role;

-- ---------------------------------------------------------------------------
-- Refresh jobs
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.featured_promotion_library_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  status text NOT NULL DEFAULT 'queued',
  phase text NOT NULL DEFAULT 'queued',
  progress jsonb NOT NULL DEFAULT '{}'::jsonb,
  result jsonb NULL,
  error text NULL,
  started_by text NULL,
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT featured_promotion_library_jobs_status_check
    CHECK (status IN ('queued', 'running', 'completed', 'partial', 'failed'))
);

CREATE INDEX IF NOT EXISTS featured_promotion_library_jobs_status_idx
  ON public.featured_promotion_library_jobs (status, started_at DESC);

COMMENT ON TABLE public.featured_promotion_library_jobs IS
  'Update Event Library job status for manual admin runs and future weekly cron. Publication-neutral.';

ALTER TABLE public.featured_promotion_library_jobs ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'featured_promotion_library_jobs'
      AND policyname = 'Service role can manage featured promotion library jobs'
  ) THEN
    CREATE POLICY "Service role can manage featured promotion library jobs"
      ON public.featured_promotion_library_jobs
      FOR ALL
      TO service_role
      USING (true)
      WITH CHECK (true);
  END IF;
END;
$$;

REVOKE ALL ON TABLE public.featured_promotion_library_jobs FROM PUBLIC;
REVOKE ALL ON TABLE public.featured_promotion_library_jobs FROM anon;
REVOKE ALL ON TABLE public.featured_promotion_library_jobs FROM authenticated;
GRANT ALL ON TABLE public.featured_promotion_library_jobs TO service_role;

-- Link reviews.job_id if jobs table exists (safe when both created here).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'featured_promotion_library_reviews_job_id_fkey'
  ) THEN
    ALTER TABLE public.featured_promotion_library_reviews
      ADD CONSTRAINT featured_promotion_library_reviews_job_id_fkey
      FOREIGN KEY (job_id) REFERENCES public.featured_promotion_library_jobs(id)
      ON DELETE SET NULL;
  END IF;
END;
$$;

COMMIT;
