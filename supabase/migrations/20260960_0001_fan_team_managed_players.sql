-- =============================================================================
-- 20260960_0001 — Parent/Guardian Managed Players for FanGeo Teams
-- =============================================================================
-- Youth Teams need a participant that is NOT an auth.users account: a child on
-- the roster whose attendance, jersey, position and lineup seat are managed by
-- one or more guardian accounts.
--
-- DESIGN RULES (deliberate, do not "simplify" later):
--   1. OPTIONAL. A user with zero managed players sees zero new behaviour. Every
--      new RPC returns empty for them and every legacy write path is untouched.
--   2. TEAMS ONLY. Managed players are Team roster participants. They are NOT
--      social identities: no user_profiles row, no friendships, no DMs, no
--      group_conversation_members row, no Discover presence, no push tokens.
--   3. auth.users memberships stay FIRST CLASS. fan_team_members.user_id keeps
--      every existing meaning; managed rows are strictly additive.
--   4. Notifications for a managed player fan out to that player's ACTIVE
--      guardians (see resolve_fan_team_notification_recipients_for_participant).
--   5. PRIVACY: ordinary teammates never SELECT fan_managed_players. Roster
--      projection is list_fan_team_members only (no birth_year / guardian ids).
--   6. Seat creation is gated by fan_geo_runtime_flags.managed_player_team_seats
--      (default false) until nullable-user_id clients are deployed.
--
-- PARTICIPANT IDENTITY MODEL
--   fan_team_members becomes a dual-identity roster:
--     membership_id       uuid  PK           -- stable roster seat id
--     user_id             uuid  NULL         -- authenticated participant
--     managed_player_id   uuid  NULL         -- guardian-managed participant
--   XOR enforced by CHECK. Team-specific attributes (role, player_number,
--   preferred_position_code, joined_at, left_at) stay on the membership row, so
--   a child on two Teams can have two jersey numbers — same as adults.
--
-- MIGRATION SAFETY
--   Every existing fan_team_members row keeps user_id, gets managed_player_id
--   NULL and a freshly generated membership_id. No row is deleted or rewritten.
--
--   The old PRIMARY KEY (team_id, user_id) is replaced by PRIMARY KEY
--   (membership_id), but a FULL unique index on (team_id, user_id) is created in
--   its place. That is required, not cosmetic: create_fan_team,
--   add_fan_team_members and accept_fan_team_invitation all use
--   `ON CONFLICT (team_id, user_id) DO UPDATE`, and Postgres cannot infer a
--   PARTIAL index from that clause. A full unique index preserves the exact
--   previous semantics (one seat per user per Team, soft-leave via left_at) and
--   is harmless for managed rows because user_id IS NULL and NULLs are distinct.
--   It therefore also subsumes the "active (team_id, user_id)" uniqueness goal.
--
-- Do NOT apply from the agent. Apply manually after 20260959.
-- Edge Functions are NOT deployed by this migration. See the note above
-- resolve_fan_team_notification_recipients_for_participant for the follow-up.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Managed player identity
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.fan_managed_players (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_by_user_id uuid NOT NULL
    REFERENCES auth.users (id) ON DELETE CASCADE,
  first_name text NOT NULL,
  last_name text NOT NULL DEFAULT '',
  display_name text NOT NULL,
  avatar_url text,
  avatar_thumbnail_url text,
  birth_year int,
  linked_user_id uuid REFERENCES auth.users (id),
  archived_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fan_managed_players_first_name_len_ck
    CHECK (char_length(btrim(first_name)) BETWEEN 1 AND 40),
  CONSTRAINT fan_managed_players_last_name_len_ck
    CHECK (char_length(btrim(last_name)) <= 40),
  CONSTRAINT fan_managed_players_display_name_len_ck
    CHECK (char_length(btrim(display_name)) BETWEEN 1 AND 60),
  CONSTRAINT fan_managed_players_birth_year_ck
    CHECK (
      birth_year IS NULL
      OR birth_year BETWEEN 1900 AND (extract(year FROM now())::int)
    )
);

COMMENT ON TABLE public.fan_managed_players IS
  'Guardian-managed Team participant (typically a child). NOT an account and NOT a '
  'social identity: no user_profiles row, no friendships, no chat membership. Only '
  'reachable through Team rosters and the guardian RPCs in this migration.';

COMMENT ON COLUMN public.fan_managed_players.birth_year IS
  'Year of birth ONLY — never a full date of birth. Teams need age banding (U10/U12, '
  'age-group eligibility) and youth-safety gating; a full DOB is personally identifying '
  'child data we have no product reason to store. Year-only is the minimum that satisfies '
  'the use case, which keeps this out of "collecting precise childrens birthdays" territory.';

COMMENT ON COLUMN public.fan_managed_players.linked_user_id IS
  'Reserved for a future "claim this player" flow (child ages up and gets their own '
  'account). Always NULL today. Unique so one account can claim at most one player.';

COMMENT ON COLUMN public.fan_managed_players.display_name IS
  'Preferred/roster name shown everywhere in Team UI ("Ellie R."). Guardians choose it.';

CREATE UNIQUE INDEX IF NOT EXISTS fan_managed_players_linked_user_uidx
  ON public.fan_managed_players (linked_user_id)
  WHERE linked_user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS fan_managed_players_creator_idx
  ON public.fan_managed_players (created_by_user_id)
  WHERE archived_at IS NULL;

CREATE TABLE IF NOT EXISTS public.fan_managed_player_guardians (
  managed_player_id uuid NOT NULL
    REFERENCES public.fan_managed_players (id) ON DELETE CASCADE,
  guardian_user_id uuid NOT NULL
    REFERENCES auth.users (id) ON DELETE CASCADE,
  role text NOT NULL DEFAULT 'guardian'
    CHECK (role IN ('guardian', 'primary_guardian')),
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  PRIMARY KEY (managed_player_id, guardian_user_id)
);

COMMENT ON TABLE public.fan_managed_player_guardians IS
  'Who may act for a managed player. PRIMARY KEY already guarantees one row per '
  'player+guardian pair; revoked_at soft-revokes without losing history.';

CREATE INDEX IF NOT EXISTS fan_managed_player_guardians_active_guardian_idx
  ON public.fan_managed_player_guardians (guardian_user_id)
  WHERE revoked_at IS NULL;

-- ---------------------------------------------------------------------------
-- 2) fan_team_members — dual participant identity
-- ---------------------------------------------------------------------------

ALTER TABLE public.fan_team_members
  ADD COLUMN IF NOT EXISTS membership_id uuid NOT NULL DEFAULT gen_random_uuid();

ALTER TABLE public.fan_team_members
  ADD COLUMN IF NOT EXISTS managed_player_id uuid
    REFERENCES public.fan_managed_players (id);

COMMENT ON COLUMN public.fan_team_members.membership_id IS
  'Stable roster seat id. Primary key since 20260960. Attendance, lineup seats and '
  'RSVP for managed players key off this, not off user_id.';

COMMENT ON COLUMN public.fan_team_members.managed_player_id IS
  'Set when this roster seat is a guardian-managed player instead of an account. '
  'Exactly one of user_id / managed_player_id is non-null.';

-- Replace composite PK with membership_id, keeping (team_id, user_id) uniqueness
-- as a full unique index so existing ON CONFLICT (team_id, user_id) upserts work.
DO $$
DECLARE
  v_fk text;
  v_fk_list text := '';
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.fan_team_members'::regclass
      AND contype = 'p'
      AND conname = 'fan_team_members_pkey'
      AND array_length(conkey, 1) > 1
  ) THEN
    -- Dependency audit: refuse to drop the composite PK if any foreign key still
    -- references it. (Postgres would also block the DROP; we fail with a clear list.)
    FOR v_fk IN
      SELECT c.conname || ' ON ' || c.conrelid::regclass::text
      FROM pg_constraint c
      WHERE c.contype = 'f'
        AND c.confrelid = 'public.fan_team_members'::regclass
        AND c.confkey IS NOT NULL
        AND EXISTS (
          SELECT 1
          FROM pg_constraint pk
          WHERE pk.conrelid = 'public.fan_team_members'::regclass
            AND pk.conname = 'fan_team_members_pkey'
            AND pk.conkey = c.confkey
        )
    LOOP
      v_fk_list := v_fk_list || E'\n  - ' || v_fk;
    END LOOP;

    IF v_fk_list <> '' THEN
      RAISE EXCEPTION
        'fan_team_members_pkey drop blocked: foreign keys still reference (team_id, user_id):%',
        v_fk_list;
    END IF;

    -- Create the replacement uniqueness BEFORE dropping the PK so there is no
    -- window in which duplicate (team_id, user_id) rows could be inserted.
    CREATE UNIQUE INDEX IF NOT EXISTS fan_team_members_team_user_uidx
      ON public.fan_team_members (team_id, user_id);

    ALTER TABLE public.fan_team_members DROP CONSTRAINT fan_team_members_pkey;
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS fan_team_members_team_user_uidx
  ON public.fan_team_members (team_id, user_id);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.fan_team_members'::regclass
      AND contype = 'p'
  ) THEN
    ALTER TABLE public.fan_team_members
      ADD CONSTRAINT fan_team_members_pkey PRIMARY KEY (membership_id);
  END IF;
END $$;

ALTER TABLE public.fan_team_members
  ALTER COLUMN user_id DROP NOT NULL;

ALTER TABLE public.fan_team_members
  DROP CONSTRAINT IF EXISTS fan_team_members_participant_identity_ck;

ALTER TABLE public.fan_team_members
  ADD CONSTRAINT fan_team_members_participant_identity_ck
  CHECK (
    (user_id IS NOT NULL AND managed_player_id IS NULL)
    OR (user_id IS NULL AND managed_player_id IS NOT NULL)
  );

-- One active seat per managed player per Team (soft-leave rows may repeat).
CREATE UNIQUE INDEX IF NOT EXISTS fan_team_members_active_managed_uidx
  ON public.fan_team_members (team_id, managed_player_id)
  WHERE left_at IS NULL AND managed_player_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS fan_team_members_active_managed_player_idx
  ON public.fan_team_members (managed_player_id)
  WHERE left_at IS NULL AND managed_player_id IS NOT NULL;

-- Managed players are always plain members; leadership requires an account.
ALTER TABLE public.fan_team_members
  DROP CONSTRAINT IF EXISTS fan_team_members_managed_role_ck;

ALTER TABLE public.fan_team_members
  ADD CONSTRAINT fan_team_members_managed_role_ck
  CHECK (managed_player_id IS NULL OR role = 'member');

-- ---------------------------------------------------------------------------
-- 3) Helpers
-- ---------------------------------------------------------------------------

-- Unchanged contract for authenticated members (still user_id based). Managed
-- rows have user_id NULL, so they can never satisfy this and no existing policy
-- or RPC silently changes meaning.
CREATE OR REPLACE FUNCTION public.is_active_fan_team_member(
  p_team_id uuid,
  p_user_id uuid
)
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
      AND m.user_id IS NOT NULL
      AND m.user_id = p_user_id
      AND m.left_at IS NULL
  );
$$;

COMMENT ON FUNCTION public.is_active_fan_team_member(uuid, uuid) IS
  'Active AUTHENTICATED membership only. Managed players never match — use '
  'is_active_fan_team_managed_member or fan_team_viewer_can_access_team.';

CREATE OR REPLACE FUNCTION public.is_active_fan_team_managed_member(
  p_team_id uuid,
  p_managed_player_id uuid
)
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
      AND m.managed_player_id IS NOT NULL
      AND m.managed_player_id = p_managed_player_id
      AND m.left_at IS NULL
  );
$$;

CREATE OR REPLACE FUNCTION public.is_authorized_managed_player_guardian(
  p_managed_player_id uuid,
  p_guardian_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.fan_managed_player_guardians g
    JOIN public.fan_managed_players p ON p.id = g.managed_player_id
    WHERE g.managed_player_id = p_managed_player_id
      AND g.guardian_user_id = p_guardian_user_id
      AND g.revoked_at IS NULL
      AND p.archived_at IS NULL
  );
$$;

COMMENT ON FUNCTION public.is_authorized_managed_player_guardian(uuid, uuid) IS
  'Single authorization gate for every guardian action. Archived players authorize nothing.';

-- Team read access for the viewer: an active account membership OR guardianship
-- of an active managed member. A parent who is not on the Team themselves still
-- needs the roster, schedule and lineup for their child.
CREATE OR REPLACE FUNCTION public.fan_team_viewer_can_access_team(p_team_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    public.is_active_fan_team_member(p_team_id, auth.uid())
    OR EXISTS (
      SELECT 1
      FROM public.fan_team_members m
      JOIN public.fan_managed_player_guardians g
        ON g.managed_player_id = m.managed_player_id
       AND g.guardian_user_id = auth.uid()
       AND g.revoked_at IS NULL
      WHERE m.team_id = p_team_id
        AND m.managed_player_id IS NOT NULL
        AND m.left_at IS NULL
    );
$$;

COMMENT ON FUNCTION public.fan_team_viewer_can_access_team(uuid) IS
  'Viewer may read this Team: active member, or active guardian of an active managed member.';

-- Roster seat -> the auth users who should receive notifications about it.
CREATE OR REPLACE FUNCTION public.fan_team_membership_recipient_user_ids(p_membership_id uuid)
RETURNS uuid[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN m.user_id IS NOT NULL THEN ARRAY[m.user_id]
    ELSE coalesce(
      (
        SELECT array_agg(DISTINCT g.guardian_user_id)
        FROM public.fan_managed_player_guardians g
        WHERE g.managed_player_id = m.managed_player_id
          AND g.revoked_at IS NULL
      ),
      ARRAY[]::uuid[]
    )
  END
  FROM public.fan_team_members m
  WHERE m.membership_id = p_membership_id;
$$;

-- Direct-table visibility for fan_managed_players: GUARDIAN ONLY.
-- Ordinary Team members must NOT read the underlying private row (birth_year,
-- names breakdown, created_by, linked_user_id, etc.). Teammates see the safe
-- projection from list_fan_team_members / roster RPCs only.
CREATE OR REPLACE FUNCTION public.fan_managed_player_visible_to_viewer(p_managed_player_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.is_authorized_managed_player_guardian(p_managed_player_id, auth.uid());
$$;

COMMENT ON FUNCTION public.fan_managed_player_visible_to_viewer(uuid) IS
  'RLS helper: true only for an active guardian of an unarchived managed player. '
  'Never grants teammate access to the private fan_managed_players row.';

-- ---------------------------------------------------------------------------
-- 4) Lineups & exclusions — accept either participant identity
-- ---------------------------------------------------------------------------

ALTER TABLE public.fan_team_event_lineup_members
  ADD COLUMN IF NOT EXISTS managed_player_id uuid
    REFERENCES public.fan_managed_players (id) ON DELETE CASCADE;

ALTER TABLE public.fan_team_event_lineup_members
  ALTER COLUMN user_id DROP NOT NULL;

ALTER TABLE public.fan_team_event_lineup_members
  DROP CONSTRAINT IF EXISTS fan_team_event_lineup_members_identity_ck;

ALTER TABLE public.fan_team_event_lineup_members
  ADD CONSTRAINT fan_team_event_lineup_members_identity_ck
  CHECK (
    (user_id IS NOT NULL AND managed_player_id IS NULL)
    OR (user_id IS NULL AND managed_player_id IS NOT NULL)
  );

-- fan_team_event_lineup_members_unique UNIQUE (lineup_id, user_id) is retained:
-- NULLs are distinct, so managed rows are unaffected and account rows keep the
-- exact previous constraint.
CREATE UNIQUE INDEX IF NOT EXISTS fan_team_event_lineup_members_managed_uidx
  ON public.fan_team_event_lineup_members (lineup_id, managed_player_id)
  WHERE managed_player_id IS NOT NULL;

ALTER TABLE public.fan_team_event_exclusions
  ADD COLUMN IF NOT EXISTS managed_player_id uuid
    REFERENCES public.fan_managed_players (id) ON DELETE CASCADE;

-- PK (team_id, pickup_game_id, user_id) blocks a nullable user_id. No write path
-- uses ON CONFLICT on this table (set_fan_team_event_member_excluded does an
-- existence check first), so partial unique indexes are a safe replacement.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.fan_team_event_exclusions'::regclass
      AND contype = 'p'
  ) THEN
    CREATE UNIQUE INDEX IF NOT EXISTS fan_team_event_exclusions_user_uidx
      ON public.fan_team_event_exclusions (team_id, pickup_game_id, user_id)
      WHERE user_id IS NOT NULL;

    ALTER TABLE public.fan_team_event_exclusions
      DROP CONSTRAINT fan_team_event_exclusions_pkey;
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS fan_team_event_exclusions_user_uidx
  ON public.fan_team_event_exclusions (team_id, pickup_game_id, user_id)
  WHERE user_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS fan_team_event_exclusions_managed_uidx
  ON public.fan_team_event_exclusions (team_id, pickup_game_id, managed_player_id)
  WHERE managed_player_id IS NOT NULL;

ALTER TABLE public.fan_team_event_exclusions
  ALTER COLUMN user_id DROP NOT NULL;

ALTER TABLE public.fan_team_event_exclusions
  DROP CONSTRAINT IF EXISTS fan_team_event_exclusions_identity_ck;

ALTER TABLE public.fan_team_event_exclusions
  ADD CONSTRAINT fan_team_event_exclusions_identity_ck
  CHECK (
    (user_id IS NOT NULL AND managed_player_id IS NULL)
    OR (user_id IS NULL AND managed_player_id IS NOT NULL)
  );

-- ---------------------------------------------------------------------------
-- 5) Managed-player RSVP storage
-- ---------------------------------------------------------------------------
-- Authenticated members keep RSVPing through pickup_game_requests (unchanged,
-- backward compatible, still the source of truth for pickup rosters, chat
-- membership sync and organizer capacity). Managed players have no auth user, so
-- they cannot own a pickup_game_requests row — their attendance lives here,
-- keyed by roster seat.
--
-- FOLLOW-UP (documented, not done here): the Team roster/attendance readers
-- (get_pickup_game_roster, list_pickup_game_team_responses) still read only
-- pickup_game_requests. They must be extended to UNION fan_team_event_rsvps so
-- managed players appear in Going/Maybe/Can't Go buckets. Until then managed
-- RSVP is written and readable via list_fan_team_event_rsvps below.

CREATE TABLE IF NOT EXISTS public.fan_team_event_rsvps (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id uuid NOT NULL REFERENCES public.fan_teams (id) ON DELETE CASCADE,
  pickup_game_id uuid NOT NULL REFERENCES public.pickup_games (id) ON DELETE CASCADE,
  membership_id uuid NOT NULL
    REFERENCES public.fan_team_members (membership_id) ON DELETE CASCADE,
  status text NOT NULL CHECK (status IN ('going', 'maybe', 'cant_go')),
  set_by_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fan_team_event_rsvps_unique UNIQUE (team_id, pickup_game_id, membership_id)
);

CREATE INDEX IF NOT EXISTS fan_team_event_rsvps_game_idx
  ON public.fan_team_event_rsvps (pickup_game_id);

COMMENT ON TABLE public.fan_team_event_rsvps IS
  'Roster-seat RSVP for Team events. Used by managed players (no auth.users row). '
  'Authenticated members continue to RSVP via pickup_game_requests for backward '
  'compatibility; set_fan_team_game_rsvp_for_membership routes both.';

COMMENT ON COLUMN public.fan_team_event_rsvps.set_by_user_id IS
  'Guardian (or member) who actually pressed the button — audit trail, never the subject.';

-- ---------------------------------------------------------------------------
-- 6) RLS
-- ---------------------------------------------------------------------------

ALTER TABLE public.fan_managed_players ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fan_managed_players FORCE ROW LEVEL SECURITY;
ALTER TABLE public.fan_managed_player_guardians ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fan_managed_player_guardians FORCE ROW LEVEL SECURITY;
ALTER TABLE public.fan_team_event_rsvps ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fan_team_event_rsvps FORCE ROW LEVEL SECURITY;

DO $$
DECLARE
  pol record;
  tbl text;
BEGIN
  FOREACH tbl IN ARRAY ARRAY[
    'fan_managed_players',
    'fan_managed_player_guardians',
    'fan_team_event_rsvps'
  ] LOOP
    FOR pol IN
      SELECT policyname FROM pg_policies
      WHERE schemaname = 'public' AND tablename = tbl
    LOOP
      EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', pol.policyname, tbl);
    END LOOP;
  END LOOP;
END $$;

-- Inline guardian check (do not call revoked probe helpers from RLS).
CREATE POLICY "fan_managed_players_select_guardian"
ON public.fan_managed_players
FOR SELECT
TO authenticated
USING (
  archived_at IS NULL
  AND EXISTS (
    SELECT 1
    FROM public.fan_managed_player_guardians g
    WHERE g.managed_player_id = fan_managed_players.id
      AND g.guardian_user_id = auth.uid()
      AND g.revoked_at IS NULL
  )
);

CREATE POLICY "fan_managed_player_guardians_select_own"
ON public.fan_managed_player_guardians
FOR SELECT
TO authenticated
USING (
  guardian_user_id = auth.uid()
  AND revoked_at IS NULL
);

CREATE POLICY "fan_team_event_rsvps_select_team_access"
ON public.fan_team_event_rsvps
FOR SELECT
TO authenticated
USING (public.fan_team_viewer_can_access_team(team_id));

REVOKE ALL ON TABLE public.fan_managed_players FROM PUBLIC;
REVOKE ALL ON TABLE public.fan_managed_players FROM anon;
REVOKE ALL ON TABLE public.fan_managed_players FROM authenticated;
REVOKE ALL ON TABLE public.fan_managed_player_guardians FROM PUBLIC;
REVOKE ALL ON TABLE public.fan_managed_player_guardians FROM anon;
REVOKE ALL ON TABLE public.fan_managed_player_guardians FROM authenticated;
REVOKE ALL ON TABLE public.fan_team_event_rsvps FROM PUBLIC;
REVOKE ALL ON TABLE public.fan_team_event_rsvps FROM anon;
REVOKE ALL ON TABLE public.fan_team_event_rsvps FROM authenticated;

-- Table SELECT is intentionally NOT granted to authenticated.
-- Guardians and teammates read via SECURITY DEFINER RPCs
-- (list_my_managed_players, list_fan_team_members, list_fan_team_event_rsvps).
-- The guardian-only RLS policy remains as defense-in-depth if SELECT is granted later.
GRANT ALL ON TABLE public.fan_managed_players TO service_role;
GRANT ALL ON TABLE public.fan_managed_player_guardians TO service_role;
GRANT ALL ON TABLE public.fan_team_event_rsvps TO service_role;

-- Guardians who are NOT themselves on the Team still need Team + roster reads.
DROP POLICY IF EXISTS fan_teams_select_member ON public.fan_teams;
CREATE POLICY fan_teams_select_member ON public.fan_teams
  FOR SELECT TO authenticated
  USING (
    is_active = true
    AND public.fan_team_viewer_can_access_team(id)
  );

DROP POLICY IF EXISTS fan_team_members_select_same_team ON public.fan_team_members;
CREATE POLICY fan_team_members_select_same_team ON public.fan_team_members
  FOR SELECT TO authenticated
  USING (public.fan_team_viewer_can_access_team(team_id));

DROP POLICY IF EXISTS fan_team_game_links_select_member ON public.fan_team_game_links;
CREATE POLICY fan_team_game_links_select_member ON public.fan_team_game_links
  FOR SELECT TO authenticated
  USING (public.fan_team_viewer_can_access_team(team_id));

-- ---------------------------------------------------------------------------
-- 7) Guardian RPCs
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.list_my_managed_players()
RETURNS TABLE (
  managed_player_id uuid,
  first_name text,
  last_name text,
  display_name text,
  avatar_url text,
  avatar_thumbnail_url text,
  birth_year int,
  guardian_role text,
  team_count int,
  created_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  RETURN QUERY
  SELECT
    p.id,
    p.first_name,
    p.last_name,
    p.display_name,
    p.avatar_url,
    p.avatar_thumbnail_url,
    p.birth_year,
    g.role,
    (
      SELECT count(*)::int
      FROM public.fan_team_members m
      WHERE m.managed_player_id = p.id
        AND m.left_at IS NULL
    ),
    p.created_at
  FROM public.fan_managed_players p
  JOIN public.fan_managed_player_guardians g
    ON g.managed_player_id = p.id
   AND g.guardian_user_id = me
   AND g.revoked_at IS NULL
  WHERE p.archived_at IS NULL
  ORDER BY lower(btrim(p.display_name)) ASC;
END;
$$;

COMMENT ON FUNCTION public.list_my_managed_players() IS
  'Guardian home for "My Players". Returns zero rows for the overwhelming majority of '
  'users, which is what keeps this feature invisible unless opted into.';

-- ---------------------------------------------------------------------------
-- Rate-limit allowlist MUST include managed-player buckets before the RPCs below
-- call assert_rpc_rate_limit. Unknown buckets raise "rate limit rejected" (22023)
-- on the first attempt — see also 20260963 for already-applied environments.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_rpc_rate_limit(
  p_bucket text,
  p_max int,
  p_window_seconds int
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_bucket text := nullif(btrim(coalesce(p_bucket, '')), '');
  v_window_start timestamptz;
  v_count int;
  v_allowed_buckets text[] := ARRAY[
    'send_direct_message',
    'send_group_message',
    'friendship_ensure_pending',
    'poke_profile',
    'report_group_message',
    'search_chat_conversations',
    'search_chat_messages',
    'create_fan_team',
    'invite_fan_team_members',
    'accept_fan_team_invitation',
    'decline_fan_team_invitation',
    'report_fan_team',
    'leave_fan_team',
    'delete_fan_team',
    'resend_fan_team_invitation',
    'create_managed_player',
    'update_managed_player',
    'add_managed_player_to_fan_team',
    'accept_fan_team_invitation_as_managed_player'
  ];
BEGIN
  IF coalesce(auth.role(), '') = 'service_role' AND me IS NULL THEN
    RETURN;
  END IF;

  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  IF v_bucket IS NULL OR NOT (v_bucket = ANY (v_allowed_buckets)) THEN
    RAISE EXCEPTION 'rate limit rejected' USING ERRCODE = '22023';
  END IF;

  IF p_max IS NULL OR p_max < 1 OR p_max > 100000 THEN
    RAISE EXCEPTION 'rate limit rejected' USING ERRCODE = '22023';
  END IF;

  IF p_window_seconds IS NULL OR p_window_seconds < 1 OR p_window_seconds > 86400 THEN
    RAISE EXCEPTION 'rate limit rejected' USING ERRCODE = '22023';
  END IF;

  v_window_start := to_timestamp(
    floor(extract(epoch FROM now()) / p_window_seconds::double precision)
      * p_window_seconds::double precision
  );

  INSERT INTO public.rpc_rate_limits AS r (actor_uid, bucket, window_start, count)
  VALUES (me, v_bucket, v_window_start, 1)
  ON CONFLICT (actor_uid, bucket, window_start)
  DO UPDATE SET count = LEAST(r.count + 1, 1000000)
  RETURNING r.count INTO v_count;

  IF v_count > p_max THEN
    RAISE EXCEPTION 'rate_limit_exceeded'
      USING ERRCODE = '54000';
  END IF;

  IF (random() < 0.01) THEN
    DELETE FROM public.rpc_rate_limits
    WHERE window_start < (now() - interval '7 days');
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM anon;
REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.assert_rpc_rate_limit(text, int, int) TO service_role;

CREATE OR REPLACE FUNCTION public.create_managed_player(
  p_first_name text,
  p_last_name text,
  p_display_name text DEFAULT NULL,
  p_birth_year int DEFAULT NULL,
  p_avatar_url text DEFAULT NULL,
  p_avatar_thumbnail_url text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_first text := btrim(coalesce(p_first_name, ''));
  v_last text := btrim(coalesce(p_last_name, ''));
  v_display text := btrim(coalesce(p_display_name, ''));
  v_id uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  PERFORM public.assert_rpc_rate_limit('create_managed_player', 20, 3600);

  IF char_length(v_first) < 1 OR char_length(v_first) > 40 THEN
    RAISE EXCEPTION 'managed_player_first_name_invalid' USING ERRCODE = 'check_violation';
  END IF;
  IF char_length(v_last) > 40 THEN
    RAISE EXCEPTION 'managed_player_last_name_invalid' USING ERRCODE = 'check_violation';
  END IF;

  IF v_display = '' THEN
    v_display := btrim(v_first || ' ' || v_last);
  END IF;
  IF char_length(v_display) > 60 THEN
    v_display := left(v_display, 60);
  END IF;

  IF p_birth_year IS NOT NULL
     AND (p_birth_year < 1900 OR p_birth_year > extract(year FROM now())::int) THEN
    RAISE EXCEPTION 'managed_player_birth_year_invalid' USING ERRCODE = 'check_violation';
  END IF;

  -- Soft cap: a guardian managing more than this is almost certainly abuse.
  IF (
    SELECT count(*)
    FROM public.fan_managed_player_guardians g
    JOIN public.fan_managed_players p ON p.id = g.managed_player_id
    WHERE g.guardian_user_id = me
      AND g.revoked_at IS NULL
      AND p.archived_at IS NULL
  ) >= 12 THEN
    RAISE EXCEPTION 'managed_player_limit_reached' USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO public.fan_managed_players (
    created_by_user_id,
    first_name,
    last_name,
    display_name,
    avatar_url,
    avatar_thumbnail_url,
    birth_year
  ) VALUES (
    me,
    v_first,
    v_last,
    v_display,
    nullif(btrim(coalesce(p_avatar_url, '')), ''),
    nullif(btrim(coalesce(p_avatar_thumbnail_url, '')), ''),
    p_birth_year
  )
  RETURNING id INTO v_id;

  INSERT INTO public.fan_managed_player_guardians (
    managed_player_id, guardian_user_id, role
  ) VALUES (v_id, me, 'primary_guardian');

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_managed_player(
  p_managed_player_id uuid,
  p_first_name text DEFAULT NULL,
  p_last_name text DEFAULT NULL,
  p_display_name text DEFAULT NULL,
  p_birth_year int DEFAULT NULL,
  p_avatar_url text DEFAULT NULL,
  p_avatar_thumbnail_url text DEFAULT NULL,
  p_clear_birth_year boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_first text := nullif(btrim(coalesce(p_first_name, '')), '');
  v_last text := p_last_name;
  v_display text := nullif(btrim(coalesce(p_display_name, '')), '');
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF NOT public.is_authorized_managed_player_guardian(p_managed_player_id, me) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  PERFORM public.assert_rpc_rate_limit('update_managed_player', 60, 3600);

  IF v_first IS NOT NULL AND char_length(v_first) > 40 THEN
    RAISE EXCEPTION 'managed_player_first_name_invalid' USING ERRCODE = 'check_violation';
  END IF;
  IF v_last IS NOT NULL AND char_length(btrim(v_last)) > 40 THEN
    RAISE EXCEPTION 'managed_player_last_name_invalid' USING ERRCODE = 'check_violation';
  END IF;
  IF v_display IS NOT NULL AND char_length(v_display) > 60 THEN
    RAISE EXCEPTION 'managed_player_display_name_invalid' USING ERRCODE = 'check_violation';
  END IF;
  IF p_birth_year IS NOT NULL
     AND (p_birth_year < 1900 OR p_birth_year > extract(year FROM now())::int) THEN
    RAISE EXCEPTION 'managed_player_birth_year_invalid' USING ERRCODE = 'check_violation';
  END IF;

  UPDATE public.fan_managed_players
  SET
    first_name = coalesce(v_first, first_name),
    last_name = coalesce(btrim(v_last), last_name),
    display_name = coalesce(v_display, display_name),
    birth_year = CASE
      WHEN p_clear_birth_year THEN NULL
      ELSE coalesce(p_birth_year, birth_year)
    END,
    avatar_url = coalesce(nullif(btrim(coalesce(p_avatar_url, '')), ''), avatar_url),
    avatar_thumbnail_url = coalesce(
      nullif(btrim(coalesce(p_avatar_thumbnail_url, '')), ''),
      avatar_thumbnail_url
    ),
    updated_at = now()
  WHERE id = p_managed_player_id
    AND archived_at IS NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.archive_managed_player(p_managed_player_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF NOT public.is_authorized_managed_player_guardian(p_managed_player_id, me) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  -- Archive is always allowed, even with Team history. Blocking on active
  -- memberships would strand guardians whose Team was abandoned by its staff.
  -- Instead every active seat is soft-left first, so rosters, past lineups and
  -- attendance history stay intact and auditable.
  UPDATE public.fan_team_members
  SET left_at = now()
  WHERE managed_player_id = p_managed_player_id
    AND left_at IS NULL;

  UPDATE public.fan_managed_players
  SET archived_at = now(),
      updated_at = now()
  WHERE id = p_managed_player_id
    AND archived_at IS NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_managed_player_team_memberships(p_managed_player_id uuid)
RETURNS TABLE (
  membership_id uuid,
  team_id uuid,
  team_name text,
  sport text,
  logo_url text,
  logo_thumbnail_url text,
  color_hex text,
  player_number smallint,
  preferred_position_code text,
  joined_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF NOT public.is_authorized_managed_player_guardian(p_managed_player_id, me) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    m.membership_id,
    t.id,
    t.name,
    t.sport,
    t.logo_url,
    t.logo_thumbnail_url,
    t.color_hex,
    m.player_number,
    m.preferred_position_code,
    m.joined_at
  FROM public.fan_team_members m
  JOIN public.fan_teams t ON t.id = m.team_id
  WHERE m.managed_player_id = p_managed_player_id
    AND m.left_at IS NULL
    AND t.is_active = true
  ORDER BY lower(btrim(t.name)) ASC;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_my_managed_players_on_team(p_team_id uuid)
RETURNS TABLE (
  membership_id uuid,
  managed_player_id uuid,
  display_name text,
  avatar_url text,
  avatar_thumbnail_url text,
  player_number smallint,
  preferred_position_code text,
  joined_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  -- No authorization error for non-members: an outsider simply has no players
  -- here. This is the RPC the Team Overview uses to decide whether the
  -- "My Players" card exists at all, so it must be cheap and non-throwing.
  RETURN QUERY
  SELECT
    m.membership_id,
    p.id,
    p.display_name,
    p.avatar_url,
    p.avatar_thumbnail_url,
    m.player_number,
    m.preferred_position_code,
    m.joined_at
  FROM public.fan_team_members m
  JOIN public.fan_managed_players p ON p.id = m.managed_player_id
  JOIN public.fan_managed_player_guardians g
    ON g.managed_player_id = p.id
   AND g.guardian_user_id = me
   AND g.revoked_at IS NULL
  WHERE m.team_id = p_team_id
    AND m.left_at IS NULL
    AND p.archived_at IS NULL
  ORDER BY lower(btrim(p.display_name)) ASC;
END;
$$;

-- ---------------------------------------------------------------------------
-- 8) Runtime flag — managed Team seats (rollout gate)
-- ---------------------------------------------------------------------------
-- Old FanGeo builds decode list_fan_team_members.user_id as a non-null UUID and
-- use it as row identity. A managed seat (user_id NULL) can crash those clients
-- when they load a Team that already has managed rows. Schema may land first;
-- seat-creating RPCs stay OFF until operators flip this flag after compatible
-- clients are deployed.

CREATE TABLE IF NOT EXISTS public.fan_geo_runtime_flags (
  flag_key text PRIMARY KEY,
  enabled boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now(),
  note text
);

INSERT INTO public.fan_geo_runtime_flags (flag_key, enabled, note)
VALUES (
  'managed_player_team_seats',
  false,
  'Enable only after FanGeo builds that tolerate nullable user_id / membership_id on list_fan_team_members are required.'
)
ON CONFLICT (flag_key) DO NOTHING;

REVOKE ALL ON TABLE public.fan_geo_runtime_flags FROM PUBLIC;
REVOKE ALL ON TABLE public.fan_geo_runtime_flags FROM anon;
REVOKE ALL ON TABLE public.fan_geo_runtime_flags FROM authenticated;
GRANT SELECT, UPDATE, INSERT ON TABLE public.fan_geo_runtime_flags TO service_role;

CREATE OR REPLACE FUNCTION public.is_fan_geo_runtime_flag_enabled(p_flag_key text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (
      SELECT f.enabled
      FROM public.fan_geo_runtime_flags f
      WHERE f.flag_key = p_flag_key
    ),
    false
  );
$$;

COMMENT ON FUNCTION public.is_fan_geo_runtime_flag_enabled(text) IS
  'Internal rollout gate. Not granted to authenticated; called only from SECURITY DEFINER RPCs.';

-- ---------------------------------------------------------------------------
-- 9) Team membership for managed players
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.add_managed_player_to_fan_team(
  p_team_id uuid,
  p_managed_player_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_membership_id uuid;
  v_team_active boolean;
  v_already_active boolean;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  IF NOT public.is_fan_geo_runtime_flag_enabled('managed_player_team_seats') THEN
    RAISE EXCEPTION 'managed_player_team_seats_disabled'
      USING ERRCODE = 'check_violation';
  END IF;

  IF NOT public.is_authorized_managed_player_guardian(p_managed_player_id, me) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  -- Ordinary Team Members may NOT attach managed seats. Staff (owner/manager)
  -- who are also an authorized guardian may add their own managed player.
  -- Guardians who are only ordinary members must use
  -- accept_fan_team_invitation_as_managed_player after a Team invitation.
  IF NOT public.fan_team_viewer_can_manage(p_team_id) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  PERFORM public.assert_rpc_rate_limit('add_managed_player_to_fan_team', 30, 3600);

  SELECT t.is_active INTO v_team_active
  FROM public.fan_teams t WHERE t.id = p_team_id;

  IF v_team_active IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Team is no longer available.';
  END IF;

  IF NOT public.is_active_fan_team_member(p_team_id, me) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  IF (
    SELECT count(*)::int
    FROM public.fan_team_members
    WHERE team_id = p_team_id AND left_at IS NULL
  ) >= 50 THEN
    RAISE EXCEPTION 'A team may have at most 50 members.';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.fan_team_members m
    WHERE m.team_id = p_team_id
      AND m.managed_player_id = p_managed_player_id
      AND m.left_at IS NULL
  ) INTO v_already_active;

  IF v_already_active THEN
    RAISE EXCEPTION 'managed_player_already_on_team'
      USING ERRCODE = 'unique_violation';
  END IF;

  SELECT m.membership_id INTO v_membership_id
  FROM public.fan_team_members m
  WHERE m.team_id = p_team_id
    AND m.managed_player_id = p_managed_player_id
    AND m.left_at IS NOT NULL
  ORDER BY m.joined_at DESC
  LIMIT 1;

  IF v_membership_id IS NOT NULL THEN
    -- Soft rejoin: reactivate the prior left seat (preserves membership_id).
    UPDATE public.fan_team_members
    SET left_at = NULL,
        joined_at = now(),
        role = 'member'
    WHERE membership_id = v_membership_id;
    RETURN v_membership_id;
  END IF;

  -- Deliberately NO group_conversation_members row: a managed player is not a
  -- chat participant. Team Chat stays adults-only; guardians already have their
  -- own membership and receive Team messages there.
  INSERT INTO public.fan_team_members (team_id, user_id, managed_player_id, role)
  VALUES (p_team_id, NULL, p_managed_player_id, 'member')
  RETURNING membership_id INTO v_membership_id;

  RETURN v_membership_id;
END;
$$;

COMMENT ON FUNCTION public.add_managed_player_to_fan_team(uuid, uuid) IS
  'Staff (owner/manager) + authorized guardian path to place a managed player on a Team. '
  'Ordinary members cannot call this. Gated by managed_player_team_seats runtime flag.';

CREATE OR REPLACE FUNCTION public.accept_fan_team_invitation_as_managed_player(
  p_invitation_id uuid,
  p_managed_player_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_inv public.fan_team_invitations%ROWTYPE;
  v_team_active boolean;
  v_membership_id uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  IF NOT public.is_fan_geo_runtime_flag_enabled('managed_player_team_seats') THEN
    RAISE EXCEPTION 'managed_player_team_seats_disabled'
      USING ERRCODE = 'check_violation';
  END IF;

  PERFORM public.assert_rpc_rate_limit('accept_fan_team_invitation_as_managed_player', 60, 3600);

  IF NOT public.is_authorized_managed_player_guardian(p_managed_player_id, me) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_inv
  FROM public.fan_team_invitations
  WHERE id = p_invitation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invitation not found.' USING ERRCODE = 'P0002';
  END IF;
  IF v_inv.invitee_user_id <> me THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  IF v_inv.status <> 'pending' THEN
    RAISE EXCEPTION 'Invitation is no longer pending.';
  END IF;
  IF v_inv.expires_at IS NOT NULL AND v_inv.expires_at <= now() THEN
    UPDATE public.fan_team_invitations
    SET status = 'expired', responded_at = now()
    WHERE id = v_inv.id;
    RAISE EXCEPTION 'Invitation has expired.';
  END IF;

  SELECT t.is_active INTO v_team_active
  FROM public.fan_teams t WHERE t.id = v_inv.team_id;

  IF v_team_active IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Team is no longer available.';
  END IF;

  IF NOT public.is_active_fan_team_member(v_inv.team_id, v_inv.inviter_user_id) THEN
    RAISE EXCEPTION 'Invitation is no longer valid.';
  END IF;

  IF (
    SELECT count(*)::int
    FROM public.fan_team_members
    WHERE team_id = v_inv.team_id AND left_at IS NULL
  ) >= 50 THEN
    RAISE EXCEPTION 'A team may have at most 50 members.';
  END IF;

  -- The guardian consumed the invitation on behalf of the child and does NOT
  -- join themselves: no fan_team_members row and no Team Chat seat for the
  -- adult. Guardian visibility comes from fan_team_viewer_can_access_team.
  IF EXISTS (
    SELECT 1
    FROM public.fan_team_members m
    WHERE m.team_id = v_inv.team_id
      AND m.managed_player_id = p_managed_player_id
      AND m.left_at IS NULL
  ) THEN
    RAISE EXCEPTION 'managed_player_already_on_team'
      USING ERRCODE = 'unique_violation';
  END IF;

  SELECT m.membership_id INTO v_membership_id
  FROM public.fan_team_members m
  WHERE m.team_id = v_inv.team_id
    AND m.managed_player_id = p_managed_player_id
    AND m.left_at IS NOT NULL
  ORDER BY m.joined_at DESC
  LIMIT 1;

  IF v_membership_id IS NULL THEN
    INSERT INTO public.fan_team_members (team_id, user_id, managed_player_id, role)
    VALUES (v_inv.team_id, NULL, p_managed_player_id, 'member');
  ELSE
    UPDATE public.fan_team_members
    SET left_at = NULL,
        joined_at = now(),
        role = 'member'
    WHERE membership_id = v_membership_id;
  END IF;

  UPDATE public.fan_team_invitations
  SET status = 'accepted', responded_at = now()
  WHERE id = v_inv.id AND status = 'pending';

  RETURN v_inv.team_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 9) RSVP for a roster seat
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.set_fan_team_game_rsvp_for_membership(
  p_game_id uuid,
  p_membership_id uuid,
  p_status text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_status text := lower(btrim(coalesce(p_status, '')));
  v_member public.fan_team_members%ROWTYPE;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF v_status NOT IN ('going', 'maybe', 'cant_go') THEN
    RAISE EXCEPTION 'Invalid RSVP status.';
  END IF;

  SELECT * INTO v_member
  FROM public.fan_team_members
  WHERE membership_id = p_membership_id
    AND left_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Not a participant for this team game.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.fan_team_game_links l
    WHERE l.pickup_game_id = p_game_id
      AND l.team_id = v_member.team_id
  ) THEN
    RAISE EXCEPTION 'Not a participant for this team game.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.pickup_games pg
    WHERE pg.id = p_game_id
      AND pg.status = 'active'
      AND pg.archived_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Game not found.';
  END IF;

  IF v_member.user_id IS NOT NULL THEN
    -- Authenticated seat: unchanged storage (pickup_game_requests). Only the
    -- account holder may write; nobody gets to RSVP for another adult.
    IF v_member.user_id <> me THEN
      RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
    END IF;
    PERFORM public.set_fan_team_game_rsvp(p_game_id, v_status);
    RETURN;
  END IF;

  IF NOT public.is_authorized_managed_player_guardian(v_member.managed_player_id, me) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.fan_team_event_rsvps (
    team_id, pickup_game_id, membership_id, status, set_by_user_id
  ) VALUES (
    v_member.team_id, p_game_id, p_membership_id, v_status, me
  )
  ON CONFLICT ON CONSTRAINT fan_team_event_rsvps_unique DO UPDATE
    SET status = EXCLUDED.status,
        set_by_user_id = EXCLUDED.set_by_user_id,
        updated_at = now();
END;
$$;

COMMENT ON FUNCTION public.set_fan_team_game_rsvp_for_membership(uuid, uuid, text) IS
  'Single RSVP entry point for a Team roster seat. Authenticated seats delegate to '
  'set_fan_team_game_rsvp (pickup_game_requests, unchanged). Managed seats write '
  'fan_team_event_rsvps after guardian authorization.';

CREATE OR REPLACE FUNCTION public.list_fan_team_event_rsvps(
  p_team_id uuid,
  p_pickup_game_id uuid
)
RETURNS TABLE (
  membership_id uuid,
  managed_player_id uuid,
  display_name text,
  status text,
  updated_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF NOT public.fan_team_viewer_can_access_team(p_team_id) THEN
    RAISE EXCEPTION 'Not a team member.';
  END IF;

  RETURN QUERY
  SELECT
    r.membership_id,
    m.managed_player_id,
    coalesce(nullif(btrim(p.display_name), ''), 'Player')::text,
    r.status,
    r.updated_at
  FROM public.fan_team_event_rsvps r
  JOIN public.fan_team_members m ON m.membership_id = r.membership_id
  LEFT JOIN public.fan_managed_players p ON p.id = m.managed_player_id
  WHERE r.team_id = p_team_id
    AND r.pickup_game_id = p_pickup_game_id
    AND m.left_at IS NULL;
END;
$$;

-- ---------------------------------------------------------------------------
-- 10) Roster read — dual identity
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.list_fan_team_members(uuid);

CREATE FUNCTION public.list_fan_team_members(p_team_id uuid)
RETURNS TABLE (
  user_id uuid,
  role text,
  joined_at timestamptz,
  display_name text,
  username text,
  avatar_url text,
  avatar_thumbnail_url text,
  last_seen_at text,
  player_number smallint,
  gender text,
  membership_id uuid,
  managed_player_id uuid,
  is_managed_player boolean,
  guardian_display_name text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_can_manage boolean;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_team_id IS NULL OR NOT public.fan_team_viewer_can_access_team(p_team_id) THEN
    RAISE EXCEPTION 'Not a team member.';
  END IF;

  v_can_manage := public.fan_team_viewer_can_manage(p_team_id);

  RETURN QUERY
  SELECT
    m.user_id,
    m.role,
    m.joined_at,
    CASE
      WHEN m.managed_player_id IS NOT NULL
        THEN coalesce(nullif(btrim(mp.display_name), ''), 'Player')
      ELSE coalesce(nullif(btrim(p.display_name), ''), 'Fan')
    END::text,
    p.username,
    CASE WHEN m.managed_player_id IS NOT NULL THEN mp.avatar_url ELSE p.avatar_url END,
    CASE
      WHEN m.managed_player_id IS NOT NULL THEN mp.avatar_thumbnail_url
      ELSE p.avatar_thumbnail_url
    END,
    CASE
      -- Managed players have no presence: they are not signed in anywhere.
      WHEN m.managed_player_id IS NOT NULL THEN NULL
      WHEN p.activity_status_visible IS FALSE THEN NULL
      ELSE p.last_seen_at::text
    END AS last_seen_at,
    m.player_number,
    CASE WHEN m.managed_player_id IS NOT NULL THEN NULL ELSE p.gender END,
    m.membership_id,
    m.managed_player_id,
    (m.managed_player_id IS NOT NULL),
    CASE
      -- Staff need a contact for the child; teammates do not.
      WHEN m.managed_player_id IS NOT NULL
        AND (
          v_can_manage
          OR public.is_authorized_managed_player_guardian(m.managed_player_id, me)
        )
        THEN (
          SELECT coalesce(nullif(btrim(gp.display_name), ''), 'Guardian')
          FROM public.fan_managed_player_guardians g
          JOIN public.user_profiles gp ON gp.id = g.guardian_user_id
          WHERE g.managed_player_id = m.managed_player_id
            AND g.revoked_at IS NULL
          ORDER BY (g.role = 'primary_guardian') DESC, g.created_at ASC
          LIMIT 1
        )
      ELSE NULL
    END::text
  FROM public.fan_team_members m
  LEFT JOIN public.user_profiles p ON p.id = m.user_id
  LEFT JOIN public.fan_managed_players mp ON mp.id = m.managed_player_id
  WHERE m.team_id = p_team_id
    AND m.left_at IS NULL
  ORDER BY
    CASE m.role
      WHEN 'owner' THEN 0
      WHEN 'manager' THEN 1
      WHEN 'head_coach' THEN 2
      WHEN 'assistant_coach' THEN 3
      WHEN 'captain' THEN 4
      WHEN 'assistant_captain' THEN 5
      ELSE 6
    END,
    lower(coalesce(mp.display_name, p.display_name, p.username, '')) ASC;
END;
$$;

COMMENT ON FUNCTION public.list_fan_team_members(uuid) IS
  'Active Team roster with dual participant identity. user_id is NULL for managed '
  'players; membership_id is always the stable row identity. Hierarchy sort preserved. '
  'Does NOT expose birth_year, created_by_user_id, linked_user_id, or guardian user ids. '
  'guardian_display_name is staff/guardian-only.';

-- ---------------------------------------------------------------------------
-- 11) Notification recipients (Edge Function preparation)
-- ---------------------------------------------------------------------------
-- Edge Functions (notify-fan-team-member-change, notify-fan-team-member-left,
-- notify-pickup-game-change) currently fan out to fan_team_members.user_id and
-- would therefore silently skip managed players. They must be updated in a
-- FOLLOW-UP change to resolve recipients through this function so a child's
-- schedule change reaches the child's guardians. Nothing is deployed here.

CREATE OR REPLACE FUNCTION public.resolve_fan_team_notification_recipients_for_participant(
  p_team_id uuid,
  p_membership_id uuid DEFAULT NULL,
  p_user_id uuid DEFAULT NULL,
  p_managed_player_id uuid DEFAULT NULL
)
RETURNS TABLE (recipient_user_id uuid)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT DISTINCT r.recipient_user_id
  FROM public.fan_team_members m
  CROSS JOIN LATERAL (
    SELECT unnest(
      CASE
        WHEN m.user_id IS NOT NULL THEN ARRAY[m.user_id]
        ELSE coalesce(
          (
            SELECT array_agg(DISTINCT g.guardian_user_id)
            FROM public.fan_managed_player_guardians g
            WHERE g.managed_player_id = m.managed_player_id
              AND g.revoked_at IS NULL
          ),
          ARRAY[]::uuid[]
        )
      END
    ) AS recipient_user_id
  ) r
  WHERE m.team_id = p_team_id
    AND m.left_at IS NULL
    AND (p_membership_id IS NULL OR m.membership_id = p_membership_id)
    AND (p_user_id IS NULL OR m.user_id = p_user_id)
    AND (p_managed_player_id IS NULL OR m.managed_player_id = p_managed_player_id)
    AND (
      p_membership_id IS NOT NULL
      OR p_user_id IS NOT NULL
      OR p_managed_player_id IS NOT NULL
    );
$$;

COMMENT ON FUNCTION public.resolve_fan_team_notification_recipients_for_participant(uuid, uuid, uuid, uuid) IS
  'Participant -> push recipients. Authenticated seat resolves to itself; managed seat '
  'resolves to every active guardian. Intended caller is service_role from Edge Functions.';

-- ---------------------------------------------------------------------------
-- 12) Grants
-- ---------------------------------------------------------------------------

-- Client-facing RPCs (iOS calls these).
DO $$
DECLARE
  fn text;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'public.list_my_managed_players()',
    'public.create_managed_player(text, text, text, int, text, text)',
    'public.update_managed_player(uuid, text, text, text, int, text, text, boolean)',
    'public.archive_managed_player(uuid)',
    'public.list_managed_player_team_memberships(uuid)',
    'public.list_my_managed_players_on_team(uuid)',
    'public.add_managed_player_to_fan_team(uuid, uuid)',
    'public.accept_fan_team_invitation_as_managed_player(uuid, uuid)',
    'public.set_fan_team_game_rsvp_for_membership(uuid, uuid, text)',
    'public.list_fan_team_event_rsvps(uuid, uuid)',
    'public.list_fan_team_members(uuid)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', fn);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', fn);
  END LOOP;
END $$;

-- Internal helpers: callable only from SECURITY DEFINER owners / service_role.
-- Never expose guardian/relationship probes or roster-recipient expansion to clients.
DO $$
DECLARE
  fn text;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'public.is_active_fan_team_managed_member(uuid, uuid)',
    'public.is_authorized_managed_player_guardian(uuid, uuid)',
    'public.fan_managed_player_visible_to_viewer(uuid)',
    'public.fan_team_membership_recipient_user_ids(uuid)',
    'public.is_fan_geo_runtime_flag_enabled(text)',
    'public.resolve_fan_team_notification_recipients_for_participant(uuid, uuid, uuid, uuid)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', fn);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', fn);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM authenticated', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', fn);
  END LOOP;
END $$;

-- Team access helper is used by RLS policies for authenticated viewers — keep EXECUTE.
REVOKE ALL ON FUNCTION public.fan_team_viewer_can_access_team(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fan_team_viewer_can_access_team(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.fan_team_viewer_can_access_team(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_viewer_can_access_team(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 13) Structural self-checks
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  -- Every pre-existing roster row survived with an authenticated identity.
  IF EXISTS (
    SELECT 1 FROM public.fan_team_members
    WHERE membership_id IS NULL
  ) THEN
    RAISE EXCEPTION 'assert_failed: fan_team_members.membership_id must be populated';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.fan_team_members
    WHERE user_id IS NULL AND managed_player_id IS NULL
  ) THEN
    RAISE EXCEPTION 'assert_failed: fan_team_members identity XOR violated';
  END IF;

  IF (
    SELECT count(*) FROM public.fan_team_members
  ) <> (
    SELECT count(DISTINCT membership_id) FROM public.fan_team_members
  ) THEN
    RAISE EXCEPTION 'assert_failed: membership_id is not unique';
  END IF;

  -- ON CONFLICT (team_id, user_id) inference must still resolve.
  IF NOT EXISTS (
    SELECT 1
    FROM pg_index i
    JOIN pg_class c ON c.oid = i.indexrelid
    WHERE i.indrelid = 'public.fan_team_members'::regclass
      AND i.indisunique
      AND i.indpred IS NULL
      AND c.relname = 'fan_team_members_team_user_uidx'
  ) THEN
    RAISE EXCEPTION 'assert_failed: full unique (team_id, user_id) index missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.fan_team_members'::regclass
      AND contype = 'p'
      AND array_length(conkey, 1) = 1
  ) THEN
    RAISE EXCEPTION 'assert_failed: fan_team_members PK must be membership_id only';
  END IF;

  -- No foreign keys should still reference the old composite PK shape.
  IF EXISTS (
    SELECT 1
    FROM pg_constraint c
    WHERE c.contype = 'f'
      AND c.confrelid = 'public.fan_team_members'::regclass
      AND array_length(c.confkey, 1) > 1
  ) THEN
    RAISE EXCEPTION 'assert_failed: composite FK still references fan_team_members';
  END IF;

  IF to_regclass('public.fan_geo_runtime_flags') IS NULL THEN
    RAISE EXCEPTION 'assert_failed: fan_geo_runtime_flags missing';
  END IF;

  IF public.is_fan_geo_runtime_flag_enabled('managed_player_team_seats') IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'assert_failed: managed_player_team_seats must default to false';
  END IF;

  -- Privilege: internal guardian probe must not be executable by authenticated.
  IF has_function_privilege(
    'authenticated',
    'public.is_authorized_managed_player_guardian(uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'assert_failed: is_authorized_managed_player_guardian granted to authenticated';
  END IF;

  IF has_table_privilege('authenticated', 'public.fan_managed_players', 'SELECT') THEN
    RAISE EXCEPTION 'assert_failed: authenticated must not SELECT fan_managed_players';
  END IF;
END $$;

COMMIT;

-- Manual verification (staging):
--   -- No managed players: every path must behave exactly as before.
--   SELECT * FROM list_my_managed_players();                 -- 0 rows
--   SELECT * FROM list_my_managed_players_on_team('<team>');  -- 0 rows
--   SELECT * FROM list_fan_team_members('<team>');            -- unchanged roster
--
--   -- Privacy: ordinary teammate has no table SELECT on fan_managed_players.
--   SELECT has_table_privilege('authenticated','public.fan_managed_players','SELECT'); -- false
--
--   -- Rollout: seat creation stays disabled until compatible clients ship.
--   UPDATE public.fan_geo_runtime_flags
--     SET enabled = true, updated_at = now()
--     WHERE flag_key = 'managed_player_team_seats';  -- only after client gate
--
--   -- Staff+guardian path (not ordinary member).
--   SELECT create_managed_player('Ellie', 'Rivera', NULL, 2015);
--   SELECT add_managed_player_to_fan_team('<team>', '<player>');
--   SELECT set_fan_team_game_rsvp_for_membership('<pickup>', '<membership>', 'going');
--   SELECT * FROM list_fan_team_event_rsvps('<team>', '<pickup>');
--
--   -- Invitation path for ordinary guardians.
--   SELECT accept_fan_team_invitation_as_managed_player('<invite>', '<player>');
--
--   -- list_fan_team_members must not leak birth_year / guardian user ids.
--   SELECT * FROM list_fan_team_members('<team>');
