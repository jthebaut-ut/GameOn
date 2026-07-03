-- Admin dashboard queue for support_conversations: server-side filtering, sorting, pagination.

CREATE INDEX IF NOT EXISTS idx_support_conversations_created_at_desc
  ON public.support_conversations (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_support_conversations_issue_type
  ON public.support_conversations (issue_type);

CREATE OR REPLACE FUNCTION public.admin_support_inbox_queue(
  p_status text DEFAULT 'all',
  p_issue_type text DEFAULT 'all',
  p_date_from timestamptz DEFAULT NULL,
  p_date_to timestamptz DEFAULT NULL,
  p_user_search text DEFAULT NULL,
  p_subject_search text DEFAULT NULL,
  p_unread_only boolean DEFAULT false,
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
  v_user_search text := NULLIF(trim(p_user_search), '');
  v_subject_search text := NULLIF(trim(p_subject_search), '');
BEGIN
  v_offset := GREATEST(COALESCE(p_page, 1) - 1, 0) * GREATEST(COALESCE(p_page_size, 25), 1);

  WITH filtered AS (
    SELECT
      sc.id,
      sc.user_id,
      sc.status,
      sc.assigned_admin_email,
      sc.subject,
      sc.issue_type,
      sc.chat_opened_at,
      sc.last_message_at,
      sc.last_support_message_at,
      sc.last_user_message_at,
      sc.closed_at,
      sc.cancelled_at,
      sc.closed_by,
      sc.created_at,
      sc.updated_at,
      lm.body AS last_message_preview,
      CASE
        WHEN sc.status = 'cancelled' OR lower(COALESCE(sc.closed_by, '')) = 'user' THEN 'cancelled'
        WHEN sc.status = 'closed' THEN 'resolved'
        WHEN sc.status = 'open'
          AND sc.last_support_message_at IS NOT NULL
          AND sc.last_support_message_at > COALESCE(sc.last_user_message_at, 'epoch'::timestamptz)
          THEN 'waiting_for_user'
        WHEN sc.status = 'open'
          AND sc.chat_opened_at IS NULL
          AND sc.last_support_message_at IS NULL
          THEN 'open'
        WHEN sc.status = 'open' AND sc.chat_opened_at IS NOT NULL THEN 'chat_open'
        WHEN sc.status = 'open' THEN 'waiting_for_fangeo'
        ELSE 'resolved'
      END AS queue_status,
      (
        sc.status = 'open'
        AND COALESCE(sc.last_user_message_at, sc.created_at) >= COALESCE(sc.last_support_message_at, 'epoch'::timestamptz)
      ) AS has_unread_admin,
      (
        lower(COALESCE(sc.issue_type, '')) IN ('account_issue', 'bug_report', 'report_user')
        OR (
          sc.status = 'open'
          AND COALESCE(sc.last_user_message_at, sc.created_at) < now() - interval '24 hours'
          AND COALESCE(sc.last_user_message_at, sc.created_at) >= COALESCE(sc.last_support_message_at, 'epoch'::timestamptz)
        )
      ) AS is_high_priority
    FROM public.support_conversations sc
    LEFT JOIN public.user_profiles up ON up.id = sc.user_id
    LEFT JOIN LATERAL (
      SELECT sm.body
      FROM public.support_messages sm
      WHERE sm.conversation_id = sc.id
        AND sm.deleted_at IS NULL
      ORDER BY sm.created_at DESC, sm.id DESC
      LIMIT 1
    ) lm ON true
    WHERE (p_date_from IS NULL OR sc.created_at >= p_date_from)
      AND (p_date_to IS NULL OR sc.created_at <= p_date_to)
      AND (
        p_issue_type IS NULL
        OR p_issue_type = 'all'
        OR lower(COALESCE(sc.issue_type, '')) = lower(p_issue_type)
      )
      AND (
        COALESCE(p_unread_only, false) = false
        OR (
          sc.status = 'open'
          AND COALESCE(sc.last_user_message_at, sc.created_at) >= COALESCE(sc.last_support_message_at, 'epoch'::timestamptz)
        )
      )
      AND (
        p_status IS NULL
        OR p_status = 'all'
        OR (
          CASE
            WHEN sc.status = 'cancelled' OR lower(COALESCE(sc.closed_by, '')) = 'user' THEN 'cancelled'
            WHEN sc.status = 'closed' THEN 'resolved'
            WHEN sc.status = 'open'
              AND sc.last_support_message_at IS NOT NULL
              AND sc.last_support_message_at > COALESCE(sc.last_user_message_at, 'epoch'::timestamptz)
              THEN 'waiting_for_user'
            WHEN sc.status = 'open'
              AND sc.chat_opened_at IS NULL
              AND sc.last_support_message_at IS NULL
              THEN 'open'
            WHEN sc.status = 'open' AND sc.chat_opened_at IS NOT NULL THEN 'chat_open'
            WHEN sc.status = 'open' THEN 'waiting_for_fangeo'
            ELSE 'resolved'
          END
        ) = lower(p_status)
      )
      AND (
        (v_user_search IS NULL AND v_subject_search IS NULL)
        OR (
          (
            v_user_search IS NOT NULL
            AND (
              up.email ILIKE '%' || v_user_search || '%'
              OR up.display_name ILIKE '%' || v_user_search || '%'
              OR up.handle ILIKE '%' || v_user_search || '%'
              OR up.username ILIKE '%' || v_user_search || '%'
            )
          )
          OR (
            v_subject_search IS NOT NULL
            AND sc.subject ILIKE '%' || v_subject_search || '%'
          )
        )
      )
  ),
  ordered AS (
    SELECT *
    FROM filtered
    ORDER BY
      CASE WHEN lower(COALESCE(p_sort, 'newest')) = 'priority' THEN CASE WHEN is_high_priority THEN 0 ELSE 1 END END,
      CASE WHEN lower(COALESCE(p_sort, 'newest')) = 'waiting_longest' THEN CASE WHEN queue_status IN ('waiting_for_fangeo', 'open') THEN 0 ELSE 1 END END,
      CASE WHEN lower(COALESCE(p_sort, 'newest')) = 'waiting_longest' THEN COALESCE(last_user_message_at, created_at) END ASC NULLS LAST,
      CASE WHEN lower(COALESCE(p_sort, 'newest')) = 'recently_updated' THEN COALESCE(last_message_at, updated_at, created_at) END DESC NULLS LAST,
      CASE WHEN lower(COALESCE(p_sort, 'newest')) = 'oldest' THEN created_at END ASC NULLS LAST,
      CASE WHEN lower(COALESCE(p_sort, 'newest')) NOT IN ('oldest', 'waiting_longest', 'recently_updated') THEN COALESCE(last_message_at, updated_at, created_at) END DESC NULLS LAST,
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

REVOKE ALL ON FUNCTION public.admin_support_inbox_queue(text, text, timestamptz, timestamptz, text, text, boolean, text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_support_inbox_queue(text, text, timestamptz, timestamptz, text, text, boolean, text, integer, integer) TO service_role;

CREATE OR REPLACE FUNCTION public.admin_support_inbox_summary()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH base AS (
    SELECT
      sc.*,
      CASE
        WHEN sc.status = 'cancelled' OR lower(COALESCE(sc.closed_by, '')) = 'user' THEN 'cancelled'
        WHEN sc.status = 'closed' THEN 'resolved'
        WHEN sc.status = 'open'
          AND sc.last_support_message_at IS NOT NULL
          AND sc.last_support_message_at > COALESCE(sc.last_user_message_at, 'epoch'::timestamptz)
          THEN 'waiting_for_user'
        WHEN sc.status = 'open'
          AND sc.chat_opened_at IS NULL
          AND sc.last_support_message_at IS NULL
          THEN 'open'
        WHEN sc.status = 'open' AND sc.chat_opened_at IS NOT NULL THEN 'chat_open'
        WHEN sc.status = 'open' THEN 'waiting_for_fangeo'
        ELSE 'resolved'
      END AS queue_status,
      (
        lower(COALESCE(sc.issue_type, '')) IN ('account_issue', 'bug_report', 'report_user')
        OR (
          sc.status = 'open'
          AND COALESCE(sc.last_user_message_at, sc.created_at) < now() - interval '24 hours'
          AND COALESCE(sc.last_user_message_at, sc.created_at) >= COALESCE(sc.last_support_message_at, 'epoch'::timestamptz)
        )
      ) AS is_high_priority
    FROM public.support_conversations sc
  )
  SELECT jsonb_build_object(
    'open_count',
      COUNT(*) FILTER (WHERE queue_status = 'open'),
    'waiting_for_fangeo_count',
      COUNT(*) FILTER (WHERE queue_status = 'waiting_for_fangeo'),
    'chat_open_count',
      COUNT(*) FILTER (WHERE queue_status = 'chat_open'),
    'waiting_for_user_count',
      COUNT(*) FILTER (WHERE queue_status = 'waiting_for_user'),
    'resolved_today_count',
      COUNT(*) FILTER (
        WHERE queue_status = 'resolved'
          AND COALESCE(closed_at, updated_at) >= date_trunc('day', now())
      ),
    'cancelled_by_users_count',
      COUNT(*) FILTER (WHERE queue_status = 'cancelled'),
    'high_priority_count',
      COUNT(*) FILTER (WHERE is_high_priority AND queue_status IN ('open', 'chat_open', 'waiting_for_fangeo', 'waiting_for_user'))
  )
  FROM base;
$$;

REVOKE ALL ON FUNCTION public.admin_support_inbox_summary() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_support_inbox_summary() TO service_role;
