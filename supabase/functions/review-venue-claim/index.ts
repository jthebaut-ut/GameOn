/**
 * Legacy HMAC admin link for venue claim review.
 *
 * Prefetch-safe:
 * - GET / HEAD: verify HMAC params, show confirmation text — NO mutation
 * - POST: verify same params (form or query), then approve/reject
 *
 * Prefer venue-claim-approve / venue-claim-reject (JWT token flow) for new emails.
 *
 * Deploy: supabase functions deploy review-venue-claim --no-verify-jwt
 */
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

async function hmacSha256Hex(secret: string, message: string): Promise<string> {
  const enc = new TextEncoder()
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  )
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(message))
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, "0")).join("")
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false
  let out = 0
  for (let i = 0; i < a.length; i++) out |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return out === 0
}

function textResponse(text: string, status = 200): Response {
  return new Response(text, {
    status,
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  })
}

function formatActionTimestamp(d: Date): string {
  const datePart = new Intl.DateTimeFormat("en-US", {
    year: "numeric",
    month: "short",
    day: "numeric",
  }).format(d)
  const timePart = new Intl.DateTimeFormat("en-US", {
    hour: "numeric",
    minute: "2-digit",
  }).format(d)
  const normalizedTime = timePart.replace(/\u202F/g, " ")
  return `${datePart} at ${normalizedTime}`
}

function plainPage(message: string, status = 200): Response {
  return textResponse(`${message}\n`, status)
}

type ActionParams = {
  action: "approve" | "reject"
  claimId: string
  exp: number
  sig: string
}

async function parseParams(req: Request): Promise<ActionParams | Response> {
  const url = new URL(req.url)
  let actionRaw = (url.searchParams.get("action") ?? "").trim().toLowerCase()
  let claimId = (url.searchParams.get("claim_id") ?? "").trim()
  let expRaw = (url.searchParams.get("exp") ?? "").trim()
  let sig = (url.searchParams.get("sig") ?? "").trim().toLowerCase()

  if (req.method === "POST") {
    const contentType = (req.headers.get("Content-Type") ?? "").toLowerCase()
    if (contentType.includes("application/x-www-form-urlencoded") || contentType.includes("multipart/form-data")) {
      const form = await req.formData()
      actionRaw = String(form.get("action") ?? actionRaw).trim().toLowerCase()
      claimId = String(form.get("claim_id") ?? claimId).trim()
      expRaw = String(form.get("exp") ?? expRaw).trim()
      sig = String(form.get("sig") ?? sig).trim().toLowerCase()
    }
  }

  const action = actionRaw === "approve" ? "approve" : actionRaw === "reject" ? "reject" : ""
  if (!action || !claimId || !expRaw || !sig) {
    return plainPage("Invalid request. Missing or invalid parameters.", 400)
  }

  const exp = Number(expRaw)
  if (!Number.isFinite(exp) || exp <= 0) {
    return plainPage("Invalid request. Invalid expiration timestamp.", 400)
  }

  const now = Math.floor(Date.now() / 1000)
  if (now > exp) {
    return plainPage("Link expired. This moderation link has expired. Please request a new email.", 401)
  }

  const secret = Deno.env.get("MODERATION_HMAC_SECRET")
  if (!secret) {
    return plainPage("Server misconfigured. Missing moderation secret.", 500)
  }

  const expected = await hmacSha256Hex(secret, `${action}:${claimId}:${exp}`)
  if (!constantTimeEqual(expected, sig)) {
    return plainPage("Unauthorized. This moderation link is invalid.", 401)
  }

  return { action, claimId, exp, sig }
}

serve(async (req) => {
  if (req.method === "HEAD") {
    return textResponse("", 200)
  }
  if (req.method !== "GET" && req.method !== "POST") {
    return plainPage("Method not allowed.", 405)
  }

  const parsed = await parseParams(req)
  if (parsed instanceof Response) return parsed
  const { action, claimId, exp, sig } = parsed

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? Deno.env.get("PROJECT_URL")
  const serviceRole = Deno.env.get("SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!supabaseUrl || !serviceRole) {
    return plainPage("Server misconfigured. Missing Supabase service configuration.", 500)
  }

  const admin = createClient(supabaseUrl, serviceRole)

  const { data: claimRow } = await admin
    .from("venue_claims")
    .select("venue_name, approval_status")
    .eq("id", claimId)
    .maybeSingle()

  const venueName = (claimRow?.venue_name ?? "Venue").trim() || "Venue"
  const currentStatus = String(claimRow?.approval_status ?? "").trim().toLowerCase()

  // GET: confirmation only — no mutation (blocks email prefetch CSRF).
  if (req.method === "GET") {
    return plainPage(
      [
        `Confirm ${action} for "${venueName}".`,
        `Claim ID: ${claimId}`,
        `Current status: ${currentStatus || "unknown"}`,
        "",
        "Opening this link does NOT change the claim.",
        "Submit the confirmation form (POST) to apply the change.",
        "",
        // Minimal HTML-ish form as plain instructions; browsers that follow POST from email HTML
        // should use venue-claim-approve/reject. This legacy endpoint accepts POST with same params.
        `POST this same URL with form fields action, claim_id, exp, sig to ${action}.`,
        `exp=${exp}`,
        `sig=${sig}`,
      ].join("\n"),
      200,
    )
  }

  const approval_status = action === "approve" ? "approved" : "rejected"
  const updatePayload: Record<string, unknown> =
    approval_status === "rejected"
      ? { approval_status, rejection_acknowledged_at: null }
      : { approval_status }

  const { error } = await admin.from("venue_claims").update(updatePayload).eq("id", claimId)

  if (error) {
    return plainPage(`Update failed. Could not update venue claim. ${error.message}`, 502)
  }

  const when = formatActionTimestamp(new Date())
  const verb = approval_status === "approved" ? "approved" : "rejected"

  return plainPage(
    `${venueName} ${verb} on ${when}.\nYou can close this tab.\n\nClaim ID: ${claimId}\n\nThis link was secured with an expiring action token.`,
    200,
  )
})
