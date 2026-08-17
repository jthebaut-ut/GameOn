-- Durable TheSportsDB provider identity + artwork cache for professional FanGeo favorites.
-- Populated only by the privileged sync-sports-provider-artwork Edge Function.
-- Clients have read-only SELECT. The paid API key never enters this table.

CREATE TABLE IF NOT EXISTS public.sports_provider_identities (
  catalog_id text PRIMARY KEY,
  kind text NOT NULL CHECK (kind IN ('team', 'national_team', 'player', 'league')),
  provider text NOT NULL DEFAULT 'thesportsdb',
  provider_team_id text,
  provider_player_id text,
  canonical_name text NOT NULL,
  league text,
  sport text,
  country text,
  badge_url text,
  logo_url text,
  provider_league_id text,
  player_cutout_url text,
  player_creative_commons boolean,
  refreshed_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sports_provider_identities_provider_chk
    CHECK (provider = 'thesportsdb'),
  CONSTRAINT sports_provider_identities_team_id_for_teams
    CHECK (kind NOT IN ('team', 'national_team') OR provider_team_id IS NOT NULL OR badge_url IS NULL),
  CONSTRAINT sports_provider_identities_player_not_club_badge
    CHECK (kind <> 'player' OR badge_url IS NULL)
);

CREATE INDEX IF NOT EXISTS idx_sports_provider_identities_provider_team
  ON public.sports_provider_identities (provider, provider_team_id)
  WHERE provider_team_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_sports_provider_identities_provider_player
  ON public.sports_provider_identities (provider, provider_player_id)
  WHERE provider_player_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_sports_provider_identities_league_refreshed
  ON public.sports_provider_identities (league, refreshed_at);

CREATE INDEX IF NOT EXISTS idx_sports_provider_identities_provider_league
  ON public.sports_provider_identities (provider, provider_league_id, refreshed_at)
  WHERE provider_league_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_sports_provider_identities_kind
  ON public.sports_provider_identities (kind);

CREATE OR REPLACE FUNCTION public.sports_provider_identities_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sports_provider_identities_touch_updated_at
  ON public.sports_provider_identities;
CREATE TRIGGER sports_provider_identities_touch_updated_at
  BEFORE UPDATE ON public.sports_provider_identities
  FOR EACH ROW
  EXECUTE FUNCTION public.sports_provider_identities_touch_updated_at();

ALTER TABLE public.sports_provider_identities ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS sports_provider_identities_select_public
  ON public.sports_provider_identities;
CREATE POLICY sports_provider_identities_select_public
  ON public.sports_provider_identities
  FOR SELECT
  TO anon, authenticated
  USING (true);

REVOKE INSERT, UPDATE, DELETE ON public.sports_provider_identities FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.sports_provider_identities FROM authenticated;
GRANT SELECT ON public.sports_provider_identities TO anon;
GRANT SELECT ON public.sports_provider_identities TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.sports_provider_identities TO service_role;

COMMENT ON TABLE public.sports_provider_identities IS
  'Durable TheSportsDB team/player artwork metadata keyed by FanGeo catalog_id. Written by sync-sports-provider-artwork; clients read badge/cutout URLs only.';

COMMENT ON COLUMN public.sports_provider_identities.badge_url IS
  'Primary professional crest from TheSportsDB strBadge.';

COMMENT ON COLUMN public.sports_provider_identities.player_cutout_url IS
  'Player artwork only when strCreativeCommons permits. Never a club badge.';

-- Optional weekly cron. Uses the same Vault secret names as sync-live-matches.
-- Skips scheduling when Vault or pg_net is unavailable. Does not store API keys.
DO $$
DECLARE
  v_url_secret_name text;
  v_service_role_secret_name text;
  v_command text;
BEGIN
  IF to_regclass('vault.decrypted_secrets') IS NULL THEN
    RAISE NOTICE 'vault.decrypted_secrets unavailable; schedule sync-sports-provider-artwork-weekly manually.';
    RETURN;
  END IF;

  SELECT name
  INTO v_url_secret_name
  FROM vault.decrypted_secrets
  WHERE name IN ('fangeo_supabase_url', 'SUPABASE_URL', 'PROJECT_URL')
    AND NULLIF(BTRIM(decrypted_secret), '') IS NOT NULL
  LIMIT 1;

  SELECT name
  INTO v_service_role_secret_name
  FROM vault.decrypted_secrets
  WHERE name IN ('fangeo_service_role_key', 'SUPABASE_SERVICE_ROLE_KEY', 'SERVICE_ROLE_KEY')
    AND NULLIF(BTRIM(decrypted_secret), '') IS NOT NULL
  LIMIT 1;

  IF v_url_secret_name IS NULL OR v_service_role_secret_name IS NULL THEN
    RAISE NOTICE 'Required Vault secrets missing; schedule sync-sports-provider-artwork-weekly manually.';
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'sync-sports-provider-artwork-weekly'
  ) THEN
    PERFORM cron.unschedule('sync-sports-provider-artwork-weekly');
  END IF;

  v_command := format(
    $command$
      SELECT net.http_post(
        url := (
          SELECT RTRIM(decrypted_secret, '/')
          FROM vault.decrypted_secrets
          WHERE name = %L
          ORDER BY updated_at DESC NULLS LAST, created_at DESC
          LIMIT 1
        ) || '/functions/v1/sync-sports-provider-artwork',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || (
            SELECT decrypted_secret
            FROM vault.decrypted_secrets
            WHERE name = %L
            ORDER BY updated_at DESC NULLS LAST, created_at DESC
            LIMIT 1
          )
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 120000
      );
    $command$,
    v_url_secret_name,
    v_service_role_secret_name
  );

  PERFORM cron.schedule(
    'sync-sports-provider-artwork-weekly',
    '15 4 * * 1',
    v_command
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'Could not schedule sync-sports-provider-artwork-weekly; configure cron manually.';
END $$;
