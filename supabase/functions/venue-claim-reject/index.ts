import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { handleVenueClaimAdminRequest } from "../_shared/venue_claim_admin_handler.ts"

/**
 * Admin venue-claim reject:
 * - GET ?token=… → read-only confirmation (no DB mutation; prefetch-safe)
 * - POST token (+ action) → reject pending claim
 *
 * Deploy: `supabase functions deploy venue-claim-reject`
 */

Deno.serve(async (req) => {
  const response = await handleVenueClaimAdminRequest(req, "reject")

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
