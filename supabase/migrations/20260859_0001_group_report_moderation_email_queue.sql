-- PROPOSED (do not auto-apply to linked production).
-- Narrow additive support for server-side moderation email on group chat reports.
--
-- Why required:
-- 1) Idempotent email delivery tracking for group_message_reports
-- 2) Async pg_net enqueue after INSERT so email does not depend on the iOS client
--
-- Affects only:
-- - public.group_message_reports (new moderation_notified_at column)
-- - public.group_conversation_reports (trigger enqueue; column may already exist from 20260858)
-- - new SECURITY DEFINER queue helper + AFTER INSERT triggers
--
-- Does NOT modify:
-- - conversation_reports / message_reports / user_reports
-- - RLS insert/select policies for reporters
-- - report_group_conversation / report_group_message validation logic

-- ---------------------------------------------------------------------------
-- 1) Idempotency column for group message reports
-- ---------------------------------------------------------------------------

ALTER TABLE public.group_message_reports
  ADD COLUMN IF NOT EXISTS moderation_notified_at timestamptz;

COMMENT ON COLUMN public.group_message_reports.moderation_notified_at IS
  'Set by notify-moderation-report after a successful admin email send. Prevents duplicate emails.';

CREATE INDEX IF NOT EXISTS group_message_reports_moderation_notified_idx
  ON public.group_message_reports (moderation_notified_at)
  WHERE moderation_notified_at IS NULL;

ALTER TABLE public.group_conversation_reports
  ADD COLUMN IF NOT EXISTS moderation_notified_at timestamptz;

-- ---------------------------------------------------------------------------
-- 2) Async queue helper (service-role Edge Function via pg_net)
-- ---------------------------------------------------------------------------

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

  IF v_type NOT IN ('group_conversation', 'group_message') THEN
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
  'Best-effort async enqueue of notify-moderation-report for group chat reports. Failures are logged and do not roll back the report insert.';

REVOKE ALL ON FUNCTION public.queue_moderation_report_email(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.queue_moderation_report_email(text, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3) AFTER INSERT → AFTER INSERT? Use AFTER INSERT ... FOR EACH ROW AFTER
--    Actually AFTER INSERT cannot see RETURNING id easily in all cases;
--    use AFTER INSERT so NEW.id is committed-visible to the queue helper.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.trg_queue_group_conversation_report_email()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.queue_moderation_report_email('group_conversation', NEW.id);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS group_conversation_reports_queue_email_ai
  ON public.group_conversation_reports;
CREATE TRIGGER group_conversation_reports_queue_email_ai
  AFTER INSERT ON public.group_conversation_reports
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_queue_group_conversation_report_email();

CREATE OR REPLACE FUNCTION public.trg_queue_group_message_report_email()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.queue_moderation_report_email('group_message', NEW.id);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS group_message_reports_queue_email_ai
  ON public.group_message_reports;
CREATE TRIGGER group_message_reports_queue_email_ai
  AFTER INSERT ON public.group_message_reports
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_queue_group_message_report_email();
