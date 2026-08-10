-- Pickup Invite Friends → Teams mode.
--
-- Do NOT apply from the agent. Apply manually after prior Team/pickup migrations.
--
-- Architecture (approved):
--   - Teams mode is a convenience over normal per-user pickup_game_invites
--   - No Team invite table / Team RSVP / parallel notification type
--   - create_pickup_game_invites_from_fan_team resolves active roster server-side
--   - Same existing Pickup invite notification path (row insert → notify)
--
-- Security model:
--   1) create_pickup_game_invites(...) — INDIVIDUAL path only:
--        friend | public-invitable (+ block/self/activity/duplicate/join gates)
--        Does NOT grant eligibility via managed-Team co-membership.
--   2) create_pickup_game_invites_from_fan_team(...) — TEAM bulk path:
--        requires fan_team_viewer_can_manage(team)
--        active roster membership on THAT team is the eligibility source
--        still enforces active/unblocked + duplicate/join/cap gates
--   3) preview_pickup_game_fan_team_invite(...) — SAME eligibility as Team bulk send
--
-- Also:
--   - Raise per-call / per-game invite cap 20 → 50 (Team max ~50)
--   - Skip users already pending/approved on pickup_game_requests
--
-- Production invite lifecycle (preserve — from 20260803 create_pickup_game_invites):
--   - Duplicate check matches ANY pickup_game_invites row for (game, invitee),
--     including status='cancelled'. Cancelled historical invites are NOT re-inviteable.
--   - Active invite CAP counts only status <> 'cancelled'.
-- Preview/Send must share those rules (no deterministic mismatch).

-- ---------------------------------------------------------------------------
-- 1) create_pickup_game_invites — individual eligibility only + higher cap + join-gate
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_pickup_game_invites(
  p_pickup_game_id uuid,
  p_invitee_user_ids uuid[],
  p_message text DEFAULT NULL
)
RETURNS TABLE (
  invitee_user_id uuid,
  invite_id uuid,
  outcome text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  clean_message text := nullif(btrim(coalesce(p_message, '')), '');
  invitee uuid;
  existing_id uuid;
  inserted_id uuid;
  active_invite_count int;
  join_status text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF NOT public.pickup_invite_user_is_active(me) THEN
    RAISE EXCEPTION 'pickup_inviter_not_allowed';
  END IF;

  IF p_pickup_game_id IS NULL THEN
    RAISE EXCEPTION 'pickup_game_required';
  END IF;

  IF p_invitee_user_ids IS NULL OR array_length(p_invitee_user_ids, 1) IS NULL THEN
    RETURN;
  END IF;

  PERFORM 1
  FROM public.pickup_games g
  WHERE g.id = p_pickup_game_id
    AND g.creator_user_id = me
    AND g.status = 'active'
    AND (g.remove_after_at IS NULL OR g.remove_after_at > now())
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'pickup_game_not_invitable';
  END IF;

  SELECT count(*)::int
  INTO active_invite_count
  FROM public.pickup_game_invites i
  WHERE i.pickup_game_id = p_pickup_game_id
    AND i.status <> 'cancelled';

  FOR invitee IN
    SELECT DISTINCT x
    FROM unnest(p_invitee_user_ids) AS x
    WHERE x IS NOT NULL
    LIMIT 50
  LOOP
    existing_id := NULL;
    inserted_id := NULL;
    join_status := NULL;

    -- Production semantics: ANY prior invite row (incl. cancelled) => duplicate.
    SELECT i.id INTO existing_id
    FROM public.pickup_game_invites i
    WHERE i.pickup_game_id = p_pickup_game_id
      AND i.invitee_user_id = invitee
    LIMIT 1;

    IF existing_id IS NOT NULL THEN
      invitee_user_id := invitee;
      invite_id := existing_id;
      outcome := 'duplicate';
      RETURN NEXT;
      CONTINUE;
    END IF;

    SELECT lower(btrim(r.status)) INTO join_status
    FROM public.pickup_game_requests r
    WHERE r.pickup_game_id = p_pickup_game_id
      AND r.requester_user_id = invitee
      AND lower(btrim(r.status)) IN ('pending', 'approved')
    LIMIT 1;

    IF join_status IS NOT NULL THEN
      invitee_user_id := invitee;
      invite_id := NULL;
      outcome := CASE WHEN join_status = 'approved' THEN 'already_playing' ELSE 'already_pending' END;
      RETURN NEXT;
      CONTINUE;
    END IF;

    IF active_invite_count >= 50 THEN
      invitee_user_id := invitee;
      invite_id := NULL;
      outcome := 'max_reached';
      RETURN NEXT;
      CONTINUE;
    END IF;

    -- Individual path only: friend OR public-invitable.
    -- Managed-Team co-membership is NOT an eligibility source here.
    IF invitee = me
       OR NOT public.pickup_invite_user_is_active(invitee)
       OR NOT public.pickup_invite_users_are_unblocked(me, invitee)
       OR NOT (
         public.pickup_invite_users_are_friends(me, invitee)
         OR public.pickup_invite_user_is_public_invitable(invitee)
       ) THEN
      invitee_user_id := invitee;
      invite_id := NULL;
      outcome := 'skipped';
      RETURN NEXT;
      CONTINUE;
    END IF;

    INSERT INTO public.pickup_game_invites (
      pickup_game_id,
      inviter_user_id,
      invitee_user_id,
      message
    )
    VALUES (
      p_pickup_game_id,
      me,
      invitee,
      CASE WHEN clean_message IS NULL THEN NULL ELSE left(clean_message, 280) END
    )
    RETURNING id INTO inserted_id;

    active_invite_count := active_invite_count + 1;
    invitee_user_id := invitee;
    invite_id := inserted_id;
    outcome := 'created';
    RETURN NEXT;
  END LOOP;
END;
$$;

COMMENT ON FUNCTION public.create_pickup_game_invites(uuid, uuid[], text) IS
  'Organizer bulk Pickup invites (Individuals). Caps at 50. Eligibility: friend | public-invitable only. '
  'Skips blocked/self/duplicates/pending|approved joiners. Does not grant Team co-member eligibility.';

REVOKE ALL ON FUNCTION public.create_pickup_game_invites(uuid, uuid[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_pickup_game_invites(uuid, uuid[], text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2) Trusted Team bulk invite — roster membership is eligibility (THIS team only)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_pickup_game_invites_from_fan_team(
  p_pickup_game_id uuid,
  p_team_id uuid,
  p_message text DEFAULT NULL
)
RETURNS TABLE (
  invitee_user_id uuid,
  invite_id uuid,
  outcome text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  clean_message text := nullif(btrim(coalesce(p_message, '')), '');
  invitee uuid;
  existing_id uuid;
  inserted_id uuid;
  active_invite_count int;
  join_status text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF NOT public.pickup_invite_user_is_active(me) THEN
    RAISE EXCEPTION 'pickup_inviter_not_allowed';
  END IF;

  IF p_pickup_game_id IS NULL OR p_team_id IS NULL THEN
    RAISE EXCEPTION 'pickup_game_and_team_required';
  END IF;

  -- Actor must manage THIS Team (cannot spoof another Team's roster).
  IF NOT public.fan_team_viewer_can_manage(p_team_id) THEN
    RAISE EXCEPTION 'fan_team_invite_not_allowed';
  END IF;

  PERFORM 1
  FROM public.pickup_games g
  WHERE g.id = p_pickup_game_id
    AND g.creator_user_id = me
    AND g.status = 'active'
    AND (g.remove_after_at IS NULL OR g.remove_after_at > now())
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'pickup_game_not_invitable';
  END IF;

  SELECT count(*)::int
  INTO active_invite_count
  FROM public.pickup_game_invites i
  WHERE i.pickup_game_id = p_pickup_game_id
    AND i.status <> 'cancelled';

  -- Active roster only (pending Team invitees never appear; left_at excludes removed).
  FOR invitee IN
    SELECT m.user_id
    FROM public.fan_team_members m
    WHERE m.team_id = p_team_id
      AND m.left_at IS NULL
      AND m.user_id IS DISTINCT FROM me
    ORDER BY m.joined_at ASC NULLS LAST, m.user_id
    LIMIT 50
  LOOP
    existing_id := NULL;
    inserted_id := NULL;
    join_status := NULL;

    -- Same production semantics as individual path: ANY invite row => duplicate
    -- (cancelled historical invites are not re-inviteable).
    SELECT i.id INTO existing_id
    FROM public.pickup_game_invites i
    WHERE i.pickup_game_id = p_pickup_game_id
      AND i.invitee_user_id = invitee
    LIMIT 1;

    IF existing_id IS NOT NULL THEN
      invitee_user_id := invitee;
      invite_id := existing_id;
      outcome := 'duplicate';
      RETURN NEXT;
      CONTINUE;
    END IF;

    SELECT lower(btrim(r.status)) INTO join_status
    FROM public.pickup_game_requests r
    WHERE r.pickup_game_id = p_pickup_game_id
      AND r.requester_user_id = invitee
      AND lower(btrim(r.status)) IN ('pending', 'approved')
    LIMIT 1;

    IF join_status IS NOT NULL THEN
      invitee_user_id := invitee;
      invite_id := NULL;
      outcome := CASE WHEN join_status = 'approved' THEN 'already_playing' ELSE 'already_pending' END;
      RETURN NEXT;
      CONTINUE;
    END IF;

    IF active_invite_count >= 50 THEN
      invitee_user_id := invitee;
      invite_id := NULL;
      outcome := 'max_reached';
      RETURN NEXT;
      CONTINUE;
    END IF;

    -- Team path eligibility: active member of the selected managed Team.
    -- Do NOT require friend / public-invitable here.
    IF NOT public.pickup_invite_user_is_active(invitee)
       OR NOT public.pickup_invite_users_are_unblocked(me, invitee) THEN
      invitee_user_id := invitee;
      invite_id := NULL;
      outcome := 'skipped';
      RETURN NEXT;
      CONTINUE;
    END IF;

    INSERT INTO public.pickup_game_invites (
      pickup_game_id,
      inviter_user_id,
      invitee_user_id,
      message
    )
    VALUES (
      p_pickup_game_id,
      me,
      invitee,
      CASE WHEN clean_message IS NULL THEN NULL ELSE left(clean_message, 280) END
    )
    RETURNING id INTO inserted_id;

    active_invite_count := active_invite_count + 1;
    invitee_user_id := invitee;
    invite_id := inserted_id;
    outcome := 'created';
    RETURN NEXT;
  END LOOP;
END;
$$;

COMMENT ON FUNCTION public.create_pickup_game_invites_from_fan_team(uuid, uuid, text) IS
  'Manager/owner Team bulk invite: resolves active roster for p_team_id server-side and inserts '
  'normal pickup_game_invites. Eligibility = active member of that Team + active/unblocked. '
  'Does not require friend/public. Caps/dedupe/join outcomes match individual path.';

REVOKE ALL ON FUNCTION public.create_pickup_game_invites_from_fan_team(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_pickup_game_invites_from_fan_team(uuid, uuid, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3) Preview — identical eligibility semantics to Team bulk send (no writes)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.preview_pickup_game_fan_team_invite(
  p_pickup_game_id uuid,
  p_team_id uuid
)
RETURNS TABLE (
  team_id uuid,
  pickup_game_id uuid,
  member_count_excluding_organizer integer,
  eligible_count integer,
  already_invited_count integer,
  already_playing_count integer,
  already_pending_count integer,
  ineligible_count integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_total int := 0;
  v_eligible int := 0;
  v_raw_eligible int := 0;
  v_already_invited int := 0;
  v_already_playing int := 0;
  v_already_pending int := 0;
  v_ineligible int := 0;
  v_active_invite_count int := 0;
  v_remaining_slots int := 0;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF NOT public.fan_team_viewer_can_manage(p_team_id) THEN
    RAISE EXCEPTION 'fan_team_invite_not_allowed';
  END IF;

  PERFORM 1
  FROM public.pickup_games g
  WHERE g.id = p_pickup_game_id
    AND g.creator_user_id = me
    AND g.status = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'pickup_game_not_invitable';
  END IF;

  -- Same active-invite CAP definition as Send (cancelled rows do not consume slots).
  SELECT count(*)::int
  INTO v_active_invite_count
  FROM public.pickup_game_invites i
  WHERE i.pickup_game_id = p_pickup_game_id
    AND i.status <> 'cancelled';

  v_remaining_slots := greatest(0, 50 - v_active_invite_count);

  -- Mutually exclusive classes mirror Send check order:
  --   any invite row (incl. cancelled) → already_invited / duplicate
  --   approved request → already_playing
  --   pending request → already_pending
  --   inactive/blocked → ineligible / skipped
  --   else → raw_eligible (then capped by remaining slots → eligible / max_reached)
  WITH roster AS (
    SELECT m.user_id
    FROM public.fan_team_members m
    WHERE m.team_id = p_team_id
      AND m.left_at IS NULL
      AND m.user_id IS DISTINCT FROM me
  ),
  classed AS (
    SELECT
      r.user_id,
      CASE
        WHEN EXISTS (
          SELECT 1
          FROM public.pickup_game_invites i
          WHERE i.pickup_game_id = p_pickup_game_id
            AND i.invitee_user_id = r.user_id
        ) THEN 'already_invited'
        WHEN EXISTS (
          SELECT 1
          FROM public.pickup_game_requests req
          WHERE req.pickup_game_id = p_pickup_game_id
            AND req.requester_user_id = r.user_id
            AND lower(btrim(req.status)) = 'approved'
        ) THEN 'already_playing'
        WHEN EXISTS (
          SELECT 1
          FROM public.pickup_game_requests req
          WHERE req.pickup_game_id = p_pickup_game_id
            AND req.requester_user_id = r.user_id
            AND lower(btrim(req.status)) = 'pending'
        ) THEN 'already_pending'
        WHEN NOT public.pickup_invite_user_is_active(r.user_id)
          OR NOT public.pickup_invite_users_are_unblocked(me, r.user_id)
        THEN 'ineligible'
        ELSE 'raw_eligible'
      END AS class
    FROM roster r
  )
  SELECT
    count(*)::int,
    count(*) FILTER (WHERE class = 'already_invited')::int,
    count(*) FILTER (WHERE class = 'already_playing')::int,
    count(*) FILTER (WHERE class = 'already_pending')::int,
    count(*) FILTER (WHERE class = 'ineligible')::int,
    count(*) FILTER (WHERE class = 'raw_eligible')::int
  INTO
    v_total,
    v_already_invited,
    v_already_playing,
    v_already_pending,
    v_ineligible,
    v_raw_eligible
  FROM classed;

  -- eligible_count = how many Send can create NOW under the 50 active-invite cap.
  -- Cap overflow (would be max_reached) folds into ineligible_count so the existing
  -- UI schema stays unchanged and never overstates actionable invites.
  v_eligible := least(v_raw_eligible, v_remaining_slots);
  v_ineligible := v_ineligible + (v_raw_eligible - v_eligible);

  team_id := p_team_id;
  pickup_game_id := p_pickup_game_id;
  member_count_excluding_organizer := v_total;
  eligible_count := v_eligible;
  already_invited_count := v_already_invited;
  already_playing_count := v_already_playing;
  already_pending_count := v_already_pending;
  ineligible_count := v_ineligible;
  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION public.preview_pickup_game_fan_team_invite(uuid, uuid) IS
  'Read-only eligibility summary for Invite Friends → Teams. Semantics match '
  'create_pickup_game_invites_from_fan_team: ANY invite row (incl. cancelled) = already_invited; '
  'eligible_count is capped by remaining active-invite slots (50 - non-cancelled). '
  'Cap overflow is included in ineligible_count. No friend/public requirement. No writes.';

REVOKE ALL ON FUNCTION public.preview_pickup_game_fan_team_invite(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.preview_pickup_game_fan_team_invite(uuid, uuid) TO authenticated;

-- Drop the broad helper if a prior draft of this migration created it.
-- Team co-member eligibility must not leak into the generic individual invite RPC.
DROP FUNCTION IF EXISTS public.pickup_invite_eligible_via_managed_fan_team(uuid, uuid);
