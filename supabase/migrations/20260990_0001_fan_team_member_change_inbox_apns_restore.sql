-- =============================================================================
-- 20260990_0001 — Restore removed-from-Team + role/admin dual delivery
-- =============================================================================
-- 20260970 rewrote remove_fan_team_member and dropped
-- emit_fan_team_member_change_notification. Target user_id was already
-- captured (p_user_id) before left_at, but no inbox row and no APNs queue
-- were created after the soft-remove.
--
-- This forward migration:
--   1) Expands fan_team_member_change_events.kind for Administrator ON/OFF
--   2) Restores emit on remove_fan_team_member using the pre-captured
--      p_user_id (never re-queried from the post-delete roster)
--   3) Emits team_admin_granted / team_admin_removed from
--      set_fan_team_member_permissions(uuid, uuid, text[]) — the 20260986
--      iOS contract — when the Administrator preset actually toggles
--      (not every custom-permission tweak; not a duplicate of
--      team_role_changed). Does NOT recreate the obsolete jsonb overload.
--   4) Rewrites inbox fan-out copy + teamsHome destination + kind-specific
--      dedupe keys, snapshotting team_name + sport (no logo URL)
--   5) Dual-key Bearer + apikey on the member-change APNs queue
--      (same class of fix as 20260988 for pickup)
--
-- Inbox and APNs stay independent. Does not weaken auth.
-- PREPARE ONLY — do not auto-apply.
-- =============================================================================

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.fan_team_member_change_events') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_team_member_change_events'];
  END IF;
  IF to_regclass('public.fan_notification_inbox') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_notification_inbox'];
  END IF;
  IF to_regprocedure('public.emit_fan_team_member_change_notification(uuid, text, uuid, uuid, jsonb)') IS NULL THEN
    v_missing := v_missing || ARRAY['emit_fan_team_member_change_notification'];
  END IF;
  IF to_regprocedure('public.remove_fan_team_member(uuid, uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['remove_fan_team_member'];
  END IF;
  IF to_regprocedure('public.set_fan_team_member_permissions(uuid, uuid, text[])') IS NULL THEN
    v_missing := v_missing || ARRAY['set_fan_team_member_permissions(uuid, uuid, text[])'];
  END IF;
  IF to_regprocedure('public.upsert_fan_notification_inbox(uuid, text, text, text, text, text, text, text, text, uuid, uuid, jsonb)') IS NULL
     AND to_regprocedure('public.upsert_fan_notification_inbox(uuid,text,text,text,text,text,text,text,text,uuid,uuid,jsonb)') IS NULL THEN
    -- Named-arg form from 20260983; probe by proname.
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc
      WHERE proname = 'upsert_fan_notification_inbox'
        AND pronamespace = 'public'::regnamespace
    ) THEN
      v_missing := v_missing || ARRAY['upsert_fan_notification_inbox'];
    END IF;
  END IF;
  IF to_regprocedure('public.fan_team_permission_keys()') IS NULL THEN
    v_missing := v_missing || ARRAY['fan_team_permission_keys()'];
  END IF;
  IF to_regprocedure('public.fan_team_effective_permissions(text,boolean,jsonb)') IS NULL THEN
    v_missing := v_missing || ARRAY['fan_team_effective_permissions'];
  END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION
      '20260990_0001 prerequisites missing: %',
      array_to_string(v_missing, ', ');
  END IF;
END $$;

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Kind CHECK: add Administrator grant/remove
-- -----------------------------------------------------------------------------
ALTER TABLE public.fan_team_member_change_events
  DROP CONSTRAINT IF EXISTS fan_team_member_change_events_kind_check;

ALTER TABLE public.fan_team_member_change_events
  ADD CONSTRAINT fan_team_member_change_events_kind_check
  CHECK (kind IN (
    'player_number_set', 'player_number_changed', 'player_number_removed',
    'preferred_position_set', 'preferred_position_changed', 'preferred_position_removed',
    'team_role_changed',
    'removed_from_event', 'added_back_to_event',
    'removed_from_team',
    'team_admin_granted', 'team_admin_removed'
  ));

-- -----------------------------------------------------------------------------
-- 2) Role display + Administrator preset helper (inbox / emit copy)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fan_team_role_display_label(p_role text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
  SELECT CASE lower(btrim(coalesce(p_role, '')))
    WHEN 'owner' THEN 'Owner'
    WHEN 'manager' THEN 'Manager'
    WHEN 'head_coach' THEN 'Head Coach'
    WHEN 'assistant_coach' THEN 'Assistant Coach'
    WHEN 'captain' THEN 'Captain'
    WHEN 'assistant_captain' THEN 'Assistant Captain'
    WHEN 'member' THEN 'Member'
    ELSE 'Member'
  END;
$$;

COMMENT ON FUNCTION public.fan_team_role_display_label(text) IS
  'English display label for fan_team_members.role tokens. Inbox/APNs copy; iOS localizes.';

CREATE OR REPLACE FUNCTION public.fan_team_is_administrator_preset(p_keys text[])
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT coalesce(p_keys, '{}'::text[]) @> public.fan_team_permission_keys();
$$;

COMMENT ON FUNCTION public.fan_team_is_administrator_preset(text[]) IS
  'True when keys contain the full Team Administrator catalog (20260987/89).';

CREATE OR REPLACE FUNCTION public.fan_team_member_change_inbox_dedupe_key(
  p_kind text,
  p_team_id uuid,
  p_user_id uuid,
  p_event_id uuid
)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
  SELECT CASE lower(btrim(coalesce(p_kind, '')))
    WHEN 'removed_from_team' THEN
      'team_removed:' || lower(p_team_id::text) || ':' || lower(p_user_id::text) || ':' || lower(p_event_id::text)
    WHEN 'team_role_changed' THEN
      'team_role_changed:' || lower(p_team_id::text) || ':' || lower(p_user_id::text) || ':' || lower(p_event_id::text)
    WHEN 'team_admin_granted' THEN
      'team_admin_granted:' || lower(p_team_id::text) || ':' || lower(p_user_id::text) || ':' || lower(p_event_id::text)
    WHEN 'team_admin_removed' THEN
      'team_admin_removed:' || lower(p_team_id::text) || ':' || lower(p_user_id::text) || ':' || lower(p_event_id::text)
    ELSE
      'team_member_change:' || lower(p_event_id::text) || ':' || lower(p_user_id::text)
  END;
$$;

-- -----------------------------------------------------------------------------
-- 3) emit: snapshot sport onto payload (Team still exists after member remove)
-- -----------------------------------------------------------------------------
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
  v_sport text;
  v_event_id uuid := gen_random_uuid();
  v_recipients uuid[];
  v_payload jsonb;
BEGIN
  IF p_team_id IS NULL OR p_target_user_id IS NULL THEN
    RAISE NOTICE
      '[FanTeamMemberChangeDebug] emit_skip reason=missing_team_or_target team_id=% kind=% target=%',
      p_team_id, p_kind, p_target_user_id;
    RETURN NULL;
  END IF;

  IF p_actor_user_id IS NULL OR p_actor_user_id = p_target_user_id THEN
    RAISE NOTICE
      '[FanTeamMemberChangeDebug] emit_skip reason=self_or_missing_actor team_id=% kind=% actor=% target=%',
      p_team_id, p_kind, p_actor_user_id, p_target_user_id;
    RETURN NULL;
  END IF;

  SELECT
    coalesce(nullif(btrim(t.name), ''), 'Team'),
    nullif(btrim(t.sport), '')
  INTO v_team_name, v_sport
  FROM public.fan_teams t
  WHERE t.id = p_team_id;

  v_team_name := coalesce(v_team_name, 'Team');
  v_recipients := ARRAY[p_target_user_id]::uuid[];
  v_payload := coalesce(p_payload, '{}'::jsonb)
    || jsonb_build_object(
         'team_name', v_team_name,
         'sport', coalesce(v_sport, '')
       );

  INSERT INTO public.fan_team_member_change_events (
    id, team_id, kind, actor_user_id, target_user_id, team_name, payload, recipient_user_ids
  ) VALUES (
    v_event_id, p_team_id, p_kind, p_actor_user_id, p_target_user_id,
    v_team_name, v_payload, v_recipients
  );

  RAISE NOTICE
    '[FanTeamMemberChangeDebug] emit_ok event=% team_id=% kind=% actor=% target=% recipient_count=%',
    v_event_id, p_team_id, p_kind, p_actor_user_id, p_target_user_id, cardinality(v_recipients);

  PERFORM public.queue_fan_team_member_change_push_notification(v_event_id);
  RETURN v_event_id;
END;
$$;

COMMENT ON FUNCTION public.emit_fan_team_member_change_notification(uuid, text, uuid, uuid, jsonb) IS
  'Records member-change event for the explicit target user, fans durable inbox, then queues '
  'notify-fan-team-member-change. Recipient is never inferred from post-mutation roster. '
  'Snapshots team_name + sport onto payload for Action Center identity after removal.';

-- -----------------------------------------------------------------------------
-- 4) remove_fan_team_member — restore emit with pre-captured p_user_id
-- -----------------------------------------------------------------------------
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
  v_sport text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'User is required.';
  END IF;

  SELECT
    t.group_conversation_id,
    coalesce(nullif(btrim(t.name), ''), 'Team'),
    nullif(btrim(t.sport), '')
  INTO v_conversation_id, v_team_name, v_sport
  FROM public.fan_teams t
  WHERE t.id = p_team_id AND t.is_active = true;

  IF v_conversation_id IS NULL THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  -- Capture target BEFORE left_at. Do not rediscover from roster after delete.
  SELECT m.role INTO v_target_role
  FROM public.fan_team_members m
  WHERE m.team_id = p_team_id
    AND m.user_id = p_user_id
    AND m.left_at IS NULL;

  IF v_target_role IS NULL THEN
    RETURN;
  END IF;

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
  SET left_at = now(),
      role = 'member'
  WHERE conversation_id = v_conversation_id
    AND user_id = p_user_id
    AND left_at IS NULL;

  UPDATE public.fan_teams
  SET updated_at = now()
  WHERE id = p_team_id;

  RAISE NOTICE
    '[FanTeamMemberLeaveDebug] remove_complete team_id=% removed_user_id=% actor=%',
    p_team_id, p_user_id, me;

  -- Explicit p_user_id captured above — never SELECT remaining members.
  PERFORM public.emit_fan_team_member_change_notification(
    p_team_id,
    'removed_from_team',
    me,
    p_user_id,
    jsonb_build_object(
      'team_name', coalesce(v_team_name, 'Team'),
      'sport', coalesce(v_sport, ''),
      'previous_role', v_target_role
    )
  );
END;
$$;

COMMENT ON FUNCTION public.remove_fan_team_member(uuid, uuid) IS
  'STAFF soft-remove of another ACCOUNT member. Captures p_user_id before left_at, then '
  'emits removed_from_team (durable inbox + notify-fan-team-member-change). '
  'Rejects self-removal. Managed seats use remove_fan_team_membership.';

REVOKE ALL ON FUNCTION public.remove_fan_team_member(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.remove_fan_team_member(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_fan_team_member(uuid, uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 5) set_fan_team_member_role — keep emit; snapshot already merged by emit
-- -----------------------------------------------------------------------------
-- Last body is 20260958 (still emits team_role_changed). No rewrite needed
-- beyond emit payload merge. Confirmed actor <> target + OLD vs NEW role.

-- -----------------------------------------------------------------------------
-- 6) Administrator ON/OFF — notify only when the full preset toggles
--     Canonical RPC remains 20260986: set_fan_team_member_permissions(uuid, uuid, text[])
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.set_fan_team_member_permissions(uuid, uuid, jsonb);

CREATE OR REPLACE FUNCTION public.set_fan_team_member_permissions(
  p_team_id uuid,
  p_membership_id uuid,
  p_permissions text[]
)
RETURNS text[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  me uuid := (SELECT auth.uid());
  v_owner uuid;
  v_target_role text;
  v_target_user uuid;
  v_target_managed uuid;
  v_old_custom boolean;
  v_old_granted jsonb;
  v_keys text[];
  v_was_admin boolean;
  v_now_admin boolean;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '42501';
  END IF;
  IF p_team_id IS NULL OR p_membership_id IS NULL THEN
    RAISE EXCEPTION 'Team and membership are required.';
  END IF;

  PERFORM public.assert_rpc_rate_limit('set_fan_team_member_permissions', 60, 3600);

  SELECT t.owner_user_id INTO v_owner
  FROM public.fan_teams t
  WHERE t.id = p_team_id
    AND t.is_active IS TRUE;

  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Team is no longer available.';
  END IF;
  IF v_owner IS DISTINCT FROM me THEN
    RAISE EXCEPTION 'Only the Team Owner can manage permissions.' USING ERRCODE = '42501';
  END IF;

  SELECT
    m.role,
    m.user_id,
    m.managed_player_id,
    coalesce(m.use_custom_permissions, false),
    m.granted_permissions
  INTO
    v_target_role,
    v_target_user,
    v_target_managed,
    v_old_custom,
    v_old_granted
  FROM public.fan_team_members m
  WHERE m.membership_id = p_membership_id
    AND m.team_id = p_team_id
    AND m.left_at IS NULL
  FOR UPDATE;

  IF v_target_role IS NULL THEN
    RAISE EXCEPTION 'Member not found.';
  END IF;
  IF v_target_managed IS NOT NULL THEN
    RAISE EXCEPTION 'Managed player seats do not receive account permissions.';
  END IF;
  IF lower(btrim(v_target_role)) = 'owner' THEN
    RAISE EXCEPTION 'Owner permissions cannot be changed.';
  END IF;
  IF v_target_user IS NOT DISTINCT FROM me THEN
    RAISE EXCEPTION 'Owner permissions cannot be changed.';
  END IF;

  v_keys := public.fan_team_normalize_permission_keys(
    to_jsonb(coalesce(p_permissions, ARRAY[]::text[]))
  );
  v_was_admin := public.fan_team_is_administrator_preset(
    public.fan_team_effective_permissions(
      v_target_role,
      v_old_custom,
      v_old_granted
    )
  );
  v_now_admin := public.fan_team_is_administrator_preset(v_keys);

  UPDATE public.fan_team_members
  SET granted_permissions = to_jsonb(v_keys),
      use_custom_permissions = true
  WHERE membership_id = p_membership_id
    AND left_at IS NULL;

  -- Chat admin from moderate_team_chat. gcm only in SET/WHERE (20260989).
  UPDATE public.group_conversation_members gcm
  SET role = CASE
        WHEN 'moderate_team_chat' = ANY (v_keys) THEN 'admin'
        ELSE 'member'
      END
  FROM public.fan_teams t
  WHERE t.id = p_team_id
    AND gcm.conversation_id = t.group_conversation_id
    AND gcm.user_id = v_target_user;

  IF v_target_user IS NOT NULL AND v_was_admin IS DISTINCT FROM v_now_admin THEN
    PERFORM public.emit_fan_team_member_change_notification(
      p_team_id,
      CASE WHEN v_now_admin THEN 'team_admin_granted' ELSE 'team_admin_removed' END,
      me,
      v_target_user,
      jsonb_build_object(
        'administrator', v_now_admin,
        'previous_administrator', v_was_admin
      )
    );
  END IF;

  RETURN v_keys;
END;
$$;

COMMENT ON FUNCTION public.set_fan_team_member_permissions(uuid, uuid, text[]) IS
  'Owner-only custom permission keys (text[] iOS contract from 20260986). '
  'Emits team_admin_granted / team_admin_removed only when the full Administrator '
  'preset toggles. Does not emit on role changes (set_fan_team_member_role).';

REVOKE ALL ON FUNCTION public.set_fan_team_member_permissions(uuid, uuid, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_fan_team_member_permissions(uuid, uuid, text[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_fan_team_member_permissions(uuid, uuid, text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_fan_team_member_permissions(uuid, uuid, text[]) TO service_role;

DO $$
BEGIN
  IF to_regprocedure('public.set_fan_team_member_permissions(uuid, uuid, text[])') IS NULL THEN
    RAISE EXCEPTION
      '20260990: canonical set_fan_team_member_permissions(uuid, uuid, text[]) missing';
  END IF;
  IF to_regprocedure('public.set_fan_team_member_permissions(uuid, uuid, jsonb)') IS NOT NULL THEN
    RAISE EXCEPTION
      '20260990: obsolete set_fan_team_member_permissions(uuid, uuid, jsonb) must not exist';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 7) Durable inbox fan-out — copy, destination, identity snapshot, dedupe
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fanout_fan_notification_inbox_for_member_change_event(
  p_event_id uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_team_id uuid;
  v_team_name text;
  v_sport text;
  v_recipients uuid[];
  v_change_kind text;
  v_payload jsonb;
  v_uid uuid;
  v_title text;
  v_body text;
  v_dest text;
  v_dedupe text;
  v_role text;
  v_role_label text;
  v_count integer := 0;
BEGIN
  IF p_event_id IS NULL OR to_regclass('public.fan_team_member_change_events') IS NULL THEN
    RETURN 0;
  END IF;

  SELECT
    e.team_id,
    coalesce(e.recipient_user_ids, '{}'::uuid[]),
    lower(btrim(coalesce(e.kind, 'member_change'))),
    coalesce(nullif(btrim(e.team_name), ''), 'Team'),
    coalesce(e.payload, '{}'::jsonb)
  INTO v_team_id, v_recipients, v_change_kind, v_team_name, v_payload
  FROM public.fan_team_member_change_events e
  WHERE e.id = p_event_id;

  IF v_team_id IS NULL THEN
    RETURN 0;
  END IF;

  v_sport := nullif(btrim(coalesce(v_payload->>'sport', '')), '');
  IF v_sport IS NULL THEN
    SELECT nullif(btrim(t.sport), '') INTO v_sport
    FROM public.fan_teams t
    WHERE t.id = v_team_id;
  END IF;

  v_role := nullif(btrim(coalesce(v_payload->>'role', '')), '');
  v_role_label := public.fan_team_role_display_label(v_role);
  v_dest := 'teamsHome';

  CASE v_change_kind
    WHEN 'removed_from_team' THEN
      v_title := 'Removed from Team';
      v_body := 'You are no longer a member of ' || v_team_name || '.';
    WHEN 'team_role_changed' THEN
      v_title := 'Team Role Updated';
      IF lower(coalesce(v_role, 'member')) = 'member' THEN
        v_body := 'Your role on ' || v_team_name || ' is now Member.';
      ELSE
        v_body := 'You''re now a ' || v_role_label || ' for ' || v_team_name || '.';
      END IF;
    WHEN 'team_admin_granted' THEN
      v_title := 'Team Access Updated';
      v_body := 'You can now help manage ' || v_team_name || '.';
    WHEN 'team_admin_removed' THEN
      v_title := 'Team Access Updated';
      v_body := 'Your Team Administrator access for ' || v_team_name || ' was removed.';
    WHEN 'removed_from_event' THEN
      v_title := v_team_name || ' event update';
      v_body := 'Removed from an event';
    WHEN 'added_back_to_event' THEN
      v_title := v_team_name || ' event update';
      v_body := 'Added back to an event';
    WHEN 'player_number_set' THEN
      v_title := v_team_name || ' player information updated';
      v_body := 'Player number updated';
    WHEN 'player_number_changed' THEN
      v_title := v_team_name || ' player information updated';
      v_body := 'Player number updated';
    WHEN 'player_number_removed' THEN
      v_title := v_team_name || ' player information updated';
      v_body := 'Player number removed';
    WHEN 'preferred_position_set' THEN
      v_title := v_team_name || ' player information updated';
      v_body := 'Preferred position updated';
    WHEN 'preferred_position_changed' THEN
      v_title := v_team_name || ' player information updated';
      v_body := 'Preferred position updated';
    WHEN 'preferred_position_removed' THEN
      v_title := v_team_name || ' player information updated';
      v_body := 'Preferred position removed';
    ELSE
      v_title := 'Team Role Updated';
      v_body := 'Your Team membership was updated.';
  END CASE;

  FOREACH v_uid IN ARRAY coalesce(v_recipients, '{}'::uuid[]) LOOP
    IF v_uid IS NULL THEN
      CONTINUE;
    END IF;
    v_dedupe := public.fan_team_member_change_inbox_dedupe_key(
      v_change_kind, v_team_id, v_uid, p_event_id
    );
    IF public.upsert_fan_notification_inbox(
      p_user_id := v_uid,
      p_notification_type := v_change_kind,
      p_title := v_title,
      p_body := v_body,
      p_kind_raw := 'scheduleChange',
      p_destination_raw := v_dest,
      p_deduplication_key := v_dedupe,
      p_source_type := 'member_change',
      p_source_id := p_event_id::text,
      p_team_id := v_team_id,
      p_event_id := p_event_id,
      p_payload := jsonb_build_object(
        'team_id', v_team_id,
        'event_id', p_event_id,
        'change_kind', v_change_kind,
        'team_name', v_team_name,
        'sport', coalesce(v_sport, ''),
        'role', coalesce(v_role, ''),
        'previous_role', coalesce(v_payload->>'previous_role', ''),
        'administrator', v_payload->'administrator',
        'deduplication_key', v_dedupe,
        'safe_destination', v_dest
      )
    ) IS NOT NULL THEN
      v_count := v_count + 1;
    END IF;
  END LOOP;

  RAISE LOG
    '[FanTeamMemberChangeDebug] inbox_fanout event=% kind=% team=% recipients=% inserted=% dest=%',
    p_event_id, v_change_kind, v_team_id, cardinality(v_recipients), v_count, v_dest;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.fanout_fan_notification_inbox_for_member_change_event(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fanout_fan_notification_inbox_for_member_change_event(uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 8) Dual-key APNs queue (inbox hook already wraps this as of 20260983)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.queue_fan_team_member_change_push_notification_apns(
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
  WHERE name IN ('fangeo_service_role_key', 'SUPABASE_SERVICE_ROLE_KEY')
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY CASE name WHEN 'fangeo_service_role_key' THEN 0 ELSE 1 END
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

  -- Dual-key: same Vault value on Bearer + apikey (20260988 class).
  v_headers := jsonb_build_object(
    'Content-Type', 'application/json',
    'Authorization', 'Bearer ' || v_service_role_key,
    'apikey', v_service_role_key
  );
  IF v_cron_secret IS NOT NULL THEN
    v_headers := v_headers || jsonb_build_object(
      'x-cron-secret', v_cron_secret,
      'x-fangeo-cron-secret', v_cron_secret
    );
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

COMMENT ON FUNCTION public.queue_fan_team_member_change_push_notification_apns(uuid) IS
  'pg_net POST to notify-fan-team-member-change with dual-key Bearer+apikey. '
  'Pre-inserts delivery ledger. Independent of durable inbox success.';

REVOKE ALL ON FUNCTION public.queue_fan_team_member_change_push_notification_apns(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.queue_fan_team_member_change_push_notification_apns(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.queue_fan_team_member_change_push_notification_apns(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.queue_fan_team_member_change_push_notification_apns(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.queue_fan_team_member_change_push_notification(p_event_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  BEGIN
    PERFORM public.fanout_fan_notification_inbox_for_member_change_event(p_event_id);
  EXCEPTION WHEN OTHERS THEN
    RAISE LOG '[FanNotificationInbox] memberChangeFanoutFailed event=% err=%', p_event_id, SQLERRM;
  END;
  PERFORM public.queue_fan_team_member_change_push_notification_apns(p_event_id);
END;
$$;

COMMENT ON FUNCTION public.queue_fan_team_member_change_push_notification(uuid) IS
  'Durable inbox fan-out first, then dual-key pg_net invoke of notify-fan-team-member-change.';

REVOKE ALL ON FUNCTION public.queue_fan_team_member_change_push_notification(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.queue_fan_team_member_change_push_notification(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.queue_fan_team_member_change_push_notification(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.queue_fan_team_member_change_push_notification(uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 9) upsert destination whitelist — teamsHome must not collapse to scheduleActivity
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.upsert_fan_notification_inbox(
  p_user_id uuid,
  p_notification_type text,
  p_title text,
  p_body text,
  p_kind_raw text,
  p_destination_raw text,
  p_deduplication_key text,
  p_source_type text DEFAULT NULL,
  p_source_id text DEFAULT NULL,
  p_team_id uuid DEFAULT NULL,
  p_event_id uuid DEFAULT NULL,
  p_actor_user_id uuid DEFAULT NULL,
  p_payload jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_id uuid;
  v_key text;
  v_title text;
  v_body text;
  v_kind text;
  v_dest text;
  v_type text;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_key := lower(btrim(coalesce(p_deduplication_key, '')));
  v_key := regexp_replace(v_key, '[^a-z0-9_\-:\.]', '', 'g');
  IF v_key = '' THEN
    RETURN NULL;
  END IF;
  IF char_length(v_key) > 180 THEN
    v_key := left(v_key, 180);
  END IF;

  v_title := nullif(btrim(coalesce(p_title, '')), '');
  IF v_title IS NULL THEN
    RETURN NULL;
  END IF;
  v_body := coalesce(btrim(p_body), '');
  v_type := lower(btrim(coalesce(p_notification_type, 'schedule_change')));
  IF v_type = '' THEN
    v_type := 'schedule_change';
  END IF;
  v_kind := CASE lower(btrim(coalesce(p_kind_raw, '')))
    WHEN 'eventcancellation' THEN 'eventCancellation'
    WHEN 'event_cancellation' THEN 'eventCancellation'
    WHEN 'poke' THEN 'poke'
    ELSE 'scheduleChange'
  END;
  v_dest := CASE lower(btrim(coalesce(p_destination_raw, '')))
    WHEN 'teamshome' THEN 'teamsHome'
    WHEN 'teams_home' THEN 'teamsHome'
    WHEN 'my_teams' THEN 'teamsHome'
    WHEN 'teamsinvites' THEN 'teamsInvites'
    WHEN 'teams_invites' THEN 'teamsInvites'
    WHEN 'accountpokes' THEN 'accountPokes'
    WHEN 'account_pokes' THEN 'accountPokes'
    WHEN 'chatfriendrequests' THEN 'chatFriendRequests'
    WHEN 'chat_friend_requests' THEN 'chatFriendRequests'
    WHEN 'chatunread' THEN 'chatUnread'
    WHEN 'goingpickupinvites' THEN 'goingPickupInvites'
    WHEN 'goinghostingapprovals' THEN 'goingHostingApprovals'
    WHEN 'goingpendingrating' THEN 'goingPendingRating'
    WHEN 'accountbusinessclaim' THEN 'accountBusinessClaim'
    WHEN 'scheduleactivity' THEN 'scheduleActivity'
    WHEN 'schedule_activity' THEN 'scheduleActivity'
    ELSE 'scheduleActivity'
  END;

  INSERT INTO public.fan_notification_inbox AS i (
    user_id,
    notification_type,
    title,
    body,
    kind_raw,
    destination_raw,
    source_type,
    source_id,
    team_id,
    event_id,
    actor_user_id,
    payload,
    deduplication_key
  ) VALUES (
    p_user_id,
    v_type,
    left(v_title, 240),
    left(v_body, 500),
    v_kind,
    v_dest,
    nullif(btrim(coalesce(p_source_type, '')), ''),
    nullif(btrim(coalesce(p_source_id, '')), ''),
    p_team_id,
    p_event_id,
    p_actor_user_id,
    coalesce(p_payload, '{}'::jsonb),
    v_key
  )
  ON CONFLICT (user_id, deduplication_key) DO UPDATE
    SET
      title = EXCLUDED.title,
      body = EXCLUDED.body,
      notification_type = EXCLUDED.notification_type,
      kind_raw = EXCLUDED.kind_raw,
      destination_raw = EXCLUDED.destination_raw,
      source_type = EXCLUDED.source_type,
      source_id = EXCLUDED.source_id,
      team_id = COALESCE(EXCLUDED.team_id, i.team_id),
      event_id = COALESCE(EXCLUDED.event_id, i.event_id),
      actor_user_id = COALESCE(EXCLUDED.actor_user_id, i.actor_user_id),
      payload = EXCLUDED.payload
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_fan_notification_inbox(
  uuid, text, text, text, text, text, text, text, text, uuid, uuid, uuid, jsonb
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.upsert_fan_notification_inbox(
  uuid, text, text, text, text, text, text, text, text, uuid, uuid, uuid, jsonb
) FROM anon;
REVOKE ALL ON FUNCTION public.upsert_fan_notification_inbox(
  uuid, text, text, text, text, text, text, text, text, uuid, uuid, uuid, jsonb
) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_fan_notification_inbox(
  uuid, text, text, text, text, text, text, text, text, uuid, uuid, uuid, jsonb
) TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
