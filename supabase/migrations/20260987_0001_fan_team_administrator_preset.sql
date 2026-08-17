-- =============================================================================
-- 20260987_0001 — Team Administrator preset (single Owner toggle)
-- =============================================================================
-- Keeps the 20260985/20260986 flexible permission architecture.
--
-- Product: Owner answers one question — "Can this person help manage the Team?"
-- Internally that is the full management key set (never ownership).
--
-- 1) Backfill: seats whose CURRENT effective permissions are the full set
--    → use_custom_permissions + granted_permissions = all keys (Administrator ON)
-- 2) Everyone else (non-owner account seats) → role-default path (Administrator OFF)
-- 3) Role defaults: Owner = all keys; every other role = none
--    (roles remain titles; management is the Administrator preset)
-- 4) Align Team Chat group-admin flag with moderate_team_chat
--
-- Non-destructive to membership / ownership / Team rows.
-- PREPARE ONLY — apply after 20260985 + 20260986.
-- =============================================================================

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.fan_team_members') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_team_members'];
  END IF;
  IF to_regclass('public.fan_teams') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_teams'];
  END IF;
  IF to_regprocedure('public.fan_team_permission_keys()') IS NULL THEN
    v_missing := v_missing || ARRAY['fan_team_permission_keys()'];
  END IF;
  IF to_regprocedure('public.fan_team_effective_permissions(text,boolean,jsonb)') IS NULL THEN
    v_missing := v_missing || ARRAY['fan_team_effective_permissions(text,boolean,jsonb)'];
  END IF;
  IF to_regprocedure('public.fan_team_role_default_permissions(text)') IS NULL THEN
    v_missing := v_missing || ARRAY['fan_team_role_default_permissions(text)'];
  END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION
      '20260987_0001 prerequisites missing: %',
      array_to_string(v_missing, ', ');
  END IF;
END $$;

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Backfill Administrator ON: current effective set contains every management key
-- -----------------------------------------------------------------------------
UPDATE public.fan_team_members m
SET
  granted_permissions = to_jsonb(public.fan_team_permission_keys()),
  use_custom_permissions = true
WHERE m.left_at IS NULL
  AND m.user_id IS NOT NULL
  AND m.managed_player_id IS NULL
  AND lower(btrim(coalesce(m.role, ''))) IS DISTINCT FROM 'owner'
  AND public.fan_team_effective_permissions(
        m.role,
        coalesce(m.use_custom_permissions, false),
        m.granted_permissions
      ) @> public.fan_team_permission_keys();

-- Administrator OFF: clear custom grants so the upcoming empty role defaults apply.
UPDATE public.fan_team_members m
SET
  granted_permissions = '[]'::jsonb,
  use_custom_permissions = false
WHERE m.left_at IS NULL
  AND m.user_id IS NOT NULL
  AND m.managed_player_id IS NULL
  AND lower(btrim(coalesce(m.role, ''))) IS DISTINCT FROM 'owner'
  AND NOT (
    public.fan_team_effective_permissions(
      m.role,
      coalesce(m.use_custom_permissions, false),
      m.granted_permissions
    ) @> public.fan_team_permission_keys()
  );

-- -----------------------------------------------------------------------------
-- 2) Role defaults: titles only (Owner retains full control)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fan_team_role_default_permissions(p_role text)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
  SELECT CASE lower(btrim(coalesce(p_role, 'member')))
    WHEN 'owner' THEN public.fan_team_permission_keys()
    ELSE ARRAY[]::text[]
  END;
$$;

COMMENT ON FUNCTION public.fan_team_role_default_permissions(text) IS
  'Role-title defaults: Owner = all management keys; every other role = none. '
  'Team Administrator is the Owner-assigned custom full set (20260987).';

-- -----------------------------------------------------------------------------
-- 3) Team Chat moderation flag follows moderate_team_chat / Owner
-- -----------------------------------------------------------------------------
-- Target alias `gcm` is visible in SET/WHERE only — never in JOIN ON (42P01).
UPDATE public.group_conversation_members gcm
SET role = CASE
  WHEN t.owner_user_id IS NOT DISTINCT FROM gcm.user_id THEN 'admin'
  WHEN 'moderate_team_chat' = ANY (
    public.fan_team_effective_permissions(
      m.role,
      coalesce(m.use_custom_permissions, false),
      m.granted_permissions
    )
  ) THEN 'admin'
  ELSE 'member'
END
FROM public.fan_teams t
JOIN public.fan_team_members m
  ON m.team_id = t.id
 AND m.left_at IS NULL
 AND m.user_id IS NOT NULL
WHERE gcm.conversation_id = t.group_conversation_id
  AND gcm.user_id IS NOT NULL
  AND m.user_id = gcm.user_id
  AND t.is_active IS TRUE
  AND t.group_conversation_id IS NOT NULL;

NOTIFY pgrst, 'reload schema';

COMMIT;
