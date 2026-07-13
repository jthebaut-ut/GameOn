-- Admin FanGeo+ grant: entitlement mutation + audit + one queued award push.
-- Push path: admin_set_user_fangeo_plus → queue_fangeo_plus_award_push_notification
--   → Edge Function notify-fangeo-plus-award → APNs via shared ApnsClient.

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS ad_free_expires_at timestamptz;

COMMENT ON COLUMN public.user_profiles.ad_free_expires_at IS
  'Optional FanGeo+ expiration for admin-granted ad_free_enabled. NULL means no expiration. Apple subscription records are unrelated.';

ALTER TABLE public.user_notification_preferences
  ADD COLUMN IF NOT EXISTS account_access_notifications_enabled boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.user_notification_preferences.account_access_notifications_enabled IS
  'When false, skip account/access pushes such as admin FanGeo+ awards. Missing row is treated as enabled.';

CREATE TABLE IF NOT EXISTS public.fangeo_plus_award_push_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  audit_log_id uuid,
  change_kind text NOT NULL CHECK (change_kind IN ('grant', 'extension')),
  entitlement_source text NOT NULL DEFAULT 'admin_manual',
  expires_at timestamptz,
  admin_email text,
  created_at timestamptz NOT NULL DEFAULT now(),
  push_queued_at timestamptz NOT NULL DEFAULT now(),
  push_attempted_at timestamptz
);

CREATE UNIQUE INDEX IF NOT EXISTS fangeo_plus_award_push_events_audit_log_id_uidx
  ON public.fangeo_plus_award_push_events (audit_log_id)
  WHERE audit_log_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS fangeo_plus_award_push_events_user_created_idx
  ON public.fangeo_plus_award_push_events (user_id, created_at DESC);

ALTER TABLE public.fangeo_plus_award_push_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.fangeo_plus_award_push_events FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE ON TABLE public.fangeo_plus_award_push_events TO service_role;

CREATE OR REPLACE FUNCTION public.queue_fangeo_plus_award_push_notification(
  p_award_event_id uuid
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
BEGIN
  IF to_regnamespace('net') IS NULL OR to_regclass('vault.decrypted_secrets') IS NULL THEN
    RAISE NOTICE 'fangeo plus award push skipped: pg_net or vault unavailable';
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

  SELECT decrypted_secret
  INTO v_cron_secret
  FROM vault.decrypted_secrets
  WHERE name IN (
      'FANGEO_PLUS_AWARD_PUSH_CRON_SECRET',
      'FANGEO_ANNOUNCEMENT_PUSH_CRON_SECRET',
      'SUPPORT_REPLY_PUSH_CRON_SECRET'
    )
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY CASE name
    WHEN 'FANGEO_PLUS_AWARD_PUSH_CRON_SECRET' THEN 0
    WHEN 'FANGEO_ANNOUNCEMENT_PUSH_CRON_SECRET' THEN 1
    ELSE 2
  END
  LIMIT 1;

  IF v_url IS NULL OR v_service_role_key IS NULL THEN
    RAISE NOTICE 'fangeo plus award push skipped: vault url or service role secret missing';
    RETURN;
  END IF;

  v_headers := jsonb_build_object(
    'Content-Type', 'application/json',
    'Authorization', 'Bearer ' || v_service_role_key
  );

  IF v_cron_secret IS NOT NULL THEN
    v_headers := v_headers || jsonb_build_object(
      'x-cron-secret', v_cron_secret,
      'x-fangeo-cron-secret', v_cron_secret
    );
  END IF;

  PERFORM net.http_post(
    url := v_url || '/functions/v1/notify-fangeo-plus-award',
    headers := v_headers,
    body := jsonb_build_object(
      'award_event_id', p_award_event_id
    ),
    timeout_milliseconds := 15000
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'fangeo plus award push queue failed: %', SQLERRM;
END;
$$;

REVOKE ALL ON FUNCTION public.queue_fangeo_plus_award_push_notification(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.queue_fangeo_plus_award_push_notification(uuid) TO service_role;

COMMENT ON FUNCTION public.queue_fangeo_plus_award_push_notification(uuid) IS
  'Best-effort async invoke of notify-fangeo-plus-award after a successful admin FanGeo+ grant/extension.';

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
  IF NOT public.is_support_inbox_admin(p_admin_email) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'missing user id';
  END IF;

  IF p_enabled IS NULL THEN
    RAISE EXCEPTION 'missing enabled flag';
  END IF;

  v_admin_email := NULLIF(
    lower(
      btrim(
        coalesce(
          nullif(btrim(coalesce(p_admin_email, '')), ''),
          coalesce(auth.jwt() ->> 'email', '')
        )
      )
    ),
    ''
  );

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

  -- No effective change: do not mutate, audit, or notify.
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

REVOKE ALL ON FUNCTION public.admin_set_user_fangeo_plus(uuid, boolean, text, timestamptz, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_user_fangeo_plus(uuid, boolean, text, timestamptz, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_set_user_fangeo_plus(uuid, boolean, text, timestamptz, text) TO authenticated;

COMMENT ON FUNCTION public.admin_set_user_fangeo_plus(uuid, boolean, text, timestamptz, text) IS
  'Admin FanGeo+ grant/remove/extend. Validates admin, updates ad_free_enabled (+ optional ad_free_expires_at), writes audit, queues one award push for grant/extension only.';
