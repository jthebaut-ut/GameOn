-- After organizer soft-cancel, join rows become `cancelled`. Allow those former
-- participants to still SELECT the pickup row so cancelled-game deep links /
-- historical detail can render "This game was cancelled."
--
-- Do NOT apply from the agent. Apply manually after prior pickup migrations.
--
-- Does NOT expand Team-wide access. Team membership alone still uses
-- is_pickup_game_fan_team_participant. Does NOT resurrect active Discover pins
-- (public branch still requires status=active + is_visible).

CREATE OR REPLACE FUNCTION public.can_read_pickup_game_for_requester(p_pickup_game_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.pickup_game_requests r
    WHERE r.pickup_game_id = p_pickup_game_id
      AND r.requester_user_id = auth.uid()
      AND r.status IN ('pending', 'approved', 'rejected', 'cancelled')
  );
$$;

COMMENT ON FUNCTION public.can_read_pickup_game_for_requester(uuid) IS
  'Requester-scoped pickup SELECT. Includes cancelled join rows so soft-cancelled games remain readable for historical detail/deep links.';

REVOKE ALL ON FUNCTION public.can_read_pickup_game_for_requester(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_read_pickup_game_for_requester(uuid) TO authenticated;
