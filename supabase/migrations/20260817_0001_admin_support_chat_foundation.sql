-- Admin Support Chat foundation (dashboard-only phase 1).
-- Separate from direct_messages / direct_conversations. No app client reads yet.

CREATE TABLE IF NOT EXISTS public.support_conversations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'open',
  assigned_admin_email text,
  last_message_at timestamptz,
  last_support_message_at timestamptz,
  last_user_message_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT support_conversations_status_check
    CHECK (status IN ('open', 'closed'))
);

CREATE UNIQUE INDEX IF NOT EXISTS support_conversations_one_open_per_user
  ON public.support_conversations (user_id)
  WHERE status = 'open';

CREATE INDEX IF NOT EXISTS idx_support_conversations_status_last_message
  ON public.support_conversations (status, last_message_at DESC NULLS LAST);

CREATE INDEX IF NOT EXISTS idx_support_conversations_user_id
  ON public.support_conversations (user_id, updated_at DESC);

CREATE TABLE IF NOT EXISTS public.support_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL REFERENCES public.support_conversations (id) ON DELETE CASCADE,
  sender_kind text NOT NULL,
  sender_auth_user_id uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  admin_email text,
  body text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  CONSTRAINT support_messages_sender_kind_check
    CHECK (sender_kind IN ('user', 'support', 'system')),
  CONSTRAINT support_messages_body_len_check
    CHECK (char_length(btrim(body)) > 0 AND char_length(body) <= 4000)
);

CREATE INDEX IF NOT EXISTS idx_support_messages_conversation_created
  ON public.support_messages (conversation_id, created_at);

CREATE OR REPLACE FUNCTION public.support_conversations_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.support_conversations_sync_last_message_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE public.support_conversations sc
  SET
    last_message_at = NEW.created_at,
    last_support_message_at = CASE
      WHEN NEW.sender_kind = 'support' THEN NEW.created_at
      ELSE sc.last_support_message_at
    END,
    last_user_message_at = CASE
      WHEN NEW.sender_kind = 'user' THEN NEW.created_at
      ELSE sc.last_user_message_at
    END,
    updated_at = now()
  WHERE sc.id = NEW.conversation_id;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS support_conversations_touch_updated_at ON public.support_conversations;
CREATE TRIGGER support_conversations_touch_updated_at
  BEFORE UPDATE ON public.support_conversations
  FOR EACH ROW
  EXECUTE FUNCTION public.support_conversations_touch_updated_at();

DROP TRIGGER IF EXISTS support_messages_sync_conversation_last_message ON public.support_messages;
CREATE TRIGGER support_messages_sync_conversation_last_message
  AFTER INSERT ON public.support_messages
  FOR EACH ROW
  EXECUTE FUNCTION public.support_conversations_sync_last_message_at();

ALTER TABLE public.support_conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.support_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS support_conversations_service_role_all ON public.support_conversations;
CREATE POLICY support_conversations_service_role_all
  ON public.support_conversations
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

DROP POLICY IF EXISTS support_messages_service_role_all ON public.support_messages;
CREATE POLICY support_messages_service_role_all
  ON public.support_messages
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

REVOKE ALL ON TABLE public.support_conversations FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.support_messages FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.support_conversations TO service_role;
GRANT ALL ON TABLE public.support_messages TO service_role;

COMMENT ON TABLE public.support_conversations IS
  'FanGeo admin support chat threads. Dashboard service-role only in phase 1.';
COMMENT ON TABLE public.support_messages IS
  'FanGeo admin support chat messages. Separate from direct_messages.';
