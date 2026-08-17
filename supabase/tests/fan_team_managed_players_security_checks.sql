-- Staging checks for 20260960 security / privacy / authorization hardening.
-- Run AFTER applying 20260960 (and ideally 20260961). Manual / staging only.
-- Does not mutate production data beyond privilege introspection.

DO $$
DECLARE
  v_src text;
  v_pol text;
BEGIN
  IF to_regclass('public.fan_managed_players') IS NULL THEN
    RAISE EXCEPTION 'FAIL: 20260960 not applied (fan_managed_players missing)';
  END IF;

  -- A) Ordinary teammate cannot SELECT full fan_managed_players row (no table SELECT).
  IF has_table_privilege('authenticated', 'public.fan_managed_players', 'SELECT') THEN
    RAISE EXCEPTION 'FAIL: authenticated still has SELECT on fan_managed_players';
  END IF;
  IF has_table_privilege('anon', 'public.fan_managed_players', 'SELECT') THEN
    RAISE EXCEPTION 'FAIL: anon has SELECT on fan_managed_players';
  END IF;

  -- B/C pattern: guardian SELECT is only via SECURITY DEFINER RPCs; table has
  -- guardian-only RLS if SELECT is ever re-granted.
  SELECT polcmd || ':' || qual INTO v_pol
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename = 'fan_managed_players'
    AND policyname = 'fan_managed_players_select_guardian'
  LIMIT 1;
  IF v_pol IS NULL THEN
    RAISE EXCEPTION 'FAIL: fan_managed_players_select_guardian policy missing';
  END IF;
  IF position('fan_managed_player_guardians' IN coalesce(v_pol, '')) = 0 THEN
    RAISE EXCEPTION 'FAIL: guardian policy does not reference fan_managed_player_guardians';
  END IF;
  IF position('is_active_fan_team_member' IN coalesce(v_pol, '')) > 0
     OR position('teammate' IN lower(coalesce(v_pol, ''))) > 0 THEN
    RAISE EXCEPTION 'FAIL: managed-player SELECT policy still allows teammate path';
  END IF;

  -- D) Authenticated cannot execute internal guardian/helper probes.
  IF has_function_privilege(
    'authenticated',
    'public.is_authorized_managed_player_guardian(uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: is_authorized_managed_player_guardian executable by authenticated';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'public.is_active_fan_team_managed_member(uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: is_active_fan_team_managed_member executable by authenticated';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'public.fan_managed_player_visible_to_viewer(uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: fan_managed_player_visible_to_viewer executable by authenticated';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'public.fan_team_membership_recipient_user_ids(uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: fan_team_membership_recipient_user_ids executable by authenticated';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'public.resolve_fan_team_notification_recipients_for_participant(uuid,uuid,uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: resolve_fan_team_notification_recipients_for_participant executable by authenticated';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'public.is_fan_geo_runtime_flag_enabled(text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: is_fan_geo_runtime_flag_enabled executable by authenticated';
  END IF;

  -- E) Client-facing managed-player RPCs remain executable.
  IF NOT has_function_privilege(
    'authenticated',
    'public.list_my_managed_players()',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: list_my_managed_players not granted to authenticated';
  END IF;
  IF NOT has_function_privilege(
    'authenticated',
    'public.create_managed_player(text,text,text,int,text,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: create_managed_player not granted to authenticated';
  END IF;

  -- Rate-limit allowlist must include managed-player buckets (else first Save
  -- raises "rate limit rejected" 22023 before any counter runs).
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE oid = to_regprocedure('public.assert_rpc_rate_limit(text,int,int)');
  IF v_src IS NULL THEN
    RAISE EXCEPTION 'FAIL: assert_rpc_rate_limit missing';
  END IF;
  IF position('''create_managed_player''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: create_managed_player missing from rate-limit allowlist (apply 20260963)';
  END IF;
  IF position('''update_managed_player''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: update_managed_player missing from rate-limit allowlist';
  END IF;
  IF position('''add_managed_player_to_fan_team''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: add_managed_player_to_fan_team missing from rate-limit allowlist';
  END IF;
  IF position('''accept_fan_team_invitation_as_managed_player''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: accept_fan_team_invitation_as_managed_player missing from allowlist';
  END IF;
  -- Authenticated must NOT execute the limiter directly.
  IF has_function_privilege(
    'authenticated',
    'public.assert_rpc_rate_limit(text,int,int)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: authenticated can execute assert_rpc_rate_limit';
  END IF;
  IF NOT has_function_privilege(
    'authenticated',
    'public.list_fan_team_members(uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: list_fan_team_members not granted to authenticated';
  END IF;
  IF NOT has_function_privilege(
    'authenticated',
    'public.add_managed_player_to_fan_team(uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: add_managed_player_to_fan_team not granted to authenticated';
  END IF;
  IF NOT has_function_privilege(
    'authenticated',
    'public.accept_fan_team_invitation_as_managed_player(uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: accept_fan_team_invitation_as_managed_player not granted to authenticated';
  END IF;
  IF NOT has_function_privilege(
    'authenticated',
    'public.set_fan_team_game_rsvp_for_membership(uuid,uuid,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: set_fan_team_game_rsvp_for_membership not granted to authenticated';
  END IF;

  -- F/G) add_managed_player_to_fan_team requires staff manage gate + guardian + flag.
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'add_managed_player_to_fan_team'
  ORDER BY oid DESC
  LIMIT 1;
  IF position('fan_team_viewer_can_manage' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: add_managed_player_to_fan_team missing owner/manager gate';
  END IF;
  IF position('is_authorized_managed_player_guardian' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: add_managed_player_to_fan_team missing guardian gate';
  END IF;
  IF position('managed_player_team_seats' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: add_managed_player_to_fan_team missing runtime seat flag';
  END IF;
  IF position('managed_player_already_on_team' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: add_managed_player_to_fan_team missing duplicate active rejection';
  END IF;

  -- H) Invitation acceptance path exists and is flag-gated.
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'accept_fan_team_invitation_as_managed_player'
  ORDER BY oid DESC
  LIMIT 1;
  IF v_src IS NULL THEN
    RAISE EXCEPTION 'FAIL: accept_fan_team_invitation_as_managed_player missing';
  END IF;
  IF position('managed_player_team_seats' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: accept invitation missing runtime seat flag';
  END IF;
  IF position('is_authorized_managed_player_guardian' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: accept invitation missing guardian gate';
  END IF;

  -- I) Duplicate active managed seat uniqueness index present.
  IF NOT EXISTS (
    SELECT 1
    FROM pg_index i
    JOIN pg_class c ON c.oid = i.indexrelid
    WHERE i.indrelid = 'public.fan_team_members'::regclass
      AND c.relname = 'fan_team_members_active_managed_uidx'
      AND i.indisunique
  ) THEN
    RAISE EXCEPTION 'FAIL: active managed seat unique index missing';
  END IF;

  -- J/Q) Legacy ON CONFLICT (team_id, user_id) still supported for account seats.
  IF NOT EXISTS (
    SELECT 1
    FROM pg_index i
    JOIN pg_class c ON c.oid = i.indexrelid
    WHERE i.indrelid = 'public.fan_team_members'::regclass
      AND c.relname = 'fan_team_members_team_user_uidx'
      AND i.indisunique
      AND i.indpred IS NULL
  ) THEN
    RAISE EXCEPTION 'FAIL: full unique (team_id, user_id) index missing for ON CONFLICT';
  END IF;

  -- N/O) list_fan_team_members projection must not expose birth_year / guardian ids.
  SELECT pg_get_function_result(p.oid) INTO v_src
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'list_fan_team_members'
  ORDER BY p.oid DESC
  LIMIT 1;
  IF position('birth_year' IN lower(coalesce(v_src, ''))) > 0 THEN
    RAISE EXCEPTION 'FAIL: list_fan_team_members exposes birth_year';
  END IF;
  IF position('guardian_user_id' IN lower(coalesce(v_src, ''))) > 0 THEN
    RAISE EXCEPTION 'FAIL: list_fan_team_members exposes guardian_user_id';
  END IF;
  IF position('created_by_user_id' IN lower(coalesce(v_src, ''))) > 0 THEN
    RAISE EXCEPTION 'FAIL: list_fan_team_members exposes created_by_user_id';
  END IF;
  IF position('linked_user_id' IN lower(coalesce(v_src, ''))) > 0 THEN
    RAISE EXCEPTION 'FAIL: list_fan_team_members exposes linked_user_id';
  END IF;

  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'list_fan_team_members'
  ORDER BY oid DESC
  LIMIT 1;
  IF position('birth_year' IN lower(coalesce(v_src, ''))) > 0 THEN
    RAISE EXCEPTION 'FAIL: list_fan_team_members body references birth_year';
  END IF;

  -- P) PK is membership_id; no composite FK remain against fan_team_members.
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.fan_team_members'::regclass
      AND contype = 'p'
      AND array_length(conkey, 1) = 1
  ) THEN
    RAISE EXCEPTION 'FAIL: fan_team_members PK is not membership_id-only';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM pg_constraint c
    WHERE c.contype = 'f'
      AND c.confrelid = 'public.fan_team_members'::regclass
      AND array_length(c.confkey, 1) > 1
  ) THEN
    RAISE EXCEPTION 'FAIL: composite FK still references fan_team_members';
  END IF;

  -- Rollout gate defaults OFF.
  IF public.is_fan_geo_runtime_flag_enabled('managed_player_team_seats') IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL: managed_player_team_seats must default false after apply';
  END IF;

  RAISE NOTICE 'PASS: fan_team_managed_players_security_checks';
END $$;
