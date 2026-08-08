# Venue photos — UID ownership migration

## Current hardened model (`20260915_0004`)

| Operation | Rule |
|---|---|
| SELECT | Public (legacy email folders + new `{auth.uid}/…` paths) |
| INSERT / UPDATE / DELETE | Authenticated only under `{auth.uid()}/…` |

Sanitized-email folders are **read-only** for clients. Email is not an enduring ownership key.

## App requirement

iOS `uploadVenuePhoto` must upload under `session.user.id` (already updated in repo). Apply storage RLS only after that build is shipping, or ship together.

## Legacy objects

Existing URLs like `{sanitized_email}/cover_….jpg` keep working via public SELECT.

When an owner replaces a photo:

1. Upload to `{uid}/…`
2. Update `venues.cover_photo_url` / `menu_photo_url` to the new public URL
3. Optionally delete the old object later (Edge/service_role) — path has no venue id, so do not grant client DELETE on email folders

## Optional later batch

1. Enumerate `storage.objects` where `bucket_id = 'venue-photos'` and first segment is not a UUID
2. Map via `venues` / `businesses.owner_email` sanitized match (best-effort; collisions possible)
3. Copy to `{owner_user_id}/…`, rewrite URLs, delete orphans

Do not re-enable email-folder writes to shortcut this.
