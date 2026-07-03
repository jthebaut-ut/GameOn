-- Admin dashboard queue for user_reports: server-side filtering, sorting, pagination.

CREATE INDEX IF NOT EXISTS idx_user_reports_created_at_desc
  ON public.user_reports (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_user_reports_reported_user_id
  ON public.user_reports (reported_user_id);

CREATE OR REPLACE FUNCTION public.admin_user_reports_queue(
  p_status text DEFAULT 'all',
  p_category text DEFAULT 'all',
  p_date_from timestamptz DEFAULT NULL,
  p_date_to timestamptz DEFAULT NULL,
  p_reporter_search text DEFAULT NULL,
  p_reported_user_search text DEFAULT NULL,
  p_min_report_count integer DEFAULT 1,
  p_suspension_status text DEFAULT 'all',
  p_sort text DEFAULT 'newest',
  p_page integer DEFAULT 1,
  p_page_size integer DEFAULT 25
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_total bigint;
  v_offset integer;
  v_items jsonb;
  v_reporter_search text := NULLIF(trim(p_reporter_search), '');
  v_reported_search text := NULLIF(trim(p_reported_user_search), '');
BEGIN
  v_offset := GREATEST(COALESCE(p_page, 1) - 1, 0) * GREATEST(COALESCE(p_page_size, 25), 1);

  WITH report_counts AS (
    SELECT reported_user_id, COUNT(*)::int AS report_count
    FROM public.user_reports
    WHERE reported_user_id IS NOT NULL
    GROUP BY reported_user_id
  ),
  active_bans AS (
    SELECT DISTINCT ON (ub.user_id)
      ub.user_id,
      ub.expires_at,
      ub.lifted_at
    FROM public.user_bans ub
    WHERE ub.lifted_at IS NULL
      AND (ub.expires_at IS NULL OR ub.expires_at > now())
    ORDER BY ub.user_id, ub.created_at DESC
  ),
  filtered AS (
    SELECT
      ur.id,
      ur.created_at,
      ur.admin_resolution_status,
      ur.admin_resolved_at,
      ur.admin_resolved_by,
      ur.admin_resolution_note,
      ur.admin_escalated_at,
      ur.admin_escalated_by,
      ur.reporter_user_id,
      ur.reported_user_id,
      ur.reporter_email,
      ur.reported_email,
      ur.category,
      ur.details,
      ur.reason,
      ur.status,
      ur.reporter_withdrawn_at,
      COALESCE(rc.report_count, 0) AS reported_user_report_count,
      CASE
        WHEN COALESCE(rc.report_count, 0) >= 2 THEN true
        ELSE false
      END AS is_high_priority,
      ab.expires_at AS active_ban_expires_at,
      (ab.user_id IS NOT NULL) AS has_active_ban,
      COALESCE(ur.admin_resolved_at, ur.admin_escalated_at, ur.created_at) AS last_updated_at
    FROM public.user_reports ur
    LEFT JOIN report_counts rc ON rc.reported_user_id = ur.reported_user_id
    LEFT JOIN public.user_profiles reporter_profile ON reporter_profile.id = ur.reporter_user_id
    LEFT JOIN public.user_profiles reported_profile ON reported_profile.id = ur.reported_user_id
    LEFT JOIN active_bans ab ON ab.user_id = ur.reported_user_id
    WHERE COALESCE(rc.report_count, 0) >= GREATEST(COALESCE(p_min_report_count, 1), 1)
      AND (p_date_from IS NULL OR ur.created_at >= p_date_from)
      AND (p_date_to IS NULL OR ur.created_at <= p_date_to)
      AND (
        p_category IS NULL
        OR p_category = 'all'
        OR lower(COALESCE(ur.category, '')) = lower(p_category)
      )
      AND (
        p_status IS NULL
        OR p_status = 'all'
        OR (
          p_status = 'open' AND COALESCE(ur.admin_resolution_status, 'open') = 'open'
        )
        OR (p_status = 'escalated' AND ur.admin_resolution_status = 'escalated')
        OR (p_status = 'resolved' AND ur.admin_resolution_status = 'resolved')
        OR (p_status = 'dismissed' AND ur.admin_resolution_status = 'dismissed')
      )
      AND (
        p_suspension_status IS NULL
        OR p_suspension_status = 'all'
        OR (p_suspension_status = 'not_suspended' AND ab.user_id IS NULL)
        OR (p_suspension_status = 'suspended' AND ab.user_id IS NOT NULL AND ab.expires_at IS NOT NULL)
        OR (p_suspension_status = 'permanent' AND ab.user_id IS NOT NULL AND ab.expires_at IS NULL)
      )
      AND (
        v_reporter_search IS NULL
        OR ur.reporter_email ILIKE '%' || v_reporter_search || '%'
        OR reporter_profile.email ILIKE '%' || v_reporter_search || '%'
        OR reporter_profile.display_name ILIKE '%' || v_reporter_search || '%'
        OR reporter_profile.handle ILIKE '%' || v_reporter_search || '%'
        OR reporter_profile.username ILIKE '%' || v_reporter_search || '%'
      )
      AND (
        v_reported_search IS NULL
        OR ur.reported_email ILIKE '%' || v_reported_search || '%'
        OR reported_profile.email ILIKE '%' || v_reported_search || '%'
        OR reported_profile.display_name ILIKE '%' || v_reported_search || '%'
        OR reported_profile.handle ILIKE '%' || v_reported_search || '%'
        OR reported_profile.username ILIKE '%' || v_reported_search || '%'
      )
  ),
  ordered AS (
    SELECT *
    FROM filtered
    ORDER BY
      CASE WHEN lower(COALESCE(p_sort, 'newest')) = 'priority' THEN CASE WHEN is_high_priority THEN 0 ELSE 1 END END,
      CASE WHEN lower(COALESCE(p_sort, 'newest')) IN ('priority', 'most_reported') THEN -reported_user_report_count END,
      CASE WHEN lower(COALESCE(p_sort, 'newest')) = 'recently_updated' THEN last_updated_at END DESC NULLS LAST,
      CASE WHEN lower(COALESCE(p_sort, 'newest')) = 'oldest' THEN created_at END ASC NULLS LAST,
      CASE
        WHEN lower(COALESCE(p_sort, 'newest')) NOT IN ('oldest', 'recently_updated')
        THEN created_at
      END DESC NULLS LAST,
      id DESC
  )
  SELECT COUNT(*)::bigint INTO v_total FROM ordered;

  SELECT COALESCE(jsonb_agg(row_to_json(page_rows)), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT *
    FROM ordered
    OFFSET v_offset
    LIMIT GREATEST(COALESCE(p_page_size, 25), 1)
  ) page_rows;

  RETURN jsonb_build_object(
    'total_count', COALESCE(v_total, 0),
    'items', COALESCE(v_items, '[]'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_user_reports_queue(text, text, timestamptz, timestamptz, text, text, integer, text, text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_user_reports_queue(text, text, timestamptz, timestamptz, text, text, integer, text, text, integer, integer) TO service_role;
