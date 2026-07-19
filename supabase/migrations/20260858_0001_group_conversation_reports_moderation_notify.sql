-- Additive moderation support for group_conversation_reports.
-- Does not recreate the table or change RLS insert/select policies.
-- Enables idempotent admin email notification tracking only.

ALTER TABLE public.group_conversation_reports
  ADD COLUMN IF NOT EXISTS moderation_notified_at timestamptz;

COMMENT ON COLUMN public.group_conversation_reports.moderation_notified_at IS
  'Set by notify-moderation-report after a successful admin email send. Prevents duplicate emails for the same report.';

CREATE INDEX IF NOT EXISTS group_conversation_reports_moderation_notified_idx
  ON public.group_conversation_reports (moderation_notified_at)
  WHERE moderation_notified_at IS NULL;
