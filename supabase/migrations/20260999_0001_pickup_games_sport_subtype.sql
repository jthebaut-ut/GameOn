-- =============================================================================
-- 20260999_0001 — Optional reusable sport_subtype on pickup_games
-- =============================================================================
-- Adds a nullable activity subtype (Cycling / Electric Scooter / Inline Skating
-- now; Running / Skiing / Climbing later) without changing sport tokens.
--
-- Existing Biking/Cycling rows remain valid (subtype NULL).
-- No recipient / notification / RLS changes.
-- PREPARE ONLY — do not auto-apply.
-- =============================================================================

DO $$
BEGIN
  IF to_regclass('public.pickup_games') IS NULL THEN
    RAISE EXCEPTION '20260999 missing public.pickup_games';
  END IF;
END $$;

BEGIN;

ALTER TABLE public.pickup_games
  ADD COLUMN IF NOT EXISTS sport_subtype text;

ALTER TABLE public.pickup_games
  DROP CONSTRAINT IF EXISTS pickup_games_sport_subtype_len;

ALTER TABLE public.pickup_games
  ADD CONSTRAINT pickup_games_sport_subtype_len
  CHECK (
    sport_subtype IS NULL
    OR (
      char_length(btrim(sport_subtype)) BETWEEN 1 AND 40
      AND sport_subtype = btrim(sport_subtype)
    )
  );

COMMENT ON COLUMN public.pickup_games.sport_subtype IS
  'Optional reusable activity subtype token (e.g. mountain_biking, group_ride). '
  'Interpreted with pickup_games.sport. NULL = unspecified / sports without subtypes. '
  'Client catalog is the allowlist; sport remains free-text as today.';

COMMIT;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'pickup_games'
      AND column_name = 'sport_subtype'
  ) THEN
    RAISE EXCEPTION '20260999 sport_subtype column missing';
  END IF;
END $$;
