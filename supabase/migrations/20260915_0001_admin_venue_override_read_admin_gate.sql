-- =============================================================================
-- 20260915_0001 — Admin gate for venue-override read RPCs
-- =============================================================================
-- Recreates admin_business_venue_override_summaries / _venues from the latest
-- bodies (summaries: 20260840; venues: 20260808_0013 unchanged by 20260840)
-- and adds JWT admin auth at the start of each. p_admin_email is ignored for
-- authorization (same pattern as other support-inbox admin RPCs).
--
-- Do NOT apply from the agent; review and apply deliberately.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_business_venue_override_summaries(p_admin_email text)
RETURNS TABLE (
  business_id uuid,
  display_name text,
  owner_email text,
  plan_type text,
  plan_status text,
  computed_is_pro boolean,
  venue_limit integer,
  effective_venue_limit integer,
  admin_active_venue_limit_override integer,
  approved_count integer,
  active_count integer,
  locked_count integer
)
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
BEGIN
  -- p_admin_email is intentionally unused (deprecated; client-spoofable).
  -- is_support_inbox_admin() allows service_role OR JWT @fangeosports.com.
  IF NOT public.is_support_inbox_admin() THEN
    RAISE EXCEPTION 'Access denied' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH b AS (
    SELECT *
    FROM public.businesses
    WHERE lower(btrim(coalesce(admin_status, ''))) = 'active'
  ),
  counts AS (
    SELECT
      b.id AS business_id,
      count(DISTINCT v.id)::integer AS approved_count,
      count(DISTINCT v.id) FILTER (WHERE lower(btrim(coalesce(v.admin_status, 'active'))) = 'active')::integer AS active_count,
      count(DISTINCT v.id) FILTER (WHERE lower(btrim(coalesce(v.admin_status, 'active'))) = 'plan_locked')::integer AS locked_count
    FROM b
    LEFT JOIN public.venues v ON v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(b.id))
    GROUP BY b.id
  )
  SELECT
    b.id,
    b.display_name,
    b.owner_email,
    COALESCE(NULLIF(btrim(b.plan_type), ''), 'free') AS plan_type,
    COALESCE(NULLIF(btrim(b.plan_status), ''), 'active') AS plan_status,
    public.admin_venue_override_is_pro(b) AS computed_is_pro,
    COALESCE(b.venue_limit, 5) AS venue_limit,
    public.business_effective_active_venue_limit(b) AS effective_venue_limit,
    CASE
      WHEN COALESCE(b.admin_unlimited_active_venues_override, false)
        AND (b.admin_venue_override_expires_at IS NULL OR b.admin_venue_override_expires_at > now())
        THEN NULL
      WHEN b.admin_venue_override_expires_at IS NOT NULL AND b.admin_venue_override_expires_at <= now()
        THEN NULL
      ELSE b.admin_active_venue_limit_override
    END AS admin_active_venue_limit_override,
    COALESCE(c.approved_count, 0),
    COALESCE(c.active_count, 0),
    COALESCE(c.locked_count, 0)
  FROM b
  LEFT JOIN counts c ON c.business_id = b.id
  ORDER BY lower(coalesce(b.display_name, '')), b.created_at DESC;
END;
$$;

COMMENT ON FUNCTION public.admin_business_venue_override_summaries(text) IS
  'Admin read of business active-venue override summaries. Auth via is_support_inbox_admin() (JWT @fangeosports.com domain OR service_role). p_admin_email deprecated/ignored. FOLLOW-UP: replace domain gate with explicit admin UID allowlist table.';

-- Converted from LANGUAGE sql → plpgsql so auth gates can RAISE before the query.
CREATE OR REPLACE FUNCTION public.admin_business_venue_override_venues(
  p_business_id uuid,
  p_admin_email text
)
RETURNS TABLE (
  venue_id uuid,
  business_id uuid,
  venue_name text,
  city text,
  state text,
  admin_status text,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
  -- p_admin_email is intentionally unused (deprecated; client-spoofable).
  -- is_support_inbox_admin() allows service_role OR JWT @fangeosports.com.
  IF NOT public.is_support_inbox_admin() THEN
    RAISE EXCEPTION 'Access denied' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    v.id,
    p_business_id,
    v.venue_name,
    v.city,
    v.state,
    coalesce(nullif(btrim(v.admin_status), ''), 'active') AS admin_status,
    v.created_at
  FROM public.venues v
  WHERE v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(p_business_id))
  ORDER BY
    CASE WHEN lower(btrim(coalesce(v.admin_status, 'active'))) = 'active' THEN 0 ELSE 1 END,
    v.created_at DESC NULLS LAST,
    lower(coalesce(v.venue_name, ''));
END;
$$;

COMMENT ON FUNCTION public.admin_business_venue_override_venues(uuid, text) IS
  'Admin read of managed venues for override UI. Auth via is_support_inbox_admin() (JWT/service_role). p_admin_email deprecated/ignored.';

REVOKE ALL ON FUNCTION public.admin_business_venue_override_summaries(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_business_venue_override_summaries(text) FROM anon;
REVOKE ALL ON FUNCTION public.admin_business_venue_override_venues(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_business_venue_override_venues(uuid, text) FROM anon;

GRANT EXECUTE ON FUNCTION public.admin_business_venue_override_summaries(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_business_venue_override_summaries(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_business_venue_override_venues(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_business_venue_override_venues(uuid, text) TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
