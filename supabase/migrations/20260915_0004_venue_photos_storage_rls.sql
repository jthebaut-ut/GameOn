-- =============================================================================
-- 20260915_0004 — venue-photos Storage RLS (UID ownership)
-- =============================================================================
-- Authoritative ownership key: auth.uid() as the first path segment.
--
-- New uploads MUST use: {auth.uid()}/{fileName}
-- Legacy objects under sanitized-email folders remain publicly readable so
-- existing cover/menu URLs keep working. Clients may NOT insert/update/delete
-- under email folders (sanitized JWT email is not enduring ownership).
--
-- Legacy write migration plan (ops, not automated here):
--   1. Ship iOS that uploads under auth.uid().
--   2. On next venue photo save, write new UID path + update venues.*_photo_url.
--   3. Optional later: batch-copy legacy email-folder objects → uid folders and
--      rewrite URLs; then delete orphans.
-- Legacy email-folder objects have no venue/business id in the path, so this
-- migration does NOT grant weak email-based write access.
--
-- Do NOT apply from the agent; review and apply deliberately.
-- Apply AFTER or WITH the iOS UID upload path change.
-- =============================================================================

BEGIN;

-- Drop prior draft policies from earlier 20260915_0004 revisions and any
-- known Dashboard names for this bucket.
DROP POLICY IF EXISTS "venue_photos_select_public" ON storage.objects;
DROP POLICY IF EXISTS "venue_photos_insert_own" ON storage.objects;
DROP POLICY IF EXISTS "venue_photos_update_own" ON storage.objects;
DROP POLICY IF EXISTS "venue_photos_delete_own" ON storage.objects;
DROP POLICY IF EXISTS "venue_photos_insert_uid" ON storage.objects;
DROP POLICY IF EXISTS "venue_photos_update_uid" ON storage.objects;
DROP POLICY IF EXISTS "venue_photos_delete_uid" ON storage.objects;

-- Read: public URLs / AsyncImage (legacy email folders + new uid folders).
CREATE POLICY "venue_photos_select_public"
  ON storage.objects FOR SELECT
  TO public
  USING (bucket_id = 'venue-photos');

-- Insert: UID folder only.
CREATE POLICY "venue_photos_insert_uid"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'venue-photos'
    AND split_part(name, '/', 1) = auth.uid()::text
    AND length(split_part(name, '/', 1)) > 0
  );

-- Update/delete: UID folder only (no email-folder writes).
CREATE POLICY "venue_photos_update_uid"
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'venue-photos'
    AND split_part(name, '/', 1) = auth.uid()::text
  )
  WITH CHECK (
    bucket_id = 'venue-photos'
    AND split_part(name, '/', 1) = auth.uid()::text
  );

CREATE POLICY "venue_photos_delete_uid"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'venue-photos'
    AND split_part(name, '/', 1) = auth.uid()::text
  );

COMMIT;
