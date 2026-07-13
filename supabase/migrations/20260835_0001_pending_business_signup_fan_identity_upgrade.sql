-- Allow the same auth user to upgrade a provisional fan account_identity to business
-- only while inserting their own businesses row (no businesses row yet).
--
-- Security: fan -> business upgrade is NOT available on naked claim_account_type RPC
-- calls. It is enabled only when enforce_business_account_identity_guard sets a
-- one-shot session flag immediately before calling claim_account_type('business').

CREATE OR REPLACE FUNCTION public.enforce_business_account_identity_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_auth_email text;
  v_owner_email text := lower(btrim(coalesce(NEW.owner_email, '')));
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.owner_user_id IS NOT NULL AND NEW.owner_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Business owner auth user mismatch.' USING ERRCODE = '42501';
  END IF;

  SELECT lower(btrim(coalesce(email, '')))
  INTO v_auth_email
  FROM auth.users
  WHERE id = auth.uid();

  IF v_owner_email <> '' AND v_owner_email <> v_auth_email THEN
    RAISE EXCEPTION 'Business owner email must match the authenticated user email.' USING ERRCODE = '42501';
  END IF;

  PERFORM set_config('fangeo.allow_fan_to_business_identity_upgrade', 'true', true);
  PERFORM public.claim_account_type('business');
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.claim_account_type(p_account_type text)
RETURNS TABLE(account_type text, email text, account_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_account_id uuid := auth.uid();
  v_email text;
  v_existing_by_email public.account_identities%ROWTYPE;
  v_existing_by_account public.account_identities%ROWTYPE;
  v_provider text;
  v_providers jsonb;
  v_is_apple boolean := false;
  v_email_verified boolean := false;
  v_allow_fan_upgrade boolean := false;
  v_can_upgrade_fan_to_business boolean := false;
BEGIN
  p_account_type := lower(btrim(coalesce(p_account_type, '')));
  IF p_account_type NOT IN ('fan', 'business') THEN
    RAISE EXCEPTION 'Invalid account type.' USING ERRCODE = '22023';
  END IF;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'You must be signed in to continue.' USING ERRCODE = '28000';
  END IF;

  SELECT
    lower(btrim(coalesce(u.email, ''))),
    u.raw_app_meta_data ->> 'provider',
    u.raw_app_meta_data -> 'providers',
    (
      u.email_confirmed_at IS NOT NULL
      OR lower(coalesce(u.raw_app_meta_data ->> 'provider', '')) = 'apple'
      OR coalesce(u.raw_app_meta_data -> 'providers', '[]'::jsonb) ? 'apple'
    )
  INTO v_email, v_provider, v_providers, v_email_verified
  FROM auth.users u
  WHERE u.id = v_account_id;

  IF v_email IS NULL OR v_email = '' THEN
    RAISE EXCEPTION 'A verified email address is required.' USING ERRCODE = '28000';
  END IF;

  v_is_apple := lower(coalesce(v_provider, '')) = 'apple'
    OR coalesce(v_providers, '[]'::jsonb) ? 'apple';

  IF NOT v_email_verified AND NOT v_is_apple THEN
    RAISE EXCEPTION 'Please verify your email before continuing.' USING ERRCODE = '28000';
  END IF;

  v_allow_fan_upgrade := coalesce(
    current_setting('fangeo.allow_fan_to_business_identity_upgrade', true),
    ''
  ) = 'true';

  v_can_upgrade_fan_to_business := p_account_type = 'business'
    AND v_allow_fan_upgrade
    AND NOT EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE coalesce(lower(btrim(b.admin_status)), 'active') IN ('active', 'archived', 'disabled')
        AND (
          b.owner_user_id = v_account_id
          OR lower(btrim(coalesce(b.owner_email, ''))) = v_email
        )
    );

  SELECT *
  INTO v_existing_by_email
  FROM public.account_identities ai
  WHERE ai.email = v_email
  LIMIT 1;

  IF FOUND THEN
    IF v_existing_by_email.account_id = v_account_id
       AND v_existing_by_email.account_type = p_account_type THEN
      RETURN QUERY
      SELECT v_existing_by_email.account_type, v_existing_by_email.email, v_existing_by_email.account_id;
      RETURN;
    END IF;

    IF v_can_upgrade_fan_to_business
       AND v_existing_by_email.account_id = v_account_id
       AND v_existing_by_email.account_type = 'fan'
       AND lower(btrim(v_existing_by_email.email)) = v_email THEN
      UPDATE public.account_identities ai
      SET email = v_email,
          account_type = 'business'
      WHERE ai.account_id = v_account_id
      RETURNING ai.account_type, ai.email, ai.account_id
      INTO account_type, email, account_id;
      RETURN NEXT;
      RETURN;
    END IF;

    IF v_existing_by_email.account_type = 'fan' THEN
      RAISE EXCEPTION 'Email already used for a Fan account.' USING ERRCODE = '23505';
    ELSE
      RAISE EXCEPTION 'Email already used for a Business account.' USING ERRCODE = '23505';
    END IF;
  END IF;

  SELECT *
  INTO v_existing_by_account
  FROM public.account_identities ai
  WHERE ai.account_id = v_account_id
  LIMIT 1;

  IF FOUND THEN
    IF v_existing_by_account.account_type = p_account_type THEN
      UPDATE public.account_identities ai
      SET email = v_email
      WHERE ai.account_id = v_account_id
      RETURNING ai.account_type, ai.email, ai.account_id
      INTO account_type, email, account_id;
      RETURN NEXT;
      RETURN;
    END IF;

    IF v_can_upgrade_fan_to_business
       AND v_existing_by_account.account_type = 'fan'
       AND lower(btrim(v_existing_by_account.email)) = v_email THEN
      UPDATE public.account_identities ai
      SET email = v_email,
          account_type = 'business'
      WHERE ai.account_id = v_account_id
      RETURNING ai.account_type, ai.email, ai.account_id
      INTO account_type, email, account_id;
      RETURN NEXT;
      RETURN;
    END IF;

    IF v_existing_by_account.account_type = 'fan' THEN
      RAISE EXCEPTION 'This auth user is already claimed as a Fan account.' USING ERRCODE = '23505';
    ELSE
      RAISE EXCEPTION 'This auth user is already claimed as a Business account.' USING ERRCODE = '23505';
    END IF;
  END IF;

  INSERT INTO public.account_identities(account_id, email, account_type)
  VALUES (v_account_id, v_email, p_account_type)
  RETURNING account_identities.account_type, account_identities.email, account_identities.account_id
  INTO account_type, email, account_id;

  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_account_type(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_account_type(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
