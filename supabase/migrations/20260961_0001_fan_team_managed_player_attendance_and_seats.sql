-- =============================================================================
-- 20260961_0001 — Managed-player attendance, roster seats, lineups & exclusions
-- =============================================================================
-- 20260960 introduced the dual-identity roster (fan_team_members.membership_id +
-- managed_player_id) and managed RSVP storage (fan_team_event_rsvps), but every
-- READER and every player-attribute WRITER still keyed on user_id. A managed
-- player therefore existed on the roster and could RSVP, yet was invisible in:
--   * jersey number / preferred position editing (both keyed on user_id),
--   * pickup roster buckets (Going / Maybe / Can't Go / No Response / Excluded),
--   * event lineups (fan_team_event_lineup_members insert was user_id only),
--   * per-event exclusion (fan_team_event_exclusions writer was user_id only),
--   * roster READ ACCESS for a guardian who is not themselves on the Team.
--
-- This migration closes those gaps. It is strictly additive for authenticated
-- members: with zero managed players every function in here returns exactly what
-- it returned before (the account code paths are byte-for-byte the same queries
-- plus new NULL-valued jsonb keys).
--
-- WHY membership_id is the write key
--   A managed player has no auth.users row, so (team_id, user_id) cannot address
--   its seat. Every new writer takes p_membership_id and resolves the seat, which
--   also works unchanged for account seats — one code path, both identities.
--
-- NOTIFICATIONS
--   emit_fan_team_member_change_notification requires an auth.users target and is
--   consumed by an ALREADY DEPLOYED Edge Function
--   (notify-fan-team-member-change reads target_user_id and pushes to
--   recipient_user_ids). Rather than break that contract, this migration adds
--   emit_fan_team_member_change_notification_for_membership:
--     * account seat  -> delegates to the existing emit (identical behaviour),
--     * managed seat  -> recipient_user_ids = every ACTIVE guardian minus the
--       actor, target_user_id = the primary guardian (a real account, so the
--       deployed Edge stays valid), plus new target_membership_id /
--       target_managed_player_id columns and payload keys
--       (is_managed_player / managed_player_id / managed_player_name) so the
--       Edge copy can be reworded in a follow-up deploy without another
--       migration. Until that deploy, guardians receive the existing member
--       wording for their player's change. No push is lost.
--
-- Depends on: 20260947, 20260948, 20260952 (lineups), 20260953, 20260957,
--             20260958 (exclusions + member-change pipeline), 20260960 (seats).
--
-- Do NOT apply from the agent. Apply manually in Supabase after 20260960.
-- No Edge Function is deployed by this migration.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0) Dependency guard — 20260960 must be applied first
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('public.fan_managed_players') IS NULL
     OR to_regclass('public.fan_team_event_rsvps') IS NULL
     OR NOT EXISTS (
       SELECT 1
       FROM information_schema.columns
       WHERE table_schema = 'public'
         AND table_name = 'fan_team_members'
         AND column_name = 'membership_id'
     )
  THEN
    RAISE EXCEPTION
      'assert_failed: apply 20260960_0001_fan_team_managed_players.sql before this migration';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 1) Member-change notifications for a roster SEAT (account or managed)
-- ---------------------------------------------------------------------------

ALTER TABLE public.fan_team_member_change_events
  ADD COLUMN IF NOT EXISTS target_membership_id uuid
    REFERENCES public.fan_team_members (membership_id) ON DELETE SET NULL;

ALTER TABLE public.fan_team_member_change_events
  ADD COLUMN IF NOT EXISTS target_managed_player_id uuid
    REFERENCES public.fan_managed_players (id) ON DELETE SET NULL;

COMMENT ON COLUMN public.fan_team_member_change_events.target_membership_id IS
  'Roster seat the change is about. Always set by '
  'emit_fan_team_member_change_notification_for_membership; NULL for legacy rows.';

COMMENT ON COLUMN public.fan_team_member_change_events.target_managed_player_id IS
  'Set when the subject of the change is a guardian-managed player. In that case '
  'target_user_id is the PRIMARY GUARDIAN (the deployed Edge requires a real '
  'auth.users target) and recipient_user_ids holds every active guardian.';

CREATE INDEX IF NOT EXISTS fan_team_member_change_events_target_seat_idx
  ON public.fan_team_member_change_events (target_membership_id, created_at DESC)
  WHERE target_membership_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.emit_fan_team_member_change_notification_for_membership(
  p_team_id uuid,
  p_kind text,
  p_actor_user_id uuid,
  p_membership_id uuid,
  p_payload jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_member public.fan_team_members%ROWTYPE;
  v_team_name text;
  v_event_id uuid;
  v_recipients uuid[];
  v_primary_target uuid;
  v_player_name text;
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb);
BEGIN
  IF p_team_id IS NULL OR p_membership_id IS NULL THEN
    RAISE NOTICE
      '[FanTeamMemberChangeDebug] emit_seat_skip reason=missing_team_or_seat team_id=% kind=%',
      p_team_id, p_kind;
    RETURN NULL;
  END IF;

  SELECT * INTO v_member
  FROM public.fan_team_members m
  WHERE m.membership_id = p_membership_id
    AND m.team_id = p_team_id
    AND m.left_at IS NULL;

  IF NOT FOUND THEN
    RAISE NOTICE
      '[FanTeamMemberChangeDebug] emit_seat_skip reason=seat_not_active team_id=% seat=% kind=%',
      p_team_id, p_membership_id, p_kind;
    RETURN NULL;
  END IF;

  -- Account seat: unchanged legacy pipeline (self-edit suppression lives there).
  IF v_member.user_id IS NOT NULL THEN
    RETURN public.emit_fan_team_member_change_notification(
      p_team_id, p_kind, p_actor_user_id, v_member.user_id, v_payload
    );
  END IF;

  -- Managed seat: fan out to the player's active guardians, never to the actor.
  SELECT coalesce(array_agg(DISTINCT g.guardian_user_id), ARRAY[]::uuid[])
  INTO v_recipients
  FROM public.fan_managed_player_guardians g
  WHERE g.managed_player_id = v_member.managed_player_id
    AND g.revoked_at IS NULL
    AND g.guardian_user_id IS DISTINCT FROM p_actor_user_id;

  IF coalesce(cardinality(v_recipients), 0) = 0 THEN
    RAISE NOTICE
      '[FanTeamMemberChangeDebug] emit_seat_skip reason=no_guardian_recipients team_id=% seat=% kind=%',
      p_team_id, p_membership_id, p_kind;
    RETURN NULL;
  END IF;

  -- Deployed Edge requires a non-null auth.users target: use the primary guardian.
  SELECT g.guardian_user_id
  INTO v_primary_target
  FROM public.fan_managed_player_guardians g
  WHERE g.managed_player_id = v_member.managed_player_id
    AND g.revoked_at IS NULL
    AND g.guardian_user_id = ANY (v_recipients)
  ORDER BY (g.role = 'primary_guardian') DESC, g.created_at ASC
  LIMIT 1;

  IF v_primary_target IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT coalesce(nullif(btrim(t.name), ''), 'Team') INTO v_team_name
  FROM public.fan_teams t WHERE t.id = p_team_id;

  SELECT coalesce(nullif(btrim(mp.display_name), ''), 'Player') INTO v_player_name
  FROM public.fan_managed_players mp WHERE mp.id = v_member.managed_player_id;

  v_payload := v_payload || jsonb_build_object(
    'is_managed_player', true,
    'managed_player_id', v_member.managed_player_id,
    'managed_player_name', coalesce(v_player_name, 'Player'),
    'membership_id', p_membership_id
  );

  v_event_id := gen_random_uuid();

  INSERT INTO public.fan_team_member_change_events (
    id, team_id, kind, actor_user_id, target_user_id, team_name, payload,
    recipient_user_ids, target_membership_id, target_managed_player_id
  ) VALUES (
    v_event_id, p_team_id, p_kind, p_actor_user_id, v_primary_target,
    coalesce(v_team_name, 'Team'), v_payload,
    v_recipients, p_membership_id, v_member.managed_player_id
  );

  RAISE NOTICE
    '[FanTeamMemberChangeDebug] emit_seat_ok event=% team_id=% kind=% actor=% seat=% managed=% recipient_count=%',
    v_event_id, p_team_id, p_kind, p_actor_user_id, p_membership_id,
    v_member.managed_player_id, cardinality(v_recipients);

  PERFORM public.queue_fan_team_member_change_push_notification(v_event_id);

  RETURN v_event_id;
END;
$$;

COMMENT ON FUNCTION public.emit_fan_team_member_change_notification_for_membership(uuid, text, uuid, uuid, jsonb) IS
  'Seat-scoped member-change emit. Account seats delegate to '
  'emit_fan_team_member_change_notification unchanged. Managed seats notify every active '
  'guardian except the actor; target_user_id is the primary guardian so the deployed Edge '
  'contract holds, and payload carries is_managed_player / managed_player_id / '
  'managed_player_name for the follow-up Edge rewording deploy.';

REVOKE ALL ON FUNCTION
  public.emit_fan_team_member_change_notification_for_membership(uuid, text, uuid, uuid, jsonb)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION
  public.emit_fan_team_member_change_notification_for_membership(uuid, text, uuid, uuid, jsonb)
  FROM anon;
REVOKE ALL ON FUNCTION
  public.emit_fan_team_member_change_notification_for_membership(uuid, text, uuid, uuid, jsonb)
  FROM authenticated;
GRANT EXECUTE ON FUNCTION
  public.emit_fan_team_member_change_notification_for_membership(uuid, text, uuid, uuid, jsonb)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 2) A) set_fan_team_member_player_number_for_membership
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_fan_team_member_player_number_for_membership(
  p_team_id uuid,
  p_membership_id uuid,
  p_player_number integer
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_member public.fan_team_members%ROWTYPE;
  v_old_number smallint;
  v_new_number smallint := p_player_number::smallint;
  v_kind text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_team_id IS NULL OR p_membership_id IS NULL THEN
    RAISE EXCEPTION 'Team and roster seat are required.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.fan_teams t
    WHERE t.id = p_team_id AND t.is_active = true
  ) THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  -- Same authorization as set_fan_team_member_player_number: owner / manager.
  IF NOT public.fan_team_viewer_can_manage(p_team_id) THEN
    RAISE EXCEPTION 'Only the owner or a manager can set player numbers.';
  END IF;

  IF p_player_number IS NOT NULL
     AND (p_player_number < 0 OR p_player_number > 99)
  THEN
    RAISE EXCEPTION 'Player number must be between 0 and 99.';
  END IF;

  SELECT * INTO v_member
  FROM public.fan_team_members m
  WHERE m.membership_id = p_membership_id
    AND m.team_id = p_team_id
    AND m.left_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'User is not an active team member.';
  END IF;

  -- Uniqueness is per SEAT, so a managed player's jersey now genuinely blocks an
  -- adult's (the old user_id <> p_user_id predicate evaluated to NULL for managed
  -- rows and silently skipped them).
  IF p_player_number IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM public.fan_team_members o
       WHERE o.team_id = p_team_id
         AND o.left_at IS NULL
         AND o.membership_id <> p_membership_id
         AND o.player_number = v_new_number
     )
  THEN
    RAISE EXCEPTION 'That player number is already assigned on this Team.';
  END IF;

  v_old_number := v_member.player_number;

  UPDATE public.fan_team_members
  SET player_number = v_new_number
  WHERE membership_id = p_membership_id;

  IF v_old_number IS DISTINCT FROM v_new_number THEN
    v_kind := CASE
      WHEN v_old_number IS NULL AND v_new_number IS NOT NULL THEN 'player_number_set'
      WHEN v_old_number IS NOT NULL AND v_new_number IS NULL THEN 'player_number_removed'
      ELSE 'player_number_changed'
    END;

    -- Self-edit suppression for account seats lives in the emit helper.
    PERFORM public.emit_fan_team_member_change_notification_for_membership(
      p_team_id,
      v_kind,
      me,
      p_membership_id,
      jsonb_build_object('player_number', v_new_number)
    );
  END IF;
END;
$$;

COMMENT ON FUNCTION public.set_fan_team_member_player_number_for_membership(uuid, uuid, integer) IS
  'Owner/manager assigns or clears (NULL) the jersey number of ANY active roster seat '
  '(account or guardian-managed), keyed by membership_id. Number uniqueness is enforced '
  'across all active seats. Notifies the seat (member, or the player''s guardians).';

-- Legacy user-scoped RPC is now a thin resolver so both entry points share one
-- implementation (and one uniqueness rule). Signature, authorization, error
-- messages and emitted notification kinds are unchanged for callers.
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
  v_membership_id uuid;
BEGIN
  IF p_team_id IS NULL OR p_user_id IS NULL THEN
    RAISE EXCEPTION 'Team and user are required.';
  END IF;

  SELECT m.membership_id INTO v_membership_id
  FROM public.fan_team_members m
  WHERE m.team_id = p_team_id
    AND m.user_id = p_user_id
    AND m.left_at IS NULL;

  IF v_membership_id IS NULL THEN
    -- Preserve the pre-20260961 ordering of failures: team, then permission,
    -- then membership, so existing client error copy still matches.
    IF NOT EXISTS (
      SELECT 1 FROM public.fan_teams t
      WHERE t.id = p_team_id AND t.is_active = true
    ) THEN
      RAISE EXCEPTION 'Team not found.';
    END IF;
    IF NOT public.fan_team_viewer_can_manage(p_team_id) THEN
      RAISE EXCEPTION 'Only the owner or a manager can set player numbers.';
    END IF;
    RAISE EXCEPTION 'User is not an active team member.';
  END IF;

  PERFORM public.set_fan_team_member_player_number_for_membership(
    p_team_id, v_membership_id, p_player_number
  );
END;
$$;

COMMENT ON FUNCTION public.set_fan_team_member_player_number(uuid, uuid, integer) IS
  'Account-seat entry point: resolves membership_id and delegates to '
  'set_fan_team_member_player_number_for_membership. Kept for existing iOS callers.';

-- ---------------------------------------------------------------------------
-- 3) B) set_fan_team_member_preferred_position_for_membership
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_fan_team_member_preferred_position_for_membership(
  p_team_id uuid,
  p_membership_id uuid,
  p_position_code text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_member public.fan_team_members%ROWTYPE;
  v_sport text;
  v_position text;
  v_old_position text;
  v_kind text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_team_id IS NULL OR p_membership_id IS NULL THEN
    RAISE EXCEPTION 'Team and roster seat are required.';
  END IF;

  SELECT t.sport INTO v_sport
  FROM public.fan_teams t
  WHERE t.id = p_team_id AND t.is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  -- Same authorization as set_fan_team_member_preferred_position: lineup managers.
  IF NOT public.fan_team_viewer_can_manage_lineup(p_team_id) THEN
    RAISE EXCEPTION 'Only coaches and managers can set player positions.';
  END IF;

  SELECT * INTO v_member
  FROM public.fan_team_members m
  WHERE m.membership_id = p_membership_id
    AND m.team_id = p_team_id
    AND m.left_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'User is not an active team member.';
  END IF;

  v_position := public.fan_team_event_normalize_position_code(p_position_code);

  IF NOT public.fan_team_event_position_code_is_valid(v_sport, v_position) THEN
    RAISE EXCEPTION 'Invalid position for this sport.';
  END IF;

  v_old_position := v_member.preferred_position_code;

  UPDATE public.fan_team_members
  SET preferred_position_code = v_position
  WHERE membership_id = p_membership_id;

  IF v_old_position IS DISTINCT FROM v_position THEN
    v_kind := CASE
      WHEN v_old_position IS NULL AND v_position IS NOT NULL THEN 'preferred_position_set'
      WHEN v_old_position IS NOT NULL AND v_position IS NULL THEN 'preferred_position_removed'
      ELSE 'preferred_position_changed'
    END;

    PERFORM public.emit_fan_team_member_change_notification_for_membership(
      p_team_id,
      v_kind,
      me,
      p_membership_id,
      jsonb_build_object('position_code', v_position)
    );
  END IF;
END;
$$;

COMMENT ON FUNCTION public.set_fan_team_member_preferred_position_for_membership(uuid, uuid, text) IS
  'Owner/Manager/Head Coach/Assistant Coach sets or clears (NULL) the preferred position of '
  'ANY active roster seat (account or guardian-managed), keyed by membership_id.';

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
  v_membership_id uuid;
BEGIN
  IF p_team_id IS NULL OR p_user_id IS NULL THEN
    RAISE EXCEPTION 'Team and user are required.';
  END IF;

  SELECT m.membership_id INTO v_membership_id
  FROM public.fan_team_members m
  WHERE m.team_id = p_team_id
    AND m.user_id = p_user_id
    AND m.left_at IS NULL;

  IF v_membership_id IS NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.fan_teams t
      WHERE t.id = p_team_id AND t.is_active = true
    ) THEN
      RAISE EXCEPTION 'Team not found.';
    END IF;
    IF NOT public.fan_team_viewer_can_manage_lineup(p_team_id) THEN
      RAISE EXCEPTION 'Only coaches and managers can set player positions.';
    END IF;
    RAISE EXCEPTION 'User is not an active team member.';
  END IF;

  PERFORM public.set_fan_team_member_preferred_position_for_membership(
    p_team_id, v_membership_id, p_position_code
  );
END;
$$;

COMMENT ON FUNCTION public.set_fan_team_member_preferred_position(uuid, uuid, text) IS
  'Account-seat entry point: resolves membership_id and delegates to '
  'set_fan_team_member_preferred_position_for_membership. Kept for existing iOS callers.';

-- ---------------------------------------------------------------------------
-- 4) C) is_pickup_game_fan_team_participant — guardians count as participants
-- ---------------------------------------------------------------------------
-- Gates roster READ access in get_pickup_game_roster. Without this a parent who
-- is not on the Team themselves cannot see their own child's event roster.
-- Mirrors fan_team_viewer_can_access_team, but for an explicit p_user_id instead
-- of auth.uid() (this helper is also called with other users' ids).
CREATE OR REPLACE FUNCTION public.is_pickup_game_fan_team_participant(
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
    FROM public.fan_team_game_links l
    JOIN public.fan_team_members m
      ON m.team_id = l.team_id
     AND m.left_at IS NULL
    WHERE l.pickup_game_id = p_pickup_game_id
      AND p_user_id IS NOT NULL
      AND (
        m.user_id = p_user_id
        OR (
          m.managed_player_id IS NOT NULL
          AND EXISTS (
            SELECT 1
            FROM public.fan_managed_player_guardians g
            WHERE g.managed_player_id = m.managed_player_id
              AND g.guardian_user_id = p_user_id
              AND g.revoked_at IS NULL
          )
        )
      )
  );
$$;

COMMENT ON FUNCTION public.is_pickup_game_fan_team_participant(uuid, uuid) IS
  'True when the user holds an active seat on a Team linked to this event, OR is an active '
  'guardian of a managed player holding one. Guardian participation is read-only reach: '
  'organizer/lineup permissions still come from fan_team_viewer_can_manage* (account roles).';

-- ---------------------------------------------------------------------------
-- 5) D) Exclusion helpers for managed seats
-- ---------------------------------------------------------------------------
-- is_fan_team_event_member_excluded keeps its exact user_id contract (many
-- callers pass a bare user id); managed seats get sibling helpers.
CREATE OR REPLACE FUNCTION public.is_fan_team_event_managed_player_excluded(
  p_team_id uuid,
  p_pickup_game_id uuid,
  p_managed_player_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p_managed_player_id IS NOT NULL AND EXISTS (
    SELECT 1
    FROM public.fan_team_event_exclusions e
    WHERE e.team_id = p_team_id
      AND e.pickup_game_id = p_pickup_game_id
      AND e.managed_player_id = p_managed_player_id
  );
$$;

CREATE OR REPLACE FUNCTION public.is_fan_team_event_membership_excluded(
  p_team_id uuid,
  p_pickup_game_id uuid,
  p_membership_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.fan_team_members m
    JOIN public.fan_team_event_exclusions e
      ON e.team_id = m.team_id
     AND e.pickup_game_id = p_pickup_game_id
     AND (
       (m.user_id IS NOT NULL AND e.user_id = m.user_id)
       OR (m.managed_player_id IS NOT NULL AND e.managed_player_id = m.managed_player_id)
     )
    WHERE m.membership_id = p_membership_id
      AND m.team_id = p_team_id
  );
$$;

COMMENT ON FUNCTION public.is_fan_team_event_managed_player_excluded(uuid, uuid, uuid) IS
  'INTERNAL helper: managed player set aside from one event. Mirrors '
  'is_fan_team_event_member_excluded for the managed identity.';

COMMENT ON FUNCTION public.is_fan_team_event_membership_excluded(uuid, uuid, uuid) IS
  'INTERNAL helper: seat-scoped exclusion check that resolves either participant identity.';

REVOKE ALL ON FUNCTION
  public.is_fan_team_event_managed_player_excluded(uuid, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION
  public.is_fan_team_event_managed_player_excluded(uuid, uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION
  public.is_fan_team_event_managed_player_excluded(uuid, uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION
  public.is_fan_team_event_managed_player_excluded(uuid, uuid, uuid) TO service_role;

REVOKE ALL ON FUNCTION
  public.is_fan_team_event_membership_excluded(uuid, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION
  public.is_fan_team_event_membership_excluded(uuid, uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION
  public.is_fan_team_event_membership_excluded(uuid, uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION
  public.is_fan_team_event_membership_excluded(uuid, uuid, uuid) TO service_role;

-- Seat-scoped exclusion writer. Account seats delegate to the existing RPC so
-- its RSVP-withdrawal / lineup-drop / idempotency semantics stay identical.
CREATE OR REPLACE FUNCTION public.set_fan_team_event_membership_excluded(
  p_team_id uuid,
  p_pickup_game_id uuid,
  p_membership_id uuid,
  p_excluded boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_member public.fan_team_members%ROWTYPE;
  v_game_format text;
  v_game_start_at timestamptz;
  v_event_title text;
  v_change_payload jsonb;
  v_already_excluded boolean;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_team_id IS NULL OR p_pickup_game_id IS NULL OR p_membership_id IS NULL THEN
    RAISE EXCEPTION 'Team, event, and roster seat are required.';
  END IF;

  SELECT * INTO v_member
  FROM public.fan_team_members m
  WHERE m.membership_id = p_membership_id
    AND m.team_id = p_team_id
    AND m.left_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'User is not an active team member.';
  END IF;

  IF v_member.user_id IS NOT NULL THEN
    PERFORM public.set_fan_team_event_member_excluded(
      p_team_id, p_pickup_game_id, v_member.user_id, p_excluded
    );
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.fan_teams t
    WHERE t.id = p_team_id AND t.is_active = true
  ) THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.fan_team_game_links l
    WHERE l.pickup_game_id = p_pickup_game_id
      AND l.team_id = p_team_id
  ) THEN
    RAISE EXCEPTION 'Event is not linked to this Team.';
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

  IF v_game_start_at IS NULL OR v_game_start_at < now() THEN
    RAISE EXCEPTION 'Cannot change exclusion for a past event.';
  END IF;

  v_already_excluded := public.is_fan_team_event_managed_player_excluded(
    p_team_id, p_pickup_game_id, v_member.managed_player_id
  );

  v_change_payload := jsonb_build_object(
    'game_format', v_game_format,
    'game_start_at', v_game_start_at,
    'event_title', v_event_title,
    'pickup_game_id', p_pickup_game_id
  );

  IF coalesce(p_excluded, false) THEN
    IF v_already_excluded THEN
      RETURN;
    END IF;

    INSERT INTO public.fan_team_event_exclusions (
      team_id, pickup_game_id, user_id, managed_player_id, excluded_by
    ) VALUES (
      p_team_id, p_pickup_game_id, NULL, v_member.managed_player_id, me
    );

    DELETE FROM public.fan_team_event_lineup_members lm
    USING public.fan_team_event_lineups l
    WHERE lm.lineup_id = l.id
      AND l.team_id = p_team_id
      AND l.pickup_game_id = p_pickup_game_id
      AND lm.managed_player_id = v_member.managed_player_id;

    -- Managed attendance has no request row to withdraw: dropping the RSVP is
    -- the equivalent end state (the seat lands back in No Response).
    DELETE FROM public.fan_team_event_rsvps r
    WHERE r.team_id = p_team_id
      AND r.pickup_game_id = p_pickup_game_id
      AND r.membership_id = p_membership_id;

    PERFORM public.emit_fan_team_member_change_notification_for_membership(
      p_team_id, 'removed_from_event', me, p_membership_id, v_change_payload
    );
  ELSE
    IF NOT v_already_excluded THEN
      RETURN;
    END IF;

    DELETE FROM public.fan_team_event_exclusions
    WHERE team_id = p_team_id
      AND pickup_game_id = p_pickup_game_id
      AND managed_player_id = v_member.managed_player_id;

    PERFORM public.emit_fan_team_member_change_notification_for_membership(
      p_team_id, 'added_back_to_event', me, p_membership_id, v_change_payload
    );
  END IF;
END;
$$;

COMMENT ON FUNCTION public.set_fan_team_event_membership_excluded(uuid, uuid, uuid, boolean) IS
  'Seat-scoped per-event exclusion. Account seats delegate to '
  'set_fan_team_event_member_excluded (unchanged). Managed seats write a '
  'managed_player_id exclusion, drop the event lineup seat and the event RSVP, and notify '
  'the player''s guardians. Future events only; idempotent.';

REVOKE ALL ON FUNCTION
  public.set_fan_team_event_membership_excluded(uuid, uuid, uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION
  public.set_fan_team_event_membership_excluded(uuid, uuid, uuid, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION
  public.set_fan_team_event_membership_excluded(uuid, uuid, uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION
  public.set_fan_team_event_membership_excluded(uuid, uuid, uuid, boolean) TO service_role;

-- ---------------------------------------------------------------------------
-- 6) E) get_pickup_game_roster — managed seats in every Team bucket
-- ---------------------------------------------------------------------------
-- Changes vs 20260958:
--   * Managed seats appear in playing / pending / declined / no_response /
--     excluded, sourced from fan_team_event_rsvps (going / maybe / cant_go) and
--     from the absence of an rsvp row (no_response).
--   * A managed row's jsonb `user_id` is its managed_player_id. That key is the
--     SwiftUI ForEach identity and the attendance-map key on iOS; managed and
--     account ids never collide, and the client already treats this field as an
--     opaque participant key. New keys membership_id / is_managed_player /
--     managed_player_id let the client be explicit where it matters.
--   * The no_response query no longer assumes user_profiles joins on m.user_id
--     (NULL for managed seats), which previously produced nameless rows.
--   * PRIVACY: managed players are children and are NOT social identities, so
--     they are only added to `playing` for viewers who may already see Team
--     responses (organizer or Team participant/guardian). Strangers on an
--     outside-recruiting event see exactly what they saw before.
--   * CAPACITY: approved_join_count / playing_total_count stay derived from
--     account requests only, so Spots math is unchanged and identical for every
--     viewer. Managed attendance is a Team-roster concern, not pickup capacity.
--   * Authenticated-member behaviour is otherwise unchanged.
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
  v_managed_playing jsonb := '[]'::jsonb;
  v_managed_pending jsonb := '[]'::jsonb;
  v_managed_declined jsonb := '[]'::jsonb;
  v_managed_no_response jsonb := '[]'::jsonb;
  v_managed_excluded jsonb := '[]'::jsonb;
  v_account_playing_count integer := 0;
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
        'status', 'approved',
        'membership_id', fm.membership_id,
        'is_managed_player', false,
        'managed_player_id', NULL
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
  LEFT JOIN public.fan_team_members fm
    ON fm.team_id = v_team_id
   AND fm.user_id = r.requester_user_id
   AND fm.left_at IS NULL
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

  -- Public capacity math is account-only and viewer-independent (see header).
  v_account_playing_count := jsonb_array_length(v_playing);

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
          'status', 'pending',
          'membership_id', fm.membership_id,
          'is_managed_player', false,
          'managed_player_id', NULL
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
    LEFT JOIN public.fan_team_members fm
      ON fm.team_id = v_team_id
     AND fm.user_id = r.requester_user_id
     AND fm.left_at IS NULL
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
          'status', lower(btrim(r.status)),
          'membership_id', fm.membership_id,
          'is_managed_player', false,
          'managed_player_id', NULL
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
    LEFT JOIN public.fan_team_members fm
      ON fm.team_id = v_team_id
     AND fm.user_id = r.requester_user_id
     AND fm.left_at IS NULL
    WHERE r.pickup_game_id = p_pickup_game_id
      AND lower(btrim(r.status)) IN ('withdrawn', 'rejected', 'cancelled')
      AND r.requester_user_id IS DISTINCT FROM v_creator
      AND public.is_fan_team_linked_request_actor_eligible(
        v_team_id, r.requester_user_id, r.created_at, v_game_is_future
      )
      AND NOT public.is_fan_team_event_member_excluded(v_team_id, p_pickup_game_id, r.requester_user_id);

    -- No Response = ACTIVE ACCOUNT members with no request row (never former
    -- members, never event-excluded members — they live in 'excluded' instead).
    -- Managed seats are handled by their own query below because they have no
    -- pickup_game_requests row and no user_profiles row.
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
          'status', 'no_response',
          'membership_id', m.membership_id,
          'is_managed_player', false,
          'managed_player_id', NULL
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
      AND m.user_id IS NOT NULL
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

  -- Managed seats: attendance comes from fan_team_event_rsvps.
  IF v_team_id IS NOT NULL AND v_include_team_responses THEN
    SELECT
      coalesce(
        jsonb_agg(seat.seat_row ORDER BY seat.sort_name, seat.membership_id)
          FILTER (WHERE seat.bucket = 'playing'),
        '[]'::jsonb
      ),
      coalesce(
        jsonb_agg(seat.seat_row ORDER BY seat.sort_name, seat.membership_id)
          FILTER (WHERE seat.bucket = 'pending'),
        '[]'::jsonb
      ),
      coalesce(
        jsonb_agg(seat.seat_row ORDER BY seat.sort_name, seat.membership_id)
          FILTER (WHERE seat.bucket = 'declined'),
        '[]'::jsonb
      ),
      coalesce(
        jsonb_agg(seat.seat_row ORDER BY seat.sort_name, seat.membership_id)
          FILTER (WHERE seat.bucket = 'no_response'),
        '[]'::jsonb
      )
    INTO v_managed_playing, v_managed_pending, v_managed_declined, v_managed_no_response
    FROM (
      SELECT
        m.membership_id,
        lower(coalesce(btrim(mp.display_name), '')) AS sort_name,
        CASE lower(btrim(coalesce(r.status, '')))
          WHEN 'going' THEN 'playing'
          WHEN 'maybe' THEN 'pending'
          WHEN 'cant_go' THEN 'declined'
          ELSE 'no_response'
        END AS bucket,
        jsonb_build_object(
          'user_id', m.managed_player_id,
          'request_id', NULL,
          'display_name', nullif(btrim(coalesce(mp.display_name, '')), ''),
          'username', NULL,
          'avatar_url', nullif(btrim(coalesce(mp.avatar_url, '')), ''),
          'avatar_thumbnail_url',
            nullif(btrim(coalesce(mp.avatar_thumbnail_url, mp.avatar_url, '')), ''),
          'role', CASE lower(btrim(coalesce(r.status, '')))
            WHEN 'going' THEN 'playing'
            WHEN 'maybe' THEN 'pending'
            WHEN 'cant_go' THEN 'declined'
            ELSE 'no_response'
          END,
          'status', CASE lower(btrim(coalesce(r.status, '')))
            WHEN 'going' THEN 'approved'
            WHEN 'maybe' THEN 'pending'
            WHEN 'cant_go' THEN 'cant_go'
            ELSE 'no_response'
          END,
          'membership_id', m.membership_id,
          'is_managed_player', true,
          'managed_player_id', m.managed_player_id
        ) AS seat_row
      FROM public.fan_team_members m
      JOIN public.fan_managed_players mp ON mp.id = m.managed_player_id
      LEFT JOIN public.fan_team_event_rsvps r
        ON r.membership_id = m.membership_id
       AND r.pickup_game_id = p_pickup_game_id
       AND r.team_id = m.team_id
      WHERE m.team_id = v_team_id
        AND m.left_at IS NULL
        AND m.managed_player_id IS NOT NULL
        AND NOT public.is_fan_team_event_managed_player_excluded(
          v_team_id, p_pickup_game_id, m.managed_player_id
        )
    ) seat;

    v_playing := v_playing || v_managed_playing;
    v_pending := v_pending || v_managed_pending;
    v_declined := v_declined || v_managed_declined;
    v_no_response := v_no_response || v_managed_no_response;
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
          'status', 'excluded',
          'membership_id', m.membership_id,
          'is_managed_player', false,
          'managed_player_id', NULL
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
      AND m.left_at IS NULL
      AND m.user_id IS NOT NULL;

    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'user_id', m.managed_player_id,
          'request_id', NULL,
          'display_name', nullif(btrim(coalesce(mp.display_name, '')), ''),
          'username', NULL,
          'avatar_url', nullif(btrim(coalesce(mp.avatar_url, '')), ''),
          'avatar_thumbnail_url',
            nullif(btrim(coalesce(mp.avatar_thumbnail_url, mp.avatar_url, '')), ''),
          'role', 'excluded',
          'status', 'excluded',
          'membership_id', m.membership_id,
          'is_managed_player', true,
          'managed_player_id', m.managed_player_id
        )
        ORDER BY lower(coalesce(btrim(mp.display_name), '')), m.membership_id
      ),
      '[]'::jsonb
    )
    INTO v_managed_excluded
    FROM public.fan_team_members m
    JOIN public.fan_managed_players mp ON mp.id = m.managed_player_id
    INNER JOIN public.fan_team_event_exclusions e
      ON e.team_id = m.team_id
     AND e.pickup_game_id = p_pickup_game_id
     AND e.managed_player_id = m.managed_player_id
    WHERE m.team_id = v_team_id
      AND m.left_at IS NULL;

    v_excluded := v_excluded || v_managed_excluded;
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
    'approved_join_count', v_account_playing_count,
    'playing_total_count', 1 + v_account_playing_count
  );
END;
$$;

COMMENT ON FUNCTION public.get_pickup_game_roster(uuid) IS
  'Privacy-safe pickup roster with dual participant identity. Account rows are unchanged. '
  'Guardian-managed seats appear in playing/pending/declined/no_response/excluded for Team '
  'viewers only (organizer or Team participant/guardian), sourced from fan_team_event_rsvps '
  '(going/maybe/cant_go) and from a missing rsvp row (no_response). A managed row''s user_id '
  'is its managed_player_id; membership_id / is_managed_player / managed_player_id are also '
  'emitted. approved_join_count / playing_total_count remain account-only so pickup capacity '
  'is viewer-independent. Per-event exclusions apply to both identities.';

REVOKE ALL ON FUNCTION public.get_pickup_game_roster(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_pickup_game_roster(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_pickup_game_roster(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_pickup_game_roster(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 7) F) save_fan_team_event_lineup — accept user_id XOR managed_player_id
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.save_fan_team_event_lineup(
  p_pickup_game_id uuid,
  p_team_id uuid,
  p_status text,
  p_formation text DEFAULT NULL,
  p_members jsonb DEFAULT '[]'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_status text := lower(btrim(coalesce(p_status, 'draft')));
  v_formation text := nullif(btrim(coalesce(p_formation, '')), '');
  v_lineup_id uuid;
  v_elem jsonb;
  v_user uuid;
  v_managed uuid;
  v_key uuid;
  v_member_status text;
  v_position text;
  v_sort int;
  v_seen uuid[] := ARRAY[]::uuid[];
  v_game_status text;
  v_sport text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_pickup_game_id IS NULL OR p_team_id IS NULL THEN
    RAISE EXCEPTION 'Team and pickup game are required.';
  END IF;
  IF v_status NOT IN ('draft', 'published') THEN
    RAISE EXCEPTION 'Invalid lineup status.';
  END IF;
  IF NOT public.fan_team_viewer_can_manage_lineup(p_team_id) THEN
    RAISE EXCEPTION 'Only coaches and managers can edit lineups.';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.fan_team_game_links l
    WHERE l.pickup_game_id = p_pickup_game_id
      AND l.team_id = p_team_id
  ) THEN
    RAISE EXCEPTION 'Team is not linked to this event.';
  END IF;

  SELECT
    lower(btrim(coalesce(g.status, ''))),
    g.sport
  INTO v_game_status, v_sport
  FROM public.pickup_games g
  WHERE g.id = p_pickup_game_id;

  IF v_game_status IS NULL THEN
    RAISE EXCEPTION 'Event not found.';
  END IF;
  IF v_game_status IS DISTINCT FROM 'active' AND v_status = 'published' THEN
    RAISE EXCEPTION 'Cannot publish a lineup for a cancelled event.';
  END IF;

  -- Formation is soccer metadata only; non-soccer always NULL.
  IF NOT public.fan_team_event_sport_supports_formation(v_sport) THEN
    v_formation := NULL;
  ELSIF v_formation IS NOT NULL AND char_length(v_formation) > 40 THEN
    RAISE EXCEPTION 'Invalid formation.';
  END IF;

  INSERT INTO public.fan_team_event_lineups (
    team_id,
    pickup_game_id,
    status,
    formation,
    published_at,
    published_by,
    updated_at
  )
  VALUES (
    p_team_id,
    p_pickup_game_id,
    v_status,
    v_formation,
    CASE WHEN v_status = 'published' THEN now() ELSE NULL END,
    CASE WHEN v_status = 'published' THEN me ELSE NULL END,
    now()
  )
  ON CONFLICT (team_id, pickup_game_id) DO UPDATE
    SET status = EXCLUDED.status,
        formation = EXCLUDED.formation,
        published_at = CASE
          WHEN EXCLUDED.status = 'published' THEN now()
          ELSE public.fan_team_event_lineups.published_at
        END,
        published_by = CASE
          WHEN EXCLUDED.status = 'published' THEN me
          ELSE public.fan_team_event_lineups.published_by
        END,
        updated_at = now()
  RETURNING id INTO v_lineup_id;

  DELETE FROM public.fan_team_event_lineup_members
  WHERE lineup_id = v_lineup_id;

  FOR v_elem IN
    SELECT value
    FROM jsonb_array_elements(coalesce(p_members, '[]'::jsonb))
  LOOP
    BEGIN
      v_user := nullif(btrim(coalesce(v_elem->>'user_id', '')), '')::uuid;
    EXCEPTION WHEN others THEN
      v_user := NULL;
    END;
    BEGIN
      v_managed := nullif(btrim(coalesce(v_elem->>'managed_player_id', '')), '')::uuid;
    EXCEPTION WHEN others THEN
      v_managed := NULL;
    END;

    -- Same XOR the fan_team_event_lineup_members CHECK enforces.
    IF v_user IS NOT NULL AND v_managed IS NOT NULL THEN
      RAISE EXCEPTION 'Lineup player must be either an account or a managed player.';
    END IF;
    IF v_user IS NULL AND v_managed IS NULL THEN
      CONTINUE;
    END IF;

    v_key := coalesce(v_user, v_managed);
    IF v_key = ANY (v_seen) THEN
      RAISE EXCEPTION 'Duplicate lineup player.';
    END IF;

    IF v_user IS NOT NULL THEN
      IF NOT public.is_active_fan_team_member(p_team_id, v_user) THEN
        RAISE EXCEPTION 'Lineup player is not an active Team member.';
      END IF;
    ELSE
      IF NOT public.is_active_fan_team_managed_member(p_team_id, v_managed) THEN
        RAISE EXCEPTION 'Lineup player is not an active Team member.';
      END IF;
    END IF;

    v_member_status := lower(btrim(coalesce(v_elem->>'lineup_status', '')));
    IF v_member_status NOT IN ('starting', 'bench') THEN
      RAISE EXCEPTION 'Invalid lineup status for member.';
    END IF;

    v_position := public.fan_team_event_normalize_position_code(v_elem->>'position_code');
    IF NOT public.fan_team_event_position_code_is_valid(v_sport, v_position) THEN
      RAISE EXCEPTION 'Invalid position for this sport.';
    END IF;

    BEGIN
      v_sort := coalesce((v_elem->>'sort_order')::integer, 0);
    EXCEPTION WHEN others THEN
      v_sort := 0;
    END;

    INSERT INTO public.fan_team_event_lineup_members (
      lineup_id, user_id, managed_player_id, lineup_status, position_code, sort_order
    ) VALUES (
      v_lineup_id, v_user, v_managed, v_member_status, v_position, v_sort
    );

    v_seen := array_append(v_seen, v_key);
  END LOOP;

  RETURN v_lineup_id;
END;
$$;

COMMENT ON FUNCTION public.save_fan_team_event_lineup(uuid, uuid, text, text, jsonb) IS
  'Atomic replace of a Team event lineup. Each member element carries EITHER user_id OR '
  'managed_player_id (never both); both identities must hold an active seat on the Team. '
  'Duplicate detection is per participant, not per user_id.';

REVOKE ALL ON FUNCTION public.save_fan_team_event_lineup(uuid, uuid, text, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.save_fan_team_event_lineup(uuid, uuid, text, text, jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION public.save_fan_team_event_lineup(uuid, uuid, text, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_fan_team_event_lineup(uuid, uuid, text, text, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- 8) get_fan_team_event_lineup — emit managed identity + guardian read access
-- ---------------------------------------------------------------------------
-- Required by F: a lineup that can STORE managed seats must also RETURN them.
-- Without managed_player_id in the payload a managed row decodes as a nameless
-- NULL-identity member on iOS.
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

  -- Guardians of an active managed seat are Team readers even when they hold no
  -- seat themselves; drafts stay hidden from them (viewer_can_manage is false).
  IF NOT public.fan_team_viewer_can_access_team(v_team_id) THEN
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
        'managed_player_id', m.managed_player_id,
        'is_managed_player', (m.managed_player_id IS NOT NULL),
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
  ), '[]'::jsonb);

  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION public.get_fan_team_event_lineup(uuid, uuid) IS
  'Team event lineup for the viewer. Members carry user_id XOR managed_player_id plus '
  'is_managed_player. Readable by active members and by guardians of an active managed seat; '
  'drafts remain visible only to lineup managers.';

-- Direct-table reads follow the same widened rule (the RPCs above are SECURITY
-- DEFINER, but a guardian must not hit RLS if a future client selects directly).
DROP POLICY IF EXISTS fan_team_event_lineups_select ON public.fan_team_event_lineups;
CREATE POLICY fan_team_event_lineups_select ON public.fan_team_event_lineups
  FOR SELECT TO authenticated
  USING (
    public.fan_team_viewer_can_access_team(team_id)
    AND (
      status = 'published'
      OR public.fan_team_viewer_can_manage_lineup(team_id)
    )
  );

DROP POLICY IF EXISTS fan_team_event_lineup_members_select ON public.fan_team_event_lineup_members;
CREATE POLICY fan_team_event_lineup_members_select ON public.fan_team_event_lineup_members
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.fan_team_event_lineups l
      WHERE l.id = lineup_id
        AND public.fan_team_viewer_can_access_team(l.team_id)
        AND (
          l.status = 'published'
          OR public.fan_team_viewer_can_manage_lineup(l.team_id)
        )
    )
  );

-- Exclusions are Team-internal but a guardian must see why their player is out.
DROP POLICY IF EXISTS fan_team_event_exclusions_select ON public.fan_team_event_exclusions;
CREATE POLICY fan_team_event_exclusions_select ON public.fan_team_event_exclusions
  FOR SELECT TO authenticated
  USING (public.fan_team_viewer_can_access_team(team_id));

-- ---------------------------------------------------------------------------
-- 9) list_pickup_game_change_push_tokens — reach guardians of managed seats
-- ---------------------------------------------------------------------------
-- A managed seat has no user_id, so the pre-20260961 fan-out silently dropped
-- the whole point of the feature: the parent never heard that their child's game
-- moved. Return shape is unchanged, so the deployed notify-pickup-game-change
-- Edge Function needs no redeploy.
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
      AND m.user_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public.fan_team_event_exclusions ex
        WHERE ex.team_id = m.team_id
          AND ex.pickup_game_id = p_pickup_game_id
          AND ex.user_id = m.user_id
      )

    UNION

    -- Guardians of an active, non-excluded managed seat on a linked Team.
    SELECT g.guardian_user_id AS uid
    FROM public.fan_team_members m
    INNER JOIN linked_teams lt ON lt.team_id = m.team_id
    INNER JOIN public.fan_managed_player_guardians g
      ON g.managed_player_id = m.managed_player_id
     AND g.revoked_at IS NULL
    WHERE m.left_at IS NULL
      AND m.managed_player_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public.fan_team_event_exclusions ex
        WHERE ex.team_id = m.team_id
          AND ex.pickup_game_id = p_pickup_game_id
          AND ex.managed_player_id = m.managed_player_id
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

COMMENT ON FUNCTION public.list_pickup_game_change_push_tokens(uuid, uuid) IS
  'Change-push tokens: Team-linked includes active members, eligible outside requests, and '
  'active guardians of active managed seats. Former members with stale pre-leave RSVP rows '
  'are excluded for future events. Per-event exclusions (both identities) drop the recipient.';

REVOKE ALL ON FUNCTION public.list_pickup_game_change_push_tokens(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_pickup_game_change_push_tokens(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.list_pickup_game_change_push_tokens(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.list_pickup_game_change_push_tokens(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 10) G) Grants for the new client-callable RPCs
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  fn text;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'public.set_fan_team_member_player_number_for_membership(uuid, uuid, integer)',
    'public.set_fan_team_member_preferred_position_for_membership(uuid, uuid, text)',
    'public.set_fan_team_event_membership_excluded(uuid, uuid, uuid, boolean)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', fn);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', fn);
  END LOOP;
END $$;

-- Re-assert 20260960 internal-helper lockdown (idempotent). 60961 calls these
-- only from SECURITY DEFINER owners; authenticated must never probe them.
DO $$
DECLARE
  fn text;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'public.is_active_fan_team_managed_member(uuid, uuid)',
    'public.is_authorized_managed_player_guardian(uuid, uuid)',
    'public.fan_managed_player_visible_to_viewer(uuid)',
    'public.fan_team_membership_recipient_user_ids(uuid)',
    'public.is_fan_geo_runtime_flag_enabled(text)',
    'public.resolve_fan_team_notification_recipients_for_participant(uuid, uuid, uuid, uuid)'
  ] LOOP
    IF to_regprocedure(fn) IS NULL THEN
      CONTINUE;
    END IF;
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', fn);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', fn);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM authenticated', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', fn);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 11) Structural self-checks
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regprocedure(
    'public.set_fan_team_member_player_number_for_membership(uuid, uuid, integer)'
  ) IS NULL THEN
    RAISE EXCEPTION 'assert_failed: membership player-number RPC missing';
  END IF;

  IF to_regprocedure(
    'public.set_fan_team_member_preferred_position_for_membership(uuid, uuid, text)'
  ) IS NULL THEN
    RAISE EXCEPTION 'assert_failed: membership preferred-position RPC missing';
  END IF;

  IF to_regprocedure(
    'public.emit_fan_team_member_change_notification_for_membership(uuid, text, uuid, uuid, jsonb)'
  ) IS NULL THEN
    RAISE EXCEPTION 'assert_failed: seat-scoped member-change emit missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'fan_team_member_change_events'
      AND column_name = 'target_managed_player_id'
  ) THEN
    RAISE EXCEPTION 'assert_failed: member-change events missing managed target column';
  END IF;

  -- The deployed Edge still requires a real auth.users target.
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'fan_team_member_change_events'
      AND column_name = 'target_user_id'
      AND is_nullable = 'YES'
  ) THEN
    RAISE EXCEPTION 'assert_failed: target_user_id must stay NOT NULL for the deployed Edge';
  END IF;

  -- Lineup members must accept a managed identity.
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'fan_team_event_lineup_members'
      AND column_name = 'managed_player_id'
  ) THEN
    RAISE EXCEPTION 'assert_failed: lineup members missing managed_player_id (apply 20260960)';
  END IF;
END $$;

COMMIT;

-- =============================================================================
-- MANUAL VERIFICATION (staging only — run as the relevant users)
-- =============================================================================
-- A) NO-MANAGED-PLAYER REGRESSION (must be byte-identical to pre-20260961):
--    SELECT get_pickup_game_roster('<team_linked_game>');
--      -- playing/pending/declined/no_response/excluded unchanged; every row now
--      -- also carries is_managed_player=false, managed_player_id=null and
--      -- membership_id (null for outside requesters).
--    SELECT approved_join_count, playing_total_count
--      FROM jsonb_to_record(get_pickup_game_roster('<game>'))
--        AS x(approved_join_count int, playing_total_count int);
--      -- identical to the pre-migration values.
--    SELECT set_fan_team_member_player_number('<team>', '<user>', 7);   -- owner/manager
--    SELECT set_fan_team_member_preferred_position('<team>', '<user>', 'CB');
--    SELECT * FROM get_fan_team_event_lineup('<game>', '<team>');
--
-- B) MANAGED SEAT, JERSEY + POSITION (as owner/manager of the Team):
--    SELECT membership_id FROM list_my_managed_players_on_team('<team>');
--    SELECT set_fan_team_member_player_number_for_membership('<team>', '<seat>', 12);
--    SELECT set_fan_team_member_player_number_for_membership('<team>', '<seat2>', 12);
--      -- expect: 'That player number is already assigned on this Team.'
--    SELECT set_fan_team_member_preferred_position_for_membership('<team>', '<seat>', 'GK');
--    SELECT kind, target_user_id, target_managed_player_id, recipient_user_ids, payload
--      FROM fan_team_member_change_events
--      ORDER BY created_at DESC LIMIT 3;
--      -- managed rows: target_user_id = primary guardian, recipients = guardians
--      -- minus the acting manager, payload.is_managed_player = true.
--
-- C) MANAGED ATTENDANCE IN THE ROSTER (as a Team member, then as the guardian):
--    SELECT set_fan_team_game_rsvp_for_membership('<game>', '<seat>', 'going');
--    SELECT jsonb_pretty(get_pickup_game_roster('<game>'));
--      -- the child appears in "playing" with user_id = managed_player_id,
--      -- is_managed_player = true and its display name / avatar.
--    SELECT set_fan_team_game_rsvp_for_membership('<game>', '<seat>', 'maybe');   -- pending
--    SELECT set_fan_team_game_rsvp_for_membership('<game>', '<seat>', 'cant_go'); -- declined
--    DELETE is not needed: a seat with no fan_team_event_rsvps row is no_response.
--
-- D) GUARDIAN WHO IS NOT ON THE TEAM:
--    SELECT is_pickup_game_fan_team_participant('<game>', '<guardian>');  -- true
--    SELECT get_pickup_game_roster('<game>');                             -- allowed
--    SELECT * FROM get_fan_team_event_lineup('<game>', '<team>');          -- published only
--    -- viewer_can_manage_event_roster / viewer_can_manage must both be false.
--
-- E) LINEUP WITH A MANAGED SEAT (as a lineup manager):
--    SELECT save_fan_team_event_lineup(
--      '<game>', '<team>', 'published', NULL,
--      '[{"user_id":"<adult>","lineup_status":"starting","position_code":"CB","sort_order":0},
--         {"managed_player_id":"<child>","lineup_status":"starting","position_code":"GK","sort_order":1}]'::jsonb
--    );
--    SELECT members FROM get_fan_team_event_lineup('<game>', '<team>');
--    -- Rejections to confirm:
--    --   both ids in one element      -> 'Lineup player must be either an account or a managed player.'
--    --   same participant twice       -> 'Duplicate lineup player.'
--    --   managed player of other Team -> 'Lineup player is not an active Team member.'
--
-- F) PER-EVENT EXCLUSION OF A MANAGED SEAT (as a lineup manager, FUTURE event):
--    SELECT set_fan_team_event_membership_excluded('<team>', '<game>', '<seat>', true);
--      -- child leaves every response bucket, appears in "excluded"; its lineup
--      -- seat and its fan_team_event_rsvps row are gone.
--    SELECT set_fan_team_event_membership_excluded('<team>', '<game>', '<seat>', false);
--      -- back to no_response (RSVP is deliberately NOT restored, same as adults).
--
-- G) PUSH FAN-OUT:
--    SELECT count(*) FROM list_pickup_game_change_push_tokens('<game>', NULL);
--      -- includes the guardian's tokens even when the guardian holds no seat.
--
-- FOLLOW-UPS (deliberately NOT in this migration):
--   1) Deploy a reworded notify-fan-team-member-change so guardian pushes read
--      "Ellie's number is now 12" instead of the member-voiced copy. The payload
--      already carries managed_player_name / is_managed_player.
--   2) notify-fan-team-member-left / notify-fan-team-member-change deep links
--      still target account rosters only.
--   3) list_pickup_game_team_responses (if still used) has not been extended.
-- =============================================================================
