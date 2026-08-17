-- Staging checks for Fan Team locations (20260978 — patch vs location replacement).
-- Manual / staging only. Do NOT run against production from the agent.
--
-- Section A: structural / catalog invariants (safe anytime after migrate).
-- Section B: identity helper + replacement key semantics (no row mutations).
-- Section C: sequential mutation checklist (organizer fixtures).
-- Section D: MANUAL Session A / Session B concurrency scripts (required).

-- =============================================================================
-- A) Structural
-- =============================================================================
DO $$
DECLARE
  r record;
  v_vol text;
  v_idxdef text;
BEGIN
  IF to_regclass('public.fan_team_locations') IS NULL THEN
    RAISE EXCEPTION 'fan_team_locations missing — apply 20260978_0001';
  END IF;

  SELECT indexdef INTO v_idxdef
  FROM pg_indexes
  WHERE schemaname = 'public' AND indexname = 'fan_team_locations_team_identity_uq';
  IF v_idxdef IS NULL OR v_idxdef NOT ILIKE '%deleted_at IS NULL%' THEN
    RAISE EXCEPTION 'team_identity_uq must be partial WHERE deleted_at IS NULL';
  END IF;

  SELECT indexdef INTO v_idxdef
  FROM pg_indexes
  WHERE schemaname = 'public' AND indexname = 'fan_team_locations_one_default_uq';
  IF v_idxdef IS NULL
     OR v_idxdef NOT ILIKE '%is_default%'
     OR v_idxdef NOT ILIKE '%is_saved%'
     OR v_idxdef NOT ILIKE '%deleted_at IS NULL%' THEN
    RAISE EXCEPTION 'one_default_uq must be partial on active saved default';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = 'fan_team_locations' AND c.relrowsecurity
  ) THEN
    RAISE EXCEPTION 'fan_team_locations RLS is not enabled';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.role_table_grants
    WHERE table_schema = 'public'
      AND table_name = 'fan_team_locations'
      AND grantee IN ('anon', 'PUBLIC')
  ) THEN
    RAISE EXCEPTION 'fan_team_locations must not be granted to anon/PUBLIC';
  END IF;

  -- No authenticated direct write grants
  IF EXISTS (
    SELECT 1 FROM information_schema.role_table_grants
    WHERE table_schema = 'public'
      AND table_name = 'fan_team_locations'
      AND grantee = 'authenticated'
      AND privilege_type IN ('INSERT', 'UPDATE', 'DELETE')
  ) THEN
    RAISE EXCEPTION 'authenticated must not have direct INSERT/UPDATE/DELETE on fan_team_locations';
  END IF;

  IF to_regprocedure('public._fan_team_location_lock_team(uuid)') IS NULL THEN
    RAISE EXCEPTION '_fan_team_location_lock_team missing';
  END IF;

  -- Replacement flag must exist; old overloads without it must be gone.
  IF to_regprocedure(
    'public.save_fan_team_location(uuid,text,text,text,text,text,double precision,double precision,text,boolean,uuid,boolean)'
  ) IS NULL THEN
    RAISE EXCEPTION 'save_fan_team_location missing p_replace_location boolean arg';
  END IF;

  IF to_regprocedure(
    'public.update_fan_team_location(uuid,text,boolean,boolean,text,text,text,text,double precision,double precision,text,boolean)'
  ) IS NULL THEN
    RAISE EXCEPTION 'update_fan_team_location missing p_replace_location boolean arg';
  END IF;

  IF to_regprocedure(
    'public.save_fan_team_location(uuid,text,text,text,text,text,double precision,double precision,text,boolean,uuid)'
  ) IS NOT NULL THEN
    RAISE EXCEPTION 'old save_fan_team_location signature without p_replace_location still present';
  END IF;
  IF to_regprocedure(
    'public.update_fan_team_location(uuid,text,boolean,boolean,text,text,text,text,double precision,double precision,text)'
  ) IS NOT NULL THEN
    RAISE EXCEPTION 'old update_fan_team_location signature without p_replace_location still present';
  END IF;

  FOR r IN
    SELECT p.oid, p.proname
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'list_fan_team_locations',
        'upsert_fan_team_location_usage',
        'save_fan_team_location',
        'update_fan_team_location',
        'remove_fan_team_saved_location',
        'clear_fan_team_recent_locations',
        '_fan_team_location_rekey_or_merge',
        '_fan_team_location_clear_other_defaults',
        '_fan_team_location_lock_team'
      )
      AND p.prosecdef
  LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM pg_proc p
      WHERE p.oid = r.oid
        AND EXISTS (
          SELECT 1
          FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) cfg
          WHERE replace(cfg, ' ', '') ILIKE 'search_path=pg_catalog,public%'
        )
    ) THEN
      RAISE EXCEPTION 'SECURITY DEFINER % missing search_path=pg_catalog, public', r.proname;
    END IF;
  END LOOP;

  SELECT p.provolatile INTO v_vol
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'fan_team_location_identity_key'
  LIMIT 1;
  IF v_vol IS DISTINCT FROM 's' THEN
    RAISE EXCEPTION 'fan_team_location_identity_key must be STABLE (got %)', v_vol;
  END IF;

  IF has_function_privilege(
    'authenticated',
    'public._fan_team_location_lock_team(uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'lock_team helper must not be EXECUTE for authenticated';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'public._fan_team_location_rekey_or_merge(uuid,uuid,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'rekey_or_merge helper must not be EXECUTE for authenticated';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'public._fan_team_location_clear_other_defaults(uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'clear_other_defaults helper must not be EXECUTE for authenticated';
  END IF;

  IF EXISTS (
    SELECT team_id, identity_key
    FROM public.fan_team_locations
    WHERE deleted_at IS NULL
    GROUP BY team_id, identity_key
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'duplicate active identity_key rows exist';
  END IF;

  IF EXISTS (
    SELECT team_id
    FROM public.fan_team_locations
    WHERE deleted_at IS NULL AND is_default AND is_saved
    GROUP BY team_id
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'more than one active default per team';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.fan_team_locations
    WHERE deleted_at IS NOT NULL AND is_default
  ) THEN
    RAISE EXCEPTION 'soft-deleted row still marked default';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.fan_team_locations
    WHERE is_saved = false AND is_default
  ) THEN
    RAISE EXCEPTION 'unsaved row marked default';
  END IF;
END $$;

-- =============================================================================
-- B) Identity helper + replacement key semantics
-- =============================================================================
DO $$
DECLARE
  v_old_provider_key text;
  v_new_manual_key text;
  v_new_provider_key text;
  v_addr_only_key text;
BEGIN
  IF public.fan_team_location_identity_key(
    'ABC123', 40.1, -111.8, '1 Main', 'Lehi', 'UT', 'Park'
  ) IS DISTINCT FROM 'provider:abc123' THEN
    RAISE EXCEPTION 'provider preference failed';
  END IF;

  IF public.fan_team_location_identity_key(
    '  AbC123  ', NULL, NULL, NULL, NULL, NULL, NULL
  ) IS DISTINCT FROM 'provider:abc123' THEN
    RAISE EXCEPTION 'provider normalize failed';
  END IF;

  IF public.fan_team_location_coords_usable(0, 0) THEN
    RAISE EXCEPTION '(0,0) must not be usable';
  END IF;

  IF public.fan_team_location_identity_key(
    NULL, NULL, NULL, '  ', ' ', '', NULL
  ) IS NOT NULL THEN
    RAISE EXCEPTION 'empty location must not invent identity';
  END IF;

  -- A) Provider → manual replacement: new key must NOT keep provider:old
  v_old_provider_key := public.fan_team_location_identity_key(
    'provider_old', 40.1, -111.8, 'Old Address', 'Lehi', 'UT', 'Park'
  );
  v_new_manual_key := public.fan_team_location_identity_key(
    NULL, 40.25, -111.85, 'New Address', 'Lehi', 'UT', NULL
  );
  IF v_old_provider_key IS DISTINCT FROM 'provider:provider_old' THEN
    RAISE EXCEPTION 'A setup: old provider key wrong: %', v_old_provider_key;
  END IF;
  IF v_new_manual_key LIKE 'provider:%' THEN
    RAISE EXCEPTION 'A: replacement key must not keep provider_old';
  END IF;
  IF v_new_manual_key IS DISTINCT FROM
       public.fan_team_location_identity_key(
         NULL, 40.25, -111.85, 'New Address', 'Lehi', 'UT', NULL
       ) THEN
    RAISE EXCEPTION 'A: replacement key unstable';
  END IF;
  IF v_new_manual_key IS NOT DISTINCT FROM v_old_provider_key THEN
    RAISE EXCEPTION 'A: replacement key must differ from old provider key';
  END IF;

  -- B) Manual → provider replacement
  v_new_provider_key := public.fan_team_location_identity_key(
    'provider_new', 40.3, -111.7, 'Somewhere', 'Orem', 'UT', 'Field'
  );
  IF v_new_provider_key IS DISTINCT FROM 'provider:provider_new' THEN
    RAISE EXCEPTION 'B: expected provider:provider_new got %', v_new_provider_key;
  END IF;

  -- C) Full location → address-only replacement (no provider, no coords)
  v_addr_only_key := public.fan_team_location_identity_key(
    NULL, NULL, NULL, 'Only Address', 'Draper', 'UT', NULL
  );
  IF v_addr_only_key IS NULL OR v_addr_only_key NOT LIKE 'addr:%' THEN
    RAISE EXCEPTION 'C: address-only replacement must use addr: key, got %', v_addr_only_key;
  END IF;
  IF v_addr_only_key LIKE 'provider:%' OR v_addr_only_key LIKE 'geo%' THEN
    RAISE EXCEPTION 'C: stale provider/geo must not survive address-only key';
  END IF;

  -- D/E) Metadata-only does not change identity helper inputs → same key
  IF public.fan_team_location_identity_key(
    'provider_old', 40.1, -111.8, 'Old Address', 'Lehi', 'UT', 'Park'
  ) IS DISTINCT FROM v_old_provider_key THEN
    RAISE EXCEPTION 'D/E: identity helper must be deterministic for unchanged fields';
  END IF;
END $$;

-- =============================================================================
-- C) Sequential mutation checklist (organizer JWT / fixtures required)
-- =============================================================================
-- Replace :team_id / :loc_a / :loc_b. Run as organizer. Prefer ROLLBACK.
--
-- 1) save new location
-- 2) save same location again → one active row; nickname/saved preserved/merged
-- 3) usage increments atomically (usage_count = usage_count + 1)
-- 4) usage on saved location does not unset saved/default/nickname
-- 5) REPLACE location (p_replace_location := true) — see A–F below
-- 6) rekey collision merge: replace A onto B → one active row; usage summed; B soft-deleted
-- 7) default transfer → one active default
-- 8) remove default / unsaved conversion
-- 9) clear_recent keeps saved defaults; soft-deletes unsaved recent-only
-- 10) soft-deleted identity excluded from list
-- 11) same identity after delete → NEW active row (no revival)
-- 12) Captain/Member denied mutations
-- 13) METADATA-ONLY (p_replace_location := false / omitted) preserves identity fields
--
-- ----- A) Provider → manual replacement -----
-- BEGIN;
--   SELECT public.save_fan_team_location(
--     :team_id, 'Home', 'Park', 'Old Address', 'Lehi', 'UT',
--     40.1, -111.8, 'provider_old', false, NULL, false
--   );
--   -- capture :loc_id
--   SELECT public.update_fan_team_location(
--     :loc_id, NULL, false, NULL,
--     NULL, 'New Address', 'Lehi', 'UT',
--     40.25, -111.85, NULL,
--     true  -- p_replace_location
--   );
--   -- EXPECT: provider_place_id IS NULL
--   -- EXPECT: identity_key NOT LIKE 'provider:provider_old%'
--   -- EXPECT: identity_key matches geoaddr/new address fields
--   -- EXPECT: address = 'New Address'; latitude/longitude = new coords
-- ROLLBACK;
--
-- ----- B) Manual → provider replacement -----
-- BEGIN;
--   SELECT public.save_fan_team_location(
--     :team_id, 'Home', NULL, 'Manual St', 'Lehi', 'UT',
--     40.1, -111.8, NULL, false, NULL, false
--   );
--   SELECT public.update_fan_team_location(
--     :loc_id, NULL, false, NULL,
--     'POI', '1 Main', 'Lehi', 'UT', 40.2, -111.9, 'provider_new', true
--   );
--   -- EXPECT: provider_place_id = 'provider_new'
--   -- EXPECT: identity_key = 'provider:provider_new'
-- ROLLBACK;
--
-- ----- C) Full → address-only replacement (clear provider + coords) -----
-- BEGIN;
--   -- start from provider row, then:
--   SELECT public.update_fan_team_location(
--     :loc_id, NULL, false, NULL,
--     NULL, 'Only Address', 'Draper', 'UT', NULL, NULL, NULL, true
--   );
--   -- EXPECT: provider_place_id IS NULL; latitude/longitude IS NULL
--   -- EXPECT: identity_key LIKE 'addr:%'
-- ROLLBACK;
--
-- ----- D) Nickname-only edit -----
-- BEGIN;
--   -- note provider/coords/address before
--   SELECT public.update_fan_team_location(
--     :loc_id, 'Home Field', false, NULL,
--     NULL, NULL, NULL, NULL, NULL, NULL, NULL, false
--   );
--   -- EXPECT: provider/coords/address/identity_key UNCHANGED
--   -- EXPECT: nickname = 'Home Field'
-- ROLLBACK;
--
-- ----- E) Default-only edit -----
-- BEGIN;
--   SELECT public.update_fan_team_location(
--     :loc_id, NULL, false, true,
--     NULL, NULL, NULL, NULL, NULL, NULL, NULL, false
--   );
--   -- EXPECT: identity fields UNCHANGED; is_default = true; ≤1 team default
-- ROLLBACK;
--
-- ----- F) Replacement collides with existing row -----
-- BEGIN;
--   SELECT public.save_fan_team_location(:team_id,'A','Park A','1 A','Lehi','UT',40.1,-111.8,NULL,false,NULL,false);
--   SELECT public.save_fan_team_location(:team_id,'B','Park B','2 B','Lehi','UT',40.2,-111.9,NULL,true,NULL,false);
--   -- replace A onto B's identity with p_replace_location := true
--   -- EXPECT: no unique_violation; one active identity; merged usage; ≤1 default
-- ROLLBACK;

-- =============================================================================
-- D) MANUAL concurrency (two sessions) — NOT proven by sequential SQL
-- =============================================================================
--
-- TEST A — Concurrent save same new place
-- Session A + B (same :team_id, never-used provider id 'conc-save-001'):
--   BEGIN;
--   SELECT public.save_fan_team_location(
--     :team_id, 'Nick', NULL, NULL, NULL, NULL, NULL, NULL, 'conc-save-001', false, NULL, false);
--   COMMIT;
-- Verify: exactly ONE active row for provider:conc-save-001; no unique_violation.
--
-- TEST B — Concurrent usage same new place
-- Session A + B:
--   BEGIN;
--   SELECT public.upsert_fan_team_location_usage(
--     :team_id, NULL, NULL, NULL, NULL, NULL, NULL, 'conc-use-001');
--   COMMIT;
-- Verify: one active row; usage_count = 2; nickname/is_saved/is_default unchanged
--         if row was previously saved.
--
-- TEST C — Concurrent default changes
-- Session A sets location A default; Session B sets location B default.
-- Verify: exactly one active default for the team.
--
-- TEST D — Opposite-direction rekey (optional stress)
-- Session A edits Loc1 toward Loc2 identity; Session B edits Loc2 toward Loc1.
-- Verify: no deadlock (team advisory lock serializes); final state has no
--         duplicate active identity.

DO $$
BEGIN
  RAISE NOTICE
    'fan_team_locations replacement-semantics checks PASSED. Run C + D on staging.';
END $$;
