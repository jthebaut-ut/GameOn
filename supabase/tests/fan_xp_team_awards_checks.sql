-- Static checks for 20260996 Team Fan XP (run after migration apply).
DO $$
DECLARE
  v_src text;
BEGIN
  IF public.fan_xp_amount_for_source('pickup_create') IS DISTINCT FROM 20 THEN
    RAISE EXCEPTION 'FAIL: pickup_create amount changed';
  END IF;
  IF public.fan_xp_amount_for_source('team_created') IS DISTINCT FROM 20 THEN
    RAISE EXCEPTION 'FAIL: team_created amount';
  END IF;
  IF public.fan_xp_amount_for_source('team_join_player') IS DISTINCT FROM 10 THEN
    RAISE EXCEPTION 'FAIL: team_join_player amount';
  END IF;
  IF public.fan_xp_is_real_team_event_format('announcement') THEN
    RAISE EXCEPTION 'FAIL: announcement must not be a real Team event';
  END IF;
  IF public.fan_xp_team_created_lifetime_cap() IS DISTINCT FROM 5 THEN
    RAISE EXCEPTION 'FAIL: team_created lifetime cap';
  END IF;
  IF public.fan_xp_team_event_created_daily_cap() IS DISTINCT FROM 8 THEN
    RAISE EXCEPTION 'FAIL: team_event_created daily cap';
  END IF;
  IF public.fan_xp_is_eligible_account_player_seat(
       '00000000-0000-0000-0000-000000000001'::uuid,
       '00000000-0000-0000-0000-000000000002'::uuid,
       NULL, true
     ) THEN
    RAISE EXCEPTION 'FAIL: managed seat must not be eligible account player';
  END IF;
  SELECT p.prosrc INTO v_src
  FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.fan_xp_trg_team_join_player()'::regprocedure;
  IF position('v_old_eligible' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: join trigger must ignore already-eligible UPDATEs';
  END IF;
  SELECT p.prosrc INTO v_src
  FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.fan_xp_try_award_internal(uuid, text, uuid)'::regprocedure;
  IF position('fan_xp_team_created_cap_allows' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: try_award missing team_created cap';
  END IF;
  SELECT p.prosrc INTO v_src
  FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.fan_xp_validate_and_resolve(text, uuid, uuid)'::regprocedure;
  IF position('team_event_use_team_source' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: pickup sources must reject team-linked rows';
  END IF;
  IF position('team_join_player_not_recent' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: claim must not backfill historical player seats';
  END IF;
  SELECT p.prosrc INTO v_src
  FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.fan_xp_trg_team_event_linked()'::regprocedure;
  IF position('fan_xp_award_team_event_completed' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: link trigger must evaluate already-completed events';
  END IF;
END $$;
