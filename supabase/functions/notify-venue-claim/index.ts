import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "npm:@supabase/supabase-js@2"
import { SignJWT } from "npm:jose@5"

/**
 * Sends admin email when a venue_claim row is created (Discover claim, owner onboarding, or new location request).
 *
 * Security:
 * - Authenticate caller via anon key + Authorization → supabase.auth.getUser()
 * - Load claim from DB with SUPABASE_SERVICE_ROLE_KEY (ignore client venue/email fields)
 * - Caller must own the claim (JWT email ↔ owner_email, or businesses.owner_user_id ↔ JWT uid)
 *
 * Secrets: ADMIN_EMAIL_TO, RESEND_API_KEY, RESEND_FROM, SUPABASE_SERVICE_ROLE_KEY
 * Approve/Reject links open a confirmation page (GET preview → POST confirm):
 *   set `ADMIN_VENUE_CLAIM_LINK_SECRET` (same HS256 secret as venue-claim-approve / venue-claim-reject).
 * Legacy: `ADMIN_VENUE_CLAIM_APPROVE_URL_TEMPLATE` / `..._REJECT_...` with `{claim_id}`.
 *
 * Deploy: `supabase functions deploy notify-venue-claim`
 */

/** Client should send `{ claim_id }`. Extra fields are ignored; email content is loaded from DB. */
interface Payload {
  claim_id: string
  /** Accepted for backward compatibility; cancellation is detected from DB `approval_status` only. */
  claim_kind?: string | null
}

interface VenueClaimRow {
  id: string
  owner_email: string | null
  business_id: string | null
  venue_id: string | null
  venue_name: string | null
  venue_address: string | null
  venue_city: string | null
  venue_state: string | null
  venue_country: string | null
  venue_zip_code: string | null
  venue_phone: string | null
  venue_website: string | null
  venue_description: string | null
  venue_features: string | null
  screen_count: number | string | null
  serves_food: boolean | null
  has_wifi: boolean | null
  has_garden: boolean | null
  has_projector: boolean | null
  pet_friendly: boolean | null
  cover_photo_url: string | null
  menu_photo_url: string | null
  proof_note: string | null
  approval_status: string | null
  created_at: string | null
  updated_at: string | null
  venue_identity_key: string | null
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;")
}

function str(v: string | null | undefined): string {
  return (v ?? "").trim()
}

function bool(v: boolean | null | undefined): boolean {
  return v === true
}

/** When service role is configured, warn admins if other rows share the same venue_identity_key. */
async function duplicateAdminWarningHtml(
  supabaseUrl: string,
  serviceRoleKey: string,
  claimId: string,
): Promise<string> {
  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } })
  const { data: crow, error: rowErr } = await admin
    .from("venue_claims")
    .select("venue_identity_key")
    .eq("id", claimId)
    .maybeSingle()
  if (rowErr || !crow?.venue_identity_key) return ""
  const key = String(crow.venue_identity_key).trim()
  if (!key) return ""

  const { count: otherClaims, error: cErr } = await admin
    .from("venue_claims")
    .select("id", { count: "exact", head: true })
    .eq("venue_identity_key", key)
    .neq("id", claimId)
  if (cErr) return ""

  const { count: nonActiveVenues, error: vErr } = await admin
    .from("venues")
    .select("id", { count: "exact", head: true })
    .eq("venue_identity_key", key)
    .neq("admin_status", "active")
  if (vErr) return ""

  const oc = otherClaims ?? 0
  const nv = nonActiveVenues ?? 0
  if (oc === 0 && nv === 0) return ""

  return (
    `<p style="margin:14px 0;padding:12px 14px;background:#fffbeb;border:1px solid #fcd34d;border-radius:10px;font-size:14px;color:#92400e">` +
    `<strong>Possible duplicate:</strong> this submission matches the same normalized location signature as ` +
    `<strong>${escapeHtml(String(oc))}</strong> other claim(s) and <strong>${escapeHtml(String(nv))}</strong> non-active venue row(s). ` +
    `Review before approving.</p>`
  )
}

function expandClaimUrlTemplate(tpl: string, claimId: string): string {
  return tpl.replace(/\{claim_id\}/g, claimId)
}

/** Legacy env pointed at `review-venue-claim`; handlers are `venue-claim-approve` / `venue-claim-reject`. */
function fixLegacyReviewVenueClaimUrl(template: string, route: "approve" | "reject"): string {
  const fn = route === "approve" ? "venue-claim-approve" : "venue-claim-reject"
  return template
    .replace(/\/functions\/v1\/review-venue-claim\b/g, `/functions/v1/${fn}`)
    .replace(/\breview-venue-claim\b/g, fn)
}

async function signedVenueClaimAdminActionUrl(
  supabaseUrl: string,
  linkSecret: string,
  claimId: string,
  route: "approve" | "reject",
): Promise<string> {
  const key = new TextEncoder().encode(linkSecret)
  const action = route
  const token = await new SignJWT({ claim_id: claimId, action })
    .setProtectedHeader({ alg: "HS256" })
    .setIssuedAt()
    .setExpirationTime("7d")
    .sign(key)
  const base = supabaseUrl.replace(/\/$/, "")
  const path = route === "approve" ? "venue-claim-approve" : "venue-claim-reject"
  return `${base}/functions/v1/${path}?token=${encodeURIComponent(token)}`
}

function deriveClaimKind(claim: VenueClaimRow): string {
  const status = str(claim.approval_status).toLowerCase()
  if (status === "cancelled" || status === "withdrawn") return "cancelled_before_review"
  if (str(claim.venue_id)) return "discover_claim"
  if (str(claim.business_id)) return "new_location"
  return "owner_venue_claim"
}

/** Cancellation is detected from DB approval_status only (never from client-supplied claim_kind alone). */
function isCancellationClaim(claim: VenueClaimRow): boolean {
  const status = str(claim.approval_status).toLowerCase()
  return status === "cancelled" || status === "withdrawn"
}

async function callerOwnsClaim(
  admin: ReturnType<typeof createClient>,
  claim: VenueClaimRow,
  userId: string,
  jwtEmail: string,
): Promise<boolean> {
  const claimEmail = str(claim.owner_email).toLowerCase()
  if (jwtEmail && claimEmail && jwtEmail === claimEmail) return true

  const businessId = str(claim.business_id)
  if (!businessId) return false

  const { data: biz, error } = await admin
    .from("businesses")
    .select("owner_user_id")
    .eq("id", businessId)
    .maybeSingle()

  if (error) {
    console.error("notify-venue-claim: businesses ownership lookup failed", error.message)
    return false
  }

  const ownerUserId = str((biz as { owner_user_id?: string | null } | null)?.owner_user_id)
  return Boolean(ownerUserId && ownerUserId === userId)
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "method_not_allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    })
  }

  const authHeader = req.headers.get("Authorization")
  if (!authHeader?.startsWith("Bearer ")) {
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    })
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? ""
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? ""
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim() ?? ""
  if (!supabaseUrl || !supabaseAnonKey) {
    console.error("notify-venue-claim: missing SUPABASE_URL or SUPABASE_ANON_KEY")
    return new Response(JSON.stringify({ error: "server_misconfigured" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    })
  }
  if (!serviceRoleKey) {
    console.error("notify-venue-claim: missing SUPABASE_SERVICE_ROLE_KEY")
    return new Response(JSON.stringify({ error: "server_misconfigured" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    })
  }

  const supabase = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authHeader } },
  })

  const { data: { user }, error: authErr } = await supabase.auth.getUser()
  if (authErr || !user) {
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    })
  }

  let payload: Payload
  try {
    payload = await req.json()
  } catch {
    return new Response(JSON.stringify({ error: "invalid_json" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    })
  }

  const claimId = str(payload.claim_id)
  if (!claimId) {
    return new Response(JSON.stringify({ error: "missing_fields" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    })
  }

  const jwtEmail = str(user.email).toLowerCase()

  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } })
  const { data: claimRaw, error: claimErr } = await admin
    .from("venue_claims")
    .select(
      "id,owner_email,business_id,venue_id,venue_name,venue_address,venue_city,venue_state,venue_country,venue_zip_code,venue_phone,venue_website,venue_description,venue_features,screen_count,serves_food,has_wifi,has_garden,has_projector,pet_friendly,cover_photo_url,menu_photo_url,proof_note,approval_status,created_at,updated_at,venue_identity_key",
    )
    .eq("id", claimId)
    .maybeSingle()

  if (claimErr) {
    console.error("notify-venue-claim: venue_claims load failed", claimErr.message)
    return new Response(JSON.stringify({ error: "claim_load_failed" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    })
  }

  if (!claimRaw) {
    return new Response(JSON.stringify({ error: "claim_not_found" }), {
      status: 404,
      headers: { "Content-Type": "application/json" },
    })
  }

  const claim = claimRaw as VenueClaimRow

  const owns = await callerOwnsClaim(admin, claim, user.id, jwtEmail)
  if (!owns) {
    console.warn("notify-venue-claim: caller does not own claim")
    return new Response(JSON.stringify({ error: "forbidden" }), {
      status: 403,
      headers: { "Content-Type": "application/json" },
    })
  }

  const isCancellation = isCancellationClaim(claim)
  const kind = isCancellation ? "cancelled_before_review" : deriveClaimKind(claim)

  const adminTo = Deno.env.get("ADMIN_EMAIL_TO")?.trim()
  const resendKey = Deno.env.get("RESEND_API_KEY")?.trim()
  const resendFrom = Deno.env.get("RESEND_FROM")?.trim()
  if ((!adminTo && !isCancellation) || !resendKey || !resendFrom) {
    console.error("notify-venue-claim: missing ADMIN_EMAIL_TO, RESEND_API_KEY, or RESEND_FROM")
    return new Response(JSON.stringify({ error: "server_misconfigured" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    })
  }

  let businessName = ""
  const businessId = str(claim.business_id)
  if (businessId) {
    const { data: biz } = await admin
      .from("businesses")
      .select("display_name")
      .eq("id", businessId)
      .maybeSingle()
    businessName = str((biz as { display_name?: string | null } | null)?.display_name)
  }

  let headline = "Venue claim submitted"
  let intro =
    "A business owner submitted a venue claim. Review and approve or reject in your admin workflow."

  if (isCancellation) {
    headline = "Venue request cancelled before review"
    intro =
      "The business owner cancelled this venue request before approval/rejection."
  } else if (kind === "new_location") {
    headline = "New location request"
    intro =
      "A business owner submitted a new location request under their business account. It is pending admin review."
  } else if (kind === "discover_claim") {
    headline = "Discover — Claim this business"
    intro =
      "A user started a venue claim from Discover. It is pending admin review."
  }

  const approveTplRaw = Deno.env.get("ADMIN_VENUE_CLAIM_APPROVE_URL_TEMPLATE")?.trim()
  const rejectTplRaw = Deno.env.get("ADMIN_VENUE_CLAIM_REJECT_URL_TEMPLATE")?.trim()
  const linkSecret = Deno.env.get("ADMIN_VENUE_CLAIM_LINK_SECRET")?.trim()
  const cid = str(claim.id) || claimId

  let duplicateAdminBanner = ""
  if (isCancellation) {
    duplicateAdminBanner = ""
  } else {
    duplicateAdminBanner = await duplicateAdminWarningHtml(supabaseUrl, serviceRoleKey, cid)
  }

  let actionRow = ""

  if (isCancellation) {
    actionRow = ""
  } else if (linkSecret) {
    const approveUrl = escapeHtml(await signedVenueClaimAdminActionUrl(supabaseUrl, linkSecret, cid, "approve"))
    const rejectUrl = escapeHtml(await signedVenueClaimAdminActionUrl(supabaseUrl, linkSecret, cid, "reject"))
    console.log(
      "notify-venue-claim: using signed venue-claim-approve / venue-claim-reject URLs (ADMIN_VENUE_CLAIM_LINK_SECRET set)",
    )
    actionRow =
      `<p style="margin:18px 0 8px;font-size:14px"><a href="${approveUrl}" style="display:inline-block;padding:10px 16px;background:#0f172a;color:#fff;text-decoration:none;border-radius:10px;font-weight:650;margin-right:10px">Review &amp; approve</a>` +
      `<a href="${rejectUrl}" style="display:inline-block;padding:10px 16px;background:#64748b;color:#fff;text-decoration:none;border-radius:10px;font-weight:650">Review &amp; reject</a></p>` +
      `<p style="margin:0 0 8px;font-size:12px;color:#64748b">Links open a confirmation page. Approve/reject requires an explicit confirm step.</p>`
  } else if (approveTplRaw && rejectTplRaw) {
    const approveTpl = fixLegacyReviewVenueClaimUrl(approveTplRaw, "approve")
    const rejectTpl = fixLegacyReviewVenueClaimUrl(rejectTplRaw, "reject")
    const approveUrl = escapeHtml(expandClaimUrlTemplate(approveTpl, cid))
    const rejectUrl = escapeHtml(expandClaimUrlTemplate(rejectTpl, cid))
    console.warn(
      "notify-venue-claim: ADMIN_VENUE_CLAIM_LINK_SECRET unset — using URL templates (ensure ?token= JWT matches venue-claim-approve / venue-claim-reject handlers)",
    )
    actionRow =
      `<p style="margin:18px 0 8px;font-size:14px"><a href="${approveUrl}" style="display:inline-block;padding:10px 16px;background:#0f172a;color:#fff;text-decoration:none;border-radius:10px;font-weight:650;margin-right:10px">Review &amp; approve</a>` +
      `<a href="${rejectUrl}" style="display:inline-block;padding:10px 16px;background:#64748b;color:#fff;text-decoration:none;border-radius:10px;font-weight:650">Review &amp; reject</a></p>` +
      `<p style="margin:0 0 8px;font-size:12px;color:#64748b">Links open a confirmation page. Approve/reject requires an explicit confirm step.</p>`
  } else {
    actionRow =
      `<p style="margin:14px 0;font-size:13px;color:#64748b">Configure <code>ADMIN_VENUE_CLAIM_LINK_SECRET</code> for Review &amp; approve / Review &amp; reject links (signed links to <code>venue-claim-approve</code> / <code>venue-claim-reject</code>), or set both <code>ADMIN_VENUE_CLAIM_APPROVE_URL_TEMPLATE</code> and <code>ADMIN_VENUE_CLAIM_REJECT_URL_TEMPLATE</code>.</p>`
  }

  const ownerEmail = str(claim.owner_email)
  const venueName = str(claim.venue_name) || "Submitted venue"
  const venueAddress = str(claim.venue_address)
  const venueCity = str(claim.venue_city)
  const venueState = str(claim.venue_state)
  const venueZip = str(claim.venue_zip_code)
  const venueCountry = str(claim.venue_country)
  const venuePhone = str(claim.venue_phone)
  const venueWebsite = str(claim.venue_website)
  const venueDescription = str(claim.venue_description)
  const venueFeatures = str(claim.venue_features)
  const proofNote = str(claim.proof_note)
  const coverPhoto = str(claim.cover_photo_url)
  const menuPhoto = str(claim.menu_photo_url)
  const approvalStatus = str(claim.approval_status) || "pending"
  const createdAt = str(claim.created_at)
  const screenCount = claim.screen_count == null ? "0" : String(claim.screen_count)

  const bizLine = businessId
    ? `<tr><td style="padding:6px 0;vertical-align:top;width:180px"><strong>business_id</strong></td><td style="padding:6px 0">${escapeHtml(businessId)}</td></tr>`
    : ""

  const businessNameLine = businessName
    ? `<tr><td style="padding:6px 0;vertical-align:top;width:180px"><strong>Business name</strong></td><td style="padding:6px 0">${escapeHtml(businessName)}</td></tr>`
    : ""

  const venueId = str(claim.venue_id)
  const venueLine = venueId
    ? `<tr><td style="padding:6px 0;vertical-align:top"><strong>venue_id</strong></td><td style="padding:6px 0">${escapeHtml(venueId)}</td></tr>`
    : `<tr><td style="padding:6px 0;vertical-align:top"><strong>venue_id</strong></td><td style="padding:6px 0"><em>(none — new location / not linked yet)</em></td></tr>`

  const venueCountryTail = venueCountry.length > 0 ? ` · ${escapeHtml(venueCountry)}` : ""

  const cancelledAt = str(claim.updated_at) || new Date().toISOString()
  const cancellationRows = isCancellation
    ? `
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Status</strong></td><td style="padding:6px 0">${escapeHtml(approvalStatus)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Cancelled timestamp</strong></td><td style="padding:6px 0">${escapeHtml(cancelledAt)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Note</strong></td><td style="padding:6px 0">${escapeHtml("The business owner cancelled this venue request before approval/rejection.")}</td></tr>`
    : ""

  const html = `<!DOCTYPE html>
<html>
<body style="font-family:system-ui,-apple-system,sans-serif;line-height:1.55;color:#1a1a1a;max-width:720px">
  <h1 style="font-size:20px;font-weight:650;margin:0 0 12px;color:#0f172a">${escapeHtml(headline)}</h1>
  <p style="margin:0 0 16px;font-size:15px">${intro}</p>
  ${duplicateAdminBanner}
  <p style="margin:0 0 10px;font-size:14px"><strong>Business owner email:</strong> ${escapeHtml(ownerEmail || "(not on file)")}</p>
  <p style="margin:0 0 18px;font-size:14px;color:#475569"><strong>Status:</strong> ${isCancellation ? escapeHtml(approvalStatus) : `pending admin review (${escapeHtml(approvalStatus)})`}</p>
  ${actionRow}
  <hr style="border:none;border-top:1px solid #e2e8f0;margin:18px 0"/>
  <table style="font-size:14px;border-collapse:collapse;width:100%">
    <tr><td style="padding:6px 0;vertical-align:top;width:180px"><strong>claim_id</strong></td><td style="padding:6px 0">${escapeHtml(cid)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>claim_kind</strong></td><td style="padding:6px 0">${escapeHtml(kind)}</td></tr>
    ${businessNameLine}
    ${bizLine}
    ${venueLine}
    ${cancellationRows}
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Venue</strong></td><td style="padding:6px 0">${escapeHtml(venueName)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Address</strong></td><td style="padding:6px 0">${escapeHtml(venueAddress)}, ${escapeHtml(venueCity)}, ${escapeHtml(venueState)} ${escapeHtml(venueZip)}${venueCountryTail}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Phone</strong></td><td style="padding:6px 0">${escapeHtml(venuePhone || "—")}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Website</strong></td><td style="padding:6px 0">${escapeHtml(venueWebsite || "—")}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Screen count</strong></td><td style="padding:6px 0">${escapeHtml(screenCount)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Features (text)</strong></td><td style="padding:6px 0">${escapeHtml(venueFeatures || "—")}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Amenities</strong></td><td style="padding:6px 0">food=${bool(claim.serves_food)} wifi=${bool(claim.has_wifi)} patio=${bool(claim.has_garden)} projector=${bool(claim.has_projector)} pet=${bool(claim.pet_friendly)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Cover photo</strong></td><td style="padding:6px 0">${coverPhoto ? `<a href="${escapeHtml(coverPhoto)}">${escapeHtml(coverPhoto)}</a>` : "—"}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Menu photo</strong></td><td style="padding:6px 0">${menuPhoto ? `<a href="${escapeHtml(menuPhoto)}">${escapeHtml(menuPhoto)}</a>` : "—"}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Created</strong></td><td style="padding:6px 0">${escapeHtml(createdAt || "")}</td></tr>
  </table>
  <p style="margin:14px 0 8px;font-size:14px"><strong>Description</strong></p>
  <p style="margin:0;font-size:14px;white-space:pre-wrap;background:#f8fafc;padding:12px 14px;border-radius:10px;border:1px solid #e2e8f0">${escapeHtml(venueDescription || "—")}</p>
  <p style="margin:14px 0 8px;font-size:14px"><strong>Proof note</strong></p>
  <p style="margin:0;font-size:14px;white-space:pre-wrap;background:#f8fafc;padding:12px 14px;border-radius:10px;border:1px solid #e2e8f0">${escapeHtml(proofNote || "—")}</p>
  <p style="margin-top:22px;font-size:12px;color:#64748b">Generated by FanGeo notify-venue-claim · submitter user id ${escapeHtml(user.id)}</p>
</body>
</html>`

  const subjectPrefix =
    isCancellation
      ? "Venue request cancelled before review"
      : kind === "new_location"
      ? "FanGeo — New location request"
      : kind === "discover_claim"
        ? "FanGeo — Discover venue claim"
        : "FanGeo — Venue claim"
  const emailSubject = isCancellation
    ? "Venue request cancelled before review"
    : `${subjectPrefix} — ${venueName.slice(0, 60)}`
  const emailTo = isCancellation ? "support@fangeosports.com" : (adminTo ?? "")

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${resendKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: resendFrom,
      to: [emailTo],
      subject: emailSubject,
      html,
    }),
  })

  if (!res.ok) {
    const errText = await res.text()
    console.error("notify-venue-claim: Resend error", res.status, errText)
    return new Response(JSON.stringify({ ok: false, error: "email_send_failed", detail: errText.slice(0, 500) }), {
      status: 502,
      headers: { "Content-Type": "application/json" },
    })
  }

  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  })
})
