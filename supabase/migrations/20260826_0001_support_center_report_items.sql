-- FanGeo Support Center: read-only list of moderation reports submitted by the current user.
-- Does not modify report tables, submission paths, admin queues, or direct messaging.

CREATE OR REPLACE FUNCTION public.map_support_report_user_status(
  p_admin_status text,
  p_legacy_status text DEFAULT NULL
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
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
      public.map_support_report_user_status(ur.admin_resolution_status, NULL) AS user_status,
      ur.created_at,
      coalesce(ur.admin_resolved_at, ur.created_at) AS updated_at
    FROM public.user_reports ur
    WHERE ur.reporter_user_id = v_uid

    UNION ALL

    SELECT
      vr.id,
      'venue'::text AS report_type,
      vr.category,
      public.map_support_report_user_status(vr.admin_resolution_status, vr.status) AS user_status,
      vr.created_at,
      coalesce(vr.admin_resolved_at, vr.created_at) AS updated_at
    FROM public.venue_reports vr
    WHERE vr.reporter_user_id = v_uid

    UNION ALL

    SELECT
      cr.id,
      'conversation'::text AS report_type,
      cr.category,
      public.map_support_report_user_status(cr.admin_resolution_status, cr.status) AS user_status,
      cr.created_at,
      coalesce(cr.admin_resolved_at, cr.created_at) AS updated_at
    FROM public.conversation_reports cr
    WHERE cr.reporter_user_id = v_uid

    UNION ALL

    SELECT
      cmt.id,
      'comment'::text AS report_type,
      cmt.reason AS category,
      public.map_support_report_user_status(cmt.admin_resolution_status, NULL) AS user_status,
      cmt.created_at,
      coalesce(cmt.admin_resolved_at, cmt.created_at) AS updated_at
    FROM public.comment_reports cmt
    WHERE v_email IS NOT NULL
      AND v_email <> ''
      AND lower(btrim(cmt.reporter_email)) = v_email
  ) combined
  ORDER BY combined.updated_at DESC, combined.created_at DESC
  LIMIT v_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.map_support_report_user_status(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_support_report_items(integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.get_my_support_report_items(integer) TO authenticated;

COMMENT ON FUNCTION public.get_my_support_report_items(integer) IS
  'Lists moderation reports submitted by the authenticated user for the FanGeo Support Center.';
