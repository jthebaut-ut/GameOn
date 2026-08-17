-- =============================================================================
-- 20260969_0001 — Enable managed_player_team_seats runtime flag
-- =============================================================================
-- Compatible FanGeo clients now tolerate nullable fan_team_members.user_id and
-- membership_id-based roster seats (20260960+). Seat-creating RPCs were gated
-- off by default so old clients would not crash.
--
-- Without this flag:
--   • accept_fan_team_invitation_for_participants rejects managed selections
--   • add_managed_player_to_fan_team raises managed_player_team_seats_disabled
-- Guardians who accept "Myself" only (or who own a Team) cannot place children
-- on the roster → My Players shows "0 teams" and Player Info has no Change.
--
-- This migration only flips the rollout flag. It does NOT rewrite memberships.
-- Do NOT apply from the agent; review and apply deliberately in Supabase.
-- =============================================================================

BEGIN;

UPDATE public.fan_geo_runtime_flags
SET
  enabled = true,
  updated_at = now(),
  note = 'Enabled after FanGeo builds that tolerate managed Team seats (nullable user_id / membership_id).'
WHERE flag_key = 'managed_player_team_seats';

INSERT INTO public.fan_geo_runtime_flags (flag_key, enabled, note)
SELECT
  'managed_player_team_seats',
  true,
  'Enabled after FanGeo builds that tolerate managed Team seats (nullable user_id / membership_id).'
WHERE NOT EXISTS (
  SELECT 1
  FROM public.fan_geo_runtime_flags
  WHERE flag_key = 'managed_player_team_seats'
);

DO $$
BEGIN
  IF NOT public.is_fan_geo_runtime_flag_enabled('managed_player_team_seats') THEN
    RAISE EXCEPTION 'assert_failed: managed_player_team_seats must be enabled after 20260969';
  END IF;
END $$;

COMMIT;
