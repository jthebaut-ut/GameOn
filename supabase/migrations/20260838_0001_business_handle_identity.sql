-- Business public @handle identity (separate from fan handles and venue names).
-- Nullable for legacy businesses; new signups set business_handle at insert time.

ALTER TABLE public.businesses
  ADD COLUMN IF NOT EXISTS business_handle text;

COMMENT ON COLUMN public.businesses.business_handle IS
  'Public unique business @handle (stored without @, lowercase). Nullable for legacy rows.';

CREATE OR REPLACE FUNCTION public.businesses_sync_business_handle()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.business_handle IS NOT NULL THEN
    NEW.business_handle := public.fangeo_normalize_handle(NEW.business_handle);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_businesses_sync_business_handle ON public.businesses;
CREATE TRIGGER trg_businesses_sync_business_handle
  BEFORE INSERT OR UPDATE OF business_handle ON public.businesses
  FOR EACH ROW
  EXECUTE FUNCTION public.businesses_sync_business_handle();

CREATE UNIQUE INDEX IF NOT EXISTS idx_businesses_business_handle_unique
  ON public.businesses (public.fangeo_normalize_handle(business_handle))
  WHERE public.fangeo_normalize_handle(business_handle) IS NOT NULL;

CREATE OR REPLACE FUNCTION public.fangeo_handle_is_taken(
  p_handle text,
  p_exclude_business_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    EXISTS (
      SELECT 1
      FROM public.user_profiles up
      WHERE public.fangeo_normalize_handle(coalesce(up.handle, up.username))
        = public.fangeo_normalize_handle(p_handle)
    )
    OR EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE public.fangeo_normalize_handle(b.business_handle) = public.fangeo_normalize_handle(p_handle)
        AND b.id IS DISTINCT FROM p_exclude_business_id
    );
$$;

CREATE OR REPLACE FUNCTION public.check_business_handle_available_for_registration(p_handle text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN NOT public.fangeo_handle_is_valid(p_handle) THEN false
    ELSE NOT public.fangeo_handle_is_taken(p_handle, NULL)
  END;
$$;

CREATE OR REPLACE FUNCTION public.check_business_handle_available(
  p_handle text,
  p_exclude_business_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN auth.uid() IS NULL THEN false
    WHEN NOT public.fangeo_handle_is_valid(p_handle) THEN false
    ELSE NOT public.fangeo_handle_is_taken(p_handle, p_exclude_business_id)
  END;
$$;

REVOKE ALL ON FUNCTION public.fangeo_handle_is_taken(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fangeo_handle_is_taken(text, uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.check_business_handle_available_for_registration(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_business_handle_available_for_registration(text) TO anon, authenticated;

REVOKE ALL ON FUNCTION public.check_business_handle_available(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_business_handle_available(text, uuid) TO authenticated;

COMMENT ON FUNCTION public.check_business_handle_available_for_registration(text) IS
  'Pre-auth business signup: true when handle format is valid and not taken by a fan or business.';

COMMENT ON FUNCTION public.check_business_handle_available(text, uuid) IS
  'Authenticated business handle check; optional exclude current business id.';

DROP POLICY IF EXISTS businesses_update_identity_by_owner ON public.businesses;
CREATE POLICY businesses_update_identity_by_owner
  ON public.businesses
  FOR UPDATE
  TO authenticated
  USING (
    owner_user_id = auth.uid()
    OR (
      btrim(coalesce(owner_email, '')) <> ''
      AND lower(btrim(owner_email)) = lower(btrim(coalesce(auth.jwt() ->> 'email', '')))
    )
  )
  WITH CHECK (
    owner_user_id = auth.uid()
    OR (
      btrim(coalesce(owner_email, '')) <> ''
      AND lower(btrim(owner_email)) = lower(btrim(coalesce(auth.jwt() ->> 'email', '')))
    )
  );

COMMENT ON POLICY businesses_update_identity_by_owner ON public.businesses IS
  'Allows the owning business user to update their business row (including display_name and business_handle).';
