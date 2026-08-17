-- Staging checks for 20260979 own-managed-player Team membership auth.
-- Manual / staging only. Do NOT run against production from the agent.

DO $$
DECLARE
  v_add text;
  v_remove text;
BEGIN
  IF to_regprocedure('public.add_managed_player_to_fan_team(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'add_managed_player_to_fan_team missing — apply 20260979';
  END IF;
  IF to_regprocedure('public.remove_fan_team_membership(uuid)') IS NULL THEN
    RAISE EXCEPTION 'remove_fan_team_membership missing — apply 20260979';
  END IF;

  SELECT pg_get_functiondef('public.add_managed_player_to_fan_team(uuid,uuid)'::regprocedure)
  INTO v_add;
  IF position('fan_team_viewer_can_manage' IN v_add) > 0 THEN
    RAISE EXCEPTION 'add_managed_player_to_fan_team must not require fan_team_viewer_can_manage';
  END IF;
  IF position('is_authorized_managed_player_guardian' IN v_add) = 0 THEN
    RAISE EXCEPTION 'add_managed_player_to_fan_team must require guardian auth';
  END IF;
  IF position('is_active_fan_team_member' IN v_add) = 0 THEN
    RAISE EXCEPTION 'add_managed_player_to_fan_team must require active account membership';
  END IF;

  SELECT pg_get_functiondef('public.remove_fan_team_membership(uuid)'::regprocedure)
  INTO v_remove;
  IF position('is_authorized_managed_player_guardian' IN v_remove) = 0 THEN
    RAISE EXCEPTION 'remove_fan_team_membership must allow guardian path for own managed seats';
  END IF;
  IF position('fan_team_viewer_can_manage' IN v_remove) = 0 THEN
    RAISE EXCEPTION 'remove_fan_team_membership must retain staff path';
  END IF;
  IF position('leave_fan_team' IN v_remove) = 0 THEN
    RAISE EXCEPTION 'remove_fan_team_membership must still reject self-account via leave_fan_team';
  END IF;

  RAISE NOTICE '20260979 own-managed-player membership auth checks PASSED.';
END $$;

-- Manual mutation checklist (organizer/member JWT fixtures):
-- A) Ordinary member + own child → add_managed_player_to_fan_team succeeds
-- B) Same member → remove_fan_team_membership on child's seat succeeds
-- C) Owner / Manager / Captain / Head Coach → same add/remove on own child
-- D) Member → remove_fan_team_membership on own account seat → rejected (leave_fan_team)
-- E) Member → add another user's managed_player_id → not authorized
-- F) Member → remove another user's managed seat → not authorized
-- G) Manager → remove another user's managed seat → still authorized (staff)
