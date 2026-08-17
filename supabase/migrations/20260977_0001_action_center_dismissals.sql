-- =============================================================================
-- 20260977_0001 — Action Center per-user dismissals
-- =============================================================================
-- Additive persistence for “remove this item from MY Action Center”.
-- Does NOT delete games, events, Teams, invitations, ratings, or notifications.
-- UNAPPLIED — deploy manually. Do not auto-apply from the client.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.action_center_dismissals (
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  action_key text NOT NULL,
  dismissed_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT action_center_dismissals_pkey PRIMARY KEY (user_id, action_key),
  CONSTRAINT action_center_dismissals_action_key_check CHECK (
    char_length(action_key) BETWEEN 1 AND 180
    AND action_key ~ '^[a-z0-9_.:-]+$'
  )
);

CREATE INDEX IF NOT EXISTS action_center_dismissals_user_dismissed_at_idx
  ON public.action_center_dismissals (user_id, dismissed_at DESC);

COMMENT ON TABLE public.action_center_dismissals IS
  'Per-user Action Center hide ledger. action_key is a stable item identity '
  '(e.g. rate_game:<pickup_game_id>, pickup_update:<game_id>:<instance>). '
  'Dismissing never deletes the underlying source row.';

COMMENT ON COLUMN public.action_center_dismissals.action_key IS
  'Deterministic Action Center item key. Schedule updates MUST include an '
  'instance suffix so a later change to the same game can reappear.';

ALTER TABLE public.action_center_dismissals ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.action_center_dismissals FROM PUBLIC;
REVOKE ALL ON TABLE public.action_center_dismissals FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.action_center_dismissals TO authenticated;
GRANT ALL ON TABLE public.action_center_dismissals TO service_role;

DROP POLICY IF EXISTS action_center_dismissals_select_own ON public.action_center_dismissals;
CREATE POLICY action_center_dismissals_select_own
  ON public.action_center_dismissals
  FOR SELECT
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS action_center_dismissals_insert_own ON public.action_center_dismissals;
CREATE POLICY action_center_dismissals_insert_own
  ON public.action_center_dismissals
  FOR INSERT
  TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS action_center_dismissals_update_own ON public.action_center_dismissals;
CREATE POLICY action_center_dismissals_update_own
  ON public.action_center_dismissals
  FOR UPDATE
  TO authenticated
  USING (user_id = (SELECT auth.uid()))
  WITH CHECK (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS action_center_dismissals_delete_own ON public.action_center_dismissals;
CREATE POLICY action_center_dismissals_delete_own
  ON public.action_center_dismissals
  FOR DELETE
  TO authenticated
  USING (user_id = (SELECT auth.uid()));
