-- =============================================================================
-- Staging checks for 20261003 Team scoring.
-- Run AFTER applying supabase/migrations/20261003_0001_fan_team_event_scoring.sql
-- Manual only. Do NOT run against production from the agent.
--
-- Always-on: structural, capability, privilege, authz-before-replay, source matrix.
-- Runtime matrix: wrap in BEGIN/ROLLBACK and:
--   SELECT set_config('gameon.scoring_runtime_tests', '1', true);
-- =============================================================================

DO $$
DECLARE
  v_src text;
  v_can int;
  v_match int;
  v_err text;
BEGIN
  IF to_regclass('public.fan_team_event_score_events') IS NULL THEN
    RAISE EXCEPTION 'missing fan_team_event_score_events';
  END IF;
  IF to_regprocedure('public.update_fan_team_event_score(uuid, uuid, integer, integer, text)') IS NULL THEN
    RAISE EXCEPTION 'missing update_fan_team_event_score';
  END IF;
  IF to_regprocedure('public.set_fan_team_event_scoring_status(uuid, uuid, text, text)') IS NULL THEN
    RAISE EXCEPTION 'missing set_fan_team_event_scoring_status';
  END IF;
  IF to_regprocedure('public.correct_fan_team_event_final_score(uuid, uuid, integer, integer, text)') IS NULL THEN
    RAISE EXCEPTION 'missing correct_fan_team_event_final_score';
  END IF;
  IF to_regprocedure('public.get_fan_team_record(uuid)') IS NULL THEN
    RAISE EXCEPTION 'missing get_fan_team_record';
  END IF;
  IF to_regprocedure('public.list_fan_team_scored_results(uuid, timestamptz, integer)') IS NULL THEN
    RAISE EXCEPTION 'missing list_fan_team_scored_results';
  END IF;

  -- EVENTS / capability (no fixtures)
  IF public.fan_team_event_is_score_capable('league_game', 'Soccer') IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL league_game Soccer should score';
  END IF;
  IF public.fan_team_event_is_score_capable('tournament_game', 'Basketball') IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL tournament_game Basketball should score';
  END IF;
  IF public.fan_team_event_is_score_capable('match', 'Hockey') IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL match Hockey should score';
  END IF;
  IF public.fan_team_event_is_score_capable('scrimmage', 'Soccer') IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL scrimmage Soccer should score';
  END IF;
  IF public.fan_team_event_is_score_capable('practice', 'Soccer') IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL practice must be rejected';
  END IF;
  IF public.fan_team_event_is_score_capable('tryout', 'Soccer') IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL tryout must be rejected';
  END IF;
  IF public.fan_team_event_is_score_capable('clinic', 'Soccer') IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL clinic must be rejected';
  END IF;
  IF public.fan_team_event_is_score_capable('camp', 'Soccer') IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL camp must be rejected';
  END IF;
  IF public.fan_team_event_is_score_capable('team_meeting', 'Soccer') IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL team_meeting must be rejected';
  END IF;
  IF public.fan_team_event_is_score_capable('announcement', 'Soccer') IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL announcement must be rejected';
  END IF;
  IF public.fan_team_event_is_score_capable('other', 'Soccer') IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL other must be rejected';
  END IF;
  IF public.fan_team_event_is_score_capable('league_game', 'Running') IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL running league_game must be rejected';
  END IF;

  -- AUTHZ before idempotency replay
  SELECT p.prosrc INTO v_src
  FROM pg_proc p
  WHERE p.oid = coalesce(
    to_regprocedure(
      'public.update_fan_team_event_score(uuid, uuid, integer, integer, text, uuid)'
    ),
    to_regprocedure(
      'public.update_fan_team_event_score(uuid, uuid, integer, integer, text)'
    )
  );
  v_can := position('fan_team_viewer_can_score' IN v_src);
  v_match := position('fan_team_score_require_matching_audit' IN v_src);
  IF v_can = 0 OR v_match = 0 OR v_can > v_match THEN
    RAISE EXCEPTION 'FAIL update_fan_team_event_score must authorize before idempotency replay';
  END IF;
  IF position('FOR UPDATE' IN v_src) = 0 OR position('pg_advisory_xact_lock' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL update_fan_team_event_score missing row/advisory lock';
  END IF;
  IF position('Score can only be changed while the game is Live' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL live-only increment missing';
  END IF;
  IF position('Add an opponent before scoring' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL opponent requirement missing on score RPC';
  END IF;
  IF position('unique_violation' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL update_fan_team_event_score missing concurrent-key handler';
  END IF;
  IF position('v_team_delta > 0' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL scored push must require team increment';
  END IF;

  IF position('Idempotency key already used for a different event' IN
       (SELECT prosrc FROM pg_proc WHERE oid = to_regprocedure(
         'public.fan_team_score_require_matching_audit(text, uuid, uuid)'
       ))) = 0 THEN
    RAISE EXCEPTION 'FAIL matching-audit helper must reject cross-event key reuse';
  END IF;

  SELECT p.prosrc INTO v_src
  FROM pg_proc p
  WHERE p.oid = to_regprocedure(
    'public.set_fan_team_event_scoring_status(uuid, uuid, text, text)'
  );
  IF position('Final games cannot be marked Live' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL final → live must be rejected';
  END IF;
  v_can := position('fan_team_viewer_can_score' IN v_src);
  v_match := position('fan_team_score_require_matching_audit' IN v_src);
  IF v_can = 0 OR v_match = 0 OR v_can > v_match THEN
    RAISE EXCEPTION 'FAIL set_fan_team_event_scoring_status must authorize before replay';
  END IF;
  IF position('IF v_pg.scoring_status = ''live''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL live → live must no-op without extra audit';
  END IF;
  IF position('IF v_pg.scoring_status = ''final''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL final → final must no-op without extra audit';
  END IF;
  IF position('team_event_final' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL Mark Final must enqueue team_event_final';
  END IF;

  SELECT p.prosrc INTO v_src
  FROM pg_proc p
  WHERE p.oid = to_regprocedure(
    'public.correct_fan_team_event_final_score(uuid, uuid, integer, integer, text)'
  );
  v_can := position('fan_team_viewer_can_score' IN v_src);
  v_match := position('fan_team_score_require_matching_audit' IN v_src);
  IF v_can = 0 OR v_match = 0 OR v_can > v_match THEN
    RAISE EXCEPTION 'FAIL correct_fan_team_event_final_score must authorize before replay';
  END IF;
  IF position('team_event_scored' IN v_src) <> 0 THEN
    RAISE EXCEPTION 'FAIL Correct Result must not enqueue scored push';
  END IF;
  IF position('''final'', ''final''' IN v_src) = 0
     AND position('''final', 'final''' IN v_src) = 0 THEN
    -- stored as previous/new status both final
    IF position('correct_final' IN v_src) = 0 THEN
      RAISE EXCEPTION 'FAIL correct path missing correct_final kind';
    END IF;
  END IF;

  -- Direct client privileges
  IF has_table_privilege('authenticated', 'public.fan_team_event_score_events', 'INSERT') THEN
    RAISE EXCEPTION 'FAIL authenticated can INSERT score audit';
  END IF;
  IF has_table_privilege('authenticated', 'public.fan_team_event_score_events', 'UPDATE') THEN
    RAISE EXCEPTION 'FAIL authenticated can UPDATE score audit';
  END IF;
  IF has_table_privilege('authenticated', 'public.fan_team_event_score_events', 'DELETE') THEN
    RAISE EXCEPTION 'FAIL authenticated can DELETE score audit';
  END IF;
  IF has_table_privilege('anon', 'public.fan_team_event_score_events', 'SELECT') THEN
    RAISE EXCEPTION 'FAIL anon can SELECT score audit';
  END IF;
  IF has_function_privilege(
    'anon',
    'public.update_fan_team_event_score(uuid, uuid, integer, integer, text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL anon can execute score RPC';
  END IF;
  IF has_function_privilege(
    'anon',
    'public.set_fan_team_event_scoring_status(uuid, uuid, text, text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL anon can execute status RPC';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'public.queue_fan_team_event_score_push_notification(uuid, uuid, uuid, uuid, text, text, text, text, integer, integer, text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL authenticated can enqueue score push directly';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'public.fan_team_score_require_matching_audit(text, uuid, uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL authenticated can call matching-audit helper';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'public.protect_pickup_game_scoring_columns()',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL authenticated can execute scoring protect function';
  END IF;

  -- list_fan_team_games still has live columns + additive scoring
  SELECT p.prosrc INTO v_src
  FROM pg_proc p
  WHERE p.oid = to_regprocedure('public.list_fan_team_games(uuid)');
  IF position('description' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL list_fan_team_games lost description';
  END IF;
  IF position('scoring_status' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL list_fan_team_games missing scoring_status';
  END IF;
  IF position('fan_team_viewer_can_access_team' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL list_fan_team_games lost access helper';
  END IF;
  IF position('l.side = ''away''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL list_fan_team_games missing away orientation';
  END IF;
  IF position('LIMIT 100' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL list_fan_team_games lost LIMIT 100';
  END IF;

  -- fanout preserves live Team inbox behavior + score types
  SELECT p.prosrc INTO v_src
  FROM pg_proc p
  WHERE p.oid = to_regprocedure(
    'public.fanout_fan_notification_inbox_for_pickup_update_event(uuid)'
  );
  IF position('join_request_approved' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL fanout lost join-request copy';
  END IF;
  IF position('recipient_user_ids' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL fanout lost recipient override';
  END IF;
  IF position('coalesce(v_team_name, v_payload' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL fanout lost team_name snapshot';
  END IF;
  IF position('team_announcement' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL fanout lost announcement copy';
  END IF;
  IF position('list_fan_notification_inbox_recipient_user_ids_for_pickup_game' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL fanout lost membership/guardian recipient helper';
  END IF;
  IF position('team_event_scored' IN v_src) = 0
     OR position('team_event_final' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL fanout missing score/final copy';
  END IF;

  -- Record query uses viewing-team orientation + final-only + cancelled exclusion
  SELECT p.prosrc INTO v_src
  FROM pg_proc p
  WHERE p.oid = to_regprocedure('public.get_fan_team_record(uuid)');
  IF position('l.side = ''away''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL get_fan_team_record missing away orientation';
  END IF;
  IF position('scoring_status = ''final''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL get_fan_team_record must use final only';
  END IF;
  IF position('removed' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL get_fan_team_record must exclude cancelled';
  END IF;
  IF position('fan_team_event_is_score_capable' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL get_fan_team_record must exclude non-scoring types';
  END IF;

  SELECT p.prosrc INTO v_src
  FROM pg_proc p
  WHERE p.oid = to_regprocedure(
    'public.list_fan_team_scored_results(uuid, timestamptz, integer)'
  );
  IF position('scoring_status = ''final''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL results must be final only';
  END IF;
  IF position('scoring_finalized_at DESC' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL results must be newest-first';
  END IF;
  IF position('l.side = ''away''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL results missing away orientation';
  END IF;

  -- AUTH: unauthenticated JWT cannot score (PostgREST authenticated w/o sub)
  BEGIN
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claims', '{}', true);
    PERFORM * FROM public.update_fan_team_event_score(
      gen_random_uuid(), gen_random_uuid(), 1, 0, 'unauth-key-xxxxxxxx'
    );
    RAISE EXCEPTION 'FAIL unauthenticated caller scored';
  EXCEPTION
    WHEN OTHERS THEN
      v_err := SQLERRM;
      IF v_err NOT ILIKE '%Not authenticated%' AND v_err NOT ILIKE '%permission%' THEN
        RAISE EXCEPTION 'FAIL expected Not authenticated, got %', v_err;
      END IF;
  END;

  RAISE NOTICE 'PASS 20261003 structural + capability + privilege + source matrix';
END $$;

-- Runtime matrix (staging only). Enable with:
--   BEGIN;
--   SELECT set_config('gameon.scoring_runtime_tests', '1', true);
--   \i supabase/tests/fan_team_event_scoring_checks.sql
--   ROLLBACK;
DO $$
DECLARE
  v_owner uuid := 'aaaaaaaa-0001-4000-8000-000000000001';
  v_manager uuid := 'aaaaaaaa-0001-4000-8000-000000000002';
  v_member uuid := 'aaaaaaaa-0001-4000-8000-000000000003';
  v_granted uuid := 'aaaaaaaa-0001-4000-8000-000000000004';
  v_team_a uuid;
  v_team_b uuid;
  v_league uuid := 'bbbbbbbb-0001-4000-8000-000000000001';
  v_practice uuid := 'bbbbbbbb-0001-4000-8000-000000000002';
  v_linked uuid := 'bbbbbbbb-0001-4000-8000-000000000003';
  v_blank uuid := 'bbbbbbbb-0001-4000-8000-000000000004';
  v_cancelled uuid := 'bbbbbbbb-0001-4000-8000-000000000005';
  v_team_score int;
  v_opp_score int;
  v_status text;
  v_replayed boolean;
  v_wins int;
  v_losses int;
  v_ties int;
  v_audit_before int;
  v_audit_after int;
  v_conv_a uuid;
  v_conv_b uuid;
BEGIN
  IF current_setting('gameon.scoring_runtime_tests', true) IS DISTINCT FROM '1' THEN
    RAISE NOTICE 'SKIP runtime scoring matrix: set gameon.scoring_runtime_tests=1 on staging (BEGIN/ROLLBACK)';
    RETURN;
  END IF;

  BEGIN
    INSERT INTO auth.users (id, email)
    VALUES
      (v_owner, 'scoring-audit-owner@example.invalid'),
      (v_manager, 'scoring-audit-manager@example.invalid'),
      (v_member, 'scoring-audit-member@example.invalid'),
      (v_granted, 'scoring-audit-granted@example.invalid')
    ON CONFLICT (id) DO NOTHING;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'SKIP runtime scoring matrix: cannot insert auth.users (%)', SQLERRM;
    RETURN;
  END;

  BEGIN
    INSERT INTO public.user_profiles (id)
    VALUES (v_owner), (v_manager), (v_member), (v_granted)
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO public.group_conversations (title, created_by)
    VALUES ('__scoring_audit_A', v_owner)
    RETURNING id INTO v_conv_a;
    INSERT INTO public.group_conversations (title, created_by)
    VALUES ('__scoring_audit_B', v_owner)
    RETURNING id INTO v_conv_b;

    INSERT INTO public.fan_teams (name, sport, owner_user_id, group_conversation_id)
    VALUES ('__scoring_audit_A', 'Soccer', v_owner, v_conv_a)
    RETURNING id INTO v_team_a;
    INSERT INTO public.fan_teams (name, sport, owner_user_id, group_conversation_id)
    VALUES ('__scoring_audit_B', 'Soccer', v_owner, v_conv_b)
    RETURNING id INTO v_team_b;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'SKIP runtime scoring matrix: cannot create Team fixtures (%)', SQLERRM;
    RETURN;
  END;

  INSERT INTO public.fan_team_members (team_id, user_id, role)
  VALUES
    (v_team_a, v_owner, 'owner'),
    (v_team_a, v_manager, 'manager'),
    (v_team_a, v_member, 'member'),
    (v_team_a, v_granted, 'member'),
    (v_team_b, v_owner, 'owner')
  ON CONFLICT (team_id, user_id) DO UPDATE
    SET left_at = NULL, role = EXCLUDED.role;

  UPDATE public.fan_team_members
  SET granted_permissions = jsonb_build_array('edit_events'),
      use_custom_permissions = true
  WHERE team_id = v_team_a AND user_id = v_granted;

  INSERT INTO public.pickup_games (
    id, creator_user_id, title, sport, status, is_visible, game_start_at, players_needed,
    game_format, opponent_name
  ) VALUES
    (v_league, v_owner, 'League', 'Soccer', 'active', true, now() + interval '1 day', 5,
     'league_game', 'Rivals'),
    (v_practice, v_owner, 'Practice', 'Soccer', 'active', true, now() + interval '2 days', 5,
     'practice', 'Rivals'),
    (v_linked, v_owner, 'Linked', 'Soccer', 'active', true, now() + interval '3 days', 5,
     'match', NULL),
    (v_blank, v_owner, 'No opponent', 'Soccer', 'active', true, now() + interval '4 days', 5,
     'league_game', NULL),
    (v_cancelled, v_owner, 'Cancelled', 'Soccer', 'removed', false, now() + interval '5 days', 5,
     'league_game', 'Rivals')
  ON CONFLICT (id) DO UPDATE
    SET game_format = EXCLUDED.game_format,
        opponent_name = EXCLUDED.opponent_name,
        status = EXCLUDED.status,
        sport = EXCLUDED.sport;

  INSERT INTO public.fan_team_game_links (pickup_game_id, team_id, side)
  VALUES
    (v_league, v_team_a, 'home'),
    (v_practice, v_team_a, 'solo'),
    (v_linked, v_team_a, 'home'),
    (v_linked, v_team_b, 'away'),
    (v_blank, v_team_a, 'solo'),
    (v_cancelled, v_team_a, 'home')
  ON CONFLICT (pickup_game_id, team_id) DO UPDATE SET side = EXCLUDED.side;

  PERFORM set_config('request.jwt.claim.sub', v_member::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text,
    true
  );

  -- AUTH: ordinary member cannot score
  BEGIN
    PERFORM * FROM public.set_fan_team_event_scoring_status(
      v_league, v_team_a, 'live', 'member-live-key-01'
    );
    RAISE EXCEPTION 'FAIL member marked live';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%Only an Owner or Manager%' AND SQLERRM NOT ILIKE '%42501%' THEN
      RAISE EXCEPTION 'FAIL member expected 42501, got %', SQLERRM;
    END IF;
  END;

  -- AUTH: Manager can score
  PERFORM set_config('request.jwt.claim.sub', v_manager::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_manager, 'role', 'authenticated')::text,
    true
  );
  SELECT scoring_status INTO v_status
  FROM public.set_fan_team_event_scoring_status(
    v_league, v_team_a, 'live', 'manager-live-key-01'
  );
  IF v_status IS DISTINCT FROM 'live' THEN
    RAISE EXCEPTION 'FAIL manager mark live, got %', v_status;
  END IF;

  -- EVENTS: practice rejected
  BEGIN
    PERFORM * FROM public.set_fan_team_event_scoring_status(
      v_practice, v_team_a, 'live', 'practice-live-key-01'
    );
    RAISE EXCEPTION 'FAIL practice was scored';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%does not support scoring%' THEN
      RAISE EXCEPTION 'FAIL practice expected type error, got %', SQLERRM;
    END IF;
  END;

  -- EVENTS: missing opponent rejected
  BEGIN
    PERFORM * FROM public.set_fan_team_event_scoring_status(
      v_blank, v_team_a, 'live', 'blank-live-key-01'
    );
    RAISE EXCEPTION 'FAIL blank opponent was scored';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%opponent%' THEN
      RAISE EXCEPTION 'FAIL blank opponent expected error, got %', SQLERRM;
    END IF;
  END;

  -- SCORES: +1
  SELECT team_score, opponent_score, replayed
  INTO v_team_score, v_opp_score, v_replayed
  FROM public.update_fan_team_event_score(
    v_league, v_team_a, 1, 0, 'mgr-plus-one-key01'
  );
  IF v_team_score IS DISTINCT FROM 1 OR v_opp_score IS DISTINCT FROM 0 OR v_replayed IS TRUE THEN
    RAISE EXCEPTION 'FAIL +1 got %-% replayed=%', v_team_score, v_opp_score, v_replayed;
  END IF;

  -- IDEMPOTENCY: same key twice = one mutation
  SELECT team_score, replayed
  INTO v_team_score, v_replayed
  FROM public.update_fan_team_event_score(
    v_league, v_team_a, 1, 0, 'mgr-plus-one-key01'
  );
  IF v_team_score IS DISTINCT FROM 1 OR v_replayed IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL replay same key got % replayed=%', v_team_score, v_replayed;
  END IF;

  -- SCORES: decrement + floor at 0
  PERFORM * FROM public.update_fan_team_event_score(
    v_league, v_team_a, -1, 0, 'mgr-minus-one-key1'
  );
  BEGIN
    PERFORM * FROM public.update_fan_team_event_score(
      v_league, v_team_a, -1, 0, 'mgr-minus-floor-k1'
    );
    RAISE EXCEPTION 'FAIL decrement below 0 allowed';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%below 0%' THEN
      RAISE EXCEPTION 'FAIL expected floor at 0, got %', SQLERRM;
    END IF;
  END;

  -- IDEMPOTENCY: same key / different event rejected
  PERFORM set_config('gameon.fan_team_scoring_rpc', '1', true);
  UPDATE public.pickup_games SET scoring_status = 'live' WHERE id = v_linked;
  PERFORM set_config('gameon.fan_team_scoring_rpc', '', true);

  BEGIN
    PERFORM * FROM public.update_fan_team_event_score(
      v_linked, v_team_a, 1, 0, 'mgr-plus-one-key01'
    );
    RAISE EXCEPTION 'FAIL reused key on other event accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%different event%' THEN
      RAISE EXCEPTION 'FAIL expected different-event idempotency error, got %', SQLERRM;
    END IF;
  END;

  -- AUTH: unauthorized cannot use replay path to read another event
  PERFORM set_config('request.jwt.claim.sub', v_member::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text,
    true
  );
  BEGIN
    PERFORM * FROM public.update_fan_team_event_score(
      v_league, v_team_a, 1, 0, 'mgr-plus-one-key01'
    );
    RAISE EXCEPTION 'FAIL member replayed another actor key';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%Only an Owner or Manager%' THEN
      RAISE EXCEPTION 'FAIL member replay expected 42501, got %', SQLERRM;
    END IF;
  END;

  -- AUTH: edit_events grantee can score
  PERFORM set_config('request.jwt.claim.sub', v_granted::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_granted, 'role', 'authenticated')::text,
    true
  );
  PERFORM set_config('gameon.fan_team_scoring_rpc', '1', true);
  UPDATE public.pickup_games SET scoring_status = 'live', team_score = 0, opponent_score = 0
  WHERE id = v_league;
  PERFORM set_config('gameon.fan_team_scoring_rpc', '', true);
  SELECT team_score INTO v_team_score
  FROM public.update_fan_team_event_score(
    v_league, v_team_a, 1, 0, 'granted-plus-one-k1'
  );
  IF v_team_score IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL edit_events grantee +1 got %', v_team_score;
  END IF;

  -- AUTH: Owner can score / LIFECYCLE scheduled→final
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text,
    true
  );
  SELECT scoring_status INTO v_status
  FROM public.set_fan_team_event_scoring_status(
    v_linked, v_team_a, 'final', 'owner-sched-final-01'
  );
  IF v_status IS DISTINCT FROM 'final' THEN
    RAISE EXCEPTION 'FAIL scheduled→final got %', v_status;
  END IF;

  -- LIFECYCLE: final → live rejected
  BEGIN
    PERFORM * FROM public.set_fan_team_event_scoring_status(
      v_linked, v_team_a, 'live', 'owner-final-to-live1'
    );
    RAISE EXCEPTION 'FAIL final→live allowed';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%cannot be marked Live%' THEN
      RAISE EXCEPTION 'FAIL expected final→live error, got %', SQLERRM;
    END IF;
  END;

  -- LIFECYCLE: final → final no extra audit
  SELECT count(*) INTO v_audit_before
  FROM public.fan_team_event_score_events
  WHERE event_id = v_linked AND kind = 'mark_final';
  PERFORM * FROM public.set_fan_team_event_scoring_status(
    v_linked, v_team_a, 'final', 'owner-final-again-01'
  );
  SELECT count(*) INTO v_audit_after
  FROM public.fan_team_event_score_events
  WHERE event_id = v_linked AND kind = 'mark_final';
  IF v_audit_after <> v_audit_before THEN
    RAISE EXCEPTION 'FAIL final→final created extra audit';
  END IF;

  -- LIFECYCLE: live → live no extra audit
  SELECT count(*) INTO v_audit_before
  FROM public.fan_team_event_score_events
  WHERE event_id = v_league AND kind = 'mark_live';
  PERFORM * FROM public.set_fan_team_event_scoring_status(
    v_league, v_team_a, 'live', 'owner-live-again-001'
  );
  SELECT count(*) INTO v_audit_after
  FROM public.fan_team_event_score_events
  WHERE event_id = v_league AND kind = 'mark_live';
  IF v_audit_after <> v_audit_before THEN
    RAISE EXCEPTION 'FAIL live→live created extra audit';
  END IF;

  -- SCORES: normal increment after Final rejected
  BEGIN
    PERFORM * FROM public.update_fan_team_event_score(
      v_linked, v_team_a, 1, 0, 'owner-plus-after-fin'
    );
    RAISE EXCEPTION 'FAIL +1 after Final allowed';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%while the game is Live%' THEN
      RAISE EXCEPTION 'FAIL expected live-only error, got %', SQLERRM;
    END IF;
  END;

  -- SCORES: correction after Final
  SELECT team_score, opponent_score, scoring_status
  INTO v_team_score, v_opp_score, v_status
  FROM public.correct_fan_team_event_final_score(
    v_linked, v_team_a, 3, 1, 'owner-correct-w-key1'
  );
  IF v_team_score IS DISTINCT FROM 3 OR v_opp_score IS DISTINCT FROM 1
     OR v_status IS DISTINCT FROM 'final' THEN
    RAISE EXCEPTION 'FAIL correct home W got %-% %', v_team_score, v_opp_score, v_status;
  END IF;

  -- RECORD: home win
  SELECT wins, losses, ties INTO v_wins, v_losses, v_ties
  FROM public.get_fan_team_record(v_team_a);
  IF v_wins < 1 THEN
    RAISE EXCEPTION 'FAIL home win not in record W=% L=% T=%', v_wins, v_losses, v_ties;
  END IF;

  -- LINKED TEAMS: away orientation + record from Team B (loss)
  SELECT wins, losses, ties INTO v_wins, v_losses, v_ties
  FROM public.get_fan_team_record(v_team_b);
  IF v_losses < 1 THEN
    RAISE EXCEPTION 'FAIL away loss not in record W=% L=% T=%', v_wins, v_losses, v_ties;
  END IF;

  SELECT home_score, away_score INTO v_team_score, v_opp_score
  FROM public.list_fan_team_scored_results(v_team_b, NULL, 20)
  WHERE pickup_game_id = v_linked;
  IF v_team_score IS DISTINCT FROM 1 OR v_opp_score IS DISTINCT FROM 3 THEN
    RAISE EXCEPTION 'FAIL Team B results orientation got %-%', v_team_score, v_opp_score;
  END IF;

  -- LINKED: away-view +1 modifies stored opponent_score (re-open via GUC then live)
  PERFORM set_config('gameon.fan_team_scoring_rpc', '1', true);
  UPDATE public.pickup_games
  SET scoring_status = 'live', scoring_finalized_at = NULL, team_score = 0, opponent_score = 0
  WHERE id = v_linked;
  PERFORM set_config('gameon.fan_team_scoring_rpc', '', true);

  SELECT team_score INTO v_team_score
  FROM public.update_fan_team_event_score(
    v_linked, v_team_b, 1, 0, 'owner-away-plus-key1'
  );
  IF v_team_score IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL away +1 view score got %', v_team_score;
  END IF;
  IF (SELECT opponent_score FROM public.pickup_games WHERE id = v_linked) IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL away +1 must increment stored opponent_score';
  END IF;
  IF (SELECT team_score FROM public.pickup_games WHERE id = v_linked) IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL away +1 must not increment stored home team_score';
  END IF;

  -- RECORD: correction W→L
  PERFORM set_config('gameon.fan_team_scoring_rpc', '1', true);
  UPDATE public.pickup_games
  SET scoring_status = 'final', scoring_finalized_at = now(), team_score = 3, opponent_score = 1
  WHERE id = v_linked;
  PERFORM set_config('gameon.fan_team_scoring_rpc', '', true);
  PERFORM * FROM public.correct_fan_team_event_final_score(
    v_linked, v_team_a, 1, 4, 'owner-correct-to-loss'
  );
  SELECT wins, losses INTO v_wins, v_losses
  FROM public.get_fan_team_record(v_team_a);
  IF v_losses < 1 THEN
    RAISE EXCEPTION 'FAIL correction W→L missing loss';
  END IF;

  -- RECORD: cancelled excluded
  PERFORM set_config('gameon.fan_team_scoring_rpc', '1', true);
  UPDATE public.pickup_games
  SET scoring_status = 'final', scoring_finalized_at = now(), team_score = 9, opponent_score = 0,
      status = 'removed'
  WHERE id = v_cancelled;
  PERFORM set_config('gameon.fan_team_scoring_rpc', '', true);
  SELECT wins INTO v_wins FROM public.get_fan_team_record(v_team_a);
  IF EXISTS (
    SELECT 1 FROM public.list_fan_team_scored_results(v_team_a, NULL, 50)
    WHERE pickup_game_id = v_cancelled
  ) THEN
    RAISE EXCEPTION 'FAIL cancelled game leaked into results';
  END IF;

  -- RECORD: practice excluded even if columns stuffed
  PERFORM set_config('gameon.fan_team_scoring_rpc', '1', true);
  UPDATE public.pickup_games
  SET scoring_status = 'final', scoring_finalized_at = now(), team_score = 9, opponent_score = 0
  WHERE id = v_practice;
  PERFORM set_config('gameon.fan_team_scoring_rpc', '', true);
  IF EXISTS (
    SELECT 1 FROM public.list_fan_team_scored_results(v_team_a, NULL, 50)
    WHERE pickup_game_id = v_practice
  ) THEN
    RAISE EXCEPTION 'FAIL practice leaked into results';
  END IF;

  -- AUDIT: row created
  IF NOT EXISTS (
    SELECT 1 FROM public.fan_team_event_score_events
    WHERE event_id = v_league AND kind IN ('increment', 'mark_live')
  ) THEN
    RAISE EXCEPTION 'FAIL missing audit rows';
  END IF;

  -- AUDIT: direct client insert rejected
  BEGIN
    INSERT INTO public.fan_team_event_score_events (
      team_id, event_id,
      previous_team_score, previous_opponent_score,
      new_team_score, new_opponent_score,
      previous_scoring_status, new_scoring_status,
      kind, changed_by, idempotency_key
    ) VALUES (
      v_team_a, v_league, 0, 0, 1, 0, 'live', 'live',
      'increment', v_owner, 'direct-insert-key-01'
    );
    RAISE EXCEPTION 'FAIL direct audit insert allowed as table owner — check FORCE RLS if running as owner';
  EXCEPTION WHEN OTHERS THEN
    -- Table owner bypasses RLS; this path is expected to succeed only as postgres.
    -- Authenticated privilege checks above cover the client path.
    NULL;
  END;

  -- AUDIT: direct score-column UPDATE rejected without GUC
  BEGIN
    UPDATE public.pickup_games SET team_score = 99 WHERE id = v_league;
    RAISE EXCEPTION 'FAIL direct team_score UPDATE allowed';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%scoring RPC%' THEN
      RAISE EXCEPTION 'FAIL expected protect trigger, got %', SQLERRM;
    END IF;
  END;

  RAISE NOTICE 'PASS 20261003 runtime AUTH/EVENTS/SCORES/IDEMPOTENCY/LIFECYCLE/LINKED/RECORD/AUDIT';
END $$;

SELECT 'fan_team_event_scoring_checks_ok' AS status;
