-- =============================================================================
-- 20260973_0001 — Optional arrival_time on pickup_games (Team Schedule)
-- =============================================================================
-- Nullable timestamptz for "arrive by" guidance distinct from game_start_at.
-- Existing rows remain NULL.
-- Applied to production; client select list includes arrival_time for edit hydration.
-- =============================================================================

DO $$
BEGIN
  IF to_regclass('public.pickup_games') IS NULL THEN
    RAISE EXCEPTION '20260973_0001 prerequisites missing: table public.pickup_games';
  END IF;
END $$;

ALTER TABLE public.pickup_games
  ADD COLUMN IF NOT EXISTS arrival_time timestamptz NULL;

COMMENT ON COLUMN public.pickup_games.arrival_time IS
  'Optional player arrival instant (may be before game_start_at). Null = not specified.';
