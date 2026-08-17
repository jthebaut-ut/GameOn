-- =============================================================================
-- 20260952_0001 — Fan Team event lineups (Starting / Bench + positions)
-- =============================================================================
-- Event-specific lineups for Team-linked pickup_games.
-- Player identity / jersey number / role stay on fan_team_members + profiles.
--
-- Position codes are validated against pickup_games.sport using the same
-- canonical catalogs as client FanTeamSportPositions.
-- Writes are RPC-only (SECURITY DEFINER); authenticated has SELECT only.
--
-- Do NOT apply from the agent; review and apply deliberately in Supabase.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Role helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fan_team_role_can_manage_lineup(p_role text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT lower(coalesce(p_role, '')) IN (
    'owner',
    'manager',
    'head_coach',
    'assistant_coach'
  );
$$;

CREATE OR REPLACE FUNCTION public.fan_team_viewer_can_manage_lineup(p_team_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.fan_team_members m
    WHERE m.team_id = p_team_id
      AND m.user_id = auth.uid()
      AND m.left_at IS NULL
      AND public.fan_team_role_can_manage_lineup(m.role)
  );
$$;

REVOKE ALL ON FUNCTION public.fan_team_role_can_manage_lineup(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fan_team_role_can_manage_lineup(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_role_can_manage_lineup(text) TO service_role;

REVOKE ALL ON FUNCTION public.fan_team_viewer_can_manage_lineup(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fan_team_viewer_can_manage_lineup(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_viewer_can_manage_lineup(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 1b) Position / formation policy (mirrors FanTeamSportPositions)
-- ---------------------------------------------------------------------------
-- Normalize submitted codes: trim + uppercase. Empty → NULL.
CREATE OR REPLACE FUNCTION public.fan_team_event_normalize_position_code(p_position_code text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT nullif(upper(btrim(coalesce(p_position_code, ''))), '');
$$;

-- Map pickup_games.sport (and common aliases) → position family token.
-- NULL = unsupported sport (positions not allowed).
CREATE OR REPLACE FUNCTION public.fan_team_event_position_family(p_sport text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(btrim(coalesce(p_sport, '')))
    WHEN 'soccer' THEN 'soccer'
    WHEN 'football soccer' THEN 'soccer'
    WHEN 'baseball' THEN 'baseball'
    WHEN 'softball' THEN 'baseball'
    WHEN 'nba' THEN 'basketball'
    WHEN 'basketball' THEN 'basketball'
    WHEN 'nfl' THEN 'american_football'
    WHEN 'football' THEN 'american_football'
    WHEN 'american football' THEN 'american_football'
    WHEN 'nhl' THEN 'hockey'
    WHEN 'hockey' THEN 'hockey'
    WHEN 'volleyball' THEN 'volleyball'
    ELSE NULL
  END;
$$;

-- NULL / empty position always valid. Non-NULL requires a matching family code.
CREATE OR REPLACE FUNCTION public.fan_team_event_position_code_is_valid(
  p_sport text,
  p_position_code text
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN public.fan_team_event_normalize_position_code(p_position_code) IS NULL THEN
      true
    WHEN public.fan_team_event_position_family(p_sport) IS NULL THEN
      false
    WHEN public.fan_team_event_position_family(p_sport) = 'soccer'
      AND public.fan_team_event_normalize_position_code(p_position_code) = ANY (ARRAY[
        'GK', 'LB', 'CB', 'RB', 'LWB', 'RWB',
        'CDM', 'CM', 'CAM', 'LM', 'RM',
        'LW', 'RW', 'CF', 'ST',
        'DEF', 'MID', 'FWD'
      ]::text[]) THEN
      true
    WHEN public.fan_team_event_position_family(p_sport) = 'baseball'
      AND public.fan_team_event_normalize_position_code(p_position_code) = ANY (ARRAY[
        'P', 'C', '1B', '2B', '3B', 'SS', 'LF', 'CF', 'RF', 'DH'
      ]::text[]) THEN
      true
    WHEN public.fan_team_event_position_family(p_sport) = 'basketball'
      AND public.fan_team_event_normalize_position_code(p_position_code) = ANY (ARRAY[
        'PG', 'SG', 'SF', 'PF', 'C'
      ]::text[]) THEN
      true
    WHEN public.fan_team_event_position_family(p_sport) = 'american_football'
      AND public.fan_team_event_normalize_position_code(p_position_code) = ANY (ARRAY[
        'QB', 'RB', 'WR', 'TE', 'OL', 'DL', 'LB', 'CB', 'S', 'K', 'P'
      ]::text[]) THEN
      true
    WHEN public.fan_team_event_position_family(p_sport) = 'hockey'
      AND public.fan_team_event_normalize_position_code(p_position_code) = ANY (ARRAY[
        'G', 'LD', 'RD', 'C', 'LW', 'RW'
      ]::text[]) THEN
      true
    WHEN public.fan_team_event_position_family(p_sport) = 'volleyball'
      AND public.fan_team_event_normalize_position_code(p_position_code) = ANY (ARRAY[
        'S', 'OH', 'OPP', 'MB', 'L', 'DS'
      ]::text[]) THEN
      true
    ELSE
      false
  END;
$$;

-- Soccer-only formation metadata (nullable free text within length bound).
CREATE OR REPLACE FUNCTION public.fan_team_event_sport_supports_formation(p_sport text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT public.fan_team_event_position_family(p_sport) = 'soccer';
$$;

COMMENT ON FUNCTION public.fan_team_event_normalize_position_code(text) IS
  'Trim + uppercase lineup position_code; empty → NULL.';
COMMENT ON FUNCTION public.fan_team_event_position_family(text) IS
  'Maps pickup_games.sport to lineup position family (soccer/baseball/…). NULL = unsupported.';
COMMENT ON FUNCTION public.fan_team_event_position_code_is_valid(text, text) IS
  'Sport-scoped position allowlist (FanTeamSportPositions). NULL code always valid.';
COMMENT ON FUNCTION public.fan_team_event_sport_supports_formation(text) IS
  'True only for soccer-family events; non-soccer formations are forced NULL on save.';

REVOKE ALL ON FUNCTION public.fan_team_event_normalize_position_code(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fan_team_event_normalize_position_code(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_event_normalize_position_code(text) TO service_role;

REVOKE ALL ON FUNCTION public.fan_team_event_position_family(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fan_team_event_position_family(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_event_position_family(text) TO service_role;

REVOKE ALL ON FUNCTION public.fan_team_event_position_code_is_valid(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fan_team_event_position_code_is_valid(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_event_position_code_is_valid(text, text) TO service_role;

REVOKE ALL ON FUNCTION public.fan_team_event_sport_supports_formation(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fan_team_event_sport_supports_formation(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_event_sport_supports_formation(text) TO service_role;

-- ---------------------------------------------------------------------------
-- 2) Tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.fan_team_event_lineups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id uuid NOT NULL REFERENCES public.fan_teams (id) ON DELETE CASCADE,
  pickup_game_id uuid NOT NULL REFERENCES public.pickup_games (id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'published')),
  formation text,
  published_at timestamptz,
  published_by uuid REFERENCES auth.users (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fan_team_event_lineups_team_game_uidx UNIQUE (team_id, pickup_game_id),
  CONSTRAINT fan_team_event_lineups_formation_len_ck
    CHECK (formation IS NULL OR char_length(btrim(formation)) BETWEEN 1 AND 40)
);

CREATE TABLE IF NOT EXISTS public.fan_team_event_lineup_members (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lineup_id uuid NOT NULL REFERENCES public.fan_team_event_lineups (id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users (id),
  lineup_status text NOT NULL
    CHECK (lineup_status IN ('starting', 'bench')),
  position_code text,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fan_team_event_lineup_members_unique UNIQUE (lineup_id, user_id),
  CONSTRAINT fan_team_event_lineup_members_position_len_ck
    CHECK (position_code IS NULL OR char_length(btrim(position_code)) BETWEEN 1 AND 16)
);

CREATE INDEX IF NOT EXISTS fan_team_event_lineups_game_idx
  ON public.fan_team_event_lineups (pickup_game_id);

CREATE INDEX IF NOT EXISTS fan_team_event_lineup_members_lineup_sort_idx
  ON public.fan_team_event_lineup_members (lineup_id, lineup_status, sort_order);

COMMENT ON TABLE public.fan_team_event_lineups IS
  'Team event lineup header (draft/published). One per team_id + pickup_game_id. published_at/by = most recent publish.';
COMMENT ON TABLE public.fan_team_event_lineup_members IS
  'Lineup rows: starting/bench + optional sport-scoped position_code. Identity from Team roster.';

ALTER TABLE public.fan_team_event_lineups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fan_team_event_lineup_members ENABLE ROW LEVEL SECURITY;

-- Active Team members may SELECT published lineups; managers may SELECT drafts.
DROP POLICY IF EXISTS fan_team_event_lineups_select ON public.fan_team_event_lineups;
CREATE POLICY fan_team_event_lineups_select ON public.fan_team_event_lineups
  FOR SELECT TO authenticated
  USING (
    public.is_active_fan_team_member(team_id, auth.uid())
    AND (
      status = 'published'
      OR public.fan_team_viewer_can_manage_lineup(team_id)
    )
  );

DROP POLICY IF EXISTS fan_team_event_lineup_members_select ON public.fan_team_event_lineup_members;
CREATE POLICY fan_team_event_lineup_members_select ON public.fan_team_event_lineup_members
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.fan_team_event_lineups l
      WHERE l.id = lineup_id
        AND public.is_active_fan_team_member(l.team_id, auth.uid())
        AND (
          l.status = 'published'
          OR public.fan_team_viewer_can_manage_lineup(l.team_id)
        )
    )
  );

-- Drop any accidental write policies (RPC-only writes).
DO $$
DECLARE
  pol record;
BEGIN
  FOR pol IN
    SELECT policyname, tablename
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename IN ('fan_team_event_lineups', 'fan_team_event_lineup_members')
      AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
  LOOP
    EXECUTE format(
      'DROP POLICY IF EXISTS %I ON public.%I',
      pol.policyname,
      pol.tablename
    );
  END LOOP;
END $$;

-- Writes via SECURITY DEFINER RPCs only.
REVOKE ALL ON TABLE public.fan_team_event_lineups FROM PUBLIC;
REVOKE ALL ON TABLE public.fan_team_event_lineups FROM anon;
REVOKE ALL ON TABLE public.fan_team_event_lineups FROM authenticated;
REVOKE ALL ON TABLE public.fan_team_event_lineup_members FROM PUBLIC;
REVOKE ALL ON TABLE public.fan_team_event_lineup_members FROM anon;
REVOKE ALL ON TABLE public.fan_team_event_lineup_members FROM authenticated;

GRANT SELECT ON TABLE public.fan_team_event_lineups TO authenticated;
GRANT SELECT ON TABLE public.fan_team_event_lineup_members TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.fan_team_event_lineups FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.fan_team_event_lineup_members FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.fan_team_event_lineups FROM anon;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.fan_team_event_lineup_members FROM anon;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.fan_team_event_lineups FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.fan_team_event_lineup_members FROM PUBLIC;

GRANT ALL ON TABLE public.fan_team_event_lineups TO service_role;
GRANT ALL ON TABLE public.fan_team_event_lineup_members TO service_role;

-- ---------------------------------------------------------------------------
-- 3) get_fan_team_event_lineup
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_fan_team_event_lineup(
  p_pickup_game_id uuid,
  p_team_id uuid DEFAULT NULL
)
RETURNS TABLE (
  lineup_id uuid,
  team_id uuid,
  pickup_game_id uuid,
  status text,
  formation text,
  published_at timestamptz,
  published_by uuid,
  updated_at timestamptz,
  viewer_can_manage boolean,
  members jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_team_id uuid;
  v_lineup public.fan_team_event_lineups%ROWTYPE;
  v_can_manage boolean;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_pickup_game_id IS NULL THEN
    RAISE EXCEPTION 'Pickup game is required.';
  END IF;

  IF p_team_id IS NOT NULL THEN
    v_team_id := p_team_id;
  ELSE
    SELECT l.team_id
    INTO v_team_id
    FROM public.fan_team_game_links l
    WHERE l.pickup_game_id = p_pickup_game_id
    ORDER BY CASE l.side WHEN 'home' THEN 0 WHEN 'solo' THEN 1 ELSE 2 END
    LIMIT 1;
  END IF;

  IF v_team_id IS NULL THEN
    RAISE EXCEPTION 'Team link not found for this event.';
  END IF;

  IF NOT public.is_active_fan_team_member(v_team_id, me) THEN
    RAISE EXCEPTION 'Not a team member.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.fan_team_game_links l
    WHERE l.pickup_game_id = p_pickup_game_id
      AND l.team_id = v_team_id
  ) THEN
    RAISE EXCEPTION 'Team is not linked to this event.';
  END IF;

  v_can_manage := public.fan_team_viewer_can_manage_lineup(v_team_id);

  SELECT *
  INTO v_lineup
  FROM public.fan_team_event_lineups l
  WHERE l.team_id = v_team_id
    AND l.pickup_game_id = p_pickup_game_id;

  IF v_lineup.id IS NULL THEN
    lineup_id := NULL;
    team_id := v_team_id;
    pickup_game_id := p_pickup_game_id;
    status := NULL;
    formation := NULL;
    published_at := NULL;
    published_by := NULL;
    updated_at := NULL;
    viewer_can_manage := v_can_manage;
    members := '[]'::jsonb;
    RETURN NEXT;
    RETURN;
  END IF;

  IF v_lineup.status = 'draft' AND NOT v_can_manage THEN
    -- Members do not see unfinished drafts.
    lineup_id := NULL;
    team_id := v_team_id;
    pickup_game_id := p_pickup_game_id;
    status := NULL;
    formation := NULL;
    published_at := NULL;
    published_by := NULL;
    updated_at := NULL;
    viewer_can_manage := false;
    members := '[]'::jsonb;
    RETURN NEXT;
    RETURN;
  END IF;

  lineup_id := v_lineup.id;
  team_id := v_lineup.team_id;
  pickup_game_id := v_lineup.pickup_game_id;
  status := v_lineup.status;
  formation := v_lineup.formation;
  published_at := v_lineup.published_at;
  published_by := v_lineup.published_by;
  updated_at := v_lineup.updated_at;
  viewer_can_manage := v_can_manage;
  members := coalesce((
    SELECT jsonb_agg(
      jsonb_build_object(
        'user_id', m.user_id,
        'lineup_status', m.lineup_status,
        'position_code', m.position_code,
        'sort_order', m.sort_order
      )
      ORDER BY
        CASE m.lineup_status WHEN 'starting' THEN 0 ELSE 1 END,
        m.sort_order ASC,
        m.created_at ASC
    )
    FROM public.fan_team_event_lineup_members m
    WHERE m.lineup_id = v_lineup.id
  ), '[]'::jsonb);

  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.get_fan_team_event_lineup(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_fan_team_event_lineup(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_fan_team_event_lineup(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_fan_team_event_lineup(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 4) save_fan_team_event_lineup — atomic replace of members
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.save_fan_team_event_lineup(
  p_pickup_game_id uuid,
  p_team_id uuid,
  p_status text,
  p_formation text DEFAULT NULL,
  p_members jsonb DEFAULT '[]'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_status text := lower(btrim(coalesce(p_status, 'draft')));
  v_formation text := nullif(btrim(coalesce(p_formation, '')), '');
  v_lineup_id uuid;
  v_elem jsonb;
  v_user uuid;
  v_member_status text;
  v_position text;
  v_sort int;
  v_seen uuid[] := ARRAY[]::uuid[];
  v_game_status text;
  v_sport text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_pickup_game_id IS NULL OR p_team_id IS NULL THEN
    RAISE EXCEPTION 'Team and pickup game are required.';
  END IF;
  IF v_status NOT IN ('draft', 'published') THEN
    RAISE EXCEPTION 'Invalid lineup status.';
  END IF;
  IF NOT public.fan_team_viewer_can_manage_lineup(p_team_id) THEN
    RAISE EXCEPTION 'Only coaches and managers can edit lineups.';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.fan_team_game_links l
    WHERE l.pickup_game_id = p_pickup_game_id
      AND l.team_id = p_team_id
  ) THEN
    RAISE EXCEPTION 'Team is not linked to this event.';
  END IF;

  SELECT
    lower(btrim(coalesce(g.status, ''))),
    g.sport
  INTO v_game_status, v_sport
  FROM public.pickup_games g
  WHERE g.id = p_pickup_game_id;

  IF v_game_status IS NULL THEN
    RAISE EXCEPTION 'Event not found.';
  END IF;
  IF v_game_status IS DISTINCT FROM 'active' AND v_status = 'published' THEN
    RAISE EXCEPTION 'Cannot publish a lineup for a cancelled event.';
  END IF;

  -- Formation is soccer metadata only; non-soccer always NULL.
  IF NOT public.fan_team_event_sport_supports_formation(v_sport) THEN
    v_formation := NULL;
  ELSIF v_formation IS NOT NULL AND char_length(v_formation) > 40 THEN
    RAISE EXCEPTION 'Invalid formation.';
  END IF;

  INSERT INTO public.fan_team_event_lineups (
    team_id,
    pickup_game_id,
    status,
    formation,
    published_at,
    published_by,
    updated_at
  )
  VALUES (
    p_team_id,
    p_pickup_game_id,
    v_status,
    v_formation,
    CASE WHEN v_status = 'published' THEN now() ELSE NULL END,
    CASE WHEN v_status = 'published' THEN me ELSE NULL END,
    now()
  )
  ON CONFLICT (team_id, pickup_game_id) DO UPDATE
    SET status = EXCLUDED.status,
        formation = EXCLUDED.formation,
        -- Last successful publish wins (not first-publish coalesce).
        published_at = CASE
          WHEN EXCLUDED.status = 'published' THEN now()
          ELSE public.fan_team_event_lineups.published_at
        END,
        published_by = CASE
          WHEN EXCLUDED.status = 'published' THEN me
          ELSE public.fan_team_event_lineups.published_by
        END,
        updated_at = now()
  RETURNING id INTO v_lineup_id;

  DELETE FROM public.fan_team_event_lineup_members
  WHERE lineup_id = v_lineup_id;

  FOR v_elem IN
    SELECT value
    FROM jsonb_array_elements(coalesce(p_members, '[]'::jsonb))
  LOOP
    BEGIN
      v_user := (v_elem->>'user_id')::uuid;
    EXCEPTION WHEN others THEN
      CONTINUE;
    END;
    IF v_user IS NULL THEN
      CONTINUE;
    END IF;
    IF v_user = ANY (v_seen) THEN
      RAISE EXCEPTION 'Duplicate lineup player.';
    END IF;

    IF NOT public.is_active_fan_team_member(p_team_id, v_user) THEN
      RAISE EXCEPTION 'Lineup player is not an active Team member.';
    END IF;

    v_member_status := lower(btrim(coalesce(v_elem->>'lineup_status', '')));
    IF v_member_status NOT IN ('starting', 'bench') THEN
      RAISE EXCEPTION 'Invalid lineup status for member.';
    END IF;

    v_position := public.fan_team_event_normalize_position_code(v_elem->>'position_code');
    IF NOT public.fan_team_event_position_code_is_valid(v_sport, v_position) THEN
      RAISE EXCEPTION 'Invalid position for this sport.';
    END IF;

    BEGIN
      v_sort := coalesce((v_elem->>'sort_order')::integer, 0);
    EXCEPTION WHEN others THEN
      v_sort := 0;
    END;

    INSERT INTO public.fan_team_event_lineup_members (
      lineup_id, user_id, lineup_status, position_code, sort_order
    ) VALUES (
      v_lineup_id, v_user, v_member_status, v_position, v_sort
    );

    v_seen := array_append(v_seen, v_user);
  END LOOP;

  RETURN v_lineup_id;
END;
$$;

REVOKE ALL ON FUNCTION public.save_fan_team_event_lineup(uuid, uuid, text, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.save_fan_team_event_lineup(uuid, uuid, text, text, jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION public.save_fan_team_event_lineup(uuid, uuid, text, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_fan_team_event_lineup(uuid, uuid, text, text, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- 5) publish_fan_team_event_lineup
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.publish_fan_team_event_lineup(
  p_pickup_game_id uuid,
  p_team_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_lineup_id uuid;
  v_members jsonb;
  v_formation text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  SELECT l.id, l.formation
  INTO v_lineup_id, v_formation
  FROM public.fan_team_event_lineups l
  WHERE l.team_id = p_team_id
    AND l.pickup_game_id = p_pickup_game_id;

  IF v_lineup_id IS NULL THEN
    RAISE EXCEPTION 'No lineup to publish.';
  END IF;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'user_id', m.user_id,
      'lineup_status', m.lineup_status,
      'position_code', m.position_code,
      'sort_order', m.sort_order
    )
  ), '[]'::jsonb)
  INTO v_members
  FROM public.fan_team_event_lineup_members m
  WHERE m.lineup_id = v_lineup_id;

  -- save_… with status=published refreshes published_at / published_by to now()/me.
  RETURN public.save_fan_team_event_lineup(
    p_pickup_game_id,
    p_team_id,
    'published',
    v_formation,
    v_members
  );
END;
$$;

REVOKE ALL ON FUNCTION public.publish_fan_team_event_lineup(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.publish_fan_team_event_lineup(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.publish_fan_team_event_lineup(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.publish_fan_team_event_lineup(uuid, uuid) TO service_role;

COMMIT;
