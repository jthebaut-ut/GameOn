-- =============================================================================
-- 20260955_0001 — Private Friend Groups (owner-only organizational lists)
-- =============================================================================
-- Friend Groups are PRIVATE lists owned by one user. They are NOT Teams, NOT
-- group chats, and NOT new friendships. Members reference accepted friends by
-- auth user id only (no profile payload copied).
--
-- Mutations: SECURITY DEFINER RPCs (mirror friendships pattern).
-- Reads: RLS SELECT owner-only on tables; preferred client path is RPCs.
-- Unfriend: trigger cleans memberships both directions when an accepted
-- user↔user friendship row is deleted (remove_friend + any future path).
--
-- Do NOT apply from the agent. Apply manually after 20260954.
-- No Edge Function required.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.friend_groups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  name text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT friend_groups_name_trimmed_nonempty
    CHECK (length(btrim(name)) >= 1 AND length(btrim(name)) <= 60),
  CONSTRAINT friend_groups_name_equals_trimmed
    CHECK (name = btrim(name))
);

CREATE UNIQUE INDEX IF NOT EXISTS friend_groups_owner_normalized_name_uidx
  ON public.friend_groups (owner_user_id, lower(btrim(name)));

CREATE INDEX IF NOT EXISTS friend_groups_owner_user_id_created_at_idx
  ON public.friend_groups (owner_user_id, created_at DESC);

COMMENT ON TABLE public.friend_groups IS
  'Private Friend Groups owned by one user. Organizational only — not Teams/chats/friendships.';

CREATE TABLE IF NOT EXISTS public.friend_group_members (
  group_id uuid NOT NULL REFERENCES public.friend_groups (id) ON DELETE CASCADE,
  friend_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (group_id, friend_user_id)
);

CREATE INDEX IF NOT EXISTS friend_group_members_friend_user_id_idx
  ON public.friend_group_members (friend_user_id);

COMMENT ON TABLE public.friend_group_members IS
  'Membership of private Friend Groups. friend_user_id must be an accepted friend of the group owner (enforced in RPCs).';

-- ---------------------------------------------------------------------------
-- RLS: owner-only SELECT; no client writes (RPC-only mutations)
-- ---------------------------------------------------------------------------

ALTER TABLE public.friend_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.friend_groups FORCE ROW LEVEL SECURITY;
ALTER TABLE public.friend_group_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.friend_group_members FORCE ROW LEVEL SECURITY;

DO $$
DECLARE
  pol record;
BEGIN
  FOR pol IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'friend_groups'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.friend_groups', pol.policyname);
  END LOOP;
  FOR pol IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'friend_group_members'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.friend_group_members', pol.policyname);
  END LOOP;
END $$;

CREATE POLICY "friend_groups_select_owner"
ON public.friend_groups
FOR SELECT
TO authenticated
USING (owner_user_id = auth.uid());

CREATE POLICY "friend_group_members_select_owner"
ON public.friend_group_members
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.friend_groups g
    WHERE g.id = friend_group_members.group_id
      AND g.owner_user_id = auth.uid()
  )
);

REVOKE INSERT, UPDATE, DELETE ON TABLE public.friend_groups FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.friend_groups FROM anon;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.friend_groups FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.friend_group_members FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.friend_group_members FROM anon;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.friend_group_members FROM PUBLIC;

GRANT SELECT ON TABLE public.friend_groups TO authenticated;
GRANT SELECT ON TABLE public.friend_group_members TO authenticated;
GRANT ALL ON TABLE public.friend_groups TO service_role;
GRANT ALL ON TABLE public.friend_group_members TO service_role;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.friend_groups_users_are_accepted_friends(
  p_user_a uuid,
  p_user_b uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.friendships f
    WHERE f.status = 'accepted'
      AND coalesce(f.requester_entity_type, 'user') = 'user'
      AND coalesce(f.addressee_entity_type, 'user') = 'user'
      AND (
        (f.requester_id = p_user_a AND f.addressee_id = p_user_b)
        OR (f.requester_id = p_user_b AND f.addressee_id = p_user_a)
      )
  );
$$;

REVOKE ALL ON FUNCTION public.friend_groups_users_are_accepted_friends(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.friend_groups_users_are_accepted_friends(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.friend_groups_users_are_accepted_friends(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.friend_groups_normalize_name(p_name text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v text;
BEGIN
  v := btrim(coalesce(p_name, ''));
  IF length(v) < 1 THEN
    RAISE EXCEPTION 'Friend group name is required.'
      USING ERRCODE = '22023';
  END IF;
  IF length(v) > 60 THEN
    RAISE EXCEPTION 'Friend group name is too long.'
      USING ERRCODE = '22023';
  END IF;
  RETURN v;
END;
$$;

REVOKE ALL ON FUNCTION public.friend_groups_normalize_name(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.friend_groups_normalize_name(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.friend_groups_normalize_name(text) TO service_role;

-- ---------------------------------------------------------------------------
-- Unfriend cleanup (both owners lose the former friend in their groups)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.friend_groups_cleanup_on_friendship_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP <> 'DELETE' THEN
    RETURN OLD;
  END IF;

  IF lower(btrim(coalesce(OLD.status, ''))) <> 'accepted' THEN
    RETURN OLD;
  END IF;

  IF coalesce(OLD.requester_entity_type, 'user') <> 'user'
     OR coalesce(OLD.addressee_entity_type, 'user') <> 'user' THEN
    RETURN OLD;
  END IF;

  DELETE FROM public.friend_group_members m
  USING public.friend_groups g
  WHERE m.group_id = g.id
    AND (
      (g.owner_user_id = OLD.requester_id AND m.friend_user_id = OLD.addressee_id)
      OR (g.owner_user_id = OLD.addressee_id AND m.friend_user_id = OLD.requester_id)
    );

  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_friend_groups_cleanup_on_friendship_delete ON public.friendships;
CREATE TRIGGER trg_friend_groups_cleanup_on_friendship_delete
  AFTER DELETE ON public.friendships
  FOR EACH ROW
  EXECUTE FUNCTION public.friend_groups_cleanup_on_friendship_delete();

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.list_my_friend_groups()
RETURNS TABLE (
  id uuid,
  name text,
  member_count integer,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  me uuid := auth.uid();
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  RETURN QUERY
  SELECT
    g.id,
    g.name,
    (
      SELECT count(*)::integer
      FROM public.friend_group_members m
      WHERE m.group_id = g.id
        AND public.friend_groups_users_are_accepted_friends(me, m.friend_user_id)
    ) AS member_count,
    g.created_at,
    g.updated_at
  FROM public.friend_groups g
  WHERE g.owner_user_id = me
  ORDER BY lower(g.name) ASC, g.created_at ASC;
END;
$$;

REVOKE ALL ON FUNCTION public.list_my_friend_groups() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_my_friend_groups() TO authenticated;

CREATE OR REPLACE FUNCTION public.create_friend_group(p_name text)
RETURNS TABLE (
  id uuid,
  name text,
  member_count integer,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  me uuid := auth.uid();
  v_name text;
  v_id uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  v_name := public.friend_groups_normalize_name(p_name);

  INSERT INTO public.friend_groups (owner_user_id, name)
  VALUES (me, v_name)
  RETURNING friend_groups.id INTO v_id;

  RETURN QUERY
  SELECT g.id, g.name, 0::integer, g.created_at, g.updated_at
  FROM public.friend_groups g
  WHERE g.id = v_id;
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'A Friend Group with this name already exists.'
      USING ERRCODE = '23505';
END;
$$;

REVOKE ALL ON FUNCTION public.create_friend_group(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_friend_group(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.rename_friend_group(p_group_id uuid, p_name text)
RETURNS TABLE (
  id uuid,
  name text,
  member_count integer,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  me uuid := auth.uid();
  v_name text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_group_id IS NULL THEN
    RAISE EXCEPTION 'Friend group not found.';
  END IF;

  v_name := public.friend_groups_normalize_name(p_name);

  UPDATE public.friend_groups g
  SET name = v_name,
      updated_at = now()
  WHERE g.id = p_group_id
    AND g.owner_user_id = me;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Friend group not found.';
  END IF;

  RETURN QUERY
  SELECT *
  FROM public.list_my_friend_groups() lg
  WHERE lg.id = p_group_id;
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'A Friend Group with this name already exists.'
      USING ERRCODE = '23505';
END;
$$;

REVOKE ALL ON FUNCTION public.rename_friend_group(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rename_friend_group(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.delete_friend_group(p_group_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  me uuid := auth.uid();
  n int;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_group_id IS NULL THEN
    RAISE EXCEPTION 'Friend group not found.';
  END IF;

  DELETE FROM public.friend_groups g
  WHERE g.id = p_group_id
    AND g.owner_user_id = me;

  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN
    RAISE EXCEPTION 'Friend group not found.';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.delete_friend_group(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_friend_group(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.list_friend_group_members(p_group_id uuid)
RETURNS TABLE (
  friend_user_id uuid,
  created_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  me uuid := auth.uid();
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_group_id IS NULL THEN
    RAISE EXCEPTION 'Friend group not found.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.friend_groups g
    WHERE g.id = p_group_id AND g.owner_user_id = me
  ) THEN
    RAISE EXCEPTION 'Friend group not found.';
  END IF;

  -- Only currently accepted friends are returned (stale rows filtered).
  RETURN QUERY
  SELECT m.friend_user_id, m.created_at
  FROM public.friend_group_members m
  WHERE m.group_id = p_group_id
    AND public.friend_groups_users_are_accepted_friends(me, m.friend_user_id)
  ORDER BY m.created_at ASC;
END;
$$;

REVOKE ALL ON FUNCTION public.list_friend_group_members(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_friend_group_members(uuid) TO authenticated;

-- Batch replace membership. Non-friends are rejected (whole call fails).
CREATE OR REPLACE FUNCTION public.set_friend_group_members(
  p_group_id uuid,
  p_friend_user_ids uuid[]
)
RETURNS TABLE (
  friend_user_id uuid,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  me uuid := auth.uid();
  v_ids uuid[];
  v_uid uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_group_id IS NULL THEN
    RAISE EXCEPTION 'Friend group not found.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.friend_groups g
    WHERE g.id = p_group_id AND g.owner_user_id = me
  ) THEN
    RAISE EXCEPTION 'Friend group not found.';
  END IF;

  -- Dedupe, drop nulls/self.
  SELECT coalesce(array_agg(DISTINCT x), ARRAY[]::uuid[])
  INTO v_ids
  FROM unnest(coalesce(p_friend_user_ids, ARRAY[]::uuid[])) AS x
  WHERE x IS NOT NULL AND x <> me;

  FOREACH v_uid IN ARRAY v_ids
  LOOP
    IF NOT public.friend_groups_users_are_accepted_friends(me, v_uid) THEN
      RAISE EXCEPTION 'Only accepted friends can be added to a Friend Group.'
        USING ERRCODE = '42501';
    END IF;
  END LOOP;

  DELETE FROM public.friend_group_members m
  WHERE m.group_id = p_group_id;

  IF coalesce(array_length(v_ids, 1), 0) > 0 THEN
    INSERT INTO public.friend_group_members (group_id, friend_user_id)
    SELECT p_group_id, u
    FROM unnest(v_ids) AS u
    ON CONFLICT DO NOTHING;
  END IF;

  UPDATE public.friend_groups
  SET updated_at = now()
  WHERE id = p_group_id
    AND owner_user_id = me;

  RETURN QUERY
  SELECT * FROM public.list_friend_group_members(p_group_id);
END;
$$;

REVOKE ALL ON FUNCTION public.set_friend_group_members(uuid, uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_friend_group_members(uuid, uuid[]) TO authenticated;

-- Toggle one friend's membership across many of the owner's groups (••• menu).
-- p_group_ids = groups that should INCLUDE the friend after save.
CREATE OR REPLACE FUNCTION public.set_friend_membership_in_groups(
  p_friend_user_id uuid,
  p_group_ids uuid[]
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  me uuid := auth.uid();
  v_group_ids uuid[];
  v_gid uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_friend_user_id IS NULL OR p_friend_user_id = me THEN
    RAISE EXCEPTION 'Invalid friend user.';
  END IF;

  IF NOT public.friend_groups_users_are_accepted_friends(me, p_friend_user_id) THEN
    RAISE EXCEPTION 'Only accepted friends can be added to a Friend Group.'
      USING ERRCODE = '42501';
  END IF;

  SELECT coalesce(array_agg(DISTINCT x), ARRAY[]::uuid[])
  INTO v_group_ids
  FROM unnest(coalesce(p_group_ids, ARRAY[]::uuid[])) AS x
  WHERE x IS NOT NULL;

  -- Every target group must be owned by me.
  IF EXISTS (
    SELECT 1
    FROM unnest(v_group_ids) AS gid
    WHERE NOT EXISTS (
      SELECT 1 FROM public.friend_groups g
      WHERE g.id = gid AND g.owner_user_id = me
    )
  ) THEN
    RAISE EXCEPTION 'Friend group not found.';
  END IF;

  -- Remove friend from all of my groups that are NOT selected.
  DELETE FROM public.friend_group_members m
  USING public.friend_groups g
  WHERE m.group_id = g.id
    AND g.owner_user_id = me
    AND m.friend_user_id = p_friend_user_id
    AND (
      coalesce(array_length(v_group_ids, 1), 0) = 0
      OR m.group_id <> ALL (v_group_ids)
    );

  -- Ensure membership in selected groups.
  FOREACH v_gid IN ARRAY v_group_ids
  LOOP
    INSERT INTO public.friend_group_members (group_id, friend_user_id)
    VALUES (v_gid, p_friend_user_id)
    ON CONFLICT DO NOTHING;

    UPDATE public.friend_groups
    SET updated_at = now()
    WHERE id = v_gid AND owner_user_id = me;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.set_friend_membership_in_groups(uuid, uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_friend_membership_in_groups(uuid, uuid[]) TO authenticated;

-- Which of my groups currently include this friend (accepted only).
CREATE OR REPLACE FUNCTION public.list_my_friend_groups_containing_friend(p_friend_user_id uuid)
RETURNS TABLE (
  id uuid,
  name text,
  member_count integer,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  me uuid := auth.uid();
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_friend_user_id IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT lg.*
  FROM public.list_my_friend_groups() lg
  INNER JOIN public.friend_group_members m
    ON m.group_id = lg.id
   AND m.friend_user_id = p_friend_user_id
  WHERE public.friend_groups_users_are_accepted_friends(me, p_friend_user_id)
  ORDER BY lower(lg.name) ASC;
END;
$$;

REVOKE ALL ON FUNCTION public.list_my_friend_groups_containing_friend(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_my_friend_groups_containing_friend(uuid) TO authenticated;

COMMENT ON FUNCTION public.list_my_friend_groups() IS
  'Owner-only Friend Group summaries with live accepted-friend member counts.';
COMMENT ON FUNCTION public.create_friend_group(text) IS
  'Create a private Friend Group for auth.uid(). Unique normalized name per owner.';
COMMENT ON FUNCTION public.rename_friend_group(uuid, text) IS
  'Rename an owned Friend Group; memberships preserved.';
COMMENT ON FUNCTION public.delete_friend_group(uuid) IS
  'Delete an owned Friend Group (memberships cascade). Friendships unchanged.';
COMMENT ON FUNCTION public.list_friend_group_members(uuid) IS
  'Member user ids for an owned group; filters to currently accepted friends.';
COMMENT ON FUNCTION public.set_friend_group_members(uuid, uuid[]) IS
  'Batch replace group membership; rejects non-friends.';
COMMENT ON FUNCTION public.set_friend_membership_in_groups(uuid, uuid[]) IS
  'Set which of the owner''s groups include one friend (multi-group ••• menu).';
COMMENT ON FUNCTION public.list_my_friend_groups_containing_friend(uuid) IS
  'Owner groups that currently include the given accepted friend.';

COMMIT;

-- Manual verification (staging):
--   SELECT proname FROM pg_proc WHERE proname LIKE '%friend_group%';
--   -- Owner A cannot SELECT owner B's friend_groups rows under RLS.
