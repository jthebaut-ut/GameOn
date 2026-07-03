-- Admin dashboard queue for conversation_reports: server-side filtering, sorting, pagination.

CREATE INDEX IF NOT EXISTS idx_conversation_reports_created_at_desc
  ON public.conversation_reports (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_conversation_reports_reporter_withdrawn_at
  ON public.conversation_reports (reporter_withdrawn_at)
  WHERE reporter_withdrawn_at IS NOT NULL;

CREATE OR REPLACE FUNCTION public.admin_conversation_reports_queue(
  p_status text DEFAULT 'all',
  p_category text DEFAULT 'all',
  p_date_from timestamptz DEFAULT NULL,
  p_date_to timestamptz DEFAULT NULL,
  p_reporter_search text DEFAULT NULL,
  p_reported_user_search text DEFAULT NULL,
  p_min_report_count integer DEFAULT 1,
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
    FROM public.conversation_reports
    WHERE reported_user_id IS NOT NULL
    GROUP BY reported_user_id
  ),
  filtered AS (
    SELECT
      cr.id,
      cr.created_at,
      cr.admin_resolution_status,
      cr.admin_resolved_at,
      cr.admin_resolved_by,
      cr.admin_resolution_note,
      cr.admin_escalated_at,
      cr.admin_escalated_by,
      cr.reporter_user_id,
      cr.reported_user_id,
      cr.reporter_email,
      cr.reported_email,
      cr.conversation_id,
      cr.review_window_start,
      cr.review_window_end,
      cr.consent_for_review_window,
      cr.review_window_consent,
      cr.message_snapshot,
      cr.messages_snapshot,
      cr.category,
      cr.details,
      cr.reason,
      cr.status,
      cr.reporter_withdrawn_at,
      COALESCE(rc.report_count, 0) AS reported_user_report_count,
      CASE
        WHEN COALESCE(rc.report_count, 0) >= 2 THEN true
        ELSE false
      END AS is_high_priority
    FROM public.conversation_reports cr
    LEFT JOIN report_counts rc ON rc.reported_user_id = cr.reported_user_id
    LEFT JOIN public.user_profiles reporter_profile ON reporter_profile.id = cr.reporter_user_id
    LEFT JOIN public.user_profiles reported_profile ON reported_profile.id = cr.reported_user_id
    WHERE COALESCE(rc.report_count, 0) >= GREATEST(COALESCE(p_min_report_count, 1), 1)
      AND (p_date_from IS NULL OR cr.created_at >= p_date_from)
      AND (p_date_to IS NULL OR cr.created_at <= p_date_to)
      AND (
        p_category IS NULL
        OR p_category = 'all'
        OR lower(COALESCE(cr.category, '')) = lower(p_category)
      )
      AND (
        p_status IS NULL
        OR p_status = 'all'
        OR (
          p_status = 'withdrawn'
          AND cr.reporter_withdrawn_at IS NOT NULL
        )
        OR (
          p_status <> 'withdrawn'
          AND cr.reporter_withdrawn_at IS NULL
          AND (
            (p_status = 'open' AND COALESCE(cr.admin_resolution_status, 'open') = 'open')
            OR (p_status = 'escalated' AND cr.admin_resolution_status = 'escalated')
            OR (p_status = 'resolved' AND cr.admin_resolution_status = 'resolved')
            OR (p_status = 'dismissed' AND cr.admin_resolution_status = 'dismissed')
          )
        )
      )
      AND (
        v_reporter_search IS NULL
        OR cr.reporter_email ILIKE '%' || v_reporter_search || '%'
        OR reporter_profile.email ILIKE '%' || v_reporter_search || '%'
        OR reporter_profile.display_name ILIKE '%' || v_reporter_search || '%'
        OR reporter_profile.handle ILIKE '%' || v_reporter_search || '%'
        OR reporter_profile.username ILIKE '%' || v_reporter_search || '%'
      )
      AND (
        v_reported_search IS NULL
        OR cr.reported_email ILIKE '%' || v_reported_search || '%'
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
      CASE WHEN lower(COALESCE(p_sort, 'newest')) = 'oldest' THEN created_at END ASC NULLS LAST,
      CASE WHEN lower(COALESCE(p_sort, 'newest')) <> 'oldest' THEN created_at END DESC NULLS LAST,
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

REVOKE ALL ON FUNCTION public.admin_conversation_reports_queue(text, text, timestamptz, timestamptz, text, text, integer, text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_conversation_reports_queue(text, text, timestamptz, timestamptz, text, text, integer, text, integer, integer) TO service_role;
