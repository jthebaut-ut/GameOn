-- MANUAL EXECUTION ONLY — do not auto-apply from the app.
-- Tightens one-time Regular active-venue selection after Pro → Regular.
--
-- Changes vs current `save_free_active_business_venues` / `enforce_business_plan_venue_locks`:
-- 1) Reject a second owner submission when `businesses.free_active_venues_selected_at` is set.
-- 2) Require an exact selected count equal to the effective Regular venue limit (when limited).
-- 3) Defer automatic excess locking on Pro → Regular until the owner completes selection
--    (`free_active_venues_selected_at IS NULL`), so cancel leaves venues unchanged by this path.
--
-- Returning to Pro still unlocks `plan_locked` venues without clearing `free_active_venues_selected_at`
-- (historical selection state preserved; admin reopen remains available).

CREATE OR REPLACE FUNCTION public.save_free_active_business_venues(
  p_business_id uuid,
  p_active_venue_ids uuid[]
)
RETURNS TABLE (
  success boolean,
  active_count integer,
  locked_count integer
)
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
DECLARE
  v_business public.businesses%ROWTYPE;
  v_is_pro_active boolean;
  v_venue_limit integer;
  v_selected_count integer;
  v_invalid_count integer;
  v_locked_count integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;

  SELECT *
    INTO v_business
  FROM public.businesses
  WHERE id = p_business_id
    AND lower(btrim(coalesce(admin_status, ''))) = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'business_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT public.business_entitlement_caller_owns_business(p_business_id) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE = '42501';
  END IF;

  -- One-time enforcement: historical `free_active_venues_selected_at` survives Pro upgrades.
  IF v_business.free_active_venues_selected_at IS NOT NULL THEN
    RAISE EXCEPTION 'active_venue_selection_already_completed' USING ERRCODE = 'P0001';
  END IF;

  v_is_pro_active := public.admin_venue_override_is_pro(v_business);
  IF v_is_pro_active THEN
    RAISE EXCEPTION 'business_is_pro' USING ERRCODE = 'P0001';
  END IF;

  v_venue_limit := public.business_effective_active_venue_limit(v_business);

  WITH selected AS (
    SELECT DISTINCT unnest(coalesce(p_active_venue_ids, ARRAY[]::uuid[])) AS venue_id
  )
  SELECT count(*)::integer
    INTO v_selected_count
  FROM selected
  WHERE venue_id IS NOT NULL;

  IF v_selected_count = 0 THEN
    RAISE EXCEPTION 'no_active_venues_selected' USING ERRCODE = '22023';
  END IF;

  -- NULL effective limit = unlimited Free override (exact-count rule does not apply).
  IF v_venue_limit IS NOT NULL AND v_selected_count <> v_venue_limit THEN
    RAISE EXCEPTION 'active_venue_selection_count_mismatch' USING ERRCODE = 'P0001';
  END IF;

  WITH selected AS (
    SELECT DISTINCT unnest(coalesce(p_active_venue_ids, ARRAY[]::uuid[])) AS venue_id
  ),
  invalid_selected AS (
    SELECT s.venue_id
    FROM selected s
    LEFT JOIN public.admin_business_managed_venue_ids(p_business_id) mv ON mv.venue_id = s.venue_id
    WHERE s.venue_id IS NOT NULL
      AND mv.venue_id IS NULL
  )
  SELECT count(*)::integer
    INTO v_invalid_count
  FROM invalid_selected;

  IF v_invalid_count > 0 THEN
    RAISE EXCEPTION 'selected_venue_not_owned_by_business' USING ERRCODE = '42501';
  END IF;

  PERFORM set_config('app.business_plan_lock_enforcement', 'on', true);

  WITH selected AS (
    SELECT DISTINCT unnest(coalesce(p_active_venue_ids, ARRAY[]::uuid[])) AS venue_id
  )
  UPDATE public.venues v
  SET admin_status = CASE
    WHEN EXISTS (SELECT 1 FROM selected s WHERE s.venue_id = v.id) THEN 'active'
    ELSE 'plan_locked'
  END
  WHERE v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(p_business_id));

  UPDATE public.businesses
  SET
    free_active_venues_selected_at = now(),
    entitlement_updated_at = now()
  WHERE id = p_business_id
    AND free_active_venues_selected_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'active_venue_selection_already_completed' USING ERRCODE = 'P0001';
  END IF;

  SELECT
    count(*) FILTER (WHERE lower(btrim(coalesce(v.admin_status, 'active'))) = 'active')::integer,
    count(*) FILTER (WHERE lower(btrim(coalesce(v.admin_status, 'active'))) = 'plan_locked')::integer
    INTO v_selected_count, v_locked_count
  FROM public.venues v
  WHERE v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(p_business_id));

  RETURN QUERY
  SELECT true, coalesce(v_selected_count, 0), coalesce(v_locked_count, 0);
END;
$$;

CREATE OR REPLACE FUNCTION public.enforce_business_plan_venue_locks(p_business_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
DECLARE
  v_business public.businesses%ROWTYPE;
  v_plan_type text;
  v_plan_status text;
  v_effective_limit integer;
  v_active_venue_count integer;
  v_row record;
BEGIN
  SELECT *
    INTO v_business
  FROM public.businesses
  WHERE id = p_business_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_plan_type := lower(btrim(coalesce(v_business.plan_type, 'free')));
  v_plan_status := lower(btrim(coalesce(v_business.plan_status, 'active')));
  v_effective_limit := public.business_effective_active_venue_limit(v_business);

  PERFORM set_config('app.business_plan_lock_enforcement', 'on', true);

  SELECT count(*)::integer
    INTO v_active_venue_count
  FROM public.venues v
  WHERE v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(p_business_id))
    AND lower(btrim(coalesce(v.admin_status, 'active'))) = 'active';

  -- Pro OR active unlimited Free override: unlock plan_locked managed venues.
  IF v_effective_limit IS NULL THEN
    FOR v_row IN
      UPDATE public.venues v
      SET admin_status = 'active'
      WHERE v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(p_business_id))
        AND lower(btrim(coalesce(v.admin_status, ''))) = 'plan_locked'
      RETURNING v.id
    LOOP
      RAISE NOTICE '[BusinessPlanLock] businessId=% venueId=% previousStatus=% newStatus=% activeVenueCount=% planType=% planStatus=% downgradeDetected=%',
        p_business_id, v_row.id, 'plan_locked', 'active', v_active_venue_count, v_plan_type, v_plan_status, false;
    END LOOP;
    RETURN;
  END IF;

  -- Defer auto-lock until the owner completes one-time Regular active-venue selection.
  IF v_business.free_active_venues_selected_at IS NULL THEN
    RAISE NOTICE '[BusinessPlanLock] businessId=% skippedAutoLock reason=awaiting_free_active_venue_selection activeVenueCount=% planType=% planStatus=% venueLimit=%',
      p_business_id, v_active_venue_count, v_plan_type, v_plan_status, v_effective_limit;
    RETURN;
  END IF;

  FOR v_row IN
    WITH ranked AS (
      SELECT
        v.id,
        coalesce(nullif(btrim(v.admin_status), ''), 'active') AS previous_status,
        row_number() OVER (ORDER BY v.created_at DESC NULLS LAST, v.id DESC) AS active_rank
      FROM public.venues v
      WHERE v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(p_business_id))
        AND lower(btrim(coalesce(v.admin_status, 'active'))) = 'active'
    )
    UPDATE public.venues v
    SET admin_status = 'plan_locked'
    FROM ranked r
    WHERE v.id = r.id
      AND r.active_rank > COALESCE(v_effective_limit, 0)
    RETURNING v.id, r.previous_status
  LOOP
    RAISE NOTICE '[BusinessPlanLock] businessId=% venueId=% previousStatus=% newStatus=% activeVenueCount=% planType=% planStatus=% downgradeDetected=%',
      p_business_id, v_row.id, v_row.previous_status, 'plan_locked', v_active_venue_count, v_plan_type, v_plan_status, true;
  END LOOP;
END;
$$;

COMMENT ON FUNCTION public.save_free_active_business_venues(uuid, uuid[]) IS
  'One-time Free/Regular active venue selection. Verifies ownership, rejects second submissions, requires exact plan limit, and updates managed venues to active/plan_locked atomically.';

COMMENT ON FUNCTION public.enforce_business_plan_venue_locks(uuid) IS
  'Locks excess active venues when Regular selection is already completed; defers locking while free_active_venues_selected_at is null; restores plan_locked venues when Pro/unlimited returns.';
