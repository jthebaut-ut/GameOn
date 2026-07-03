-- FanGeo Support Center: reporter withdrawal for moderation reports (audit-safe, no deletes).
-- Does not touch direct_messages, report submission paths, or admin dashboard RPCs.

ALTER TABLE public.user_reports
  ADD COLUMN IF NOT EXISTS reporter_withdrawn_at timestamptz;

ALTER TABLE public.venue_reports
  ADD COLUMN IF NOT EXISTS reporter_withdrawn_at timestamptz;

ALTER TABLE public.conversation_reports
  ADD COLUMN IF NOT EXISTS reporter_withdrawn_at timestamptz;

ALTER TABLE public.comment_reports
  ADD COLUMN IF NOT EXISTS reporter_withdrawn_at timestamptz;

CREATE OR REPLACE FUNCTION public.map_support_report_user_status(
  p_admin_status text,
  p_legacy_status text DEFAULT NULL,
  p_reporter_withdrawn_at timestamptz DEFAULT NULL
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_reporter_withdrawn_at IS NOT NULL THEN 'withdrawn'
    WHEN coalesce(p_admin_status, 'open') IN ('resolved', 'dismissed')
      OR coalesce(p_legacy_status, 'open') IN ('closed', 'actioned')
    THEN 'closed'
    WHEN coalesce(p_admin_status, 'open') = 'escalated'
    THEN 'under_review'
    ELSE 'submitted'
  END;
$$;

CREATE OR REPLACE FUNCTION public.get_my_support_report_items(
  p_limit integer DEFAULT 50
)
RETURNS TABLE (
  id uuid,
  report_type text,
  category text,
  user_status text,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_email text;
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  SELECT lower(btrim(u.email))
    INTO v_email
  FROM auth.users u
  WHERE u.id = v_uid;

  RETURN QUERY
  SELECT *
  FROM (
    SELECT
      ur.id,
      'user'::text AS report_type,
      ur.category,
      public.map_support_report_user_status(
        ur.admin_resolution_status,
        NULL,
        ur.reporter_withdrawn_at
      ) AS user_status,
      ur.created_at,
      coalesce(ur.reporter_withdrawn_at, ur.admin_resolved_at, ur.created_at) AS updated_at
    FROM public.user_reports ur
    WHERE ur.reporter_user_id = v_uid

    UNION ALL

    SELECT
      vr.id,
      'venue'::text AS report_type,
      vr.category,
      public.map_support_report_user_status(
        vr.admin_resolution_status,
        vr.status,
        vr.reporter_withdrawn_at
      ) AS user_status,
      vr.created_at,
      coalesce(vr.reporter_withdrawn_at, vr.admin_resolved_at, vr.created_at) AS updated_at
    FROM public.venue_reports vr
    WHERE vr.reporter_user_id = v_uid

    UNION ALL

    SELECT
      cr.id,
      'conversation'::text AS report_type,
      cr.category,
      public.map_support_report_user_status(
        cr.admin_resolution_status,
        cr.status,
        cr.reporter_withdrawn_at
      ) AS user_status,
      cr.created_at,
      coalesce(cr.reporter_withdrawn_at, cr.admin_resolved_at, cr.created_at) AS updated_at
    FROM public.conversation_reports cr
    WHERE cr.reporter_user_id = v_uid

    UNION ALL

    SELECT
      cmt.id,
      'comment'::text AS report_type,
      cmt.reason AS category,
      public.map_support_report_user_status(
        cmt.admin_resolution_status,
        NULL,
        cmt.reporter_withdrawn_at
      ) AS user_status,
      cmt.created_at,
      coalesce(cmt.reporter_withdrawn_at, cmt.admin_resolved_at, cmt.created_at) AS updated_at
    FROM public.comment_reports cmt
    WHERE v_email IS NOT NULL
      AND v_email <> ''
      AND lower(btrim(cmt.reporter_email)) = v_email
  ) combined
  ORDER BY combined.updated_at DESC, combined.created_at DESC
  LIMIT v_limit;
END;
$$;

CREATE OR REPLACE FUNCTION public.withdraw_my_support_report_item(
  p_report_type text,
  p_report_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_email text;
  v_type text;
  v_updated integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  IF p_report_id IS NULL THEN
    RAISE EXCEPTION 'invalid report';
  END IF;

  v_type := lower(btrim(coalesce(p_report_type, '')));
  IF v_type NOT IN ('user', 'venue', 'conversation', 'comment') THEN
    RAISE EXCEPTION 'invalid report type';
  END IF;

  IF v_type = 'user' THEN
    UPDATE public.user_reports ur
    SET
      reporter_withdrawn_at = now(),
      admin_resolution_status = 'dismissed',
      admin_resolved_at = coalesce(ur.admin_resolved_at, now()),
      admin_resolution_note = coalesce(
        nullif(btrim(coalesce(ur.admin_resolution_note, '')), ''),
        'Withdrawn by reporter'
      )
    WHERE ur.id = p_report_id
      AND ur.reporter_user_id = v_uid
      AND ur.reporter_withdrawn_at IS NULL
      AND ur.admin_resolution_status = 'open';

    GET DIAGNOSTICS v_updated = ROW_COUNT;
  ELSIF v_type = 'venue' THEN
    UPDATE public.venue_reports vr
    SET
      reporter_withdrawn_at = now(),
      status = 'closed',
      admin_resolution_status = 'dismissed',
      admin_resolved_at = coalesce(vr.admin_resolved_at, now()),
      admin_resolution_note = coalesce(
        nullif(btrim(coalesce(vr.admin_resolution_note, '')), ''),
        'Withdrawn by reporter'
      )
    WHERE vr.id = p_report_id
      AND vr.reporter_user_id = v_uid
      AND vr.reporter_withdrawn_at IS NULL
      AND vr.admin_resolution_status = 'open'
      AND vr.status = 'open';

    GET DIAGNOSTICS v_updated = ROW_COUNT;
  ELSIF v_type = 'conversation' THEN
    UPDATE public.conversation_reports cr
    SET
      reporter_withdrawn_at = now(),
      status = 'closed',
      admin_resolution_status = 'dismissed',
      admin_resolved_at = coalesce(cr.admin_resolved_at, now()),
      admin_resolution_note = coalesce(
        nullif(btrim(coalesce(cr.admin_resolution_note, '')), ''),
        'Withdrawn by reporter'
      )
    WHERE cr.id = p_report_id
      AND cr.reporter_user_id = v_uid
      AND cr.reporter_withdrawn_at IS NULL
      AND cr.admin_resolution_status = 'open'
      AND cr.status = 'open';

    GET DIAGNOSTICS v_updated = ROW_COUNT;
  ELSE
    SELECT lower(btrim(u.email))
      INTO v_email
    FROM auth.users u
    WHERE u.id = v_uid;

    IF v_email IS NULL OR v_email = '' THEN
      RAISE EXCEPTION 'report not found or cannot be withdrawn';
    END IF;

    UPDATE public.comment_reports cmt
    SET
      reporter_withdrawn_at = now(),
      admin_resolution_status = 'dismissed',
      admin_resolved_at = coalesce(cmt.admin_resolved_at, now()),
      admin_resolution_note = coalesce(
        nullif(btrim(coalesce(cmt.admin_resolution_note, '')), ''),
        'Withdrawn by reporter'
      )
    WHERE cmt.id = p_report_id
      AND lower(btrim(cmt.reporter_email)) = v_email
      AND cmt.reporter_withdrawn_at IS NULL
      AND cmt.admin_resolution_status = 'open';

    GET DIAGNOSTICS v_updated = ROW_COUNT;
  END IF;

  IF v_updated = 0 THEN
    RAISE EXCEPTION 'report not found or cannot be withdrawn';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.withdraw_my_support_report_item(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.withdraw_my_support_report_item(text, uuid) TO authenticated;

COMMENT ON FUNCTION public.withdraw_my_support_report_item(text, uuid) IS
  'Marks an owned moderation report as withdrawn by the reporter without deleting the row.';
