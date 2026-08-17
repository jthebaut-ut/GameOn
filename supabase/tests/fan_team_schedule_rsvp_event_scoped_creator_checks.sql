-- =============================================================================
-- Staging checks: 20260962 Team Schedule creator RSVP (event-scoped)
-- =============================================================================
-- Run AFTER applying 20260961 then 20260962 (manual / staging only).
-- Structural + contract proofs for matrix A–S. No production mutation.
-- =============================================================================

DO $$
DECLARE
  v_roster text;
  v_link text;
  v_lineup text;
  v_rsvp text;
  v_sched text;
BEGIN
  IF to_regprocedure('public.get_pickup_game_roster(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: get_pickup_game_roster missing';
  END IF;

  SELECT prosrc INTO v_roster
  FROM pg_proc
  WHERE oid = to_regprocedure('public.get_pickup_game_roster(uuid)');

  -- -------------------------------------------------------------------------
  -- Preserve 20260961 managed-player / dual-identity / exclusion / lineup-adjacent
  -- -------------------------------------------------------------------------
  IF position('fan_team_event_rsvps' IN v_roster) = 0 THEN
    RAISE EXCEPTION 'FAIL R: fan_team_event_rsvps missing (managed RSVP regress)';
  END IF;
  IF position('is_managed_player' IN v_roster) = 0 THEN
    RAISE EXCEPTION 'FAIL R: is_managed_player missing';
  END IF;
  IF position('membership_id' IN v_roster) = 0 THEN
    RAISE EXCEPTION 'FAIL R: membership_id missing';
  END IF;
  IF position('managed_player_id' IN v_roster) = 0 THEN
    RAISE EXCEPTION 'FAIL R: managed_player_id missing';
  END IF;
  IF position('is_fan_team_event_managed_player_excluded' IN v_roster) = 0 THEN
    RAISE EXCEPTION 'FAIL Q: managed exclusion helper missing';
  END IF;
  IF position('v_playing := v_playing || v_managed_playing' IN v_roster) = 0 THEN
    RAISE EXCEPTION 'FAIL H/I/J: managed playing merge missing';
  END IF;
  IF position('v_pending := v_pending || v_managed_pending' IN v_roster) = 0 THEN
    RAISE EXCEPTION 'FAIL R: managed pending merge missing';
  END IF;
  IF position('v_declined := v_declined || v_managed_declined' IN v_roster) = 0 THEN
    RAISE EXCEPTION 'FAIL R: managed declined merge missing';
  END IF;
  IF position('v_no_response := v_no_response || v_managed_no_response' IN v_roster) = 0 THEN
    RAISE EXCEPTION 'FAIL R: managed no_response merge missing';
  END IF;
  IF position('v_excluded := v_excluded || v_managed_excluded' IN v_roster) = 0 THEN
    RAISE EXCEPTION 'FAIL Q: managed excluded merge missing';
  END IF;

  -- -------------------------------------------------------------------------
  -- A–D / creator RSVP presentation (Team-linked)
  -- -------------------------------------------------------------------------
  -- A no RSVP → no_response includes creator (no longer excluded by IS DISTINCT FROM v_creator)
  IF position('Include creator when they have no pickup_game_requests row' IN v_roster) = 0 THEN
    RAISE EXCEPTION 'FAIL A: Team creator no_response inclusion missing';
  END IF;
  -- B approved → playing includes Team creator
  IF position('v_team_id IS NOT NULL' IN v_roster) = 0
     OR position('Team-linked: creator appears in playing' IN v_roster) = 0 THEN
    RAISE EXCEPTION 'FAIL B: Team creator approved→playing branch missing';
  END IF;
  -- C pending already included for all requesters (no creator exclusion on pending)
  IF position('lower(btrim(r.status)) = ''pending''' IN v_roster) = 0 THEN
    RAISE EXCEPTION 'FAIL C: pending bucket missing';
  END IF;
  -- D withdrawn → declined includes creator
  IF position('Include creator Can''t Go for THIS event' IN v_roster) = 0
     AND position('Team Schedule: include creator' IN v_roster) = 0 THEN
    RAISE EXCEPTION 'FAIL D: Team creator declined inclusion missing';
  END IF;

  -- -------------------------------------------------------------------------
  -- E create path does not auto-Going (authoritative link RPC)
  -- -------------------------------------------------------------------------
  IF to_regprocedure('public.link_pickup_game_to_fan_team(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL E: link_pickup_game_to_fan_team missing';
  END IF;
  SELECT prosrc INTO v_link
  FROM pg_proc
  WHERE oid = to_regprocedure('public.link_pickup_game_to_fan_team(uuid,uuid)');
  IF position('INSERT INTO public.pickup_game_requests' IN coalesce(v_link, '')) > 0 THEN
    RAISE EXCEPTION 'FAIL E: link_pickup_game_to_fan_team auto-inserts creator RSVP';
  END IF;

  -- -------------------------------------------------------------------------
  -- F/G event-scoped: roster filters by p_pickup_game_id (no team-wide RSVP)
  -- -------------------------------------------------------------------------
  IF position('r.pickup_game_id = p_pickup_game_id' IN v_roster) = 0 THEN
    RAISE EXCEPTION 'FAIL F/G: event-scoped request filter missing';
  END IF;

  -- -------------------------------------------------------------------------
  -- H/I/J Team playing_total after managed merge
  -- -------------------------------------------------------------------------
  IF position('jsonb_array_length(v_playing)' IN v_roster) = 0 THEN
    RAISE EXCEPTION 'FAIL H/I/J: Team playing_total_count must count Going seats after merge';
  END IF;
  IF position('WHEN v_team_id IS NULL THEN 1 + v_account_playing_count' IN v_roster) = 0 THEN
    RAISE EXCEPTION 'FAIL P: standalone host playing_total semantics missing';
  END IF;

  -- -------------------------------------------------------------------------
  -- K–O taxonomy still on link path (Team create)
  -- -------------------------------------------------------------------------
  FOREACH v_sched IN ARRAY ARRAY[
    'practice', 'scrimmage', 'match', 'league_game', 'tournament_game',
    'tryout', 'clinic', 'team_meeting', 'other'
  ]
  LOOP
    IF position(quote_literal(v_sched) IN coalesce(v_link, '')) = 0
       AND position(v_sched IN coalesce(v_link, '')) = 0 THEN
      RAISE EXCEPTION 'FAIL K–O: link taxonomy missing %', v_sched;
    END IF;
  END LOOP;

  -- -------------------------------------------------------------------------
  -- P standalone: creator still excluded from playing when v_team_id IS NULL
  -- -------------------------------------------------------------------------
  IF position('v_team_id IS NULL AND r.requester_user_id IS DISTINCT FROM v_creator' IN v_roster) = 0 THEN
    RAISE EXCEPTION 'FAIL P: standalone creator-out-of-playing guard missing';
  END IF;

  -- -------------------------------------------------------------------------
  -- S lineup RPCs untouched by 60962 (still present from 60961)
  -- -------------------------------------------------------------------------
  SELECT prosrc INTO v_lineup
  FROM pg_proc
  WHERE proname = 'save_fan_team_event_lineup'
  ORDER BY oid DESC
  LIMIT 1;
  IF v_lineup IS NULL OR position('managed_player_id' IN v_lineup) = 0 THEN
    RAISE EXCEPTION 'FAIL S: save_fan_team_event_lineup managed support missing';
  END IF;

  SELECT prosrc INTO v_rsvp
  FROM pg_proc
  WHERE proname = 'set_fan_team_game_rsvp_for_membership'
  ORDER BY oid DESC
  LIMIT 1;
  IF v_rsvp IS NULL OR position('fan_team_event_rsvps' IN v_rsvp) = 0 THEN
    RAISE EXCEPTION 'FAIL R: set_fan_team_game_rsvp_for_membership missing/regress';
  END IF;

  -- -------------------------------------------------------------------------
  -- Prove 60962 did not need to / must not regress schedule_fan_team_game taxonomy
  -- by ensuring we did NOT require it for create; if present, do not fail — but
  -- warn if body still has narrow match/scrimmage/practice-only gate (legacy).
  -- -------------------------------------------------------------------------
  SELECT prosrc INTO v_sched
  FROM pg_proc
  WHERE proname = 'schedule_fan_team_game'
  ORDER BY oid DESC
  LIMIT 1;
  IF v_sched IS NOT NULL
     AND position('team_meeting' IN v_sched) = 0
     AND position('''match''' IN v_sched) > 0 THEN
    RAISE NOTICE 'INFO: legacy schedule_fan_team_game still present with narrow taxonomy; '
      'iOS Team create must use link_pickup_game_to_fan_team (verified above). '
      'Do NOT replace schedule_fan_team_game from 20260926 in 60962.';
  END IF;

  RAISE NOTICE 'PASS: fan_team_schedule_rsvp_event_scoped_creator_checks (A–S structural)';
END $$;
