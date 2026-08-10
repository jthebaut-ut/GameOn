import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2"
import { ApnsClient, type PushTokenRow } from "../_shared/apns_client.ts"
import {
  authorizeSportsWorkerRequest,
  describeAuthCandidateClasses,
  readAdminApiKey,
  readRequestCredentialPresence,
  sportsWorkerAuthLog,
} from "../_shared/sports_worker_auth.ts"
import {
  buildFanTeamInvitationPushAlert,
  resolveSenderIdentity,
} from "../_shared/chat_push_preview.ts"
import { resolveExistingDeliveryClaim } from "./claim_state.ts"

/**
 * Trusted APNs worker for pending Fan Team invitations.
 *
 * Invoked from queue_fan_team_invitation_push_notification (pg_net + service role).
 * Queue may pre-insert fan_team_invitation_push_deliveries (status=queued +
 * pg_net_request_id). Claim treats queued as claimable; sent/skipped/failed as
 * already_claimed (idempotent; no duplicate APNs).
 *
 * Auth: Bearer SERVICE_ROLE_KEY / SUPABASE_SERVICE_ROLE_KEY, or
 *       x-cron-secret matching FAN_TEAM_INVITATION_PUSH_CRON_SECRET.
 *
 * Alert copy (authoritative profiles + fan_teams.name):
 *   title = "Jennifer (@jennifer)" | "Jennifer" | "@jennifer" | "FanGeo User"
 *   body  = "Invited you to join {TeamName}"
 *
 * Badge: not set in APS payload (unchanged on create/invite/resend).
 *
 * Per-Team mute (fan_team_members.push_notifications_muted) does NOT apply here:
 * invitees are not active members yet, so no member mute preference exists.
 * After accept, Team mute becomes available for subsequent Team Chat / activity pushes.
 *
 * Deploy: `supabase functions deploy notify-fan-team-invitation --no-verify-jwt`
 */

interface Payload {
  invitation_id?: string
  event_id?: string
  /** Optional diagnostics: invite | create | resend */
  kind?: string
}

type InvitationRow = {
  id: string
  team_id: string
  inviter_user_id: string
  invitee_user_id: string
  status: string
}

type TeamRow = {
  id: string
  name: string
  is_active: boolean | null
}

type ProfileRow = {
  id: string
  display_name: string | null
  username: string | null
  is_deleted: boolean | null
}

const SOURCE = "team_invitation"
const LOG_PREFIX = "[FanTeamInvitationPush]"

function json(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  })
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value)
}

async function claimDelivery(
  admin: SupabaseClient,
  eventId: string,
  invitationId: string,
  recipientUserId: string,
  inviterUserId: string,
  teamId: string,
): Promise<"claimed" | "exists"> {
  const { data: existing, error: existingError } = await admin
    .from("fan_team_invitation_push_deliveries")
    .select("delivery_status")
    .eq("event_id", eventId)
    .maybeSingle()

  if (existingError) {
    console.error(`${LOG_PREFIX} claim_lookup_failed`, existingError)
    throw new Error("claim_failed")
  }

  const existingStatus = (existing as { delivery_status?: string } | null)
    ?.delivery_status
  const resolved = resolveExistingDeliveryClaim(existingStatus)
  if (resolved === "claimed" || resolved === "exists") return resolved

  // Omit optional diagnostic columns (kind / pg_net_request_id) so this Edge
  // remains deployable before or after 20260942 schema columns exist.
  const { error } = await admin.from("fan_team_invitation_push_deliveries").insert({
    event_id: eventId,
    invitation_id: invitationId,
    recipient_user_id: recipientUserId,
    inviter_user_id: inviterUserId,
    team_id: teamId,
    delivery_status: "queued",
  })
  if (!error) return "claimed"
  if ((error as { code?: string }).code === "23505") return "exists"
  console.error(`${LOG_PREFIX} claim_failed`, error)
  throw new Error("claim_failed")
}

async function finalizeDelivery(
  admin: SupabaseClient,
  eventId: string,
  status: "sent" | "skipped" | "failed",
  skipReason: string | null,
  sentTokenCount: number,
): Promise<void> {
  await admin
    .from("fan_team_invitation_push_deliveries")
    .update({
      delivery_status: status,
      skip_reason: skipReason,
      sent_token_count: sentTokenCount,
      updated_at: new Date().toISOString(),
    })
    .eq("event_id", eventId)
}

/** Best-effort finalize when invitation lookup fails after queue pre-insert. */
async function finalizeIfQueued(
  admin: SupabaseClient,
  eventId: string,
  reason: string,
): Promise<void> {
  await admin
    .from("fan_team_invitation_push_deliveries")
    .update({
      delivery_status: "skipped",
      skip_reason: reason,
      sent_token_count: 0,
      updated_at: new Date().toISOString(),
    })
    .eq("event_id", eventId)
    .eq("delivery_status", "queued")
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405)
  }

  const supabaseUrl = Deno.env.get("PROJECT_URL")?.trim()
    ?? Deno.env.get("SUPABASE_URL")?.trim()
    ?? ""
  const adminApiKey = readAdminApiKey()
  const cronEnvNames = ["FAN_TEAM_INVITATION_PUSH_CRON_SECRET"]
  const candidateClasses = describeAuthCandidateClasses(cronEnvNames)
  const credentialPresence = readRequestCredentialPresence(req)
  const attempted = credentialPresence.apikey
    ? "apikey"
    : credentialPresence.bearer
    ? "bearer"
    : credentialPresence.cron
    ? "cron"
    : "none"

  console.log(
    `${LOG_PREFIX} auth candidates legacy=${candidateClasses.legacy} ` +
      `secretKeys=${candidateClasses.secretKeys} cron=${candidateClasses.cronConfigured}`,
  )

  if (!supabaseUrl || !adminApiKey) {
    console.error(`${LOG_PREFIX} missing PROJECT_URL/SUPABASE_URL or admin API credential`)
    return json({ error: "server_misconfigured" }, 500)
  }

  const invocation = authorizeSportsWorkerRequest(req, {
    cronSecretEnvNames: cronEnvNames,
  })
  if (!invocation.accepted) {
    sportsWorkerAuthLog("FanTeamInvitationPush", "unauthorized", {
      reason: invocation.reason,
      attempted,
    })
    return json({ error: "unauthorized" }, 401)
  }
  sportsWorkerAuthLog("FanTeamInvitationPush", "authorized", {
    source: invocation.source,
    attempted,
  })

  let payload: Payload
  try {
    payload = await req.json()
  } catch {
    return json({ error: "invalid_json" }, 400)
  }

  const invitationId = payload.invitation_id?.trim() ?? ""
  const eventId = payload.event_id?.trim() ?? ""
  const kind = (payload.kind?.trim() || "invite").toLowerCase()
  if (!invitationId || !eventId || !isUuid(invitationId) || !isUuid(eventId)) {
    return json({ error: "missing_fields" }, 400)
  }

  const admin = createClient(supabaseUrl, adminApiKey)

  // Single lookup. pg_net does not start HTTP until COMMIT (Supabase docs), so
  // invitation_not_found is not explained by an in-TX commit race.
  const { data: invitation, error: invitationError } = await admin
    .from("fan_team_invitations")
    .select("id,team_id,inviter_user_id,invitee_user_id,status")
    .eq("id", invitationId)
    .maybeSingle()

  if (invitationError) {
    console.error(`${LOG_PREFIX} invitation_lookup_failed`, invitationError)
    return json({ error: "invitation_lookup_failed" }, 500)
  }

  const row = invitation as InvitationRow | null
  if (!row) {
    console.warn(
      `${LOG_PREFIX} invitation_not_found invitationId=${invitationId} eventId=${eventId} kind=${kind}`,
    )
    await finalizeIfQueued(admin, eventId, "invitation_not_found")
    return json({ ok: true, skipped: true, reason: "invitation_not_found", kind })
  }

  if (row.status !== "pending") {
    console.log(
      `${LOG_PREFIX} skip status_${row.status} invitationId=${row.id} kind=${kind}`,
    )
    await finalizeIfQueued(admin, eventId, `status_${row.status}`)
    // Also claim+finalize for legacy path with no pre-insert.
    try {
      const earlyClaim = await claimDelivery(
        admin,
        eventId,
        row.id,
        row.invitee_user_id,
        row.inviter_user_id,
        row.team_id,
      )
      if (earlyClaim === "claimed") {
        await finalizeDelivery(admin, eventId, "skipped", `status_${row.status}`, 0)
      }
    } catch {
      // best-effort ledger only
    }
    return json({ ok: true, skipped: true, reason: `status_${row.status}`, kind })
  }

  const inviterId = row.inviter_user_id
  const recipientId = row.invitee_user_id
  if (!inviterId || !recipientId || inviterId === recipientId) {
    await finalizeIfQueued(admin, eventId, "invalid_participants")
    return json({ ok: true, skipped: true, reason: "invalid_participants" })
  }

  const { data: team, error: teamError } = await admin
    .from("fan_teams")
    .select("id,name,is_active")
    .eq("id", row.team_id)
    .maybeSingle()

  if (teamError) {
    console.error(`${LOG_PREFIX} team_lookup_failed`, teamError)
    return json({ error: "team_lookup_failed" }, 500)
  }

  const teamRow = team as TeamRow | null
  if (!teamRow || teamRow.is_active === false) {
    await finalizeIfQueued(admin, eventId, "team_inactive")
    return json({ ok: true, skipped: true, reason: "team_inactive" })
  }

  let claim: "claimed" | "exists"
  try {
    claim = await claimDelivery(
      admin,
      eventId,
      row.id,
      recipientId,
      inviterId,
      row.team_id,
    )
  } catch {
    return json({ error: "claim_failed" }, 500)
  }
  if (claim === "exists") {
    console.log(
      `${LOG_PREFIX} already_claimed invitationId=${row.id} eventId=${eventId} kind=${kind}`,
    )
    return json({ ok: true, skipped: true, reason: "already_claimed", sent: 0, kind })
  }

  const { data: prefs } = await admin
    .from("user_notification_preferences")
    .select("fan_team_invitation_notifications_enabled")
    .eq("user_id", recipientId)
    .maybeSingle()

  // Default enabled when preference row missing or null.
  if (prefs?.fan_team_invitation_notifications_enabled === false) {
    await finalizeDelivery(admin, eventId, "skipped", "prefs_disabled", 0)
    console.log(
      `${LOG_PREFIX} prefs_disabled invitationId=${row.id} recipient=${recipientId} kind=${kind}`,
    )
    return json({ ok: true, skipped: true, reason: "prefs_disabled", sent: 0, kind })
  }

  const { data: senderProfile } = await admin
    .from("user_profiles")
    .select("id,display_name,username,is_deleted")
    .eq("id", inviterId)
    .maybeSingle()

  const inviterIdentity = resolveSenderIdentity(senderProfile as ProfileRow | null)
  const alert = buildFanTeamInvitationPushAlert({
    inviterDisplayName: inviterIdentity.displayName,
    inviterHandle: inviterIdentity.handle,
    teamName: teamRow.name ?? "a Team",
    hasExplicitDisplayName: inviterIdentity.hasExplicitDisplayName,
  })

  const { data: tokens, error: tokenError } = await admin
    .from("user_push_tokens")
    .select("id,user_id,token,environment")
    .eq("user_id", recipientId)
    .eq("is_active", true)

  if (tokenError) {
    console.error(`${LOG_PREFIX} token_lookup_failed`, tokenError)
    await finalizeDelivery(admin, eventId, "failed", "token_lookup_failed", 0)
    return json({ error: "token_lookup_failed" }, 500)
  }

  const activeTokens = (tokens ?? []) as PushTokenRow[]
  if (activeTokens.length === 0) {
    await finalizeDelivery(admin, eventId, "skipped", "no_active_tokens", 0)
    console.log(
      `${LOG_PREFIX} no_active_tokens invitationId=${row.id} recipient=${recipientId} kind=${kind}`,
    )
    return json({ ok: true, skipped: true, reason: "no_active_tokens", sent: 0, kind })
  }

  let apns: ApnsClient
  try {
    apns = await ApnsClient.fromEnvironment()
  } catch (error) {
    console.error(`${LOG_PREFIX} apns_config_failed`, error)
    await finalizeDelivery(admin, eventId, "failed", "apns_config", 0)
    return json({ error: "apns_misconfigured" }, 500)
  }

  const customData: Record<string, string> = {
    source: SOURCE,
    type: "team_invitation",
    invitation_id: row.id,
    team_id: row.team_id,
    invited_by_user_id: inviterId,
    event_id: eventId,
  }

  let sent = 0
  let invalidated = 0
  for (const token of activeTokens) {
    if (token.user_id === inviterId) continue

    const result = await apns.send(token, alert, customData)
    if (result.ok) {
      sent += 1
      // APNs HTTP 200 = accepted for that token/environment — not proof the current
      // physical device displayed the alert (stale active tokens can still 200).
      console.log(
        `${LOG_PREFIX} apns_accepted tokenId=${token.id} environment=${result.tokenEnvironment} ` +
          `status=${result.status} endpoint=${result.endpoint} invitationId=${row.id} eventId=${eventId}`,
      )
      continue
    }
    console.warn(
      `${LOG_PREFIX} apns_failed tokenId=${token.id} environment=${result.tokenEnvironment} ` +
        `status=${result.status} reason=${result.reason ?? "unknown"} invalidate=${result.invalidate === true}`,
    )
    if (result.invalidate) {
      invalidated += 1
      await admin
        .from("user_push_tokens")
        .update({ is_active: false, invalidated_at: new Date().toISOString() })
        .eq("id", token.id)
    }
  }

  if (sent > 0) {
    await finalizeDelivery(admin, eventId, "sent", null, sent)
  } else {
    const reason = invalidated > 0 ? "apns_invalid_token" : "apns_send_failed"
    await finalizeDelivery(admin, eventId, "failed", reason, 0)
    console.warn(
      `${LOG_PREFIX} ${reason} invitationId=${row.id} eventId=${eventId} kind=${kind} invalidated=${invalidated}`,
    )
  }

  console.log(
    `${LOG_PREFIX} done invitationId=${row.id} eventId=${eventId} recipient=${recipientId} ` +
      `kind=${kind} sent=${sent} invalidated=${invalidated} auth=${invocation.source}`,
  )

  return json({
    ok: true,
    sent,
    invalidated,
    invitation_id: row.id,
    event_id: eventId,
    kind,
    result: sent > 0 ? "apns_success" : (invalidated > 0 ? "apns_invalid_token" : "apns_send_failed"),
  })
})
