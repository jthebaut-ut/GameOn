-- =============================================================================
-- Staging checks for 20261004 Team scorer attribution.
-- Run AFTER applying supabase/migrations/20261004_0001_fan_team_event_scorer_attribution.sql
-- Manual only. Do NOT run against production from the agent.
--
-- Always-on: structural, kind policy, privilege, authz-before-replay.
-- Runtime matrix: wrap in BEGIN/ROLLBACK and:
--   SELECT set_config('gameon.scoring_runtime_tests', '1', true);
-- =============================================================================

DO $$
DECLARE
  v_src text;
  v_oid oid;
  v_can int;
  v_match int;
BEGIN
  IF to_regclass('public.fan_team_event_score_events') IS NULL THEN
    RAISE EXCEPTION 'missing fan_team_event_score_events';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'fan_team_event_score_events'
      AND column_name = 'scorer_membership_id'
  ) THEN
    RAISE EXCEPTION 'missing scorer_membership_id';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'fan_team_event_score_events'
      AND column_name = 'scorer_display_name_snapshot'
  ) THEN
    RAISE EXCEPTION 'missing scorer_display_name_snapshot';
  END IF;
  IF to_regprocedure(
       'public.update_fan_team_event_score(uuid, uuid, integer, integer, text)'
     ) IS NULL THEN
    RAISE EXCEPTION 'missing 5-arg compatibility wrapper';
  END IF;
  IF to_regprocedure(
       'public.update_fan_team_event_score(uuid, uuid, integer, integer, text, uuid)'
     ) IS NULL THEN
    RAISE EXCEPTION 'missing 6-arg update_fan_team_event_score';
  END IF;

  IF public.fan_team_scorer_attribution_kind('Soccer') IS DISTINCT FROM 'goal' THEN
    RAISE EXCEPTION 'FAIL soccer should be goal';
  END IF;
  IF public.fan_team_scorer_attribution_kind('futsal') IS DISTINCT FROM 'goal' THEN
    RAISE EXCEPTION 'FAIL futsal should be goal';
  END IF;
  IF public.fan_team_scorer_attribution_kind('NHL') IS DISTINCT FROM 'goal' THEN
    RAISE EXCEPTION 'FAIL hockey should be goal';
  END IF;
  IF public.fan_team_scorer_attribution_kind('Lacrosse') IS DISTINCT FROM 'goal' THEN
    RAISE EXCEPTION 'FAIL lacrosse should be goal';
  END IF;
  IF public.fan_team_scorer_attribution_kind('NBA') IS DISTINCT FROM 'score' THEN
    RAISE EXCEPTION 'FAIL basketball should be score';
  END IF;
  IF public.fan_team_scorer_attribution_kind('Baseball') IS DISTINCT FROM 'run' THEN
    RAISE EXCEPTION 'FAIL baseball should be run';
  END IF;
  IF public.fan_team_scorer_attribution_kind('Softball') IS DISTINCT FROM 'run' THEN
    RAISE EXCEPTION 'FAIL softball should be run';
  END IF;
  IF public.fan_team_scorer_attribution_kind('NFL') IS DISTINCT FROM 'touchdown_or_score' THEN
    RAISE EXCEPTION 'FAIL football should be touchdown_or_score';
  END IF;
  IF public.fan_team_scorer_attribution_kind('Volleyball') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL volleyball should be none';
  END IF;
  IF public.fan_team_scorer_attribution_kind('badminton') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL badminton should be none';
  END IF;
  IF public.fan_team_scorer_attribution_kind('Tennis') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL tennis should be none';
  END IF;
  IF public.fan_team_scorer_attribution_kind('padel') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL padel should be none';
  END IF;
  IF public.fan_team_scorer_attribution_kind('Pickleball') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL pickleball should be none';
  END IF;
  IF public.fan_team_scorer_attribution_kind('Running') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL running should be none';
  END IF;

  SELECT p.oid, p.prosrc INTO v_oid, v_src
  FROM pg_proc p
  WHERE p.oid = to_regprocedure(
    'public.update_fan_team_event_score(uuid, uuid, integer, integer, text, uuid)'
  );
  v_can := position('fan_team_viewer_can_score' IN v_src);
  v_match := position('fan_team_score_require_matching_audit' IN v_src);
  IF v_can = 0 OR v_match = 0 OR v_can > v_match THEN
    RAISE EXCEPTION 'FAIL 6-arg must authorize before idempotency replay';
  END IF;
  IF position('fan_team_resolve_eligible_scorer' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL 6-arg missing server scorer validation';
  END IF;
  IF position('Scorer is not on this Team roster' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL 6-arg missing scorer rejection';
  END IF;
  IF position('v_kind = ''increment''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL scorer must require increment';
  END IF;

  IF has_table_privilege('authenticated', 'public.fan_team_event_score_events', 'UPDATE') THEN
    RAISE EXCEPTION 'FAIL authenticated can UPDATE score audit';
  END IF;

  RAISE NOTICE '20261004 scorer attribution structural checks passed';
END $$;

DO $$
DECLARE
  v_owner uuid;
  v_manager uuid;
  v_member uuid;
  v_player uuid;
  v_other uuid;
  v_team_a uuid;
  v_team_b uuid;
  v_conv_a uuid;
  v_conv_b uuid;
  v_league uuid := gen_random_uuid();
  v_seat uuid;
  v_other_seat uuid;
  v_removed_seat uuid;
  v_admin_seat uuid;
  v_team_score integer;
  v_replayed boolean;
  v_audit public.fan_team_event_score_events%ROWTYPE;
  v_push int;
BEGIN
  IF current_setting('gameon.scoring_runtime_tests', true) IS DISTINCT FROM '1' THEN
    RETURN;
  END IF;

  SELECT id INTO v_owner FROM auth.users LIMIT 1;
  IF v_owner IS NULL THEN
    RAISE NOTICE 'SKIP runtime scorer matrix: no auth.users';
    RETURN;
  END IF;

  -- Reuse scoring audit users if present; otherwise skip.
  BEGIN
    INSERT INTO public.group_conversations (title, created_by)
    VALUES ('__scorer_audit_A', v_owner)
    RETURNING id INTO v_conv_a;
    INSERT INTO public.group_conversations (title, created_by)
    VALUES ('__scorer_audit_B', v_owner)
    RETURNING id INTO v_conv_b;
    INSERT INTO public.fan_teams (name, sport, owner_user_id, group_conversation_id)
    VALUES ('__scorer_audit_A', 'Soccer', v_owner, v_conv_a)
    RETURNING id INTO v_team_a;
    INSERT INTO public.fan_teams (name, sport, owner_user_id, group_conversation_id)
    VALUES ('__scorer_audit_B', 'Soccer', v_owner, v_conv_b)
    RETURNING id INTO v_team_b;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'SKIP runtime scorer matrix: cannot create Team fixtures (%)', SQLERRM;
    RETURN;
  END;

  v_manager := v_owner;
  INSERT INTO public.fan_team_members (team_id, user_id, role, is_player)
  VALUES (v_team_a, v_owner, 'owner', true)
  ON CONFLICT (team_id, user_id) DO UPDATE SET left_at = NULL, is_player = true
  RETURNING membership_id INTO v_seat;

  -- Admin-only non-player seat (same owner cannot be both; create a dummy if extra users exist)
  SELECT id INTO v_member
  FROM auth.users
  WHERE id <> v_owner
  LIMIT 1;
  IF v_member IS NOT NULL THEN
    INSERT INTO public.fan_team_members (team_id, user_id, role, is_player)
    VALUES (v_team_a, v_member, 'member', false)
    ON CONFLICT (team_id, user_id) DO UPDATE SET left_at = NULL, is_player = false, role = 'member'
    RETURNING membership_id INTO v_admin_seat;
  END IF;

  SELECT id INTO v_other
  FROM auth.users
  WHERE id <> v_owner AND id IS DISTINCT FROM v_member
  LIMIT 1;
  IF v_other IS NOT NULL THEN
    INSERT INTO public.fan_team_members (team_id, user_id, role, is_player)
    VALUES (v_team_b, v_other, 'member', true)
    ON CONFLICT (team_id, user_id) DO UPDATE SET left_at = NULL, is_player = true
    RETURNING membership_id INTO v_other_seat;
  END IF;

  INSERT INTO public.pickup_games (
    id, creator_user_id, title, sport, status, is_visible, game_start_at, players_needed,
    game_format, opponent_name, scoring_status
  ) VALUES (
    v_league, v_owner, 'Scorer League', 'Soccer', 'active', true, now() + interval '1 day', 5,
    'league_game', 'Rivals', 'live'
  )
  ON CONFLICT (id) DO UPDATE
    SET scoring_status = 'live', opponent_name = 'Rivals', sport = 'Soccer', game_format = 'league_game';

  INSERT INTO public.fan_team_game_links (pickup_game_id, team_id, side)
  VALUES (v_league, v_team_a, 'home')
  ON CONFLICT (pickup_game_id, team_id) DO UPDATE SET side = 'home';

  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text,
    true
  );
  PERFORM set_config('gameon.fan_team_scoring_rpc', '1', true);

  -- Valid roster scorer accepted
  SELECT team_score, replayed
  INTO v_team_score, v_replayed
  FROM public.update_fan_team_event_score(
    v_league, v_team_a, 1, 0, 'scorer-valid-key-01', v_seat
  );
  IF v_team_score IS DISTINCT FROM 1 OR v_replayed IS TRUE THEN
    RAISE EXCEPTION 'FAIL valid scorer +1';
  END IF;
  SELECT * INTO v_audit
  FROM public.fan_team_event_score_events
  WHERE idempotency_key = 'scorer-valid-key-01';
  IF v_audit.scorer_membership_id IS DISTINCT FROM v_seat THEN
    RAISE EXCEPTION 'FAIL scorer membership not persisted';
  END IF;
  IF nullif(btrim(v_audit.scorer_display_name_snapshot), '') IS NULL THEN
    RAISE EXCEPTION 'FAIL scorer name snapshot missing';
  END IF;
  IF v_audit.scorer_attribution_kind IS DISTINCT FROM 'goal' THEN
    RAISE EXCEPTION 'FAIL soccer kind should be goal';
  END IF;

  -- Retry same key preserves scorer and does not duplicate
  SELECT team_score, replayed
  INTO v_team_score, v_replayed
  FROM public.update_fan_team_event_score(
    v_league, v_team_a, 1, 0, 'scorer-valid-key-01', v_seat
  );
  IF v_replayed IS NOT TRUE OR v_team_score IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL retry did not replay';
  END IF;
  SELECT count(*) INTO v_push
  FROM public.fan_team_event_score_events
  WHERE idempotency_key = 'scorer-valid-key-01';
  IF v_push IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL duplicate audit on retry';
  END IF;

  -- Skip/null accepted
  SELECT team_score INTO v_team_score
  FROM public.update_fan_team_event_score(
    v_league, v_team_a, 1, 0, 'scorer-skip-key-01', NULL
  );
  IF v_team_score IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'FAIL skip +1';
  END IF;
  SELECT * INTO v_audit
  FROM public.fan_team_event_score_events
  WHERE idempotency_key = 'scorer-skip-key-01';
  IF v_audit.scorer_membership_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL skip stored a scorer';
  END IF;

  -- Invalid membership rejected
  BEGIN
    PERFORM * FROM public.update_fan_team_event_score(
      v_league, v_team_a, 1, 0, 'scorer-invalid-key01', gen_random_uuid()
    );
    RAISE EXCEPTION 'FAIL invalid scorer accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%Scorer is not on this Team roster%' THEN
      RAISE EXCEPTION 'FAIL invalid scorer expected roster error, got %', SQLERRM;
    END IF;
  END;

  -- Wrong team rejected
  IF v_other_seat IS NOT NULL THEN
    BEGIN
      PERFORM * FROM public.update_fan_team_event_score(
        v_league, v_team_a, 1, 0, 'scorer-wrong-team-k01', v_other_seat
      );
      RAISE EXCEPTION 'FAIL wrong-team scorer accepted';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT ILIKE '%Scorer is not on this Team roster%' THEN
        RAISE EXCEPTION 'FAIL wrong-team expected roster error, got %', SQLERRM;
      END IF;
    END;
  END IF;

  -- Non-player seat rejected
  IF v_admin_seat IS NOT NULL THEN
    BEGIN
      PERFORM * FROM public.update_fan_team_event_score(
        v_league, v_team_a, 1, 0, 'scorer-admin-key-001', v_admin_seat
      );
      RAISE EXCEPTION 'FAIL admin-only scorer accepted';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT ILIKE '%Scorer is not on this Team roster%' THEN
        RAISE EXCEPTION 'FAIL admin-only expected roster error, got %', SQLERRM;
      END IF;
    END;
  END IF;

  -- Removed roster player rejected
  INSERT INTO public.fan_team_members (team_id, user_id, role, is_player, left_at)
  SELECT v_team_a, u.id, 'member', true, now()
  FROM auth.users u
  WHERE u.id <> v_owner AND u.id IS DISTINCT FROM v_member AND u.id IS DISTINCT FROM v_other
  LIMIT 1
  ON CONFLICT (team_id, user_id) DO UPDATE SET left_at = now(), is_player = true
  RETURNING membership_id INTO v_removed_seat;
  IF v_removed_seat IS NOT NULL THEN
    BEGIN
      PERFORM * FROM public.update_fan_team_event_score(
        v_league, v_team_a, 1, 0, 'scorer-removed-key01', v_removed_seat
      );
      RAISE EXCEPTION 'FAIL removed scorer accepted';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT ILIKE '%Scorer is not on this Team roster%' THEN
        RAISE EXCEPTION 'FAIL removed expected roster error, got %', SQLERRM;
      END IF;
    END;
  END IF;

  -- Decrement cannot carry scorer
  SELECT team_score INTO v_team_score
  FROM public.update_fan_team_event_score(
    v_league, v_team_a, -1, 0, 'scorer-decrement-k01', v_seat
  );
  SELECT * INTO v_audit
  FROM public.fan_team_event_score_events
  WHERE idempotency_key = 'scorer-decrement-k01';
  IF v_audit.scorer_membership_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL decrement stored a scorer';
  END IF;
  IF v_audit.kind IS DISTINCT FROM 'decrement' THEN
    RAISE EXCEPTION 'FAIL decrement kind';
  END IF;

  RAISE NOTICE '20261004 scorer attribution runtime checks passed';
END $$;
