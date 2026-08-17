-- =============================================================================
-- 20260981_0001 — Fan Team Announcement per-user Overview clear/read state
-- =============================================================================
-- Personal Overview presentation ledger for Team announcements (pickup_games
-- with game_format = announcement). Clearing NEVER deletes the announcement,
-- NEVER hides it from other members, and does NOT send push.
-- UNAPPLIED — deploy manually. Do not auto-apply from the client.
-- =============================================================================

DO $$
BEGIN
  IF to_regclass('public.pickup_games') IS NULL THEN
    RAISE EXCEPTION '20260981_0001 prerequisite missing: public.pickup_games';
  END IF;
  IF to_regclass('public.fan_team_game_links') IS NULL THEN
    RAISE EXCEPTION '20260981_0001 prerequisite missing: public.fan_team_game_links';
  END IF;
  IF to_regprocedure('public.is_active_fan_team_member(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION '20260981_0001 prerequisite missing: is_active_fan_team_member';
  END IF;
END $$;

BEGIN;

CREATE TABLE IF NOT EXISTS public.fan_team_announcement_user_state (
  announcement_id uuid NOT NULL REFERENCES public.pickup_games (id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  read_at timestamptz NULL,
  cleared_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fan_team_announcement_user_state_pkey PRIMARY KEY (announcement_id, user_id),
  CONSTRAINT fan_team_announcement_user_state_has_activity_ck CHECK (
    read_at IS NOT NULL OR cleared_at IS NOT NULL
  )
);

CREATE INDEX IF NOT EXISTS fan_team_announcement_user_state_user_cleared_idx
  ON public.fan_team_announcement_user_state (user_id, cleared_at DESC)
  WHERE cleared_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS fan_team_announcement_user_state_announcement_idx
  ON public.fan_team_announcement_user_state (announcement_id);

COMMENT ON TABLE public.fan_team_announcement_user_state IS
  'Per-user Team announcement Overview state. cleared_at hides the card for THIS '
  'user only. read_at is optional and independent of clear. Never deletes pickup_games.';

ALTER TABLE public.fan_team_announcement_user_state ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.fan_team_announcement_user_state FROM PUBLIC;
REVOKE ALL ON TABLE public.fan_team_announcement_user_state FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.fan_team_announcement_user_state TO authenticated;
GRANT ALL ON TABLE public.fan_team_announcement_user_state TO service_role;

DROP POLICY IF EXISTS fan_team_announcement_user_state_select_own
  ON public.fan_team_announcement_user_state;
CREATE POLICY fan_team_announcement_user_state_select_own
  ON public.fan_team_announcement_user_state
  FOR SELECT
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS fan_team_announcement_user_state_insert_own
  ON public.fan_team_announcement_user_state;
CREATE POLICY fan_team_announcement_user_state_insert_own
  ON public.fan_team_announcement_user_state
  FOR INSERT
  TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS fan_team_announcement_user_state_update_own
  ON public.fan_team_announcement_user_state;
CREATE POLICY fan_team_announcement_user_state_update_own
  ON public.fan_team_announcement_user_state
  FOR UPDATE
  TO authenticated
  USING (user_id = (SELECT auth.uid()))
  WITH CHECK (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS fan_team_announcement_user_state_delete_own
  ON public.fan_team_announcement_user_state;
CREATE POLICY fan_team_announcement_user_state_delete_own
  ON public.fan_team_announcement_user_state
  FOR DELETE
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

-- -----------------------------------------------------------------------------
-- list_my_cleared_fan_team_announcement_ids
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_my_cleared_fan_team_announcement_ids(p_team_id uuid)
RETURNS TABLE (announcement_id uuid)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  me uuid := (SELECT auth.uid());
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_team_id IS NULL OR NOT public.is_active_fan_team_member(p_team_id, me) THEN
    RAISE EXCEPTION 'Not allowed.';
  END IF;

  RETURN QUERY
  SELECT s.announcement_id
  FROM public.fan_team_announcement_user_state s
  INNER JOIN public.fan_team_game_links l
    ON l.pickup_game_id = s.announcement_id
   AND l.team_id = p_team_id
  INNER JOIN public.pickup_games pg
    ON pg.id = s.announcement_id
  WHERE s.user_id = me
    AND s.cleared_at IS NOT NULL
    AND lower(btrim(coalesce(pg.game_format, ''))) = 'announcement';
END;
$$;

REVOKE ALL ON FUNCTION public.list_my_cleared_fan_team_announcement_ids(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_my_cleared_fan_team_announcement_ids(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.list_my_cleared_fan_team_announcement_ids(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_my_cleared_fan_team_announcement_ids(uuid) TO service_role;

COMMENT ON FUNCTION public.list_my_cleared_fan_team_announcement_ids(uuid) IS
  'Cleared Team announcement ids for the authenticated viewer on one Team.';

-- -----------------------------------------------------------------------------
-- clear_fan_team_announcement_for_viewer
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.clear_fan_team_announcement_for_viewer(p_announcement_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  me uuid := (SELECT auth.uid());
  v_team_id uuid;
  v_format text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_announcement_id IS NULL THEN
    RAISE EXCEPTION 'Announcement required.';
  END IF;

  SELECT l.team_id, lower(btrim(coalesce(pg.game_format, '')))
  INTO v_team_id, v_format
  FROM public.pickup_games pg
  INNER JOIN public.fan_team_game_links l ON l.pickup_game_id = pg.id
  WHERE pg.id = p_announcement_id
  LIMIT 1;

  IF v_team_id IS NULL OR v_format IS DISTINCT FROM 'announcement' THEN
    RAISE EXCEPTION 'Announcement not found.';
  END IF;
  IF NOT public.is_active_fan_team_member(v_team_id, me) THEN
    RAISE EXCEPTION 'Not allowed.';
  END IF;

  INSERT INTO public.fan_team_announcement_user_state AS s (
    announcement_id,
    user_id,
    cleared_at,
    updated_at
  ) VALUES (
    p_announcement_id,
    me,
    now(),
    now()
  )
  ON CONFLICT (announcement_id, user_id) DO UPDATE
  SET
    cleared_at = COALESCE(s.cleared_at, EXCLUDED.cleared_at),
    updated_at = now();
END;
$$;

REVOKE ALL ON FUNCTION public.clear_fan_team_announcement_for_viewer(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.clear_fan_team_announcement_for_viewer(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.clear_fan_team_announcement_for_viewer(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.clear_fan_team_announcement_for_viewer(uuid) TO service_role;

COMMENT ON FUNCTION public.clear_fan_team_announcement_for_viewer(uuid) IS
  'Marks a Team announcement cleared for the viewer only. Does not delete the announcement.';

-- -----------------------------------------------------------------------------
-- mark_fan_team_announcement_read_for_viewer (optional; does not clear)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mark_fan_team_announcement_read_for_viewer(p_announcement_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  me uuid := (SELECT auth.uid());
  v_team_id uuid;
  v_format text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_announcement_id IS NULL THEN
    RAISE EXCEPTION 'Announcement required.';
  END IF;

  SELECT l.team_id, lower(btrim(coalesce(pg.game_format, '')))
  INTO v_team_id, v_format
  FROM public.pickup_games pg
  INNER JOIN public.fan_team_game_links l ON l.pickup_game_id = pg.id
  WHERE pg.id = p_announcement_id
  LIMIT 1;

  IF v_team_id IS NULL OR v_format IS DISTINCT FROM 'announcement' THEN
    RAISE EXCEPTION 'Announcement not found.';
  END IF;
  IF NOT public.is_active_fan_team_member(v_team_id, me) THEN
    RAISE EXCEPTION 'Not allowed.';
  END IF;

  INSERT INTO public.fan_team_announcement_user_state AS s (
    announcement_id,
    user_id,
    read_at,
    updated_at
  ) VALUES (
    p_announcement_id,
    me,
    now(),
    now()
  )
  ON CONFLICT (announcement_id, user_id) DO UPDATE
  SET
    read_at = COALESCE(s.read_at, EXCLUDED.read_at),
    updated_at = now();
END;
$$;

REVOKE ALL ON FUNCTION public.mark_fan_team_announcement_read_for_viewer(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mark_fan_team_announcement_read_for_viewer(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.mark_fan_team_announcement_read_for_viewer(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_fan_team_announcement_read_for_viewer(uuid) TO service_role;

COMMENT ON FUNCTION public.mark_fan_team_announcement_read_for_viewer(uuid) IS
  'Sets read_at for the viewer without clearing Overview visibility.';

COMMIT;
