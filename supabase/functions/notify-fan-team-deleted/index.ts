import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2"
import { ApnsClient, type PushTokenRow } from "../_shared/apns_client.ts"
import { applyPushArtwork, pickTeamLogo } from "../_shared/push_artwork.ts"
import {
  authorizeSportsWorkerRequest,
  describeAuthCandidateClasses,
  readAdminApiKey,
  readRequestCredentialPresence,
  sportsWorkerAuthLog,
} from "../_shared/sports_worker_auth.ts"
import { resolveExistingDeliveryClaim } from "../notify-fan-team-invitation/claim_state.ts"
import { buildDeletedTeamAlert } from "./deleted_team_push_alert.ts"

/**
 * Trusted APNs worker for owner-driven Fan Team deletion fan-out.
 *
 * Invoked from delete_fan_team via queue_fan_team_deleted_push_notification.
 *
 * Auth: Bearer SERVICE_ROLE_KEY, or x-cron-secret matching
 *       FAN_TEAM_DELETED_PUSH_CRON_SECRET.
 *
 * Alert (see deleted_team_push_alert.ts):
 *   title = "Team deleted"
 *   body  = "Team {Name} was deleted by the Team owner."
 *
 * Recipients: fan_team_deletion_events.recipient_user_ids (captured server-side
 * before soft-leave; excludes deleting owner). Pending invitees are not notified.
 *
 * CRITICAL LIFECYCLE: Ignores fan_team_members.push_notifications_muted.
 * Members who muted the Team still receive this loss-of-access notification.
 * No global notification-preference gate.
 *
 * Delivery ledger: fan_team_deleted_push_deliveries (per recipient).
 * After 20260945, queue may pre-insert status='queued' — treat as claimable.
 *
 * Shared APNs client: ../_shared/apns_client.ts
 * Redeploy this function after shared APNs/token changes (e.g. 20260944 era).
 *
 * Deploy: `supabase functions deploy notify-fan-team-deleted --no-verify-jwt`
 */

interface Payload {
  event_id?: string
}

type DeletionEventRow = {
  id: string
  team_id: string
  owner_user_id: string
  team_name: string
  recipient_user_ids: string[] | null
}

const SOURCE = "team_deleted"
const LOG_PREFIX = "[FanTeamDeletedPush]"

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
  recipientUserId: string,
  teamId: string,
): Promise<"claimed" | "exists"> {
  const { data: existing, error: existingError } = await admin
    .from("fan_team_deleted_push_deliveries")
    .select("delivery_status")
    .eq("event_id", eventId)
    .eq("recipient_user_id", recipientUserId)
    .maybeSingle()

  if (existingError) {
    console.error(`${LOG_PREFIX} claim_lookup_failed`, existingError)
    throw new Error("claim_failed")
  }

  const existingStatus = (existing as { delivery_status?: string } | null)
    ?.delivery_status
  const resolved = resolveExistingDeliveryClaim(existingStatus)
  if (resolved === "claimed" || resolved === "exists") return resolved

  const { error } = await admin.from("fan_team_deleted_push_deliveries").insert({
    event_id: eventId,
    recipient_user_id: recipientUserId,
    team_id: teamId,
    delivery_status: "queued",
  })
  if (!error) return "claimed"
  if ((error as { code?: string }).code === "23505") {
    // Race with queue pre-insert: re-read and resolve.
    const { data: raced } = await admin
      .from("fan_team_deleted_push_deliveries")
      .select("delivery_status")
      .eq("event_id", eventId)
      .eq("recipient_user_id", recipientUserId)
      .maybeSingle()
    const racedStatus = (raced as { delivery_status?: string } | null)?.delivery_status
    const racedResolved = resolveExistingDeliveryClaim(racedStatus)
    if (racedResolved === "claimed") return "claimed"
    return "exists"
  }
  console.error(`${LOG_PREFIX} claim_failed`, error)
  throw new Error("claim_failed")
}

async function finalizeDelivery(
  admin: SupabaseClient,
  eventId: string,
  recipientUserId: string,
  status: "sent" | "skipped" | "failed",
  skipReason: string | null,
  sentTokenCount: number,
): Promise<void> {
  await admin
    .from("fan_team_deleted_push_deliveries")
    .update({
      delivery_status: status,
      skip_reason: skipReason,
      sent_token_count: sentTokenCount,
      updated_at: new Date().toISOString(),
    })
    .eq("event_id", eventId)
    .eq("recipient_user_id", recipientUserId)
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405)
  }

  const supabaseUrl = Deno.env.get("PROJECT_URL")?.trim()
    ?? Deno.env.get("SUPABASE_URL")?.trim()
    ?? ""
  const adminApiKey = readAdminApiKey()
  const cronEnvNames = ["FAN_TEAM_DELETED_PUSH_CRON_SECRET"]
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
    sportsWorkerAuthLog("FanTeamDeletedPush", "unauthorized", {
      reason: invocation.reason,
      attempted,
    })
    return json({ error: "unauthorized" }, 401)
  }
  sportsWorkerAuthLog("FanTeamDeletedPush", "authorized", {
    source: invocation.source,
    attempted,
  })

  let payload: Payload
  try {
    payload = await req.json()
  } catch {
    return json({ error: "invalid_json" }, 400)
  }

  const eventId = payload.event_id?.trim() ?? ""
  if (!eventId || !isUuid(eventId)) {
    return json({ error: "missing_fields" }, 400)
  }

  const admin = createClient(supabaseUrl, adminApiKey)

  const { data: event, error: eventError } = await admin
    .from("fan_team_deletion_events")
    .select("id,team_id,owner_user_id,team_name,recipient_user_ids")
    .eq("id", eventId)
    .maybeSingle()

  if (eventError) {
    console.error(`${LOG_PREFIX} event_lookup_failed`, eventError)
    return json({ error: "event_lookup_failed" }, 500)
  }

  const row = event as DeletionEventRow | null
  if (!row) {
    return json({ ok: true, skipped: true, reason: "event_not_found" })
  }

  const ownerId = row.owner_user_id
  const recipients = (row.recipient_user_ids ?? [])
    .map((id) => id.trim().toLowerCase())
    .filter((id) => isUuid(id) && id !== ownerId.toLowerCase())

  if (recipients.length === 0) {
    console.warn(`${LOG_PREFIX} no_recipients eventId=${eventId} teamId=${row.team_id}`)
    return json({ ok: true, skipped: true, reason: "no_recipients", sent: 0 })
  }

  const alert = buildDeletedTeamAlert(row.team_name ?? "")

  const { data: teamArt } = await admin
    .from("fan_teams")
    .select("logo_url,logo_thumbnail_url")
    .eq("id", row.team_id)
    .maybeSingle()
  const teamLogoURL = pickTeamLogo(
    (teamArt as { logo_thumbnail_url?: string | null } | null)?.logo_thumbnail_url,
    (teamArt as { logo_url?: string | null } | null)?.logo_url,
  )

  let apns: ApnsClient
  try {
    apns = await ApnsClient.fromEnvironment()
  } catch (error) {
    console.error(`${LOG_PREFIX} apns_config_failed`, error)
    for (const recipientId of recipients) {
      await finalizeDelivery(admin, eventId, recipientId, "failed", "apns_config", 0)
    }
    return json({ error: "apns_misconfigured" }, 500)
  }

  let totalSent = 0
  let totalSkipped = 0
  let totalFailed = 0

  for (const recipientId of recipients) {
    let claim: "claimed" | "exists"
    try {
      claim = await claimDelivery(admin, eventId, recipientId, row.team_id)
    } catch {
      totalFailed += 1
      continue
    }
    if (claim === "exists") {
      console.log(
        `${LOG_PREFIX} already_processed eventId=${eventId} recipient=${recipientId}`,
      )
      totalSkipped += 1
      continue
    }

    // ALL active tokens for this user (iPhone + iPad + …). Do not collapse to one.
    const { data: tokens, error: tokenError } = await admin
      .from("user_push_tokens")
      .select("id,user_id,token,environment")
      .eq("user_id", recipientId)
      .eq("is_active", true)

    if (tokenError) {
      console.error(`${LOG_PREFIX} token_lookup_failed`, tokenError)
      await finalizeDelivery(admin, eventId, recipientId, "failed", "token_lookup_failed", 0)
      totalFailed += 1
      continue
    }

    const activeTokens = (tokens ?? []) as PushTokenRow[]
    if (activeTokens.length === 0) {
      await finalizeDelivery(admin, eventId, recipientId, "skipped", "no_active_tokens", 0)
      console.warn(
        `${LOG_PREFIX} no_active_tokens eventId=${eventId} recipient=${recipientId}`,
      )
      totalSkipped += 1
      continue
    }

    console.log(
      `${LOG_PREFIX} token_fanout eventId=${eventId} recipient=${recipientId} ` +
        `activeTokenCount=${activeTokens.length}`,
    )

    const customData: Record<string, string> = {
      source: SOURCE,
      type: SOURCE,
      team_id: row.team_id,
      event_id: eventId,
      team_name: row.team_name ?? "Team",
    }
    applyPushArtwork(customData, teamLogoURL, "team", row.team_id)

    let sent = 0
    let invalidated = 0
    for (const token of activeTokens) {
      if (token.user_id === ownerId) continue
      const result = await apns.send(token, alert, customData)
      if (result.ok) {
        sent += 1
        // APNs HTTP 200 = accepted for that token/environment — not proof the current
        // physical device displayed the alert (stale active tokens can still 200).
        console.log(
          `${LOG_PREFIX} apns_accepted tokenId=${token.id} environment=${result.tokenEnvironment} ` +
            `status=${result.status} endpoint=${result.endpoint} recipient=${recipientId} eventId=${eventId}`,
        )
        continue
      }
      console.warn(
        `${LOG_PREFIX} apns_failed tokenId=${token.id} environment=${result.tokenEnvironment} ` +
          `status=${result.status} reason=${result.reason ?? "unknown"} ` +
          `invalidate=${result.invalidate === true} recipient=${recipientId}`,
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
      await finalizeDelivery(admin, eventId, recipientId, "sent", null, sent)
      totalSent += sent
    } else {
      const reason = invalidated > 0 ? "apns_invalid_token" : "apns_send_failed"
      await finalizeDelivery(admin, eventId, recipientId, "failed", reason, 0)
      console.warn(
        `${LOG_PREFIX} ${reason} eventId=${eventId} recipient=${recipientId} invalidated=${invalidated}`,
      )
      totalFailed += 1
    }
  }

  console.log(
    `${LOG_PREFIX} done eventId=${eventId} teamId=${row.team_id} recipients=${recipients.length} ` +
      `sentTokens=${totalSent} skipped=${totalSkipped} failed=${totalFailed} auth=${invocation.source}`,
  )

  return json({
    ok: true,
    event_id: eventId,
    team_id: row.team_id,
    recipients: recipients.length,
    sent: totalSent,
    skipped: totalSkipped,
    failed: totalFailed,
  })
})
