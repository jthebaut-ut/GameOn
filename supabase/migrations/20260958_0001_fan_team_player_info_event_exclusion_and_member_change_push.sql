-- =============================================================================
-- 20260958_0001 — Fan Team player management: event exclusion + member-change push
-- =============================================================================
-- Two independent features sharing one push pipeline:
--
-- A) Per-event exclusion (fan_team_event_exclusions):
--    Staff (owner/manager/head_coach/assistant_coach) can set aside an active
--    Team member from ONE specific pickup_games event without removing them
--    from the Team. Excluding drops that user's lineup seat for the event and
--    withdraws/cancels their RSVP for THAT game only. Un-excluding does NOT
--    restore RSVP or lineup — the member re-RSVPs / gets re-added manually.
--
-- B) Generalized "member change" notification pipeline
--    (fan_team_member_change_events / …_push_deliveries), replacing one-off
--    plumbing for: player_number_*, preferred_position_*, team_role_changed,
--    removed_from_event, added_back_to_event, removed_from_team.
--    Recipient is ALWAYS just the target member (never a leadership fan-out).
--    Self-edits (actor = target) never notify.
--
--    This is intentionally separate from fan_team_member_left_events /
--    notify-fan-team-member-left (20260957), which stays untouched:
--    leave_fan_team continues to push leadership on voluntary leave via the
--    member_left pipeline. remove_fan_team_member (staff-initiated) now emits
--    removed_from_team via THIS member-change pipeline instead.
--
-- get_pickup_game_roster / list_pickup_game_change_push_tokens are updated to
-- respect fan_team_event_exclusions (excluded members disappear from
-- playing/pending/declined/no_response + change-push recipients, and appear
-- in a new 'excluded' bucket visible to lineup managers / team responders).
--
-- Depends on: 20260947 (player_number), 20260950 (role hierarchy + set_role),
-- 20260952 (event lineups + position helpers), 20260953 (preferred_position),
-- 20260957 (member_left cleanup GUC + roster/token filtering baseline).
--
-- SECURITY / INTEGRITY HARDENING (pre-production SQL review):
--   1) remove_fan_team_member rejects p_user_id = auth.uid() (staff-only;
--      voluntary leave → leave_fan_team only).
--   2) set_fan_team_event_member_excluded rejects past events
--      (game_start_at < now() or null) — historical RSVP/lineup immutable.
--   3) Exclusion/unexclusion is idempotent: no mutation + no push when state
--      already matches the requested exclusion flag.
--   4) set_fan_team_member_role restores is_active_fan_team_member gate before
--      any fan_team_members / group_conversation_members updates.
--   5) is_fan_team_event_member_excluded EXECUTE revoked from authenticated/
--      anon/PUBLIC (internal helper; no iOS caller).
--
-- Do NOT apply from the agent. Apply manually in Supabase after 20260957.
-- Deploy Edge AFTER apply:
--   supabase functions deploy notify-fan-team-member-change --no-verify-jwt
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) fan_team_event_exclusions — table + RLS
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.fan_team_event_exclusions (
  team_id uuid NOT NULL REFERENCES public.fan_teams (id) ON DELETE CASCADE,
  pickup_game_id uuid NOT NULL REFERENCES public.pickup_games (id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  excluded_by uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  excluded_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (team_id, pickup_game_id, user_id)
);

CREATE INDEX IF NOT EXISTS fan_team_event_exclusions_game_idx
  ON public.fan_team_event_exclusions (pickup_game_id);

COMMENT ON TABLE public.fan_team_event_exclusions IS
  'Per-event exclusion: an active Team member set aside from one pickup_games event '
  'by staff. Does not remove Team membership. Write path: set_fan_team_event_member_excluded only.';

ALTER TABLE public.fan_team_event_exclusions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS fan_team_event_exclusions_select ON public.fan_team_event_exclusions;
CREATE POLICY fan_team_event_exclusions_select ON public.fan_team_event_exclusions
  FOR SELECT TO authenticated
  USING (public.is_active_fan_team_member(team_id, auth.uid()));

-- Drop any accidental write policies (RPC-only writes).
DO $$
DECLARE
  pol record;
BEGIN
  FOR pol IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'fan_team_event_exclusions'
      AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.fan_team_event_exclusions', pol.policyname);
  END LOOP;
END $$;

REVOKE ALL ON TABLE public.fan_team_event_exclusions FROM PUBLIC;
REVOKE ALL ON TABLE public.fan_team_event_exclusions FROM anon;
REVOKE ALL ON TABLE public.fan_team_event_exclusions FROM authenticated;
GRANT SELECT ON TABLE public.fan_team_event_exclusions TO authenticated;
GRANT ALL ON TABLE public.fan_team_event_exclusions TO service_role;

CREATE OR REPLACE FUNCTION public.is_fan_team_event_member_excluded(
  p_team_id uuid,
  p_pickup_game_id uuid,
  p_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.fan_team_event_exclusions e
    WHERE e.team_id = p_team_id
      AND e.pickup_game_id = p_pickup_game_id
      AND e.user_id = p_user_id
  );
$$;

COMMENT ON FUNCTION public.is_fan_team_event_member_excluded(uuid, uuid, uuid) IS
  'INTERNAL helper: true when a Team member is set aside from a specific event. '
  'Called only from SECURITY DEFINER roster/token RPCs — not a client RPC.';

-- Internal only (no iOS caller). Prevents arbitrary exclusion-state probing.
REVOKE ALL ON FUNCTION public.is_fan_team_event_member_excluded(uuid, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_fan_team_event_member_excluded(uuid, uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.is_fan_team_event_member_excluded(uuid, uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.is_fan_team_event_member_excluded(uuid, uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 2) Member-change notification infrastructure (tables)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.fan_team_member_change_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id uuid NOT NULL REFERENCES public.fan_teams (id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN (
    'player_number_set', 'player_number_changed', 'player_number_removed',
    'preferred_position_set', 'preferred_position_changed', 'preferred_position_removed',
    'team_role_changed',
    'removed_from_event', 'added_back_to_event',
    'removed_from_team'
  )),
  actor_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  target_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  team_name text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  recipient_user_ids uuid[] NOT NULL DEFAULT '{}',
  pg_net_request_id bigint,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS fan_team_member_change_events_team_created_idx
  ON public.fan_team_member_change_events (team_id, created_at DESC);
CREATE INDEX IF NOT EXISTS fan_team_member_change_events_target_idx
  ON public.fan_team_member_change_events (target_user_id, created_at DESC);

COMMENT ON TABLE public.fan_team_member_change_events IS
  'Player-info / role / event-roster / team-removal lifecycle events. '
  'recipient_user_ids = [target_user_id] only (never a leadership fan-out). '
  'kind for Edge/APNS: see CHECK constraint. Emitted by emit_fan_team_member_change_notification.';

ALTER TABLE public.fan_team_member_change_events ENABLE ROW LEVEL SECURITY;
GRANT ALL ON public.fan_team_member_change_events TO service_role;

CREATE TABLE IF NOT EXISTS public.fan_team_member_change_push_deliveries (
  event_id uuid NOT NULL REFERENCES public.fan_team_member_change_events (id) ON DELETE CASCADE,
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

CREATE INDEX IF NOT EXISTS fan_team_member_change_push_deliveries_team_created_idx
  ON public.fan_team_member_change_push_deliveries (team_id, created_at DESC);

ALTER TABLE public.fan_team_member_change_push_deliveries ENABLE ROW LEVEL SECURITY;
GRANT ALL ON public.fan_team_member_change_push_deliveries TO service_role;

-- ---------------------------------------------------------------------------
-- 3) queue_fan_team_member_change_push_notification
--    Clone of queue_fan_team_member_left_push_notification (20260957) —
--    pre-insert ledger, pg_net → notify-fan-team-member-change.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.queue_fan_team_member_change_push_notification(
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
  FROM public.fan_team_member_change_events e
  WHERE e.id = p_event_id;

  IF v_team_id IS NULL THEN
    RAISE NOTICE '[FanTeamMemberChangeDebug] queue skip: event missing event=%', p_event_id;
    RETURN;
  END IF;

  IF coalesce(cardinality(v_recipients), 0) = 0 THEN
    RAISE NOTICE '[FanTeamMemberChangeDebug] queue skip: no recipients event=% team=%',
      p_event_id, v_team_id;
    RETURN;
  END IF;

  FOREACH v_uid IN ARRAY v_recipients LOOP
    IF v_uid IS NULL THEN
      CONTINUE;
    END IF;
    INSERT INTO public.fan_team_member_change_push_deliveries (
      event_id, recipient_user_id, team_id, delivery_status
    ) VALUES (
      p_event_id, v_uid, v_team_id, 'queued'
    )
    ON CONFLICT (event_id, recipient_user_id) DO NOTHING;
  END LOOP;

  RAISE NOTICE
    '[FanTeamMemberChangeDebug] notification_event=yes event=% team=% recipient_snapshot=%',
    p_event_id, v_team_id, cardinality(v_recipients);

  IF to_regnamespace('net') IS NULL OR to_regclass('vault.decrypted_secrets') IS NULL THEN
    UPDATE public.fan_team_member_change_push_deliveries
    SET delivery_status = 'skipped',
        skip_reason = 'pg_net_or_vault_unavailable',
        updated_at = now()
    WHERE event_id = p_event_id
      AND delivery_status = 'queued';
    RAISE NOTICE '[FanTeamMemberChangeDebug] queue skip: pg_net/vault unavailable event=%', p_event_id;
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
    UPDATE public.fan_team_member_change_push_deliveries
    SET delivery_status = 'skipped',
        skip_reason = 'vault_secrets_missing',
        updated_at = now()
    WHERE event_id = p_event_id
      AND delivery_status = 'queued';
    RAISE NOTICE '[FanTeamMemberChangeDebug] queue skip: vault secrets missing event=%', p_event_id;
    RETURN;
  END IF;

  SELECT decrypted_secret
  INTO v_cron_secret
  FROM vault.decrypted_secrets
  WHERE name = 'FAN_TEAM_MEMBER_CHANGE_PUSH_CRON_SECRET'
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
    url := v_url || '/functions/v1/notify-fan-team-member-change',
    headers := v_headers,
    body := jsonb_build_object('event_id', p_event_id),
    timeout_milliseconds := 15000
  ) INTO v_request_id;

  IF v_request_id IS NOT NULL THEN
    UPDATE public.fan_team_member_change_events
    SET pg_net_request_id = v_request_id
    WHERE id = p_event_id
      AND pg_net_request_id IS NULL;
  END IF;

  RAISE NOTICE
    '[FanTeamMemberChangeDebug] apns_attempt=queued event=% team=% request_id=% recipients=%',
    p_event_id, v_team_id, v_request_id, cardinality(v_recipients);
EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      UPDATE public.fan_team_member_change_push_deliveries
      SET delivery_status = 'failed',
          skip_reason = left('queue_exception:' || SQLERRM, 200),
          updated_at = now()
      WHERE event_id = p_event_id
        AND delivery_status = 'queued';
    EXCEPTION
      WHEN OTHERS THEN
        NULL;
    END;
    RAISE NOTICE '[FanTeamMemberChangeDebug] queue failed event=% err=%', p_event_id, SQLERRM;
END;
$$;

COMMENT ON FUNCTION public.queue_fan_team_member_change_push_notification(uuid) IS
  'Queues notify-fan-team-member-change via pg_net. Pre-inserts delivery ledger (queued). '
  'Edge applies centralized mandatory/mute policy per kind.';

REVOKE ALL ON FUNCTION public.queue_fan_team_member_change_push_notification(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.queue_fan_team_member_change_push_notification(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.queue_fan_team_member_change_push_notification(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.queue_fan_team_member_change_push_notification(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 4) emit_fan_team_member_change_notification
--    SECURITY DEFINER helper called from other SECURITY DEFINER RPCs only.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.emit_fan_team_member_change_notification(
  p_team_id uuid,
  p_kind text,
  p_actor_user_id uuid,
  p_target_user_id uuid,
  p_payload jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_team_name text;
  v_event_id uuid := gen_random_uuid();
  v_recipients uuid[];
BEGIN
  -- Never emit without a target (nothing to notify).
  IF p_team_id IS NULL OR p_target_user_id IS NULL THEN
    RAISE NOTICE
      '[FanTeamMemberChangeDebug] emit_skip reason=missing_team_or_target team_id=% kind=% target=%',
      p_team_id, p_kind, p_target_user_id;
    RETURN NULL;
  END IF;

  -- No self-notify: manager editing their own player info/role should be silent.
  IF p_actor_user_id IS NULL OR p_actor_user_id = p_target_user_id THEN
    RAISE NOTICE
      '[FanTeamMemberChangeDebug] emit_skip reason=self_or_missing_actor team_id=% kind=% actor=% target=%',
      p_team_id, p_kind, p_actor_user_id, p_target_user_id;
    RETURN NULL;
  END IF;

  SELECT coalesce(nullif(btrim(t.name), ''), 'Team')
  INTO v_team_name
  FROM public.fan_teams t
  WHERE t.id = p_team_id;

  v_team_name := coalesce(v_team_name, 'Team');
  v_recipients := ARRAY[p_target_user_id]::uuid[];

  INSERT INTO public.fan_team_member_change_events (
    id, team_id, kind, actor_user_id, target_user_id, team_name, payload, recipient_user_ids
  ) VALUES (
    v_event_id, p_team_id, p_kind, p_actor_user_id, p_target_user_id,
    v_team_name, coalesce(p_payload, '{}'::jsonb), v_recipients
  );

  RAISE NOTICE
    '[FanTeamMemberChangeDebug] emit_ok event=% team_id=% kind=% actor=% target=% recipient_count=%',
    v_event_id, p_team_id, p_kind, p_actor_user_id, p_target_user_id, cardinality(v_recipients);

  IF cardinality(v_recipients) > 0 THEN
    PERFORM public.queue_fan_team_member_change_push_notification(v_event_id);
  ELSE
    RAISE NOTICE
      '[FanTeamMemberChangeDebug] notification_event=no team_id=% kind=% reason=no_recipients',
      p_team_id, p_kind;
  END IF;

  RETURN v_event_id;
END;
$$;

COMMENT ON FUNCTION public.emit_fan_team_member_change_notification(uuid, text, uuid, uuid, jsonb) IS
  'Internal helper: records + queues a member-change push. recipient = [target] only. '
  'Skips silently when actor = target or target is missing. Call only from SECURITY DEFINER RPCs.';

REVOKE ALL ON FUNCTION public.emit_fan_team_member_change_notification(uuid, text, uuid, uuid, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.emit_fan_team_member_change_notification(uuid, text, uuid, uuid, jsonb) FROM anon;
REVOKE ALL ON FUNCTION public.emit_fan_team_member_change_notification(uuid, text, uuid, uuid, jsonb) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.emit_fan_team_member_change_notification(uuid, text, uuid, uuid, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- 5) set_fan_team_event_member_excluded
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_fan_team_event_member_excluded(
  p_team_id uuid,
  p_pickup_game_id uuid,
  p_user_id uuid,
  p_excluded boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_team_active boolean;
  v_linked boolean;
  v_game_format text;
  v_game_start_at timestamptz;
  v_event_title text;
  v_change_payload jsonb;
  v_already_excluded boolean;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_team_id IS NULL OR p_pickup_game_id IS NULL OR p_user_id IS NULL THEN
    RAISE EXCEPTION 'Team, event, and user are required.';
  END IF;
  IF p_user_id = me THEN
    RAISE EXCEPTION 'Cannot change your own event exclusion.';
  END IF;

  SELECT t.is_active INTO v_team_active
  FROM public.fan_teams t
  WHERE t.id = p_team_id;

  IF v_team_active IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.fan_team_game_links l
    WHERE l.pickup_game_id = p_pickup_game_id
      AND l.team_id = p_team_id
  ) INTO v_linked;

  IF NOT v_linked THEN
    RAISE EXCEPTION 'Event is not linked to this Team.';
  END IF;

  IF NOT public.is_active_fan_team_member(p_team_id, p_user_id) THEN
    RAISE EXCEPTION 'User is not an active team member.';
  END IF;

  IF NOT public.fan_team_viewer_can_manage_lineup(p_team_id) THEN
    RAISE EXCEPTION 'Only coaches and managers can manage the event roster.';
  END IF;

  SELECT g.game_format, g.game_start_at, g.title
  INTO v_game_format, v_game_start_at, v_event_title
  FROM public.pickup_games g
  WHERE g.id = p_pickup_game_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Event not found.';
  END IF;

  -- Historical integrity: never mutate past completed events (RSVP / lineup / exclusions).
  IF v_game_start_at IS NULL OR v_game_start_at < now() THEN
    RAISE EXCEPTION 'Cannot change exclusion for a past event.';
  END IF;

  v_already_excluded := public.is_fan_team_event_member_excluded(
    p_team_id, p_pickup_game_id, p_user_id
  );

  v_change_payload := jsonb_build_object(
    'game_format', v_game_format,
    'game_start_at', v_game_start_at,
    'event_title', v_event_title,
    'pickup_game_id', p_pickup_game_id
  );

  IF coalesce(p_excluded, false) THEN
    -- Idempotent: already excluded → no SQL mutation, no notification.
    IF v_already_excluded THEN
      RAISE NOTICE
        '[FanTeamMemberChangeDebug] event_exclusion_noop_already_excluded team_id=% pickup_game_id=% user_id=%',
        p_team_id, p_pickup_game_id, p_user_id;
      RETURN;
    END IF;

    INSERT INTO public.fan_team_event_exclusions (
      team_id, pickup_game_id, user_id, excluded_by
    ) VALUES (
      p_team_id, p_pickup_game_id, p_user_id, me
    );

    -- Drop the excluded member's seat in this event's lineup (if any).
    DELETE FROM public.fan_team_event_lineup_members lm
    USING public.fan_team_event_lineups l
    WHERE lm.lineup_id = l.id
      AND l.team_id = p_team_id
      AND l.pickup_game_id = p_pickup_game_id
      AND lm.user_id = p_user_id;

    -- Trusted context for the pickup_game_requests status trigger (target is
    -- not the acting user — mirrors cleanup_fan_team_member_future_event_participation).
    PERFORM set_config('gameon.fan_team_member_leave_cleanup', p_user_id::text, true);

    -- This event only: approved -> withdrawn, pending -> cancelled.
    UPDATE public.pickup_game_requests r
    SET status = CASE
          WHEN lower(btrim(r.status)) = 'approved' THEN 'withdrawn'
          WHEN lower(btrim(r.status)) = 'pending' THEN 'cancelled'
          ELSE r.status
        END,
        responded_at = coalesce(r.responded_at, now()),
        updated_at = now()
    WHERE r.pickup_game_id = p_pickup_game_id
      AND r.requester_user_id = p_user_id
      AND lower(btrim(r.status)) IN ('approved', 'pending');

    PERFORM public.emit_fan_team_member_change_notification(
      p_team_id,
      'removed_from_event',
      me,
      p_user_id,
      v_change_payload
    );

    RAISE NOTICE
      '[FanTeamMemberChangeDebug] event_exclusion_set team_id=% pickup_game_id=% user_id=% actor=%',
      p_team_id, p_pickup_game_id, p_user_id, me;
  ELSE
    -- Idempotent: already included → no SQL mutation, no notification.
    IF NOT v_already_excluded THEN
      RAISE NOTICE
        '[FanTeamMemberChangeDebug] event_exclusion_noop_already_included team_id=% pickup_game_id=% user_id=%',
        p_team_id, p_pickup_game_id, p_user_id;
      RETURN;
    END IF;

    DELETE FROM public.fan_team_event_exclusions
    WHERE team_id = p_team_id
      AND pickup_game_id = p_pickup_game_id
      AND user_id = p_user_id;

    -- Intentionally does NOT restore RSVP or lineup membership.
    PERFORM public.emit_fan_team_member_change_notification(
      p_team_id,
      'added_back_to_event',
      me,
      p_user_id,
      v_change_payload
    );

    RAISE NOTICE
      '[FanTeamMemberChangeDebug] event_exclusion_cleared team_id=% pickup_game_id=% user_id=% actor=%',
      p_team_id, p_pickup_game_id, p_user_id, me;
  END IF;
END;
$$;

COMMENT ON FUNCTION public.set_fan_team_event_member_excluded(uuid, uuid, uuid, boolean) IS
  'Owner/Manager/Head Coach/Assistant Coach sets aside (or restores) an active Team member '
  'for one FUTURE Team event only (game_start_at >= now()). Past events are immutable. '
  'Idempotent: no-op + no push when exclusion state is unchanged. Excluding drops the event '
  'lineup seat and withdraws/cancels that game''s RSVP; restoring does not re-add RSVP/lineup. '
  'Emits removed_from_event / added_back_to_event only on real transitions.';

REVOKE ALL ON FUNCTION public.set_fan_team_event_member_excluded(uuid, uuid, uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_fan_team_event_member_excluded(uuid, uuid, uuid, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_fan_team_event_member_excluded(uuid, uuid, uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_fan_team_event_member_excluded(uuid, uuid, uuid, boolean) TO service_role;

-- ---------------------------------------------------------------------------
-- 6) set_fan_team_member_player_number — wire member-change push
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_fan_team_member_player_number(
  p_team_id uuid,
  p_user_id uuid,
  p_player_number integer
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_old_number smallint;
  v_new_number smallint := p_player_number::smallint;
  v_kind text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  IF p_team_id IS NULL OR p_user_id IS NULL THEN
    RAISE EXCEPTION 'Team and user are required.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.fan_teams t
    WHERE t.id = p_team_id
      AND t.is_active = true
  ) THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  IF NOT public.fan_team_viewer_can_manage(p_team_id) THEN
    RAISE EXCEPTION 'Only the owner or a manager can set player numbers.';
  END IF;

  IF NOT public.is_active_fan_team_member(p_team_id, p_user_id) THEN
    RAISE EXCEPTION 'User is not an active team member.';
  END IF;

  IF p_player_number IS NOT NULL
     AND (p_player_number < 0 OR p_player_number > 99)
  THEN
    RAISE EXCEPTION 'Player number must be between 0 and 99.';
  END IF;

  IF p_player_number IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM public.fan_team_members o
       WHERE o.team_id = p_team_id
         AND o.left_at IS NULL
         AND o.user_id <> p_user_id
         AND o.player_number = p_player_number::smallint
     )
  THEN
    RAISE EXCEPTION 'That player number is already assigned on this Team.';
  END IF;

  SELECT m.player_number INTO v_old_number
  FROM public.fan_team_members m
  WHERE m.team_id = p_team_id
    AND m.user_id = p_user_id
    AND m.left_at IS NULL
  FOR UPDATE;

  UPDATE public.fan_team_members
  SET player_number = v_new_number
  WHERE team_id = p_team_id
    AND user_id = p_user_id
    AND left_at IS NULL;

  IF me <> p_user_id AND v_old_number IS DISTINCT FROM v_new_number THEN
    v_kind := CASE
      WHEN v_old_number IS NULL AND v_new_number IS NOT NULL THEN 'player_number_set'
      WHEN v_old_number IS NOT NULL AND v_new_number IS NULL THEN 'player_number_removed'
      ELSE 'player_number_changed'
    END;

    PERFORM public.emit_fan_team_member_change_notification(
      p_team_id,
      v_kind,
      me,
      p_user_id,
      jsonb_build_object('player_number', v_new_number)
    );
  END IF;
END;
$$;

COMMENT ON FUNCTION public.set_fan_team_member_player_number(uuid, uuid, integer) IS
  'Owner/manager assigns or clears (NULL) an active member Team-specific player number (0-99). '
  'Emits player_number_set/changed/removed member-change push when actor <> target and value changed.';

REVOKE ALL ON FUNCTION public.set_fan_team_member_player_number(uuid, uuid, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_fan_team_member_player_number(uuid, uuid, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_fan_team_member_player_number(uuid, uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_fan_team_member_player_number(uuid, uuid, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 7) set_fan_team_member_preferred_position — wire member-change push
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_fan_team_member_preferred_position(
  p_team_id uuid,
  p_user_id uuid,
  p_position_code text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_sport text;
  v_position text;
  v_old_position text;
  v_kind text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  IF p_team_id IS NULL OR p_user_id IS NULL THEN
    RAISE EXCEPTION 'Team and user are required.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.fan_teams t
    WHERE t.id = p_team_id
      AND t.is_active = true
  ) THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  IF NOT public.fan_team_viewer_can_manage_lineup(p_team_id) THEN
    RAISE EXCEPTION 'Only coaches and managers can set player positions.';
  END IF;

  IF NOT public.is_active_fan_team_member(p_team_id, p_user_id) THEN
    RAISE EXCEPTION 'User is not an active team member.';
  END IF;

  SELECT t.sport
  INTO v_sport
  FROM public.fan_teams t
  WHERE t.id = p_team_id
    AND t.is_active = true;

  v_position := public.fan_team_event_normalize_position_code(p_position_code);

  IF NOT public.fan_team_event_position_code_is_valid(v_sport, v_position) THEN
    RAISE EXCEPTION 'Invalid position for this sport.';
  END IF;

  SELECT m.preferred_position_code INTO v_old_position
  FROM public.fan_team_members m
  WHERE m.team_id = p_team_id
    AND m.user_id = p_user_id
    AND m.left_at IS NULL
  FOR UPDATE;

  UPDATE public.fan_team_members
  SET preferred_position_code = v_position
  WHERE team_id = p_team_id
    AND user_id = p_user_id
    AND left_at IS NULL;

  IF me <> p_user_id AND v_old_position IS DISTINCT FROM v_position THEN
    v_kind := CASE
      WHEN v_old_position IS NULL AND v_position IS NOT NULL THEN 'preferred_position_set'
      WHEN v_old_position IS NOT NULL AND v_position IS NULL THEN 'preferred_position_removed'
      ELSE 'preferred_position_changed'
    END;

    PERFORM public.emit_fan_team_member_change_notification(
      p_team_id,
      v_kind,
      me,
      p_user_id,
      jsonb_build_object('position_code', v_position)
    );
  END IF;
END;
$$;

COMMENT ON FUNCTION public.set_fan_team_member_preferred_position(uuid, uuid, text) IS
  'Owner/Manager/Head Coach/Assistant Coach assigns or clears (NULL) an active member preferred position. '
  'Emits preferred_position_set/changed/removed member-change push when actor <> target and value changed.';

REVOKE ALL ON FUNCTION public.set_fan_team_member_preferred_position(uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_fan_team_member_preferred_position(uuid, uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_fan_team_member_preferred_position(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_fan_team_member_preferred_position(uuid, uuid, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 8) set_fan_team_member_role — wire member-change push
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_fan_team_member_role(
  p_team_id uuid,
  p_user_id uuid,
  p_role text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_role text := lower(btrim(coalesce(p_role, '')));
  v_owner uuid;
  v_conversation_id uuid;
  v_group_role text;
  v_old_role text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF v_role NOT IN (
    'manager',
    'head_coach',
    'assistant_coach',
    'captain',
    'assistant_captain',
    'member'
  ) THEN
    RAISE EXCEPTION 'Invalid role.';
  END IF;

  SELECT t.owner_user_id, t.group_conversation_id
  INTO v_owner, v_conversation_id
  FROM public.fan_teams t
  WHERE t.id = p_team_id AND t.is_active = true;

  IF v_conversation_id IS NULL THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  IF NOT public.fan_team_viewer_can_manage(p_team_id) THEN
    RAISE EXCEPTION 'Only the owner or a manager can change roles.';
  END IF;

  IF p_user_id = v_owner THEN
    RAISE EXCEPTION 'Cannot change the owner role this way.';
  END IF;

  -- Explicit active-membership gate (restored from 20260950) BEFORE any updates.
  -- Prevents role writes against former/inactive/missing memberships, including
  -- accidental group_conversation_members role changes for non-active Team members.
  IF NOT public.is_active_fan_team_member(p_team_id, p_user_id) THEN
    RAISE EXCEPTION 'User is not an active team member.';
  END IF;

  SELECT m.role INTO v_old_role
  FROM public.fan_team_members m
  WHERE m.team_id = p_team_id
    AND m.user_id = p_user_id
    AND m.left_at IS NULL
  FOR UPDATE;

  IF v_old_role IS NULL THEN
    RAISE EXCEPTION 'User is not an active team member.';
  END IF;

  UPDATE public.fan_team_members
  SET role = v_role
  WHERE team_id = p_team_id
    AND user_id = p_user_id
    AND left_at IS NULL;

  -- Group-chat `admin` is a privileged chat role (invite/remove members, update
  -- conversation settings, moderate messages). Map ONLY Team Manager → chat admin.
  -- Head Coach / coaches / captains are Team leadership or organizers, not chat admins.
  -- Owner is never targeted by this RPC (see guard above); owner stays chat admin
  -- from create_fan_team insertion.
  v_group_role := CASE
    WHEN v_role = 'manager' THEN 'admin'
    ELSE 'member'
  END;

  UPDATE public.group_conversation_members
  SET role = v_group_role
  WHERE conversation_id = v_conversation_id
    AND user_id = p_user_id
    AND left_at IS NULL;

  IF me <> p_user_id AND v_old_role IS NOT NULL AND v_old_role IS DISTINCT FROM v_role THEN
    PERFORM public.emit_fan_team_member_change_notification(
      p_team_id,
      'team_role_changed',
      me,
      p_user_id,
      jsonb_build_object('role', v_role, 'previous_role', v_old_role)
    );
  END IF;
END;
$$;

COMMENT ON FUNCTION public.set_fan_team_member_role(uuid, uuid, text) IS
  'Owner/Manager assigns a non-owner role to an ACTIVE Team member only '
  '(is_active_fan_team_member required before updates). Emits team_role_changed '
  'member-change push when actor <> target and the role actually changed.';

REVOKE ALL ON FUNCTION public.set_fan_team_member_role(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_fan_team_member_role(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_fan_team_member_role(uuid, uuid, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 9) remove_fan_team_member — member-change push (NOT member_left pipeline)
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
  v_team_name text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'User is required.';
  END IF;

  SELECT t.group_conversation_id, coalesce(nullif(btrim(t.name), ''), 'Team')
  INTO v_conversation_id, v_team_name
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

  -- Staff-removal RPC only (same invariant as 20260957). Voluntary self-leave → leave_fan_team.
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

  -- Staff-initiated removal notifies via the member-change pipeline (removed_from_team),
  -- NOT the member_left Edge (that remains leadership-notify for voluntary leave_fan_team).
  -- Self-removal is rejected above, so actor is always distinct from target here.
  PERFORM public.emit_fan_team_member_change_notification(
    p_team_id,
    'removed_from_team',
    me,
    p_user_id,
    jsonb_build_object('team_name', v_team_name)
  );
END;
$$;

COMMENT ON FUNCTION public.remove_fan_team_member(uuid, uuid) IS
  'STAFF soft-remove of another member + Team Chat leave + future Team-event cleanup. '
  'Rejects self-removal (use leave_fan_team). Emits removed_from_team via member-change '
  'pipeline. Does not send member_left_team push (voluntary leave_fan_team path only).';

REVOKE ALL ON FUNCTION public.remove_fan_team_member(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.remove_fan_team_member(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_fan_team_member(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 10) get_pickup_game_roster — exclusion-aware + excluded bucket + roster flag
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
  v_excluded jsonb := '[]'::jsonb;
  v_include_team_responses boolean := false;
  v_can_manage_event_roster boolean := false;
  v_can_view_excluded boolean := false;
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

  v_can_manage_event_roster := (v_team_id IS NOT NULL)
    AND public.fan_team_viewer_can_manage_lineup(v_team_id);

  v_can_view_excluded := v_include_team_responses OR v_can_manage_event_roster;

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
    )
    AND (
      v_team_id IS NULL
      OR NOT public.is_fan_team_event_member_excluded(v_team_id, p_pickup_game_id, r.requester_user_id)
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
      )
      AND (
        v_team_id IS NULL
        OR NOT public.is_fan_team_event_member_excluded(v_team_id, p_pickup_game_id, r.requester_user_id)
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
      )
      AND NOT public.is_fan_team_event_member_excluded(v_team_id, p_pickup_game_id, r.requester_user_id);

    -- No Response = ACTIVE Team members with no request row (never former members,
    -- never event-excluded members — they live in the 'excluded' bucket instead).
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
      AND NOT public.is_fan_team_event_member_excluded(v_team_id, p_pickup_game_id, m.user_id)
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

  IF v_team_id IS NOT NULL AND v_can_view_excluded THEN
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'user_id', m.user_id,
          'request_id', NULL,
          'display_name', nullif(btrim(coalesce(up.display_name, '')), ''),
          'username', nullif(btrim(coalesce(up.username, '')), ''),
          'avatar_url', nullif(btrim(coalesce(up.avatar_url, '')), ''),
          'avatar_thumbnail_url', nullif(btrim(coalesce(up.avatar_thumbnail_url, up.avatar_url, '')), ''),
          'role', 'excluded',
          'status', 'excluded'
        )
        ORDER BY lower(coalesce(up.display_name, up.username, '')), m.user_id
      ),
      '[]'::jsonb
    )
    INTO v_excluded
    FROM public.fan_team_members m
    INNER JOIN public.fan_team_event_exclusions e
      ON e.team_id = m.team_id
     AND e.pickup_game_id = p_pickup_game_id
     AND e.user_id = m.user_id
    LEFT JOIN public.user_profiles up
      ON up.id = m.user_id
     AND coalesce(up.is_deleted, false) = false
    WHERE m.team_id = v_team_id
      AND m.left_at IS NULL;
  END IF;

  RETURN jsonb_build_object(
    'pickup_game_id', p_pickup_game_id,
    'viewer_is_organizer', v_is_organizer,
    'organizer', v_organizer,
    'playing', v_playing,
    'pending', v_pending,
    'declined', v_declined,
    'no_response', v_no_response,
    'excluded', v_excluded,
    'viewer_can_manage_event_roster', v_can_manage_event_roster,
    'approved_join_count', jsonb_array_length(v_playing),
    'playing_total_count', 1 + jsonb_array_length(v_playing)
  );
END;
$$;

COMMENT ON FUNCTION public.get_pickup_game_roster(uuid) IS
  'Privacy-safe pickup roster. Team-linked FUTURE events exclude former Team members '
  'from playing/pending/declined; no_response is active members only. Per-event '
  'fan_team_event_exclusions members are removed from all response buckets and surfaced '
  'in ''excluded'' (visible to team responders/organizer or lineup managers). '
  'viewer_can_manage_event_roster mirrors fan_team_viewer_can_manage_lineup for team-linked events.';

-- ---------------------------------------------------------------------------
-- 11) list_pickup_game_change_push_tokens — drop event-excluded recipients
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
      AND (
        NOT tl.is_linked
        OR NOT EXISTS (
          SELECT 1
          FROM public.fan_team_event_exclusions ex
          WHERE ex.team_id = l.team_id
            AND ex.pickup_game_id = p_pickup_game_id
            AND ex.user_id = r.requester_user_id
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
      AND NOT EXISTS (
        SELECT 1
        FROM public.fan_team_event_exclusions ex
        WHERE ex.team_id = l.team_id
          AND ex.pickup_game_id = p_pickup_game_id
          AND ex.user_id = r.requester_user_id
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
      AND NOT EXISTS (
        SELECT 1
        FROM public.fan_team_event_exclusions ex
        WHERE ex.team_id = m.team_id
          AND ex.pickup_game_id = p_pickup_game_id
          AND ex.user_id = m.user_id
      )
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
  'Former Team members with stale pre-leave RSVP rows are excluded for future events. '
  'Per-event fan_team_event_exclusions rows are excluded from every recipient bucket.';

COMMIT;

-- =============================================================================
-- MANUAL APPLY NOTES
-- =============================================================================
-- 1) Apply after 20260957 in Supabase SQL editor (paste + run whole file).
-- 2) Deploy Edge:
--      supabase functions deploy notify-fan-team-member-change --no-verify-jwt
-- 3) Optional vault secret: FAN_TEAM_MEMBER_CHANGE_PUSH_CRON_SECRET
--    (falls back to Bearer SERVICE_ROLE_KEY only if unset, same as other workers).
-- 4) No other Edge redeploys required for this change — notify-fan-team-member-left
--    and notify-pickup-game-change are unmodified by this migration.
-- 5) Post-apply smoke check: run
--      supabase/tests/fan_team_player_info_event_exclusion_and_member_change_push_checks.sql
--    against staging only (does not mutate data).
-- =============================================================================
