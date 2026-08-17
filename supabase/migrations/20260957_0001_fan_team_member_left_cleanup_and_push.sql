-- =============================================================================
-- 20260957_0001 — Fan Team member leave: leadership push + future-event cleanup
-- =============================================================================
-- CODE-PROVEN ROOT CAUSES (physical device):
--
-- A) NO OWNER/MANAGER PUSH
--    leave_fan_team (20260931) only soft-sets fan_team_members.left_at +
--    group_conversation_members.left_at + cancels pending invites.
--    It never inserts a notification event or queues APNS. No Edge handler.
--
-- B) FORMER MEMBER STILL ON FUTURE ATTENDANCE
--    get_pickup_game_roster (20260948) synthesizes no_response from ACTIVE
--    members only (left_at IS NULL) — correct.
--    But playing / pending / declined buckets return ALL pickup_game_requests
--    for the game with NO active Team-membership filter. Leftover Going/Maybe/
--    Can't Go rows keep former members on Schedule stacks, Who's Going, counts.
--    leave_fan_team does not clean future RSVP rows or lineup memberships.
--
-- FIX:
--   1) member_left_team event + delivery ledger + queue → notify-fan-team-member-left
--      Recipients: active Owner + Manager (snapshot BEFORE soft-leave).
--      Mute: per-recipient Team mute respected (unlike Team deleted).
--   2) cleanup_fan_team_member_future_event_participation:
--      future lineup rows removed; future approved→withdrawn / pending→cancelled
--   3) get_pickup_game_roster: for Team-linked FUTURE games, filter request
--      buckets to active members OR legitimate outside recruits
--   4) get_fan_team_event_lineup: hide left members on future games
--   5) list_pickup_game_change_push_tokens: exclude stale former-member requests
--   6) leave_fan_team + remove_fan_team_member call cleanup; leave queues push
--      remove_fan_team_member is STAFF-ONLY (rejects p_user_id = auth.uid())
--
-- Do NOT apply from the agent. Apply manually after 20260956.
-- Deploy Edge AFTER apply:
--   supabase functions deploy notify-fan-team-member-left --no-verify-jwt
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Event + delivery ledger
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.fan_team_member_left_events (
  id uuid PRIMARY KEY,
  team_id uuid NOT NULL REFERENCES public.fan_teams (id) ON DELETE CASCADE,
  left_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  actor_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  reason text NOT NULL DEFAULT 'left'
    CHECK (reason IN ('left', 'removed')),
  team_name text NOT NULL,
  left_display_name text NOT NULL,
  recipient_user_ids uuid[] NOT NULL DEFAULT '{}',
  pg_net_request_id bigint,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS fan_team_member_left_events_team_created_idx
  ON public.fan_team_member_left_events (team_id, created_at DESC);

COMMENT ON TABLE public.fan_team_member_left_events IS
  'Voluntary leave / remove lifecycle events. recipient_user_ids = active Owner+Manager '
  'snapshot BEFORE soft-leave. kind for Edge/APNS: member_left_team.';

ALTER TABLE public.fan_team_member_left_events ENABLE ROW LEVEL SECURITY;
GRANT ALL ON public.fan_team_member_left_events TO service_role;

CREATE TABLE IF NOT EXISTS public.fan_team_member_left_push_deliveries (
  event_id uuid NOT NULL REFERENCES public.fan_team_member_left_events (id) ON DELETE CASCADE,
  recipient_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  team_id uuid NOT NULL,
  delivery_status text NOT NULL DEFAULT 'queued'
    CHECK (delivery_status IN ('queued', 'sent', 'skipped', 'failed')),
  skip_reason text,
  sent_token_count integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (event_id, recipient_user_id)
);

CREATE INDEX IF NOT EXISTS fan_team_member_left_push_deliveries_team_created_idx
  ON public.fan_team_member_left_push_deliveries (team_id, created_at DESC);

ALTER TABLE public.fan_team_member_left_push_deliveries ENABLE ROW LEVEL SECURITY;
GRANT ALL ON public.fan_team_member_left_push_deliveries TO service_role;

-- ---------------------------------------------------------------------------
-- 2) Future attendance eligibility (Team-linked)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_fan_team_linked_request_actor_eligible(
  p_team_id uuid,
  p_user_id uuid,
  p_request_created_at timestamptz,
  p_game_is_future boolean
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN p_team_id IS NULL OR p_user_id IS NULL THEN false
    -- Past / historical Team events: keep RSVP history rows.
    WHEN coalesce(p_game_is_future, false) = false THEN true
    -- Active Team member.
    WHEN EXISTS (
      SELECT 1
      FROM public.fan_team_members m
      WHERE m.team_id = p_team_id
        AND m.user_id = p_user_id
        AND m.left_at IS NULL
    ) THEN true
    -- Never a Team member → outside / recruit path.
    WHEN NOT EXISTS (
      SELECT 1
      FROM public.fan_team_members m
      WHERE m.team_id = p_team_id
        AND m.user_id = p_user_id
    ) THEN true
    -- Former member who later joined as outside player (request after leave).
    WHEN EXISTS (
      SELECT 1
      FROM public.fan_team_members m
      WHERE m.team_id = p_team_id
        AND m.user_id = p_user_id
        AND m.left_at IS NOT NULL
        AND p_request_created_at IS NOT NULL
        AND p_request_created_at > m.left_at
    ) THEN true
    ELSE false
  END;
$$;

COMMENT ON FUNCTION public.is_fan_team_linked_request_actor_eligible(uuid, uuid, timestamptz, boolean) IS
  'Team-linked FUTURE attendance: active members + outside recruits. '
  'Former members with pre-leave RSVP rows are excluded. Past events keep history. '
  'Future guardian/subject RSVP may extend eligibility separately; do not hard-block '
  'authorized subject writes here.';

-- Internal SECURITY DEFINER helper only (called from get_pickup_game_roster /
-- list_pickup_game_change_push_tokens). Not a client RPC — do not grant authenticated/anon.
REVOKE ALL ON FUNCTION public.is_fan_team_linked_request_actor_eligible(uuid, uuid, timestamptz, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_fan_team_linked_request_actor_eligible(uuid, uuid, timestamptz, boolean) FROM anon;
REVOKE ALL ON FUNCTION public.is_fan_team_linked_request_actor_eligible(uuid, uuid, timestamptz, boolean) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.is_fan_team_linked_request_actor_eligible(uuid, uuid, timestamptz, boolean) TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Trigger: Team leave cleanup GUC (keeps 20260956 Team self-RSVP branch)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pickup_game_requests_before_update_status()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  is_creator boolean;
  need int;
  cur int;
  game_removed boolean;
  v_deletion_subject_text text := nullif(btrim(current_setting('gameon.account_deletion_anonymize', true)), '');
  v_deletion_subject uuid;
  v_leave_subject_text text := nullif(btrim(current_setting('gameon.fan_team_member_leave_cleanup', true)), '');
  v_leave_subject uuid;
  v_me uuid := auth.uid();
  v_team_linked boolean;
BEGIN
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  -- Trusted account-deletion context.
  IF v_deletion_subject_text IS NOT NULL THEN
    BEGIN
      v_deletion_subject := v_deletion_subject_text::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      v_deletion_subject := NULL;
    END;

    IF v_deletion_subject IS NOT NULL THEN
      IF NEW.status = 'withdrawn'
         AND OLD.status = 'approved'
         AND NEW.requester_user_id = v_deletion_subject THEN
        RETURN NEW;
      END IF;

      IF NEW.status = 'cancelled'
         AND OLD.status IN ('pending', 'approved', 'rejected')
         AND NEW.requester_user_id = v_deletion_subject THEN
        RETURN NEW;
      END IF;

      IF NEW.status = 'cancelled'
         AND OLD.status IN ('pending', 'approved')
         AND EXISTS (
           SELECT 1
           FROM public.pickup_games g
           WHERE g.id = NEW.pickup_game_id
             AND g.creator_user_id = v_deletion_subject
             AND g.status IN ('removed', 'expired')
         ) THEN
        RETURN NEW;
      END IF;
    END IF;
  END IF;

  -- Trusted Team leave/remove cleanup (SECURITY DEFINER helper only).
  IF v_leave_subject_text IS NOT NULL THEN
    BEGIN
      v_leave_subject := v_leave_subject_text::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      v_leave_subject := NULL;
    END;

    IF v_leave_subject IS NOT NULL
       AND NEW.requester_user_id = v_leave_subject THEN
      IF NEW.status = 'withdrawn' AND OLD.status = 'approved' THEN
        RETURN NEW;
      END IF;
      IF NEW.status = 'cancelled' AND OLD.status IN ('pending', 'approved', 'rejected') THEN
        RETURN NEW;
      END IF;
    END IF;
  END IF;

  -- Team-linked SELF RSVP (set_fan_team_game_rsvp) — retained from 20260956.
  IF v_me IS NOT NULL
     AND NEW.requester_user_id IS NOT DISTINCT FROM v_me
     AND NEW.status IN ('approved', 'pending', 'withdrawn')
     AND OLD.status IN ('approved', 'pending', 'withdrawn', 'cancelled', 'rejected')
  THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.fan_team_game_links l
      WHERE l.pickup_game_id = NEW.pickup_game_id
    ) INTO v_team_linked;

    IF v_team_linked
       AND public.is_pickup_game_fan_team_participant(NEW.pickup_game_id, v_me) THEN
      RETURN NEW;
    END IF;
  END IF;

  SELECT (g.creator_user_id = v_me) INTO is_creator
  FROM public.pickup_games g
  WHERE g.id = NEW.pickup_game_id;

  SELECT EXISTS (
    SELECT 1 FROM public.pickup_games g
    WHERE g.id = NEW.pickup_game_id
      AND g.status = 'removed'
  ) INTO game_removed;

  IF NEW.status = 'cancelled' THEN
    IF NEW.requester_user_id IS NOT DISTINCT FROM v_me
       AND OLD.status IN ('pending', 'approved', 'rejected') THEN
      RETURN NEW;
    ELSIF is_creator
          AND game_removed
          AND OLD.status IN ('pending', 'approved') THEN
      RETURN NEW;
    ELSE
      RAISE EXCEPTION 'pickup_request_cancel_forbidden' USING ERRCODE = 'check_violation';
    END IF;
  ELSIF NEW.status = 'withdrawn' THEN
    IF NEW.requester_user_id IS DISTINCT FROM v_me THEN
      RAISE EXCEPTION 'pickup_request_cancel_forbidden' USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status <> 'approved' THEN
      RAISE EXCEPTION 'pickup_request_cancel_forbidden' USING ERRCODE = 'check_violation';
    END IF;
  ELSIF NEW.status IN ('approved', 'rejected') THEN
    IF NOT is_creator OR OLD.status <> 'pending' THEN
      RAISE EXCEPTION 'pickup_request_decision_forbidden' USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.status = 'approved' THEN
      PERFORM 1 FROM public.pickup_games WHERE id = NEW.pickup_game_id FOR UPDATE;
      SELECT players_needed INTO need FROM public.pickup_games WHERE id = NEW.pickup_game_id;
      SELECT count(*)::int INTO cur
      FROM public.pickup_game_requests r
      WHERE r.pickup_game_id = NEW.pickup_game_id
        AND r.status = 'approved'
        AND r.id IS DISTINCT FROM NEW.id;
      IF cur >= need THEN
        RAISE EXCEPTION 'pickup_game_full' USING ERRCODE = 'check_violation';
      END IF;
    END IF;
  ELSE
    RAISE EXCEPTION 'pickup_request_status_forbidden' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.pickup_game_requests_before_update_status() IS
  'Pickup request status guard. Team self-RSVP + account-deletion GUC + '
  'fan_team_member_leave_cleanup GUC for future Team-event participation cleanup. '
  'Standalone organizer decision rules unchanged.';

-- ---------------------------------------------------------------------------
-- 4) Future-event cleanup helper
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cleanup_fan_team_member_future_event_participation(
  p_team_id uuid,
  p_user_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_lineups_removed integer := 0;
  v_requests_updated integer := 0;
BEGIN
  IF p_team_id IS NULL OR p_user_id IS NULL THEN
    RETURN;
  END IF;

  -- Transaction-local trusted context for status trigger (remove path ≠ auth.uid).
  PERFORM set_config('gameon.fan_team_member_leave_cleanup', p_user_id::text, true);

  DELETE FROM public.fan_team_event_lineup_members lm
  USING public.fan_team_event_lineups l
  INNER JOIN public.pickup_games g ON g.id = l.pickup_game_id
  WHERE lm.lineup_id = l.id
    AND l.team_id = p_team_id
    AND lm.user_id = p_user_id
    AND g.game_start_at >= now();

  GET DIAGNOSTICS v_lineups_removed = ROW_COUNT;

  UPDATE public.pickup_game_requests r
  SET status = CASE
        WHEN lower(btrim(r.status)) = 'approved' THEN 'withdrawn'
        WHEN lower(btrim(r.status)) = 'pending' THEN 'cancelled'
        ELSE r.status
      END,
      responded_at = coalesce(r.responded_at, now()),
      updated_at = now()
  FROM public.fan_team_game_links l
  INNER JOIN public.pickup_games g ON g.id = l.pickup_game_id
  WHERE r.pickup_game_id = l.pickup_game_id
    AND l.team_id = p_team_id
    AND r.requester_user_id = p_user_id
    AND g.game_start_at >= now()
    AND lower(btrim(r.status)) IN ('approved', 'pending');

  GET DIAGNOSTICS v_requests_updated = ROW_COUNT;

  RAISE NOTICE
    '[FanTeamMemberLeaveDebug] cleanup team_id=% user_id=% future_lineup_rows=% future_rsvp_rows=%',
    p_team_id, p_user_id, v_lineups_removed, v_requests_updated;
END;
$$;

COMMENT ON FUNCTION public.cleanup_fan_team_member_future_event_participation(uuid, uuid) IS
  'On Team leave/remove: drop future lineup seats; withdraw/cancel future Team RSVP rows. '
  'Does not rewrite past event history. Outside-player rejoin after leave uses a new request.';

REVOKE ALL ON FUNCTION public.cleanup_fan_team_member_future_event_participation(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cleanup_fan_team_member_future_event_participation(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.cleanup_fan_team_member_future_event_participation(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.cleanup_fan_team_member_future_event_participation(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 5) Queue Edge fan-out
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.queue_fan_team_member_left_push_notification(
  p_event_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_url text;
  v_service_role_key text;
  v_cron_secret text;
  v_headers jsonb;
  v_team_id uuid;
  v_recipients uuid[];
  v_uid uuid;
  v_request_id bigint;
BEGIN
  IF p_event_id IS NULL THEN
    RETURN;
  END IF;

  SELECT e.team_id, coalesce(e.recipient_user_ids, '{}'::uuid[])
  INTO v_team_id, v_recipients
  FROM public.fan_team_member_left_events e
  WHERE e.id = p_event_id;

  IF v_team_id IS NULL THEN
    RAISE NOTICE '[FanTeamMemberLeaveDebug] queue skip: event missing event=%', p_event_id;
    RETURN;
  END IF;

  IF coalesce(cardinality(v_recipients), 0) = 0 THEN
    RAISE NOTICE '[FanTeamMemberLeaveDebug] queue skip: no recipients event=% team=%',
      p_event_id, v_team_id;
    RETURN;
  END IF;

  FOREACH v_uid IN ARRAY v_recipients LOOP
    IF v_uid IS NULL THEN
      CONTINUE;
    END IF;
    INSERT INTO public.fan_team_member_left_push_deliveries (
      event_id, recipient_user_id, team_id, delivery_status
    ) VALUES (
      p_event_id, v_uid, v_team_id, 'queued'
    )
    ON CONFLICT (event_id, recipient_user_id) DO NOTHING;
  END LOOP;

  RAISE NOTICE
    '[FanTeamMemberLeaveDebug] notification_event=yes event=% team=% recipient_snapshot=%',
    p_event_id, v_team_id, cardinality(v_recipients);

  IF to_regnamespace('net') IS NULL OR to_regclass('vault.decrypted_secrets') IS NULL THEN
    UPDATE public.fan_team_member_left_push_deliveries
    SET delivery_status = 'skipped',
        skip_reason = 'pg_net_or_vault_unavailable',
        updated_at = now()
    WHERE event_id = p_event_id
      AND delivery_status = 'queued';
    RAISE NOTICE '[FanTeamMemberLeaveDebug] queue skip: pg_net/vault unavailable event=%', p_event_id;
    RETURN;
  END IF;

  SELECT rtrim(decrypted_secret, '/')
  INTO v_url
  FROM vault.decrypted_secrets
  WHERE name IN ('fangeo_supabase_url', 'SUPABASE_URL')
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY CASE name WHEN 'fangeo_supabase_url' THEN 0 ELSE 1 END
  LIMIT 1;

  SELECT decrypted_secret
  INTO v_service_role_key
  FROM vault.decrypted_secrets
  WHERE name IN ('SUPABASE_SERVICE_ROLE_KEY', 'fangeo_service_role_key')
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY CASE name WHEN 'SUPABASE_SERVICE_ROLE_KEY' THEN 0 ELSE 1 END
  LIMIT 1;

  IF v_url IS NULL OR v_service_role_key IS NULL THEN
    UPDATE public.fan_team_member_left_push_deliveries
    SET delivery_status = 'skipped',
        skip_reason = 'vault_secrets_missing',
        updated_at = now()
    WHERE event_id = p_event_id
      AND delivery_status = 'queued';
    RAISE NOTICE '[FanTeamMemberLeaveDebug] queue skip: vault secrets missing event=%', p_event_id;
    RETURN;
  END IF;

  SELECT decrypted_secret
  INTO v_cron_secret
  FROM vault.decrypted_secrets
  WHERE name = 'FAN_TEAM_MEMBER_LEFT_PUSH_CRON_SECRET'
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY updated_at DESC NULLS LAST, created_at DESC
  LIMIT 1;

  v_headers := jsonb_build_object(
    'Content-Type', 'application/json',
    'Authorization', 'Bearer ' || v_service_role_key
  );

  IF v_cron_secret IS NOT NULL THEN
    v_headers := v_headers || jsonb_build_object('x-cron-secret', v_cron_secret);
  END IF;

  SELECT net.http_post(
    url := v_url || '/functions/v1/notify-fan-team-member-left',
    headers := v_headers,
    body := jsonb_build_object('event_id', p_event_id),
    timeout_milliseconds := 15000
  ) INTO v_request_id;

  IF v_request_id IS NOT NULL THEN
    UPDATE public.fan_team_member_left_events
    SET pg_net_request_id = v_request_id
    WHERE id = p_event_id
      AND pg_net_request_id IS NULL;
  END IF;

  RAISE NOTICE
    '[FanTeamMemberLeaveDebug] apns_attempt=queued event=% team=% request_id=% recipients=%',
    p_event_id, v_team_id, v_request_id, cardinality(v_recipients);
EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      UPDATE public.fan_team_member_left_push_deliveries
      SET delivery_status = 'failed',
          skip_reason = left('queue_exception:' || SQLERRM, 200),
          updated_at = now()
      WHERE event_id = p_event_id
        AND delivery_status = 'queued';
    EXCEPTION
      WHEN OTHERS THEN
        NULL;
    END;
    RAISE NOTICE '[FanTeamMemberLeaveDebug] queue failed event=% err=%', p_event_id, SQLERRM;
END;
$$;

REVOKE ALL ON FUNCTION public.queue_fan_team_member_left_push_notification(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.queue_fan_team_member_left_push_notification(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.queue_fan_team_member_left_push_notification(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.queue_fan_team_member_left_push_notification(uuid) TO service_role;

COMMENT ON FUNCTION public.queue_fan_team_member_left_push_notification(uuid) IS
  'Queues notify-fan-team-member-left via pg_net. Pre-inserts delivery ledger (queued). '
  'Edge applies per-recipient Team mute.';

-- ---------------------------------------------------------------------------
-- 6) leave_fan_team — cleanup + Owner/Manager push
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.leave_fan_team(p_team_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_role text;
  v_conversation_id uuid;
  v_team_name text;
  v_owner uuid;
  v_left_display text;
  v_recipients uuid[];
  v_manager_count integer := 0;
  v_event_id uuid := gen_random_uuid();
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  PERFORM public.assert_rpc_rate_limit('leave_fan_team', 30, 3600);

  IF p_team_id IS NULL THEN
    RAISE EXCEPTION 'Team id is required.';
  END IF;

  SELECT t.group_conversation_id, t.name, t.owner_user_id
  INTO v_conversation_id, v_team_name, v_owner
  FROM public.fan_teams t
  WHERE t.id = p_team_id AND t.is_active = true;

  IF v_conversation_id IS NULL THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  SELECT m.role INTO v_role
  FROM public.fan_team_members m
  WHERE m.team_id = p_team_id
    AND m.user_id = me
    AND m.left_at IS NULL;

  IF v_role IS NULL THEN
    RAISE NOTICE
      '[FanTeamMemberLeaveDebug] already_left_or_not_member team_id=% leaving_user_id=%',
      p_team_id, me;
    RETURN;
  END IF;

  IF v_role = 'owner' THEN
    RAISE EXCEPTION 'Team owners cannot leave while they own the Team.';
  END IF;

  -- Snapshot leadership BEFORE soft-leave (Owner + Manager only; not head_coach).
  SELECT coalesce(array_agg(m.user_id ORDER BY m.user_id), '{}'::uuid[])
  INTO v_recipients
  FROM public.fan_team_members m
  WHERE m.team_id = p_team_id
    AND m.left_at IS NULL
    AND m.user_id <> me
    AND public.fan_team_role_is_manager_or_owner(m.role);

  SELECT count(*)::integer INTO v_manager_count
  FROM unnest(v_recipients) AS r(uid)
  WHERE r.uid IS DISTINCT FROM v_owner;

  SELECT coalesce(
    nullif(btrim(up.display_name), ''),
    nullif(btrim(up.username), ''),
    'A teammate'
  )
  INTO v_left_display
  FROM public.user_profiles up
  WHERE up.id = me;

  v_left_display := coalesce(nullif(btrim(v_left_display), ''), 'A teammate');

  RAISE NOTICE
    '[FanTeamMemberLeaveDebug] leave_begin team_id=% leaving_user_id=% team_name=% owner_user_id=% active_manager_count=% recipient_snapshot=%',
    p_team_id, me, coalesce(v_team_name, ''), v_owner, v_manager_count, cardinality(v_recipients);

  -- Future event participation cleanup BEFORE soft-leave (GUC + auth.uid both OK).
  PERFORM public.cleanup_fan_team_member_future_event_participation(p_team_id, me);

  UPDATE public.fan_team_members
  SET left_at = now()
  WHERE team_id = p_team_id
    AND user_id = me
    AND left_at IS NULL;

  UPDATE public.group_conversation_members
  SET left_at = now()
  WHERE conversation_id = v_conversation_id
    AND user_id = me
    AND left_at IS NULL;

  UPDATE public.fan_team_invitations
  SET status = 'cancelled', cancelled_at = now(), responded_at = coalesce(responded_at, now())
  WHERE team_id = p_team_id
    AND invitee_user_id = me
    AND status = 'pending';

  -- Touch Team row so identity realtime subscribers refresh member counts.
  UPDATE public.fan_teams
  SET updated_at = now()
  WHERE id = p_team_id;

  IF cardinality(v_recipients) > 0 THEN
    INSERT INTO public.fan_team_member_left_events (
      id, team_id, left_user_id, actor_user_id, reason,
      team_name, left_display_name, recipient_user_ids
    ) VALUES (
      v_event_id,
      p_team_id,
      me,
      me,
      'left',
      coalesce(nullif(btrim(v_team_name), ''), 'Team'),
      v_left_display,
      v_recipients
    );

    PERFORM public.queue_fan_team_member_left_push_notification(v_event_id);
  ELSE
    RAISE NOTICE
      '[FanTeamMemberLeaveDebug] notification_event=no team_id=% reason=no_owner_manager_recipients',
      p_team_id;
  END IF;
END;
$$;

COMMENT ON FUNCTION public.leave_fan_team(uuid) IS
  'Non-owner soft-leave: membership + Team Chat + invite cancel + future event cleanup + '
  'Owner/Manager member_left_team APNS queue. Preserves past attendance history.';

REVOKE ALL ON FUNCTION public.leave_fan_team(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.leave_fan_team(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.leave_fan_team(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 7) remove_fan_team_member — same future cleanup (no leadership leave push)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.remove_fan_team_member(
  p_team_id uuid,
  p_user_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_target_role text;
  v_conversation_id uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'User is required.';
  END IF;

  SELECT t.group_conversation_id INTO v_conversation_id
  FROM public.fan_teams t
  WHERE t.id = p_team_id AND t.is_active = true;

  IF v_conversation_id IS NULL THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  SELECT m.role INTO v_target_role
  FROM public.fan_team_members m
  WHERE m.team_id = p_team_id
    AND m.user_id = p_user_id
    AND m.left_at IS NULL;

  IF v_target_role IS NULL THEN
    RETURN;
  END IF;

  -- Staff-removal RPC only. Voluntary self-leave must use leave_fan_team
  -- (Owner/Manager member_left_team push + cleanup). Never bypass manage auth via self.
  IF p_user_id = me THEN
    RAISE EXCEPTION 'Use leave_fan_team to leave the Team.';
  END IF;

  IF v_target_role = 'owner' THEN
    RAISE EXCEPTION 'The team owner cannot be removed.';
  END IF;

  IF NOT public.fan_team_viewer_can_manage(p_team_id) THEN
    RAISE EXCEPTION 'Only the owner or a manager can remove members.';
  END IF;

  PERFORM public.cleanup_fan_team_member_future_event_participation(p_team_id, p_user_id);

  UPDATE public.fan_team_members
  SET left_at = now()
  WHERE team_id = p_team_id
    AND user_id = p_user_id
    AND left_at IS NULL;

  UPDATE public.group_conversation_members
  SET left_at = now()
  WHERE conversation_id = v_conversation_id
    AND user_id = p_user_id
    AND left_at IS NULL;

  UPDATE public.fan_teams
  SET updated_at = now()
  WHERE id = p_team_id;

  RAISE NOTICE
    '[FanTeamMemberLeaveDebug] remove_complete team_id=% removed_user_id=% actor=%',
    p_team_id, p_user_id, me;
END;
$$;

COMMENT ON FUNCTION public.remove_fan_team_member(uuid, uuid) IS
  'STAFF soft-remove of another member + Team Chat leave + future Team-event cleanup. '
  'Rejects self-removal (use leave_fan_team). Does not send member_left_team push '
  '(voluntary leave_fan_team path only).';

REVOKE ALL ON FUNCTION public.remove_fan_team_member(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.remove_fan_team_member(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_fan_team_member(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 8) get_pickup_game_roster — filter former members on FUTURE Team events
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_pickup_game_roster(p_pickup_game_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_creator uuid;
  v_can_read boolean := false;
  v_is_organizer boolean := false;
  v_is_team_participant boolean := false;
  v_team_id uuid;
  v_game_start_at timestamptz;
  v_game_is_future boolean := false;
  v_organizer jsonb;
  v_playing jsonb := '[]'::jsonb;
  v_pending jsonb := '[]'::jsonb;
  v_declined jsonb := '[]'::jsonb;
  v_no_response jsonb := '[]'::jsonb;
  v_include_team_responses boolean := false;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '42501';
  END IF;

  IF p_pickup_game_id IS NULL THEN
    RAISE EXCEPTION 'Pickup game id required.';
  END IF;

  SELECT g.creator_user_id, g.game_start_at INTO v_creator, v_game_start_at
  FROM public.pickup_games g
  WHERE g.id = p_pickup_game_id;

  IF v_creator IS NULL THEN
    RAISE EXCEPTION 'Pickup game not found.';
  END IF;

  v_game_is_future := (v_game_start_at IS NOT NULL AND v_game_start_at >= now());

  SELECT EXISTS (
    SELECT 1
    FROM public.pickup_games g
    WHERE g.id = p_pickup_game_id
      AND (
        g.creator_user_id = me
        OR (
          lower(btrim(g.status)) = 'active'
          AND g.is_visible IS TRUE
          AND (g.remove_after_at IS NULL OR g.remove_after_at > now())
        )
        OR public.can_read_pickup_game_for_requester(g.id)
        OR public.is_pickup_game_fan_team_participant(g.id, me)
      )
  ) INTO v_can_read;

  IF NOT v_can_read THEN
    RAISE EXCEPTION 'Not authorized to view this pickup game roster.'
      USING ERRCODE = '42501';
  END IF;

  v_is_organizer := (v_creator = me);
  v_is_team_participant := public.is_pickup_game_fan_team_participant(p_pickup_game_id, me);

  SELECT l.team_id INTO v_team_id
  FROM public.fan_team_game_links l
  WHERE l.pickup_game_id = p_pickup_game_id
  LIMIT 1;

  v_include_team_responses := (v_team_id IS NOT NULL)
    AND (v_is_organizer OR v_is_team_participant);

  SELECT jsonb_build_object(
    'user_id', up.id,
    'display_name', nullif(btrim(coalesce(up.display_name, '')), ''),
    'username', nullif(btrim(coalesce(up.username, '')), ''),
    'avatar_url', nullif(btrim(coalesce(up.avatar_url, '')), ''),
    'avatar_thumbnail_url', nullif(btrim(coalesce(up.avatar_thumbnail_url, up.avatar_url, '')), ''),
    'role', 'organizer'
  )
  INTO v_organizer
  FROM public.user_profiles up
  WHERE up.id = v_creator
    AND coalesce(up.is_deleted, false) = false;

  IF v_organizer IS NULL THEN
    v_organizer := jsonb_build_object(
      'user_id', v_creator,
      'display_name', NULL,
      'username', NULL,
      'avatar_url', NULL,
      'avatar_thumbnail_url', NULL,
      'role', 'organizer'
    );
  END IF;

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'user_id', r.requester_user_id,
        'request_id', r.id,
        'display_name', coalesce(
          nullif(btrim(coalesce(up.display_name, '')), ''),
          nullif(btrim(coalesce(r.requester_display_name, '')), '')
        ),
        'username', nullif(btrim(coalesce(up.username, '')), ''),
        'avatar_url', nullif(btrim(coalesce(up.avatar_url, '')), ''),
        'avatar_thumbnail_url', nullif(btrim(coalesce(up.avatar_thumbnail_url, up.avatar_url, '')), ''),
        'role', 'playing',
        'status', 'approved'
      )
      ORDER BY r.responded_at NULLS LAST, r.created_at ASC, r.id ASC
    ),
    '[]'::jsonb
  )
  INTO v_playing
  FROM public.pickup_game_requests r
  LEFT JOIN public.user_profiles up
    ON up.id = r.requester_user_id
   AND coalesce(up.is_deleted, false) = false
  WHERE r.pickup_game_id = p_pickup_game_id
    AND lower(btrim(r.status)) = 'approved'
    AND r.requester_user_id IS DISTINCT FROM v_creator
    AND (
      v_team_id IS NULL
      OR public.is_fan_team_linked_request_actor_eligible(
        v_team_id, r.requester_user_id, r.created_at, v_game_is_future
      )
    );

  IF v_is_organizer OR v_include_team_responses THEN
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'user_id', r.requester_user_id,
          'request_id', r.id,
          'display_name', coalesce(
            nullif(btrim(coalesce(up.display_name, '')), ''),
            nullif(btrim(coalesce(r.requester_display_name, '')), '')
          ),
          'username', nullif(btrim(coalesce(up.username, '')), ''),
          'avatar_url', nullif(btrim(coalesce(up.avatar_url, '')), ''),
          'avatar_thumbnail_url', nullif(btrim(coalesce(up.avatar_thumbnail_url, up.avatar_url, '')), ''),
          'role', 'pending',
          'status', 'pending'
        )
        ORDER BY r.created_at ASC, r.id ASC
      ),
      '[]'::jsonb
    )
    INTO v_pending
    FROM public.pickup_game_requests r
    LEFT JOIN public.user_profiles up
      ON up.id = r.requester_user_id
     AND coalesce(up.is_deleted, false) = false
    WHERE r.pickup_game_id = p_pickup_game_id
      AND lower(btrim(r.status)) = 'pending'
      AND (
        v_team_id IS NULL
        OR public.is_fan_team_linked_request_actor_eligible(
          v_team_id, r.requester_user_id, r.created_at, v_game_is_future
        )
      );
  END IF;

  IF v_include_team_responses THEN
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'user_id', r.requester_user_id,
          'request_id', r.id,
          'display_name', coalesce(
            nullif(btrim(coalesce(up.display_name, '')), ''),
            nullif(btrim(coalesce(r.requester_display_name, '')), '')
          ),
          'username', nullif(btrim(coalesce(up.username, '')), ''),
          'avatar_url', nullif(btrim(coalesce(up.avatar_url, '')), ''),
          'avatar_thumbnail_url', nullif(btrim(coalesce(up.avatar_thumbnail_url, up.avatar_url, '')), ''),
          'role', 'declined',
          'status', lower(btrim(r.status))
        )
        ORDER BY r.updated_at DESC NULLS LAST, r.created_at ASC, r.id ASC
      ),
      '[]'::jsonb
    )
    INTO v_declined
    FROM public.pickup_game_requests r
    LEFT JOIN public.user_profiles up
      ON up.id = r.requester_user_id
     AND coalesce(up.is_deleted, false) = false
    WHERE r.pickup_game_id = p_pickup_game_id
      AND lower(btrim(r.status)) IN ('withdrawn', 'rejected', 'cancelled')
      AND r.requester_user_id IS DISTINCT FROM v_creator
      AND public.is_fan_team_linked_request_actor_eligible(
        v_team_id, r.requester_user_id, r.created_at, v_game_is_future
      );

    -- No Response = ACTIVE Team members with no request row (never former members).
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'user_id', m.user_id,
          'request_id', NULL,
          'display_name', nullif(btrim(coalesce(up.display_name, '')), ''),
          'username', nullif(btrim(coalesce(up.username, '')), ''),
          'avatar_url', nullif(btrim(coalesce(up.avatar_url, '')), ''),
          'avatar_thumbnail_url', nullif(btrim(coalesce(up.avatar_thumbnail_url, up.avatar_url, '')), ''),
          'role', 'no_response',
          'status', 'no_response'
        )
        ORDER BY lower(coalesce(up.display_name, up.username, '')), m.user_id
      ),
      '[]'::jsonb
    )
    INTO v_no_response
    FROM public.fan_team_members m
    LEFT JOIN public.user_profiles up
      ON up.id = m.user_id
     AND coalesce(up.is_deleted, false) = false
    WHERE m.team_id = v_team_id
      AND m.left_at IS NULL
      AND m.user_id IS DISTINCT FROM v_creator
      AND NOT EXISTS (
        SELECT 1
        FROM public.pickup_game_requests r
        WHERE r.pickup_game_id = p_pickup_game_id
          AND r.requester_user_id = m.user_id
          AND (
            NOT v_game_is_future
            OR public.is_fan_team_linked_request_actor_eligible(
              v_team_id, r.requester_user_id, r.created_at, v_game_is_future
            )
          )
      );
  END IF;

  RETURN jsonb_build_object(
    'pickup_game_id', p_pickup_game_id,
    'viewer_is_organizer', v_is_organizer,
    'organizer', v_organizer,
    'playing', v_playing,
    'pending', v_pending,
    'declined', v_declined,
    'no_response', v_no_response,
    'approved_join_count', jsonb_array_length(v_playing),
    'playing_total_count', 1 + jsonb_array_length(v_playing)
  );
END;
$$;

COMMENT ON FUNCTION public.get_pickup_game_roster(uuid) IS
  'Privacy-safe pickup roster. Team-linked FUTURE events exclude former Team members '
  'from playing/pending/declined; no_response is active members only. Past events keep history. '
  'Outside recruits remain visible when eligible.';

-- ---------------------------------------------------------------------------
-- 9) Change-push recipients: drop stale former-member request rows
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_pickup_game_change_push_tokens(
  p_pickup_game_id uuid,
  p_exclude_user_id uuid
)
RETURNS TABLE (
  token_id uuid,
  user_id uuid,
  token text,
  environment text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH team_linked AS (
    SELECT EXISTS (
      SELECT 1
      FROM public.fan_team_game_links l
      WHERE l.pickup_game_id = p_pickup_game_id
    ) AS is_linked
  ),
  linked_teams AS (
    SELECT DISTINCT l.team_id
    FROM public.fan_team_game_links l
    INNER JOIN public.fan_teams t
      ON t.id = l.team_id
     AND t.is_active = true
    WHERE l.pickup_game_id = p_pickup_game_id
  ),
  game_meta AS (
    SELECT g.game_start_at >= now() AS is_future
    FROM public.pickup_games g
    WHERE g.id = p_pickup_game_id
  ),
  affected AS (
    SELECT r.requester_user_id AS uid
    FROM public.pickup_game_requests r
    CROSS JOIN team_linked tl
    CROSS JOIN game_meta gm
    LEFT JOIN public.fan_team_game_links l ON l.pickup_game_id = r.pickup_game_id
    WHERE r.pickup_game_id = p_pickup_game_id
      AND lower(btrim(r.status)) = 'approved'
      AND (
        NOT tl.is_linked
        OR public.is_fan_team_linked_request_actor_eligible(
          l.team_id, r.requester_user_id, r.created_at, gm.is_future
        )
      )

    UNION

    SELECT r.requester_user_id AS uid
    FROM public.pickup_game_requests r
    CROSS JOIN team_linked tl
    CROSS JOIN game_meta gm
    LEFT JOIN public.fan_team_game_links l ON l.pickup_game_id = r.pickup_game_id
    WHERE r.pickup_game_id = p_pickup_game_id
      AND tl.is_linked
      AND lower(btrim(r.status)) = 'pending'
      AND public.is_fan_team_linked_request_actor_eligible(
        l.team_id, r.requester_user_id, r.created_at, gm.is_future
      )

    UNION

    SELECT i.invitee_user_id AS uid
    FROM public.pickup_game_invites i
    WHERE i.pickup_game_id = p_pickup_game_id
      AND lower(btrim(i.status)) IN ('accepted', 'maybe')

    UNION

    SELECT m.user_id AS uid
    FROM public.fan_team_members m
    INNER JOIN linked_teams lt ON lt.team_id = m.team_id
    WHERE m.left_at IS NULL
  )
  SELECT DISTINCT ON (t.user_id, t.token, t.environment)
    t.id AS token_id,
    t.user_id,
    t.token,
    t.environment
  FROM public.user_push_tokens t
  INNER JOIN affected a ON a.uid = t.user_id
  LEFT JOIN public.user_notification_preferences p ON p.user_id = t.user_id
  LEFT JOIN public.user_profiles up ON up.id = t.user_id
  WHERE t.is_active = true
    AND (p_exclude_user_id IS NULL OR t.user_id IS DISTINCT FROM p_exclude_user_id)
    AND COALESCE(p.pickup_game_change_notifications_enabled, true) = true
    AND up.deleted_at IS NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.user_bans ub
      WHERE ub.user_id = t.user_id
        AND public.is_user_ban_active(ub.expires_at, ub.lifted_at)
    )
  ORDER BY t.user_id, t.token, t.environment, t.last_seen_at DESC NULLS LAST;
$$;

REVOKE ALL ON FUNCTION public.list_pickup_game_change_push_tokens(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_pickup_game_change_push_tokens(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.list_pickup_game_change_push_tokens(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.list_pickup_game_change_push_tokens(uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.list_pickup_game_change_push_tokens(uuid, uuid) IS
  'Change-push tokens: Team-linked includes active members + eligible outside requests. '
  'Former Team members with stale pre-leave RSVP rows are excluded for future events.';

-- ---------------------------------------------------------------------------
-- 10) Lineup retrieval: hide left members on future games (preserve 20260952 shape)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_fan_team_event_lineup(
  p_pickup_game_id uuid,
  p_team_id uuid DEFAULT NULL
)
RETURNS TABLE (
  lineup_id uuid,
  team_id uuid,
  pickup_game_id uuid,
  status text,
  formation text,
  published_at timestamptz,
  published_by uuid,
  updated_at timestamptz,
  viewer_can_manage boolean,
  members jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_team_id uuid;
  v_lineup public.fan_team_event_lineups%ROWTYPE;
  v_can_manage boolean;
  v_game_start_at timestamptz;
  v_game_is_future boolean := false;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_pickup_game_id IS NULL THEN
    RAISE EXCEPTION 'Pickup game is required.';
  END IF;

  IF p_team_id IS NOT NULL THEN
    v_team_id := p_team_id;
  ELSE
    SELECT l.team_id
    INTO v_team_id
    FROM public.fan_team_game_links l
    WHERE l.pickup_game_id = p_pickup_game_id
    ORDER BY CASE l.side WHEN 'home' THEN 0 WHEN 'solo' THEN 1 ELSE 2 END
    LIMIT 1;
  END IF;

  IF v_team_id IS NULL THEN
    RAISE EXCEPTION 'Team link not found for this event.';
  END IF;

  IF NOT public.is_active_fan_team_member(v_team_id, me) THEN
    RAISE EXCEPTION 'Not a team member.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.fan_team_game_links l
    WHERE l.pickup_game_id = p_pickup_game_id
      AND l.team_id = v_team_id
  ) THEN
    RAISE EXCEPTION 'Team is not linked to this event.';
  END IF;

  SELECT g.game_start_at INTO v_game_start_at
  FROM public.pickup_games g
  WHERE g.id = p_pickup_game_id;
  v_game_is_future := (v_game_start_at IS NOT NULL AND v_game_start_at >= now());

  v_can_manage := public.fan_team_viewer_can_manage_lineup(v_team_id);

  SELECT *
  INTO v_lineup
  FROM public.fan_team_event_lineups l
  WHERE l.team_id = v_team_id
    AND l.pickup_game_id = p_pickup_game_id;

  IF v_lineup.id IS NULL THEN
    lineup_id := NULL;
    team_id := v_team_id;
    pickup_game_id := p_pickup_game_id;
    status := NULL;
    formation := NULL;
    published_at := NULL;
    published_by := NULL;
    updated_at := NULL;
    viewer_can_manage := v_can_manage;
    members := '[]'::jsonb;
    RETURN NEXT;
    RETURN;
  END IF;

  IF v_lineup.status = 'draft' AND NOT v_can_manage THEN
    lineup_id := NULL;
    team_id := v_team_id;
    pickup_game_id := p_pickup_game_id;
    status := NULL;
    formation := NULL;
    published_at := NULL;
    published_by := NULL;
    updated_at := NULL;
    viewer_can_manage := false;
    members := '[]'::jsonb;
    RETURN NEXT;
    RETURN;
  END IF;

  lineup_id := v_lineup.id;
  team_id := v_lineup.team_id;
  pickup_game_id := v_lineup.pickup_game_id;
  status := v_lineup.status;
  formation := v_lineup.formation;
  published_at := v_lineup.published_at;
  published_by := v_lineup.published_by;
  updated_at := v_lineup.updated_at;
  viewer_can_manage := v_can_manage;
  members := coalesce((
    SELECT jsonb_agg(
      jsonb_build_object(
        'user_id', m.user_id,
        'lineup_status', m.lineup_status,
        'position_code', m.position_code,
        'sort_order', m.sort_order
      )
      ORDER BY
        CASE m.lineup_status WHEN 'starting' THEN 0 ELSE 1 END,
        m.sort_order ASC,
        m.created_at ASC
    )
    FROM public.fan_team_event_lineup_members m
    WHERE m.lineup_id = v_lineup.id
      AND (
        NOT v_game_is_future
        OR EXISTS (
          SELECT 1
          FROM public.fan_team_members tm
          WHERE tm.team_id = v_team_id
            AND tm.user_id = m.user_id
            AND tm.left_at IS NULL
        )
      )
  ), '[]'::jsonb);

  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION public.get_fan_team_event_lineup(uuid, uuid) IS
  'Returns Team event lineup. Future games omit soft-left members; past published history kept.';

REVOKE ALL ON FUNCTION public.get_fan_team_event_lineup(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_fan_team_event_lineup(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_fan_team_event_lineup(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_fan_team_event_lineup(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 11) Realtime: fan_team_members so Owner/Manager devices refresh without restart
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('public.fan_team_members') IS NULL THEN
    RAISE NOTICE '[FanTeamMemberLeaveDebug] realtime skipped: fan_team_members missing';
    RETURN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    RAISE NOTICE '[FanTeamMemberLeaveDebug] realtime skipped: supabase_realtime missing';
    RETURN;
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables pt
    WHERE pt.pubname = 'supabase_realtime'
      AND pt.schemaname = 'public'
      AND pt.tablename = 'fan_team_members'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.fan_team_members;
    RAISE NOTICE '[FanTeamMemberLeaveDebug] realtime added fan_team_members';
  ELSE
    RAISE NOTICE '[FanTeamMemberLeaveDebug] realtime fan_team_members already published';
  END IF;
END;
$$;

COMMIT;

-- MANUAL APPLY NOTES
-- 1) Apply after 20260956 in Supabase SQL editor.
-- 2) Deploy Edge:
--      supabase functions deploy notify-fan-team-member-left --no-verify-jwt
-- 3) Optional vault: FAN_TEAM_MEMBER_LEFT_PUSH_CRON_SECRET
-- 4) No other Edge redeploys required for this change (pickup-game-change SQL only).
