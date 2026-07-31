-- =============================================================================
-- 20260910: Multilingual announcement translations (FanGeo app language)
-- PREPARED ONLY — do NOT apply to production without explicit approval.
--
-- Authoritative FanGeo iOS languages (L10n.supportedLanguages):
--   en (source), es, fr, pt, de, it, pl, ru, sq, zh-Hans
--
-- Design:
--   - announcements.* remain the English SOURCE copy (backward compatible)
--   - announcement_translations stores one row per (announcement_id, locale)
--   - Content language is independent of geographic targeting
--   - iOS resolves by ACTIVE app language (UserDefaults appLanguage), never country
-- =============================================================================

ALTER TABLE public.announcements
  ADD COLUMN IF NOT EXISTS source_language text NOT NULL DEFAULT 'en';

ALTER TABLE public.announcements
  ADD COLUMN IF NOT EXISTS source_content_hash text;

COMMENT ON COLUMN public.announcements.source_language IS
  'Canonical FanGeo source locale for announcement copy. Always en for admin-authored content.';

COMMENT ON COLUMN public.announcements.source_content_hash IS
  'Hash of English source translatable fields. Used to mark translations stale when source changes.';

CREATE TABLE IF NOT EXISTS public.announcement_translations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  announcement_id uuid NOT NULL REFERENCES public.announcements(id) ON DELETE CASCADE,
  locale text NOT NULL,
  title text NOT NULL DEFAULT '',
  subtitle text NOT NULL DEFAULT '',
  description text NOT NULL DEFAULT '',
  cta_label text,
  promo_date_chip text,
  promo_location_chip text,
  promo_offer_chip text,
  translation_status text NOT NULL DEFAULT 'pending'
    CHECK (translation_status IN (
      'pending',
      'translating',
      'current',
      'stale',
      'failed',
      'missing'
    )),
  source_content_hash text NOT NULL DEFAULT '',
  manually_edited boolean NOT NULL DEFAULT false,
  provider text,
  model text,
  error_detail text,
  translated_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT announcement_translations_locale_format
    CHECK (locale ~ '^[a-z]{2}(-[A-Za-z]+)?$'),
  CONSTRAINT announcement_translations_unique_locale
    UNIQUE (announcement_id, locale)
);

CREATE INDEX IF NOT EXISTS announcement_translations_announcement_id_idx
  ON public.announcement_translations (announcement_id);

CREATE INDEX IF NOT EXISTS announcement_translations_locale_status_idx
  ON public.announcement_translations (locale, translation_status);

COMMENT ON TABLE public.announcement_translations IS
  'Persisted FanGeo announcement localizations. Generated server-side from English source. iOS must not translate at runtime.';

CREATE OR REPLACE FUNCTION public.fangeo_supported_app_locales()
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT ARRAY[
    'en',
    'es',
    'fr',
    'pt',
    'de',
    'it',
    'pl',
    'ru',
    'sq',
    'zh-Hans'
  ]::text[];
$$;

COMMENT ON FUNCTION public.fangeo_supported_app_locales() IS
  'Authoritative FanGeo iOS app locales from L10n.supportedLanguages. en is source; others are translation targets.';

CREATE OR REPLACE FUNCTION public.fangeo_announcement_translation_target_locales()
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT array_remove(public.fangeo_supported_app_locales(), 'en');
$$;

-- Keep updated_at fresh
CREATE OR REPLACE FUNCTION public.set_announcement_translations_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_announcement_translations_updated_at ON public.announcement_translations;
CREATE TRIGGER trg_announcement_translations_updated_at
  BEFORE UPDATE ON public.announcement_translations
  FOR EACH ROW
  EXECUTE FUNCTION public.set_announcement_translations_updated_at();

-- RLS: authenticated/anon can read current translations for discoverable announcements only.
ALTER TABLE public.announcement_translations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS announcement_translations_select_discoverable ON public.announcement_translations;
CREATE POLICY announcement_translations_select_discoverable
  ON public.announcement_translations
  FOR SELECT
  TO anon, authenticated
  USING (
    translation_status = 'current'
    AND EXISTS (
      SELECT 1
      FROM public.announcements a
      WHERE a.id = announcement_translations.announcement_id
        AND a.deleted_at IS NULL
        AND a.display_type = 'discover_banner'
        AND a.status IN ('active', 'scheduled')
        AND current_date >= a.start_date
        AND current_date <= a.end_date
    )
  );

-- Writes are service_role only (admin dashboard).
REVOKE ALL ON TABLE public.announcement_translations FROM PUBLIC;
REVOKE ALL ON TABLE public.announcement_translations FROM anon;
REVOKE ALL ON TABLE public.announcement_translations FROM authenticated;
GRANT SELECT ON TABLE public.announcement_translations TO anon, authenticated;
GRANT ALL ON TABLE public.announcement_translations TO service_role;

REVOKE ALL ON FUNCTION public.fangeo_supported_app_locales() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fangeo_supported_app_locales() TO anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.fangeo_announcement_translation_target_locales() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fangeo_announcement_translation_target_locales() TO anon, authenticated, service_role;

DO $integrity$
BEGIN
  IF to_regclass('public.announcement_translations') IS NULL THEN
    RAISE EXCEPTION 'FAIL: announcement_translations missing';
  END IF;
  IF to_regprocedure('public.fangeo_supported_app_locales()') IS NULL THEN
    RAISE EXCEPTION 'FAIL: fangeo_supported_app_locales missing';
  END IF;
  IF NOT ('zh-Hans' = ANY(public.fangeo_supported_app_locales())) THEN
    RAISE EXCEPTION 'FAIL: expected zh-Hans in supported locales';
  END IF;
  IF 'en' = ANY(public.fangeo_announcement_translation_target_locales()) THEN
    RAISE EXCEPTION 'FAIL: en must not be a translation target';
  END IF;
END;
$integrity$;
