/**
 * Shared admin handler for venue-claim approve/reject Edge Functions.
 *
 * Security model (prefetch-safe):
 * - GET: verify token, show read-only confirmation page — NO database mutation
 * - POST: verify token + action + claim_id, then mutate (approve/reject)
 *
 * Env:
 * - SUPABASE_URL
 * - SUPABASE_SERVICE_ROLE_KEY
 * - ADMIN_VENUE_CLAIM_LINK_SECRET — HS256 secret for admin link JWT
 */
import { createClient } from "npm:@supabase/supabase-js@2"
import { jwtVerify } from "npm:jose@5"
import {
  ClaimApproveError,
  ensureVenueForApprovedClaim,
  type VenueClaimRecord,
} from "./venue_claim_approve_venue.ts"
import {
  htmlResponse,
  pageAlreadyProcessed,
  pageApproved,
  pageConfirmAction,
  pageExpiredOrInvalid,
  pageExpiredToken,
  pageInvalidToken,
  pageRejected,
  pageVenueApprovalFailed,
} from "./venue_claim_admin_html.ts"

export type AdminRouteAction = "approve" | "reject"

function isUuid(s: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(s)
}

function isPendingStatus(status: string | null | undefined): boolean {
  const s = status?.trim().toLowerCase() ?? ""
  if (s === "approved") return false
  if (s.includes("reject")) return false
  return true
}

function isRejectedStatus(status: string | null | undefined): boolean {
  const s = status?.trim().toLowerCase() ?? ""
  return s.includes("reject")
}

function isApprovedStatus(status: string | null | undefined): boolean {
  const s = status?.trim().toLowerCase() ?? ""
  return s === "approved"
}

function statusLabel(status: string | null | undefined): string {
  const s = status?.trim().toLowerCase() ?? ""
  if (s === "approved") return "approved"
  if (s.includes("reject")) return "rejected"
  return status?.trim() || "pending"
}

function formatTimestamp(): string {
  return new Date().toLocaleString("en-US", { dateStyle: "medium", timeStyle: "short" })
}

function isJwtExpiredError(e: unknown): boolean {
  return (
    typeof e === "object" &&
    e !== null &&
    "code" in e &&
    (e as { code?: string }).code === "ERR_JWT_EXPIRED"
  )
}

/** Verify signed admin link JWT; throws on invalid signature, expiry, or bad payload. */
async function verifyAdminActionToken(
  token: string,
  expectedAction: AdminRouteAction,
): Promise<{ claim_id: string; jti: string | null }> {
  const secret = Deno.env.get("ADMIN_VENUE_CLAIM_LINK_SECRET")?.trim()
  if (!secret) {
    console.error("venue_claim_admin: missing ADMIN_VENUE_CLAIM_LINK_SECRET")
    throw new Error("misconfigured")
  }

  const key = new TextEncoder().encode(secret)
  const { payload } = await jwtVerify(token, key, { algorithms: ["HS256"] })

  const claim_id = typeof payload.claim_id === "string" ? payload.claim_id.trim() : ""
  const action = typeof payload.action === "string" ? payload.action.trim().toLowerCase() : ""
  const jti = typeof payload.jti === "string" ? payload.jti.trim() : null

  if (!isUuid(claim_id)) throw new Error("bad_payload")
  if (action !== expectedAction) throw new Error("action_mismatch")

  return { claim_id, jti }
}

async function loadClaim(
  claimId: string,
): Promise<{ claim: VenueClaimRecord | null; errorPage: Response | null }> {
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? ""
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
  if (!supabaseUrl || !serviceKey) {
    console.error("venue_claim_admin: missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY")
    return { claim: null, errorPage: htmlResponse(pageExpiredOrInvalid(), 500) }
  }

  const supabase = createClient(supabaseUrl, serviceKey)
  const { data: claimRaw, error: selErr } = await supabase
    .from("venue_claims")
    .select("*")
    .eq("id", claimId)
    .maybeSingle()

  if (selErr) {
    console.error("venue_claim_admin: select error", selErr)
    return { claim: null, errorPage: htmlResponse(pageExpiredOrInvalid(), 500) }
  }

  return { claim: claimRaw as VenueClaimRecord | null, errorPage: null }
}

async function performReject(claim: VenueClaimRecord, claimId: string): Promise<Response> {
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? ""
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
  const supabase = createClient(supabaseUrl, serviceKey)

  const venueName = (claim.venue_name ?? "").trim() || "Unknown venue"
  const cid = claim.id
  const ts = formatTimestamp()

  if (isRejectedStatus(claim.approval_status)) {
    return htmlResponse(pageRejected({ venueName, claimId: cid, timestamp: ts }), 200)
  }
  if (isApprovedStatus(claim.approval_status)) {
    return htmlResponse(
      pageAlreadyProcessed({ venueName, claimId: cid, statusLabel: "approved" }),
      200,
    )
  }
  if (!isPendingStatus(claim.approval_status)) {
    return htmlResponse(
      pageAlreadyProcessed({
        venueName,
        claimId: cid,
        statusLabel: statusLabel(claim.approval_status),
      }),
      200,
    )
  }

  const { error: upErr } = await supabase
    .from("venue_claims")
    .update({ approval_status: "rejected", rejection_acknowledged_at: null })
    .eq("id", claimId)
    .eq("approval_status", claim.approval_status)

  if (upErr) {
    console.error("venue_claim_admin: reject update error", upErr)
    return htmlResponse(pageExpiredOrInvalid(), 500)
  }

  return htmlResponse(pageRejected({ venueName, claimId: cid, timestamp: ts }), 200)
}

async function performApprove(claim: VenueClaimRecord, claimId: string): Promise<Response> {
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? ""
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
  const supabase = createClient(supabaseUrl, serviceKey)

  const venueName = (claim.venue_name ?? "").trim() || "Unknown venue"
  const cid = claim.id
  const ts = formatTimestamp()

  if (!isPendingStatus(claim.approval_status) && !isApprovedStatus(claim.approval_status)) {
    return htmlResponse(
      pageAlreadyProcessed({
        venueName,
        claimId: cid,
        statusLabel: statusLabel(claim.approval_status),
      }),
      200,
    )
  }

  let outcome: { venueName: string; claimId: string; venueId: string }
  try {
    outcome = await ensureVenueForApprovedClaim(supabase, claim)
  } catch (e) {
    if (e instanceof ClaimApproveError) {
      return htmlResponse(
        pageVenueApprovalFailed({
          claimId: cid,
          code: e.code,
          detail: e.detail,
        }),
        500,
      )
    }
    const msg = e instanceof Error ? e.message : String(e)
    return htmlResponse(
      pageVenueApprovalFailed({
        claimId: cid,
        code: "unexpected_error",
        detail: msg,
      }),
      500,
    )
  }

  const ownerEmail = (claim.owner_email ?? "").trim()
  const businessIdRaw = claim.business_id != null ? String(claim.business_id).trim() : ""
  let businessDisplayName: string | null = null
  if (businessIdRaw.length > 0) {
    const { data: bizRow, error: bizErr } = await supabase
      .from("businesses")
      .select("display_name")
      .eq("id", businessIdRaw)
      .maybeSingle()
    if (!bizErr && bizRow && typeof (bizRow as { display_name?: unknown }).display_name === "string") {
      const dn = (bizRow as { display_name: string }).display_name.trim()
      businessDisplayName = dn.length > 0 ? dn : null
    }
  }

  return htmlResponse(
    pageApproved({
      venueName: outcome.venueName,
      claimId: outcome.claimId,
      venueId: outcome.venueId,
      timestamp: ts,
      ownerEmail,
      businessId: businessIdRaw.length > 0 ? businessIdRaw : null,
      businessDisplayName,
    }),
    200,
  )
}

async function resolveToken(
  token: string,
  routeAction: AdminRouteAction,
): Promise<{ claimId: string } | Response> {
  if (!token) {
    return htmlResponse(pageInvalidToken(), 400)
  }
  try {
    const { claim_id } = await verifyAdminActionToken(token, routeAction)
    return { claimId: claim_id }
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e)
    if (msg === "misconfigured") {
      return htmlResponse(pageExpiredOrInvalid(), 500)
    }
    if (isJwtExpiredError(e)) {
      return htmlResponse(pageExpiredToken(), 401)
    }
    return htmlResponse(pageInvalidToken(), 401)
  }
}

/**
 * GET — read-only confirmation (no mutation).
 * POST — perform approve/reject after explicit admin confirm.
 */
export async function handleVenueClaimAdminRequest(
  req: Request,
  routeAction: AdminRouteAction,
): Promise<Response> {
  if (req.method !== "GET" && req.method !== "POST") {
    return new Response(JSON.stringify({ error: "method_not_allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    })
  }

  let token = ""
  if (req.method === "GET") {
    token = new URL(req.url).searchParams.get("token")?.trim() ?? ""
  } else {
    const contentType = (req.headers.get("Content-Type") ?? "").toLowerCase()
    if (contentType.includes("application/x-www-form-urlencoded") || contentType.includes("multipart/form-data")) {
      const form = await req.formData()
      token = String(form.get("token") ?? "").trim()
      const formAction = String(form.get("action") ?? "").trim().toLowerCase()
      if (formAction && formAction !== routeAction) {
        return htmlResponse(pageInvalidToken(), 400)
      }
    } else {
      try {
        const body = await req.json() as { token?: string; action?: string }
        token = (body.token ?? "").trim()
        const bodyAction = (body.action ?? "").trim().toLowerCase()
        if (bodyAction && bodyAction !== routeAction) {
          return htmlResponse(pageInvalidToken(), 400)
        }
      } catch {
        return htmlResponse(pageInvalidToken(), 400)
      }
    }
  }

  const resolved = await resolveToken(token, routeAction)
  if (resolved instanceof Response) return resolved
  const { claimId } = resolved

  const { claim, errorPage } = await loadClaim(claimId)
  if (errorPage) return errorPage
  if (!claim) {
    return htmlResponse(pageExpiredOrInvalid(), 404)
  }

  const venueName = (claim.venue_name ?? "").trim() || "Unknown venue"

  // GET: never mutate — confirmation only (blocks email prefetch CSRF).
  if (req.method === "GET") {
    if (routeAction === "reject" && isRejectedStatus(claim.approval_status)) {
      return htmlResponse(
        pageRejected({ venueName, claimId: claim.id, timestamp: formatTimestamp() }),
        200,
      )
    }
    if (routeAction === "approve" && isApprovedStatus(claim.approval_status) && claim.venue_id) {
      return htmlResponse(
        pageAlreadyProcessed({
          venueName,
          claimId: claim.id,
          statusLabel: "approved",
        }),
        200,
      )
    }
    if (
      !isPendingStatus(claim.approval_status) &&
      !(routeAction === "approve" && isApprovedStatus(claim.approval_status))
    ) {
      return htmlResponse(
        pageAlreadyProcessed({
          venueName,
          claimId: claim.id,
          statusLabel: statusLabel(claim.approval_status),
        }),
        200,
      )
    }

    return htmlResponse(
      pageConfirmAction({
        action: routeAction,
        venueName,
        claimId: claim.id,
        token,
      }),
      200,
    )
  }

  // POST: mutate
  if (routeAction === "reject") {
    return await performReject(claim, claimId)
  }
  return await performApprove(claim, claimId)
}

/** @deprecated Use handleVenueClaimAdminRequest — GET no longer mutates. */
export async function handleVenueClaimAdminGet(
  req: Request,
  routeAction: AdminRouteAction,
): Promise<Response> {
  return handleVenueClaimAdminRequest(req, routeAction)
}
