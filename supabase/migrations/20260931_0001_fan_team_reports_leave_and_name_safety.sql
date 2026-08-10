-- =============================================================================
-- 20260931_0001 — Fan Team safety: reports, leave, name filter, admin helpers
-- =============================================================================
-- Extends FanGeo's existing moderation architecture (mirrors group_conversation_reports).
-- Does NOT create a parallel moderation universe.
--
-- Adds:
--   • fan_team_reports + report_fan_team RPC (auth.uid() reporter; no owner visibility)
--   • RPC-only writes: authenticated SELECT own reports; NO direct INSERT/UPDATE/DELETE
--   • leave_fan_team RPC (non-owner soft-leave of Team + linked Team Chat)
--   • Team name objectionable-term trigger (create/rename)
--   • service_role admin helpers: deactivate Team, clear logo (+ admin_audit_logs)
--   • email queue: ADDITIVE fan_team type (preserves group_conversation + group_message)
--   • rate-limit buckets: report_fan_team, leave_fan_team (preserves prior buckets + cleanup)
--
-- Prerequisites:
--   20260926 fan_teams, 20260929 invitations, 20260930 pending counts (optional),
--   group report email queue helper (20260859) preferred for notify path.
--
-- Do NOT apply from the agent. Review and apply deliberately.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Objectionable Team-name helper + trigger
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gameon_contains_disallowed_ugc_term(p_text text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
DECLARE
  v text := lower(regexp_replace(coalesce(p_text, ''), '[^a-z0-9]+', '', 'g'));
  v_needles text[] := ARRAY[
    'fuck', 'shit', 'bitch', 'bastard', 'asshole', 'motherfucker', 'bullshit',
    'dickhead', 'cocksuck', 'douchebag', 'faggot', 'nigger', 'nigga', 'spic',
    'chink', 'kike', 'wetback', 'retard', 'slut', 'whore', 'cumshot', 'blowjob'
  ];
  n text;
BEGIN
  IF v IS NULL OR v = '' THEN
    RETURN false;
  END IF;
  FOREACH n IN ARRAY v_needles LOOP
    IF position(n IN v) > 0 THEN
      RETURN true;
    END IF;
  END LOOP;
  RETURN false;
END;
$$;

COMMENT ON FUNCTION public.gameon_contains_disallowed_ugc_term(text) IS
  'Lightweight UGC term scan for Team names (and similar short labels). Not exhaustive; complements client ModerationService.containsProfanity.';

REVOKE ALL ON FUNCTION public.gameon_contains_disallowed_ugc_term(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gameon_contains_disallowed_ugc_term(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gameon_contains_disallowed_ugc_term(text) TO service_role;

CREATE OR REPLACE FUNCTION public.fan_teams_assert_name_allowed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.name IS NULL OR btrim(NEW.name) = '' THEN
    RAISE EXCEPTION 'Team name is required.';
  END IF;
  IF public.gameon_contains_disallowed_ugc_term(NEW.name) THEN
    RAISE EXCEPTION 'That Team name isn’t allowed on FanGeo.';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_fan_teams_assert_name_allowed ON public.fan_teams;
CREATE TRIGGER trg_fan_teams_assert_name_allowed
  BEFORE INSERT OR UPDATE OF name ON public.fan_teams
  FOR EACH ROW
  EXECUTE FUNCTION public.fan_teams_assert_name_allowed();

-- ---------------------------------------------------------------------------
-- 2) fan_team_reports
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.fan_team_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id uuid NOT NULL REFERENCES public.fan_teams (id) ON DELETE CASCADE,
  reporter_user_id uuid NOT NULL REFERENCES auth.users (id),
  owner_user_id uuid NOT NULL REFERENCES auth.users (id),
  category text NOT NULL,
  details text,
  team_name_snapshot text,
  team_logo_url_snapshot text,
  team_sport_snapshot text,
  member_count_snapshot integer,
  status text NOT NULL DEFAULT 'open'
    CHECK (status IN ('open', 'closed', 'actioned')),
  admin_resolution_status text
    CHECK (
      admin_resolution_status IS NULL
      OR admin_resolution_status IN ('open', 'resolved', 'dismissed', 'escalated')
    ),
  moderation_notified_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fan_team_reports_category_ck
    CHECK (
      category IN (
        'harassment',
        'hate',
        'spam',
        'inappropriate',
        'violence',
        'fake_account',
        'team_identity',
        'other'
      )
    ),
  CONSTRAINT fan_team_reports_details_len_ck
    CHECK (details IS NULL OR char_length(details) <= 1000)
);

COMMENT ON TABLE public.fan_team_reports IS
  'Team-level UGC reports (name/logo/identity/abuse). Reporter identity is never exposed to Team owners/managers.';

CREATE INDEX IF NOT EXISTS fan_team_reports_open_idx
  ON public.fan_team_reports (status, created_at DESC)
  WHERE status = 'open';

CREATE INDEX IF NOT EXISTS fan_team_reports_team_idx
  ON public.fan_team_reports (team_id, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS fan_team_reports_one_open_per_reporter
  ON public.fan_team_reports (reporter_user_id, team_id)
  WHERE status = 'open';

ALTER TABLE public.fan_team_reports ENABLE ROW LEVEL SECURITY;

-- RPC-only writes: report_fan_team (SECURITY DEFINER) is the sole authenticated
-- creation path. Direct INSERT would allow spoofing owner_user_id / snapshots.
DROP POLICY IF EXISTS "fan_team_reports_insert_own" ON public.fan_team_reports;

-- Reporters may SELECT only their own submitted reports.
-- Owners/managers have ZERO select access to others' reports.
-- No UPDATE/DELETE policies for authenticated clients.
DROP POLICY IF EXISTS "fan_team_reports_select_own" ON public.fan_team_reports;
CREATE POLICY "fan_team_reports_select_own"
  ON public.fan_team_reports FOR SELECT
  TO authenticated
  USING (reporter_user_id = auth.uid());

REVOKE ALL ON TABLE public.fan_team_reports FROM PUBLIC;
REVOKE ALL ON TABLE public.fan_team_reports FROM anon;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.fan_team_reports FROM authenticated;
GRANT SELECT ON TABLE public.fan_team_reports TO authenticated;
GRANT ALL ON TABLE public.fan_team_reports TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Rate-limit allowlist (+ report_fan_team / leave_fan_team)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_rpc_rate_limit(
  p_bucket text,
  p_max int,
  p_window_seconds int
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_bucket text := nullif(btrim(coalesce(p_bucket, '')), '');
  v_window_start timestamptz;
  v_count int;
  v_allowed_buckets text[] := ARRAY[
    'send_direct_message',
    'send_group_message',
    'friendship_ensure_pending',
    'poke_profile',
    'report_group_message',
    'search_chat_conversations',
    'search_chat_messages',
    'create_fan_team',
    'invite_fan_team_members',
    'accept_fan_team_invitation',
    'decline_fan_team_invitation',
    'report_fan_team',
    'leave_fan_team'
  ];
BEGIN
  IF coalesce(auth.role(), '') = 'service_role' AND me IS NULL THEN
    RETURN;
  END IF;

  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  IF v_bucket IS NULL OR NOT (v_bucket = ANY (v_allowed_buckets)) THEN
    RAISE EXCEPTION 'rate limit rejected' USING ERRCODE = '22023';
  END IF;

  IF p_max IS NULL OR p_max < 1 OR p_max > 100000 THEN
    RAISE EXCEPTION 'rate limit rejected' USING ERRCODE = '22023';
  END IF;

  IF p_window_seconds IS NULL OR p_window_seconds < 1 OR p_window_seconds > 86400 THEN
    RAISE EXCEPTION 'rate limit rejected' USING ERRCODE = '22023';
  END IF;

  v_window_start := to_timestamp(
    floor(extract(epoch FROM now()) / p_window_seconds::double precision)
      * p_window_seconds::double precision
  );

  INSERT INTO public.rpc_rate_limits AS r (actor_uid, bucket, window_start, count)
  VALUES (me, v_bucket, v_window_start, 1)
  ON CONFLICT (actor_uid, bucket, window_start)
  DO UPDATE SET count = LEAST(r.count + 1, 1000000)
  RETURNING r.count INTO v_count;

  IF v_count > p_max THEN
    RAISE EXCEPTION 'rate_limit_exceeded'
      USING ERRCODE = '54000';
  END IF;

  IF (random() < 0.01) THEN
    DELETE FROM public.rpc_rate_limits
    WHERE window_start < (now() - interval '7 days');
  END IF;
END;
$$;

COMMENT ON FUNCTION public.assert_rpc_rate_limit(text, int, int) IS
  'SECURITY DEFINER fixed-window rate limit with allowlisted buckets (includes Fan Team invite + report/leave). Not granted to authenticated clients.';

REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM anon;
REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.assert_rpc_rate_limit(text, int, int) TO service_role;

-- ---------------------------------------------------------------------------
-- 4) report_fan_team
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.report_fan_team(
  p_team_id uuid,
  p_category text,
  p_details text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_category text;
  v_details text;
  v_team public.fan_teams%ROWTYPE;
  v_member_count integer;
  v_id uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  PERFORM public.assert_rpc_rate_limit('report_fan_team', 20, 3600);

  IF p_team_id IS NULL THEN
    RAISE EXCEPTION 'Team id is required.';
  END IF;

  -- Active Team members (any role) may report Team identity/abuse.
  IF NOT public.is_active_fan_team_member(p_team_id, me) THEN
    RAISE EXCEPTION 'Not a team member.';
  END IF;

  v_category := lower(btrim(coalesce(p_category, '')));
  IF v_category NOT IN (
    'harassment', 'hate', 'spam', 'inappropriate', 'violence',
    'fake_account', 'team_identity', 'other'
  ) THEN
    RAISE EXCEPTION 'Invalid report category.';
  END IF;

  v_details := nullif(btrim(coalesce(p_details, '')), '');
  IF v_details IS NOT NULL AND char_length(v_details) > 1000 THEN
    RAISE EXCEPTION 'Details may be at most 1000 characters.';
  END IF;

  SELECT * INTO v_team
  FROM public.fan_teams t
  WHERE t.id = p_team_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  -- Membership gate uses is_active_fan_team_member (left_at IS NULL only; does not
  -- require fan_teams.is_active). So a still-joined member may report a Team that
  -- was just deactivated. Former members (left_at set) cannot report.
  -- Do not broaden to historical/left membership.

  SELECT count(*)::integer INTO v_member_count
  FROM public.fan_team_members m
  WHERE m.team_id = p_team_id AND m.left_at IS NULL;

  INSERT INTO public.fan_team_reports (
    team_id,
    reporter_user_id,
    owner_user_id,
    category,
    details,
    team_name_snapshot,
    team_logo_url_snapshot,
    team_sport_snapshot,
    member_count_snapshot,
    admin_resolution_status
  ) VALUES (
    p_team_id,
    me,
    v_team.owner_user_id,
    v_category,
    v_details,
    left(coalesce(v_team.name, ''), 120),
    left(coalesce(v_team.logo_url, ''), 512),
    left(coalesce(v_team.sport, ''), 40),
    v_member_count,
    'open'
  )
  RETURNING id INTO v_id;

  RETURN v_id;
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'You already reported this Team.'
      USING ERRCODE = '23505';
END;
$$;

COMMENT ON FUNCTION public.report_fan_team(uuid, text, text) IS
  'Active Team members report a Team (name/logo/identity/abuse). Reporter = auth.uid(); owner cannot see reporter identity.';

REVOKE ALL ON FUNCTION public.report_fan_team(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.report_fan_team(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_fan_team(uuid, text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 5) leave_fan_team
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
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  PERFORM public.assert_rpc_rate_limit('leave_fan_team', 30, 3600);

  IF p_team_id IS NULL THEN
    RAISE EXCEPTION 'Team id is required.';
  END IF;

  SELECT t.group_conversation_id INTO v_conversation_id
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
    RETURN; -- already left / not a member
  END IF;

  IF v_role = 'owner' THEN
    RAISE EXCEPTION 'Team owners cannot leave while they own the Team.';
  END IF;

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

  -- Cancel any pending invitations this user still has outstanding from this Team
  -- (they can no longer accept after leave).
  UPDATE public.fan_team_invitations
  SET status = 'cancelled', cancelled_at = now(), responded_at = coalesce(responded_at, now())
  WHERE team_id = p_team_id
    AND invitee_user_id = me
    AND status = 'pending';
END;
$$;

COMMENT ON FUNCTION public.leave_fan_team(uuid) IS
  'Non-owner soft-leave: fan_team_members.left_at + linked group_conversation_members.left_at. Preserves history.';

REVOKE ALL ON FUNCTION public.leave_fan_team(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.leave_fan_team(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.leave_fan_team(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 6) Admin helpers (service_role) — deactivate / clear logo
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_set_fan_team_active(
  p_team_id uuid,
  p_is_active boolean,
  p_admin_email text DEFAULT NULL,
  p_reason text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_before boolean;
  v_name text;
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  IF p_team_id IS NULL OR p_is_active IS NULL THEN
    RAISE EXCEPTION 'team_id and is_active are required.';
  END IF;

  SELECT t.is_active, t.name INTO v_before, v_name
  FROM public.fan_teams t
  WHERE t.id = p_team_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  UPDATE public.fan_teams
  SET is_active = p_is_active, updated_at = now()
  WHERE id = p_team_id;

  -- Cancel pending invites when deactivating.
  IF p_is_active IS FALSE THEN
    UPDATE public.fan_team_invitations
    SET status = 'cancelled', cancelled_at = now(), responded_at = coalesce(responded_at, now())
    WHERE team_id = p_team_id AND status = 'pending';
  END IF;

  IF to_regclass('public.admin_audit_logs') IS NOT NULL THEN
    INSERT INTO public.admin_audit_logs (
      admin_email, action, target_type, target_id, before_data, after_data, reason
    ) VALUES (
      nullif(btrim(coalesce(p_admin_email, '')), ''),
      CASE WHEN p_is_active THEN 'fan_team_reactivate' ELSE 'fan_team_deactivate' END,
      'fan_team',
      p_team_id::text,
      jsonb_build_object('is_active', v_before, 'name', v_name),
      jsonb_build_object('is_active', p_is_active, 'name', v_name),
      nullif(btrim(coalesce(p_reason, '')), '')
    );
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_clear_fan_team_logo(
  p_team_id uuid,
  p_admin_email text DEFAULT NULL,
  p_reason text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_logo text;
  v_thumb text;
  v_name text;
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  IF p_team_id IS NULL THEN
    RAISE EXCEPTION 'team_id is required.';
  END IF;

  SELECT t.logo_url, t.logo_thumbnail_url, t.name
  INTO v_logo, v_thumb, v_name
  FROM public.fan_teams t
  WHERE t.id = p_team_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  UPDATE public.fan_teams
  SET logo_url = NULL, logo_thumbnail_url = NULL, updated_at = now()
  WHERE id = p_team_id;

  IF to_regclass('public.admin_audit_logs') IS NOT NULL THEN
    INSERT INTO public.admin_audit_logs (
      admin_email, action, target_type, target_id, before_data, after_data, reason
    ) VALUES (
      nullif(btrim(coalesce(p_admin_email, '')), ''),
      'fan_team_clear_logo',
      'fan_team',
      p_team_id::text,
      jsonb_build_object('logo_url', v_logo, 'logo_thumbnail_url', v_thumb, 'name', v_name),
      jsonb_build_object('logo_url', NULL, 'logo_thumbnail_url', NULL, 'name', v_name),
      nullif(btrim(coalesce(p_reason, '')), '')
    );
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_fan_team_active(uuid, boolean, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_set_fan_team_active(uuid, boolean, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.admin_set_fan_team_active(uuid, boolean, text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_fan_team_active(uuid, boolean, text, text) TO service_role;

REVOKE ALL ON FUNCTION public.admin_clear_fan_team_logo(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_clear_fan_team_logo(uuid, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.admin_clear_fan_team_logo(uuid, text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_clear_fan_team_logo(uuid, text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 7) Email queue: ADDITIVE fan_team support + AFTER INSERT trigger
-- ---------------------------------------------------------------------------
-- Production baseline (20260859): only group_conversation + group_message.
-- user/conversation/message/venue/comment reports do NOT use this helper;
-- they use other notify paths. Preserve that baseline exactly and add fan_team.
CREATE OR REPLACE FUNCTION public.queue_moderation_report_email(
  p_report_type text,
  p_report_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_url text;
  v_service_role_key text;
  v_headers jsonb;
  v_type text := lower(btrim(coalesce(p_report_type, '')));
BEGIN
  IF p_report_id IS NULL THEN
    RETURN;
  END IF;

  IF v_type NOT IN ('group_conversation', 'group_message', 'fan_team') THEN
    RAISE NOTICE 'queue_moderation_report_email skipped: unsupported type %', v_type;
    RETURN;
  END IF;

  IF to_regnamespace('net') IS NULL OR to_regclass('vault.decrypted_secrets') IS NULL THEN
    RAISE NOTICE 'queue_moderation_report_email skipped: pg_net or vault unavailable';
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
    RAISE NOTICE 'queue_moderation_report_email skipped: vault url or service role secret missing';
    RETURN;
  END IF;

  v_headers := jsonb_build_object(
    'Content-Type', 'application/json',
    'Authorization', 'Bearer ' || v_service_role_key
  );

  PERFORM net.http_post(
    url := v_url || '/functions/v1/notify-moderation-report',
    headers := v_headers,
    body := jsonb_build_object(
      'report_type', v_type,
      'report_id', p_report_id,
      'source', 'pg_net_queue'
    ),
    timeout_milliseconds := 15000
  );
EXCEPTION
  WHEN OTHERS THEN
    -- Report insert must succeed even if email queue fails.
    RAISE NOTICE 'queue_moderation_report_email failed: %', SQLERRM;
END;
$$;

COMMENT ON FUNCTION public.queue_moderation_report_email(text, uuid) IS
  'Best-effort async enqueue of notify-moderation-report for group_conversation, group_message, and fan_team reports. Failures are logged and do not roll back the report insert.';

REVOKE ALL ON FUNCTION public.queue_moderation_report_email(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.queue_moderation_report_email(text, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.trg_queue_fan_team_report_email()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.queue_moderation_report_email('fan_team', NEW.id);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_fan_team_reports_queue_email ON public.fan_team_reports;
CREATE TRIGGER trg_fan_team_reports_queue_email
  AFTER INSERT ON public.fan_team_reports
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_queue_fan_team_report_email();

COMMIT;

-- =============================================================================
-- MANUAL APPLY NOTES
-- =============================================================================
-- Apply AFTER 20260926 + 20260929 (and preferably 20260930).
-- Then redeploy Edge:
--   supabase functions deploy notify-moderation-report --no-verify-jwt
--
-- Security verify (RPC-only writes):
--   SELECT has_table_privilege('authenticated','public.fan_team_reports','INSERT'); -- false
--   SELECT has_table_privilege('authenticated','public.fan_team_reports','SELECT'); -- true
--   SELECT has_function_privilege('authenticated','public.report_fan_team(uuid,text,text)','EXECUTE');
--   SELECT has_function_privilege('authenticated','public.leave_fan_team(uuid)','EXECUTE');
--
-- Email types preserved (production baseline + fan_team):
--   SELECT pg_get_functiondef('public.queue_moderation_report_email(text,uuid)'::regprocedure)
--     ILIKE ALL (ARRAY['%group_conversation%','%group_message%','%fan_team%']);
-- =============================================================================
