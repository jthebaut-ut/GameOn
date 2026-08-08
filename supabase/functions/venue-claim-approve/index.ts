import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { handleVenueClaimAdminRequest } from "../_shared/venue_claim_admin_handler.ts"

/**
 * Admin venue-claim approve:
 * - GET ?token=… → read-only confirmation page (no DB mutation; prefetch-safe)
 * - POST token (+ action) → approve and ensure linked venues row
 *
 * Token: HS256 JWT signed with ADMIN_VENUE_CLAIM_LINK_SECRET
 * Payload: claim_id (uuid), action: "approve"
 *
 * Deploy: `supabase functions deploy venue-claim-approve`
 */

Deno.serve(async (req) => {
  const response = await handleVenueClaimAdminRequest(req, "approve")

  const priorType = (response.headers.get("Content-Type") ?? "").toLowerCase()
  if (priorType.includes("application/json")) {
    return response
  }

  const html = await response.text()

  return new Response(html, {
    status: response.status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
    },
  })
})
