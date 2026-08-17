-- =============================================================================
-- 20260956_0001 — Team self-RSVP must not hit pickup organizer decision guard
-- =============================================================================
-- CODE-PROVEN ROOT CAUSE (physical iPhone Schedule Change → Can't Go):
--
--   FanTeamScheduleQuickRSVPView
--     → FanTeamsService.setRSVP
--     → RPC set_fan_team_game_rsvp(p_game_id, p_status)
--     → UPDATE pickup_game_requests.status
--         going   → 'approved'
--         maybe   → 'pending'
--         cant_go → 'withdrawn'
--     → TRIGGER pickup_game_requests_before_update_status (20260897)
--
--   That trigger only allows:
--     • requester: cancelled / withdrawn-from-approved
--     • creator: approved/rejected FROM pending (organizer join decision)
--
--   Team RSVP needs free self transitions among approved ↔ pending ↔ withdrawn.
--   Examples that raise today:
--     • withdrawn → approved  (Can't Go → Going)
--         → pickup_request_decision_forbidden
--     • pending → approved for non-creator (Maybe → Going)
--         → pickup_request_decision_forbidden
--     • approved → pending (Going → Maybe)
--         → pickup_request_status_forbidden
--     • pending → withdrawn (Maybe → Can't Go)
--         → pickup_request_cancel_forbidden
--
-- FIX:
--   Allow ACTIVE Team-linked members to change THEIR OWN request row among
--   approved/pending/withdrawn when the pickup is linked via fan_team_game_links.
--   Skip organizer capacity gate for those self-RSVP transitions.
--
--   Standalone Pickup organizer decision rules UNCHANGED.
--
-- Do NOT apply from the agent. Apply manually after 20260955.
-- No Edge Function.
-- =============================================================================

BEGIN;

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
  v_me uuid := auth.uid();
  v_team_linked boolean;
BEGIN
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  -- Trusted account-deletion context (set only inside soft-delete SECURITY DEFINER path).
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

  -- -------------------------------------------------------------------------
  -- Team-linked SELF RSVP (set_fan_team_game_rsvp).
  -- Active Team member may move THEIR OWN row among RSVP-mapped statuses:
  --   approved (Going) / pending (Maybe) / withdrawn (Can't Go)
  -- without organizer join-decision authority.
  -- -------------------------------------------------------------------------
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
      -- Self Team RSVP: no organizer gate, no pickup "spots" capacity gate.
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
    -- Standalone / non-Team: organizer decision only from pending.
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
  'Pickup request status guard. Interactive organizer decisions preserved for standalone '
  'games. Team-linked active members may self-transition approved/pending/withdrawn via '
  'set_fan_team_game_rsvp. Account-deletion GUC terminal transitions retained.';

-- Harden set_fan_team_game_rsvp contract (same write model; documents Team self-RSVP).
CREATE OR REPLACE FUNCTION public.set_fan_team_game_rsvp(
  p_game_id uuid,
  p_status text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_status text := lower(btrim(coalesce(p_status, '')));
  v_request_status text;
  v_email text;
  v_display text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF v_status NOT IN ('going', 'maybe', 'cant_go') THEN
    RAISE EXCEPTION 'Invalid RSVP status.';
  END IF;

  -- Active Team membership for a linked Team event (not organizer role).
  IF NOT public.is_pickup_game_fan_team_participant(p_game_id, me) THEN
    RAISE EXCEPTION 'Not a participant for this team game.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.pickup_games pg
    WHERE pg.id = p_game_id
      AND pg.status = 'active'
      AND pg.archived_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Game not found.';
  END IF;

  -- Storage remains pickup_game_requests with Team RSVP mapping:
  --   going → approved, maybe → pending, cant_go → withdrawn
  -- Trigger allows these self-transitions when Team-linked (20260956).
  -- Future parent/guardian authorized-subject RSVP will plug in HERE (subject ≠ auth.uid)
  -- with a separate authorized RPC — do not accept arbitrary subject ids from clients yet.
  v_request_status := CASE v_status
    WHEN 'going' THEN 'approved'
    WHEN 'maybe' THEN 'pending'
    ELSE 'withdrawn'
  END;

  SELECT nullif(btrim(u.email), '') INTO v_email
  FROM auth.users u WHERE u.id = me;

  SELECT coalesce(nullif(btrim(p.display_name), ''), 'Fan') INTO v_display
  FROM public.user_profiles p WHERE p.id = me;

  UPDATE public.pickup_game_requests
  SET
    status = v_request_status,
    responded_at = CASE WHEN v_request_status = 'pending' THEN NULL ELSE now() END,
    updated_at = now(),
    requester_display_name = coalesce(v_display, requester_display_name),
    requester_email = coalesce(v_email, requester_email)
  WHERE pickup_game_id = p_game_id
    AND requester_user_id = me;

  IF NOT FOUND THEN
    INSERT INTO public.pickup_game_requests (
      pickup_game_id,
      requester_user_id,
      requester_email,
      requester_display_name,
      requester_skill_level,
      status,
      responded_at
    ) VALUES (
      p_game_id,
      me,
      v_email,
      coalesce(v_display, 'Fan'),
      'casual',
      v_request_status,
      CASE WHEN v_request_status = 'pending' THEN NULL ELSE now() END
    );
  END IF;

  BEGIN
    PERFORM public.sync_pickup_game_group_membership(p_game_id);
  EXCEPTION
    WHEN undefined_function THEN
      NULL;
    WHEN OTHERS THEN
      NULL;
  END;
END;
$$;

COMMENT ON FUNCTION public.set_fan_team_game_rsvp(uuid, text) IS
  'Active Team member sets OWN RSVP for a Team-linked pickup/event. Maps going/maybe/cant_go '
  'onto pickup_game_requests approved/pending/withdrawn. Does not require organizer role. '
  'Subject is always auth.uid() today; guardian/subject RSVP needs a future authorized RPC.';

COMMIT;

-- Manual verification (staging, as Team member — not organizer-only):
--   SELECT set_fan_team_game_rsvp('<pickup_id>', 'cant_go');  -- from going
--   SELECT set_fan_team_game_rsvp('<pickup_id>', 'going');    -- from cant_go
--   SELECT set_fan_team_game_rsvp('<pickup_id>', 'maybe');
-- Standalone organizer approve from pending must still work for creators only.
