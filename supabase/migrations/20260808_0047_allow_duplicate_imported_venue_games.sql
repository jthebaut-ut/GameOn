-- Allow multiple active imported listings for the same external game at one venue
-- (e.g. multiple TVs or watch areas). Client duplicate detection remains advisory.

DROP INDEX IF EXISTS public.idx_venue_events_unique_external_game_per_venue_day;
DROP INDEX IF EXISTS public.idx_venue_events_unique_external_game_per_owner_day;

CREATE INDEX IF NOT EXISTS idx_venue_events_external_game_per_venue_day
  ON public.venue_events (venue_id, event_date, external_source, external_game_id)
  WHERE external_game_id IS NOT NULL
    AND COALESCE(admin_status, 'active') = 'active';

CREATE INDEX IF NOT EXISTS idx_venue_events_external_game_per_owner_day
  ON public.venue_events (owner_email, event_date, external_source, external_game_id)
  WHERE venue_id IS NULL
    AND external_game_id IS NOT NULL
    AND COALESCE(admin_status, 'active') = 'active';

COMMENT ON INDEX public.idx_venue_events_external_game_per_venue_day IS
  'Lookup index for imported venue games per venue/day; duplicates allowed for multi-screen listings.';
COMMENT ON INDEX public.idx_venue_events_external_game_per_owner_day IS
  'Lookup index for legacy owner-scoped imported venue games; duplicates allowed for multi-screen listings.';
