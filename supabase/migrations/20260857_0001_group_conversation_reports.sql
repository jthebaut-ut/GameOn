-- PROPOSED (not applied to linked production): group-level conversation reports.
-- Separate from group_message_reports (per-message) and conversation_reports (DM-only).
-- Do not run against the linked project until separately reviewed and approved.

-- =============================================================================
-- 1) Table
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.group_conversation_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_conversation_id uuid NOT NULL REFERENCES public.group_conversations (id) ON DELETE CASCADE,
  reporter_user_id uuid NOT NULL REFERENCES auth.users (id),
  category text NOT NULL,
  details text,
  group_title_snapshot text,
  member_count_snapshot integer,
  status text NOT NULL DEFAULT 'open'
    CHECK (status IN ('open', 'closed', 'actioned')),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT group_conversation_reports_category_ck
    CHECK (
      category IN (
        'harassment',
        'hate',
        'spam',
        'inappropriate',
        'violence',
        'fake_account',
        'other'
      )
    ),
  CONSTRAINT group_conversation_reports_details_len_ck
    CHECK (details IS NULL OR char_length(details) <= 1000)
);

COMMENT ON TABLE public.group_conversation_reports IS
  'Group-level conversation reports from active members. Independent of group_message_reports and DM conversation_reports.';

CREATE INDEX IF NOT EXISTS group_conversation_reports_open_idx
  ON public.group_conversation_reports (status, created_at DESC)
  WHERE status = 'open';

CREATE INDEX IF NOT EXISTS group_conversation_reports_group_idx
  ON public.group_conversation_reports (group_conversation_id, created_at DESC);

-- One open report per reporter per group (durable duplicate protection).
CREATE UNIQUE INDEX IF NOT EXISTS group_conversation_reports_one_open_per_reporter
  ON public.group_conversation_reports (reporter_user_id, group_conversation_id)
  WHERE status = 'open';

-- =============================================================================
-- 2) RLS
-- =============================================================================

ALTER TABLE public.group_conversation_reports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "group_conversation_reports_insert_own" ON public.group_conversation_reports;
CREATE POLICY "group_conversation_reports_insert_own"
ON public.group_conversation_reports
FOR INSERT
TO authenticated
WITH CHECK (
  reporter_user_id = auth.uid()
  AND public.is_active_group_member(group_conversation_id, auth.uid())
);

DROP POLICY IF EXISTS "group_conversation_reports_select_own" ON public.group_conversation_reports;
CREATE POLICY "group_conversation_reports_select_own"
ON public.group_conversation_reports
FOR SELECT
TO authenticated
USING (reporter_user_id = auth.uid());

-- No UPDATE/DELETE for authenticated clients (moderation via service role / admin tooling).

REVOKE ALL ON TABLE public.group_conversation_reports FROM PUBLIC;
GRANT SELECT, INSERT ON TABLE public.group_conversation_reports TO authenticated;
GRANT ALL ON TABLE public.group_conversation_reports TO service_role;

-- =============================================================================
-- 3) RPC
-- =============================================================================

CREATE OR REPLACE FUNCTION public.report_group_conversation(
  p_group_conversation_id uuid,
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
  v_title text;
  v_member_count integer;
  v_category text;
  v_details text;
  v_id uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  IF p_group_conversation_id IS NULL THEN
    RAISE EXCEPTION 'Group conversation id is required.';
  END IF;

  IF NOT public.is_active_group_member(p_group_conversation_id, me) THEN
    RAISE EXCEPTION 'Not an active member.';
  END IF;

  v_category := lower(btrim(coalesce(p_category, '')));
  IF v_category NOT IN (
    'harassment',
    'hate',
    'spam',
    'inappropriate',
    'violence',
    'fake_account',
    'other'
  ) THEN
    RAISE EXCEPTION 'Invalid report category.';
  END IF;

  v_details := nullif(btrim(coalesce(p_details, '')), '');
  IF v_details IS NOT NULL AND char_length(v_details) > 1000 THEN
    RAISE EXCEPTION 'Details may be at most 1000 characters.';
  END IF;

  SELECT c.title
  INTO v_title
  FROM public.group_conversations c
  WHERE c.id = p_group_conversation_id
    AND c.is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Group conversation not found.';
  END IF;

  SELECT count(*)::integer
  INTO v_member_count
  FROM public.group_conversation_members m
  WHERE m.conversation_id = p_group_conversation_id
    AND m.left_at IS NULL;

  INSERT INTO public.group_conversation_reports (
    group_conversation_id,
    reporter_user_id,
    category,
    details,
    group_title_snapshot,
    member_count_snapshot
  ) VALUES (
    p_group_conversation_id,
    me,
    v_category,
    v_details,
    left(coalesce(v_title, ''), 120),
    v_member_count
  )
  RETURNING id INTO v_id;

  RETURN v_id;
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'You already reported this group.'
      USING ERRCODE = '23505';
END;
$$;

COMMENT ON FUNCTION public.report_group_conversation(uuid, text, text) IS
  'Active group members report an entire group conversation for moderation review.';

REVOKE ALL ON FUNCTION public.report_group_conversation(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.report_group_conversation(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_group_conversation(uuid, text, text) TO service_role;
