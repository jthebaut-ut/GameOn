-- Individual Business Pro award/extension push (mirrors FanGeo+ award path).
-- Queue path: applyBusinessPlanAction → admin_enqueue_business_pro_award_push
--   → queue_business_pro_award_push_notification → notify-business-pro-award → APNs.

CREATE TABLE IF NOT EXISTS public.business_pro_award_push_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  owner_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  audit_log_id uuid,
  change_kind text NOT NULL CHECK (change_kind IN ('grant', 'extension')),
  entitlement_source text NOT NULL DEFAULT 'admin_manual',
  expires_at timestamptz,
  business_name text,
  admin_email text,
  created_at timestamptz NOT NULL DEFAULT now(),
  push_queued_at timestamptz NOT NULL DEFAULT now(),
  push_attempted_at timestamptz,
  push_sent_at timestamptz,
  push_error text,
  skip_reason text
);

CREATE UNIQUE INDEX IF NOT EXISTS business_pro_award_push_events_audit_log_id_uidx
  ON public.business_pro_award_push_events (audit_log_id)
  WHERE audit_log_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS business_pro_award_push_events_business_created_idx
  ON public.business_pro_award_push_events (business_id, created_at DESC);

CREATE INDEX IF NOT EXISTS business_pro_award_push_events_owner_created_idx
  ON public.business_pro_award_push_events (owner_user_id, created_at DESC)
  WHERE owner_user_id IS NOT NULL;

ALTER TABLE public.business_pro_award_push_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.business_pro_award_push_events FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE ON TABLE public.business_pro_award_push_events TO service_role;

CREATE OR REPLACE FUNCTION public.queue_business_pro_award_push_notification(
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
    RAISE NOTICE 'business pro award push skipped: pg_net or vault unavailable';
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
      'BUSINESS_PRO_AWARD_PUSH_CRON_SECRET',
      'FANGEO_PLUS_AWARD_PUSH_CRON_SECRET',
      'FANGEO_ANNOUNCEMENT_PUSH_CRON_SECRET',
      'SUPPORT_REPLY_PUSH_CRON_SECRET'
    )
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY CASE name
    WHEN 'BUSINESS_PRO_AWARD_PUSH_CRON_SECRET' THEN 0
    WHEN 'FANGEO_PLUS_AWARD_PUSH_CRON_SECRET' THEN 1
    WHEN 'FANGEO_ANNOUNCEMENT_PUSH_CRON_SECRET' THEN 2
    ELSE 3
  END
  LIMIT 1;

  IF v_url IS NULL OR v_service_role_key IS NULL THEN
    RAISE NOTICE 'business pro award push skipped: vault url or service role secret missing';
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
    url := v_url || '/functions/v1/notify-business-pro-award',
    headers := v_headers,
    body := jsonb_build_object(
      'award_event_id', p_award_event_id
    ),
    timeout_milliseconds := 15000
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'business pro award push queue failed: %', SQLERRM;
END;
$$;

REVOKE ALL ON FUNCTION public.queue_business_pro_award_push_notification(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.queue_business_pro_award_push_notification(uuid) TO service_role;

COMMENT ON FUNCTION public.queue_business_pro_award_push_notification(uuid) IS
  'Best-effort async invoke of notify-business-pro-award after an individual admin Business Pro grant/extension.';

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
  IF NOT public.is_support_inbox_admin(p_admin_email) THEN
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

  v_source := NULLIF(btrim(coalesce(p_entitlement_source, '')), '');
  IF v_source IS NULL THEN
    v_source := 'admin_manual';
  END IF;

  -- Idempotent on audit_log_id: one plan-change audit → one push event.
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
    'award_event_id', v_event_id,
    'owner_user_id', v_business.owner_user_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_enqueue_business_pro_award_push(uuid, uuid, text, text, timestamptz, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_enqueue_business_pro_award_push(uuid, uuid, text, text, timestamptz, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_enqueue_business_pro_award_push(uuid, uuid, text, text, timestamptz, text) TO authenticated;

COMMENT ON FUNCTION public.admin_enqueue_business_pro_award_push(uuid, uuid, text, text, timestamptz, text) IS
  'After a successful individual Business Pro grant/extension audit, create one push event and queue notify-business-pro-award. Skips queue when owner_user_id is missing.';
