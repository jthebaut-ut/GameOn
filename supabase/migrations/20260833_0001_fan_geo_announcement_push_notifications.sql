-- FanGeo official announcement push notifications (preference-gated).
-- In-app Discover banners are unchanged; this column gates APNs delivery only.

ALTER TABLE public.user_notification_preferences
  ADD COLUMN IF NOT EXISTS fan_geo_announcement_notifications_enabled boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.user_notification_preferences.fan_geo_announcement_notifications_enabled IS
  'When false, the user must not receive FanGeo official announcement push notifications. Defaults to true.';

CREATE OR REPLACE FUNCTION public.list_fangeo_announcement_push_tokens(
  p_include_fans boolean,
  p_include_businesses boolean
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
SET search_path = public
AS $$
  SELECT DISTINCT ON (t.user_id, t.token, t.environment)
    t.id AS token_id,
    t.user_id,
    t.token,
    t.environment
  FROM public.user_push_tokens t
  LEFT JOIN public.user_notification_preferences p ON p.user_id = t.user_id
  LEFT JOIN public.user_profiles up ON up.id = t.user_id
  WHERE t.is_active = true
    AND COALESCE(p.fan_geo_announcement_notifications_enabled, true) = true
    AND (
      (p_include_fans AND COALESCE(up.is_business_account, false) = false)
      OR (p_include_businesses AND COALESCE(up.is_business_account, false) = true)
    )
  ORDER BY t.user_id, t.token, t.environment, t.last_seen_at DESC NULLS LAST;
$$;

REVOKE ALL ON FUNCTION public.list_fangeo_announcement_push_tokens(boolean, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_fangeo_announcement_push_tokens(boolean, boolean) TO service_role;

CREATE OR REPLACE FUNCTION public.queue_fangeo_announcement_push_notification(
  p_announcement_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_url text;
  v_service_role_key text;
BEGIN
  IF to_regnamespace('net') IS NULL OR to_regclass('vault.decrypted_secrets') IS NULL THEN
    RAISE NOTICE 'fangeo announcement push skipped: pg_net or vault unavailable';
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
    RAISE NOTICE 'fangeo announcement push skipped: vault secrets missing';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url := v_url || '/functions/v1/notify-fangeo-announcement',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_service_role_key
    ),
    body := jsonb_build_object(
      'announcement_id', p_announcement_id
    ),
    timeout_milliseconds := 60000
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'fangeo announcement push queue failed: %', SQLERRM;
END;
$$;

REVOKE ALL ON FUNCTION public.queue_fangeo_announcement_push_notification(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.queue_fangeo_announcement_push_notification(uuid) TO service_role;

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
  IF NOT public.is_support_inbox_admin(p_admin_email) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  PERFORM public.queue_fangeo_announcement_push_notification(p_announcement_id);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_send_fangeo_announcement_push(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_send_fangeo_announcement_push(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.queue_fangeo_announcement_push_notification(uuid) IS
  'Best-effort async invoke of notify-fangeo-announcement for official FanGeo announcement pushes.';

COMMENT ON FUNCTION public.admin_send_fangeo_announcement_push(uuid, text) IS
  'Admin-triggered FanGeo announcement push. Sends only to users with fan_geo_announcement_notifications_enabled = true and active push tokens.';
