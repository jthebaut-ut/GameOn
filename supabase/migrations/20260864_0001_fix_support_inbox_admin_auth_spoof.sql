-- Fix confirmed production admin authorization spoofing.
--
-- Before: is_support_inbox_admin(p_admin_email) preferred caller-supplied email over JWT,
-- allowing any authenticated (or anon, if EXECUTE was granted) client to pass
-- anything@fangeosports.com and pass the admin gate.
--
-- After: p_admin_email is DEPRECATED and IGNORED for authorization. Trusted identity is:
--   - auth.uid() + verified JWT email ending in @fangeosports.com, OR
--   - service_role (server-side only)
-- Audit/actor email metadata also uses JWT (or 'service_role'), never the RPC parameter.
--
-- Signatures retaining p_admin_email are preserved for iOS Admin Dashboard compatibility.
-- Do NOT apply this migration from the agent; review and apply deliberately.

-- ---------------------------------------------------------------------------
-- 1) Trusted admin gate (parameter ignored)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.is_support_inbox_admin(p_admin_email text DEFAULT NULL)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  -- p_admin_email is intentionally unused (deprecated; client-spoofable).
  SELECT CASE
    WHEN COALESCE(auth.role(), '') = 'service_role' THEN true
    WHEN auth.uid() IS NULL THEN false
    ELSE (
      NULLIF(lower(btrim(coalesce(auth.jwt() ->> 'email', ''))), '')
        LIKE '%@fangeosports.com'
    )
  END;
$$;

COMMENT ON FUNCTION public.is_support_inbox_admin(text) IS
  'Returns true only for service_role or an authenticated JWT whose email ends with @fangeosports.com. '
  'Parameter p_admin_email is DEPRECATED and IGNORED for authorization (never trust client-supplied admin identity).';

-- Actor email for audit / message metadata (JWT only; never p_admin_email).
CREATE OR REPLACE FUNCTION public.support_inbox_admin_actor_email()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    NULLIF(lower(btrim(coalesce(auth.jwt() ->> 'email', ''))), ''),
    CASE WHEN COALESCE(auth.role(), '') = 'service_role' THEN 'service_role' ELSE NULL END
  );
$$;

COMMENT ON FUNCTION public.support_inbox_admin_actor_email() IS
  'Trusted admin actor email from JWT (or service_role label). Never accepts client-supplied email.';

REVOKE ALL ON FUNCTION public.support_inbox_admin_actor_email() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.support_inbox_admin_actor_email() FROM anon;
GRANT EXECUTE ON FUNCTION public.support_inbox_admin_actor_email() TO authenticated;
GRANT EXECUTE ON FUNCTION public.support_inbox_admin_actor_email() TO service_role;

-- ---------------------------------------------------------------------------
-- 2) Support inbox RPCs — trusted check + JWT actor metadata
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_list_support_conversations(
  p_admin_email text DEFAULT NULL,
  p_limit integer DEFAULT 50
)
RETURNS TABLE (
  id uuid,
  user_id uuid,
  status text,
  subject text,
  issue_type text,
  chat_opened_at timestamptz,
  last_message_at timestamptz,
  last_user_message_at timestamptz,
  last_support_message_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz,
  last_message_body text,
  last_message_sender_kind text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
BEGIN
  -- p_admin_email ignored (deprecated).
  IF NOT public.is_support_inbox_admin() THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  RETURN QUERY
  SELECT
    sc.id,
    sc.user_id,
    sc.status,
    sc.subject,
    sc.issue_type,
    sc.chat_opened_at,
    sc.last_message_at,
    sc.last_user_message_at,
    sc.last_support_message_at,
    sc.created_at,
    sc.updated_at,
    lm.body AS last_message_body,
    lm.sender_kind AS last_message_sender_kind
  FROM public.support_conversations sc
  LEFT JOIN LATERAL (
    SELECT sm.body, sm.sender_kind
    FROM public.support_messages sm
    WHERE sm.conversation_id = sc.id
      AND sm.deleted_at IS NULL
    ORDER BY sm.created_at DESC, sm.id DESC
    LIMIT 1
  ) lm ON true
  ORDER BY COALESCE(sc.last_message_at, sc.updated_at, sc.created_at) DESC
  LIMIT v_limit;
END;
$$;

COMMENT ON FUNCTION public.admin_list_support_conversations(text, integer) IS
  'Admin support inbox list. Auth via is_support_inbox_admin() (JWT/service_role). p_admin_email deprecated/ignored.';

CREATE OR REPLACE FUNCTION public.admin_fetch_support_messages(
  p_conversation_id uuid,
  p_admin_email text DEFAULT NULL,
  p_limit integer DEFAULT 100
)
RETURNS TABLE (
  id uuid,
  conversation_id uuid,
  sender_kind text,
  sender_auth_user_id uuid,
  body text,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 200);
BEGIN
  IF NOT public.is_support_inbox_admin() THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF p_conversation_id IS NULL THEN
    RAISE EXCEPTION 'conversation not found';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.support_conversations sc
    WHERE sc.id = p_conversation_id
  ) THEN
    RAISE EXCEPTION 'conversation not found';
  END IF;

  RETURN QUERY
  SELECT
    sm.id,
    sm.conversation_id,
    sm.sender_kind,
    sm.sender_auth_user_id,
    sm.body,
    sm.created_at
  FROM public.support_messages sm
  WHERE sm.conversation_id = p_conversation_id
    AND sm.deleted_at IS NULL
  ORDER BY sm.created_at ASC, sm.id ASC
  LIMIT v_limit;
END;
$$;

COMMENT ON FUNCTION public.admin_fetch_support_messages(uuid, text, integer) IS
  'Admin support message fetch. Auth via is_support_inbox_admin(). p_admin_email deprecated/ignored.';

CREATE OR REPLACE FUNCTION public.admin_open_support_chat(
  p_conversation_id uuid,
  p_admin_email text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_support_inbox_admin() THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF p_conversation_id IS NULL THEN
    RAISE EXCEPTION 'conversation not found';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.support_conversations sc
    WHERE sc.id = p_conversation_id
  ) THEN
    RAISE EXCEPTION 'conversation not found';
  END IF;

  UPDATE public.support_conversations sc
  SET
    chat_opened_at = COALESCE(sc.chat_opened_at, now()),
    status = 'open',
    updated_at = now()
  WHERE sc.id = p_conversation_id;

  RETURN p_conversation_id;
END;
$$;

COMMENT ON FUNCTION public.admin_open_support_chat(uuid, text) IS
  'Opens support chat for a ticket. Auth via is_support_inbox_admin(). p_admin_email deprecated/ignored.';

CREATE OR REPLACE FUNCTION public.admin_send_support_message(
  p_conversation_id uuid,
  p_body text,
  p_admin_email text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_email text;
  v_body text;
  v_message_id uuid;
BEGIN
  IF NOT public.is_support_inbox_admin() THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  -- Trusted actor email from JWT only (p_admin_email ignored).
  v_admin_email := public.support_inbox_admin_actor_email();

  v_body := btrim(coalesce(p_body, ''));
  IF char_length(v_body) = 0 OR char_length(v_body) > 4000 THEN
    RAISE EXCEPTION 'invalid message body';
  END IF;

  IF p_conversation_id IS NULL THEN
    RAISE EXCEPTION 'conversation not found';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.support_conversations sc
    WHERE sc.id = p_conversation_id
  ) THEN
    RAISE EXCEPTION 'conversation not found';
  END IF;

  UPDATE public.support_conversations sc
  SET
    chat_opened_at = COALESCE(sc.chat_opened_at, now()),
    status = 'open',
    updated_at = now()
  WHERE sc.id = p_conversation_id
    AND sc.status = 'closed';

  INSERT INTO public.support_messages (
    conversation_id,
    sender_kind,
    admin_email,
    body
  )
  VALUES (
    p_conversation_id,
    'support',
    v_admin_email,
    v_body
  )
  RETURNING id INTO v_message_id;

  PERFORM public.queue_support_reply_push_notification(p_conversation_id, v_message_id);

  RETURN v_message_id;
END;
$$;

COMMENT ON FUNCTION public.admin_send_support_message(uuid, text, text) IS
  'Admin support reply. Auth via is_support_inbox_admin(); admin_email metadata from JWT. p_admin_email deprecated/ignored.';

-- ---------------------------------------------------------------------------
-- 3) Announcement / FanGeo+ / Business Pro award RPCs
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_send_fangeo_announcement_push(
  p_announcement_id uuid,
  p_admin_email text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_support_inbox_admin() THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF p_announcement_id IS NULL THEN
    RAISE EXCEPTION 'missing announcement id';
  END IF;

  PERFORM public.queue_fangeo_announcement_push_notification(p_announcement_id);
END;
$$;

COMMENT ON FUNCTION public.admin_send_fangeo_announcement_push(uuid, text) IS
  'Admin-triggered FanGeo announcement push. Auth via is_support_inbox_admin(). p_admin_email deprecated/ignored.';

CREATE OR REPLACE FUNCTION public.admin_set_user_fangeo_plus(
  p_user_id uuid,
  p_enabled boolean,
  p_admin_email text DEFAULT NULL,
  p_expires_at timestamptz DEFAULT NULL,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_email text;
  v_before public.user_profiles%ROWTYPE;
  v_after public.user_profiles%ROWTYPE;
  v_before_enabled boolean;
  v_before_expires timestamptz;
  v_next_expires timestamptz;
  v_change_kind text;
  v_audit_id uuid;
  v_award_event_id uuid;
  v_action text;
  v_reason text;
BEGIN
  IF NOT public.is_support_inbox_admin() THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'missing user id';
  END IF;

  IF p_enabled IS NULL THEN
    RAISE EXCEPTION 'missing enabled flag';
  END IF;

  v_admin_email := public.support_inbox_admin_actor_email();

  SELECT *
  INTO v_before
  FROM public.user_profiles
  WHERE id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'user profile was not found';
  END IF;

  v_before_enabled := coalesce(v_before.ad_free_enabled, false);
  v_before_expires := v_before.ad_free_expires_at;

  IF p_enabled THEN
    v_next_expires := p_expires_at;
  ELSE
    v_next_expires := NULL;
  END IF;

  IF v_before_enabled IS NOT DISTINCT FROM p_enabled
     AND v_before_expires IS NOT DISTINCT FROM v_next_expires THEN
    RETURN jsonb_build_object(
      'ok', true,
      'changed', false,
      'notified', false,
      'ad_free_enabled', v_before_enabled,
      'ad_free_expires_at', to_jsonb(v_before_expires),
      'change_kind', NULL,
      'award_event_id', NULL,
      'audit_log_id', NULL,
      'message', CASE
        WHEN p_enabled THEN 'This user already has FanGeo+ enabled with the same expiration.'
        ELSE 'This user is already a Regular user.'
      END
    );
  END IF;

  IF p_enabled AND NOT v_before_enabled THEN
    v_change_kind := 'grant';
  ELSIF p_enabled AND v_before_enabled AND v_before_expires IS DISTINCT FROM v_next_expires THEN
    v_change_kind := 'extension';
  ELSE
    v_change_kind := NULL;
  END IF;

  UPDATE public.user_profiles
  SET
    ad_free_enabled = p_enabled,
    ad_free_expires_at = v_next_expires
  WHERE id = p_user_id
  RETURNING * INTO v_after;

  v_action := CASE
    WHEN p_enabled AND v_change_kind = 'extension' THEN 'extend_user_fangeo_plus'
    WHEN p_enabled THEN 'enable_user_fangeo_plus'
    ELSE 'disable_user_fangeo_plus'
  END;

  v_reason := NULLIF(btrim(coalesce(p_reason, '')), '');
  IF v_reason IS NULL THEN
    v_reason := CASE
      WHEN v_change_kind = 'extension' THEN 'Manual FanGeo+ extension'
      WHEN p_enabled THEN 'Manual FanGeo+ enable'
      ELSE 'Manual FanGeo+ removal'
    END;
  END IF;

  INSERT INTO public.admin_audit_logs (
    admin_email,
    action,
    target_type,
    target_id,
    before_data,
    after_data,
    reason
  )
  VALUES (
    coalesce(v_admin_email, 'unknown'),
    v_action,
    'user',
    p_user_id::text,
    jsonb_build_object(
      'user', jsonb_build_object(
        'id', v_before.id,
        'email', v_before.email,
        'display_name', v_before.display_name,
        'ad_free_enabled', v_before.ad_free_enabled,
        'ad_free_expires_at', v_before.ad_free_expires_at
      )
    ),
    jsonb_build_object(
      'user', jsonb_build_object(
        'id', v_after.id,
        'email', v_after.email,
        'display_name', v_after.display_name,
        'ad_free_enabled', v_after.ad_free_enabled,
        'ad_free_expires_at', v_after.ad_free_expires_at
      )
    ),
    v_reason
  )
  RETURNING id INTO v_audit_id;

  IF v_change_kind IS NOT NULL THEN
    INSERT INTO public.fangeo_plus_award_push_events (
      user_id,
      audit_log_id,
      change_kind,
      entitlement_source,
      expires_at,
      admin_email
    )
    VALUES (
      p_user_id,
      v_audit_id,
      v_change_kind,
      'admin_manual',
      v_after.ad_free_expires_at,
      v_admin_email
    )
    RETURNING id INTO v_award_event_id;

    PERFORM public.queue_fangeo_plus_award_push_notification(v_award_event_id);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'changed', true,
    'notified', v_award_event_id IS NOT NULL,
    'ad_free_enabled', v_after.ad_free_enabled,
    'ad_free_expires_at', to_jsonb(v_after.ad_free_expires_at),
    'change_kind', to_jsonb(v_change_kind),
    'award_event_id', to_jsonb(v_award_event_id),
    'audit_log_id', to_jsonb(v_audit_id),
    'message', CASE
      WHEN v_change_kind = 'extension' THEN 'FanGeo+ extended for this user. Award notification queued.'
      WHEN p_enabled THEN 'FanGeo+ enabled for this user. Award notification queued.'
      ELSE 'FanGeo+ removed from this user.'
    END
  );
END;
$$;

COMMENT ON FUNCTION public.admin_set_user_fangeo_plus(uuid, boolean, text, timestamptz, text) IS
  'Admin FanGeo+ grant/remove/extend. Auth via is_support_inbox_admin(); audit email from JWT. p_admin_email deprecated/ignored.';

CREATE OR REPLACE FUNCTION public.admin_enqueue_business_pro_award_push(
  p_business_id uuid,
  p_audit_log_id uuid,
  p_change_kind text,
  p_admin_email text DEFAULT NULL,
  p_expires_at timestamptz DEFAULT NULL,
  p_entitlement_source text DEFAULT 'admin_manual'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_email text;
  v_business public.businesses%ROWTYPE;
  v_change_kind text;
  v_source text;
  v_event_id uuid;
  v_existing_id uuid;
BEGIN
  IF NOT public.is_support_inbox_admin() THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF p_business_id IS NULL THEN
    RAISE EXCEPTION 'missing business id';
  END IF;

  IF p_audit_log_id IS NULL THEN
    RAISE EXCEPTION 'missing audit log id';
  END IF;

  v_change_kind := lower(btrim(coalesce(p_change_kind, '')));
  IF v_change_kind NOT IN ('grant', 'extension') THEN
    RAISE EXCEPTION 'invalid change kind';
  END IF;

  v_admin_email := public.support_inbox_admin_actor_email();

  v_source := NULLIF(btrim(coalesce(p_entitlement_source, '')), '');
  IF v_source IS NULL THEN
    v_source := 'admin_manual';
  END IF;

  SELECT id
  INTO v_existing_id
  FROM public.business_pro_award_push_events
  WHERE audit_log_id = p_audit_log_id
  LIMIT 1;

  IF v_existing_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'queued', false,
      'skipped', true,
      'reason', 'already_enqueued',
      'award_event_id', v_existing_id
    );
  END IF;

  SELECT *
  INTO v_business
  FROM public.businesses
  WHERE id = p_business_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'business was not found';
  END IF;

  INSERT INTO public.business_pro_award_push_events (
    business_id,
    owner_user_id,
    audit_log_id,
    change_kind,
    entitlement_source,
    expires_at,
    business_name,
    admin_email,
    skip_reason
  )
  VALUES (
    p_business_id,
    v_business.owner_user_id,
    p_audit_log_id,
    v_change_kind,
    v_source,
    p_expires_at,
    NULLIF(btrim(coalesce(v_business.display_name, '')), ''),
    v_admin_email,
    CASE
      WHEN v_business.owner_user_id IS NULL THEN 'missing_owner_user_id'
      ELSE NULL
    END
  )
  RETURNING id INTO v_event_id;

  IF v_business.owner_user_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'queued', false,
      'skipped', true,
      'reason', 'missing_owner_user_id',
      'award_event_id', v_event_id
    );
  END IF;

  PERFORM public.queue_business_pro_award_push_notification(v_event_id);

  RETURN jsonb_build_object(
    'ok', true,
    'queued', true,
    'skipped', false,
    'reason', NULL,
    'award_event_id', v_event_id
  );
END;
$$;

COMMENT ON FUNCTION public.admin_enqueue_business_pro_award_push(uuid, uuid, text, text, timestamptz, text) IS
  'Enqueue Business Pro award push. Auth via is_support_inbox_admin(); admin_email from JWT. p_admin_email deprecated/ignored.';

-- ---------------------------------------------------------------------------
-- 4) Grants — revoke anon/PUBLIC; keep authenticated (with internal check) + service_role
-- ---------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.is_support_inbox_admin(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_support_inbox_admin(text) FROM anon;
REVOKE ALL ON FUNCTION public.is_support_inbox_admin(text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.is_support_inbox_admin(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_support_inbox_admin(text) TO service_role;

REVOKE ALL ON FUNCTION public.admin_list_support_conversations(text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_list_support_conversations(text, integer) FROM anon;
REVOKE ALL ON FUNCTION public.admin_list_support_conversations(text, integer) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_support_conversations(text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_support_conversations(text, integer) TO service_role;

REVOKE ALL ON FUNCTION public.admin_fetch_support_messages(uuid, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_fetch_support_messages(uuid, text, integer) FROM anon;
REVOKE ALL ON FUNCTION public.admin_fetch_support_messages(uuid, text, integer) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_fetch_support_messages(uuid, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_fetch_support_messages(uuid, text, integer) TO service_role;

REVOKE ALL ON FUNCTION public.admin_open_support_chat(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_open_support_chat(uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.admin_open_support_chat(uuid, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_open_support_chat(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_open_support_chat(uuid, text) TO service_role;

REVOKE ALL ON FUNCTION public.admin_send_support_message(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_send_support_message(uuid, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.admin_send_support_message(uuid, text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_send_support_message(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_send_support_message(uuid, text, text) TO service_role;

REVOKE ALL ON FUNCTION public.admin_send_fangeo_announcement_push(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_send_fangeo_announcement_push(uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.admin_send_fangeo_announcement_push(uuid, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_send_fangeo_announcement_push(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_send_fangeo_announcement_push(uuid, text) TO service_role;

REVOKE ALL ON FUNCTION public.admin_set_user_fangeo_plus(uuid, boolean, text, timestamptz, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_set_user_fangeo_plus(uuid, boolean, text, timestamptz, text) FROM anon;
REVOKE ALL ON FUNCTION public.admin_set_user_fangeo_plus(uuid, boolean, text, timestamptz, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_user_fangeo_plus(uuid, boolean, text, timestamptz, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_user_fangeo_plus(uuid, boolean, text, timestamptz, text) TO service_role;

REVOKE ALL ON FUNCTION public.admin_enqueue_business_pro_award_push(uuid, uuid, text, text, timestamptz, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_enqueue_business_pro_award_push(uuid, uuid, text, text, timestamptz, text) FROM anon;
REVOKE ALL ON FUNCTION public.admin_enqueue_business_pro_award_push(uuid, uuid, text, text, timestamptz, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_enqueue_business_pro_award_push(uuid, uuid, text, text, timestamptz, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_enqueue_business_pro_award_push(uuid, uuid, text, text, timestamptz, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 5) Read-only validation queries (run after apply; do not mutate)
-- ---------------------------------------------------------------------------
--
-- -- Final helper definition:
-- SELECT pg_get_functiondef('public.is_support_inbox_admin(text)'::regprocedure);
--
-- -- Privileges (anon must be absent):
-- SELECT routine_name, grantee, privilege_type
-- FROM information_schema.routine_privileges
-- WHERE routine_schema = 'public'
--   AND routine_name IN (
--     'is_support_inbox_admin',
--     'support_inbox_admin_actor_email',
--     'admin_list_support_conversations',
--     'admin_fetch_support_messages',
--     'admin_open_support_chat',
--     'admin_send_support_message',
--     'admin_send_fangeo_announcement_push',
--     'admin_set_user_fangeo_plus',
--     'admin_enqueue_business_pro_award_push'
--   )
-- ORDER BY routine_name, grantee;
--
-- -- Spoof string must not appear in authorization path of helper:
-- SELECT pg_get_functiondef('public.is_support_inbox_admin(text)'::regprocedure)
--   NOT LIKE '%p_admin_email%' AS param_unused_in_body_check;
-- -- (Body may still mention deprecated in COMMENT; definition SELECT should not
-- --  coalesce p_admin_email into the authorization expression.)
--
-- -- Staging behavioral tests (staging project only):
-- -- A) As normal authenticated user (non-@fangeosports.com JWT):
-- --    SELECT public.is_support_inbox_admin('spoof@fangeosports.com');  -- expect false
-- --    SELECT public.admin_list_support_conversations('spoof@fangeosports.com', 1);
-- --      -- expect not authorized
-- -- B) As real @fangeosports.com JWT:
-- --    SELECT public.is_support_inbox_admin('ignored@example.com');  -- expect true
-- --    SELECT public.admin_list_support_conversations('ignored@example.com', 1);
-- --      -- expect success
-- -- C) As anon key: EXECUTE should fail (permission denied) or return false if somehow callable.
