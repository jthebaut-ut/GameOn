import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2"
import { ApnsClient, type PushTokenRow } from "../_shared/apns_client.ts"
import { applyPushArtwork, pickTeamLogo } from "../_shared/push_artwork.ts"
import { loadMutedFanTeamMemberIds } from "../_shared/fan_team_push_mute.ts"
import {
  authorizeSportsWorkerRequest,
  describeAuthCandidateClasses,
  readAdminApiKey,
  readRequestCredentialPresence,
  sportsWorkerAuthLog,
} from "../_shared/sports_worker_auth.ts"
import { resolveExistingDeliveryClaim } from "../notify-fan-team-invitation/claim_state.ts"
import { buildMemberLeftTeamAlert } from "./member_left_team_push_alert.ts"

/**
 * Trusted APNs worker for Fan Team voluntary member leave (member_left_team).
 *
 * Invoked from leave_fan_team via queue_fan_team_member_left_push_notification.
 *
 * Auth: Bearer SERVICE_ROLE_KEY, or x-cron-secret matching
 *       FAN_TEAM_MEMBER_LEFT_PUSH_CRON_SECRET.
 *
 * Recipients: fan_team_member_left_events.recipient_user_ids
 *   (active Owner + Manager snapshot BEFORE soft-leave; excludes leaving member).
 *
 * Mute: respects fan_team_members.push_notifications_muted per recipient
 *   (management/activity Team mute). Never uses the departed member's mute.
 *
 * Deploy: `supabase functions deploy notify-fan-team-member-left --no-verify-jwt`
 */

interface Payload {
  event_id?: string
}

type MemberLeftEventRow = {
  id: string
  team_id: string
  left_user_id: string
  actor_user_id: string
  reason: string
  team_name: string
  left_display_name: string
  recipient_user_ids: string[] | null
}

const SOURCE = "member_left_team"
const LOG_PREFIX = "[FanTeamMemberLeaveDebug]"

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
    .from("fan_team_member_left_push_deliveries")
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

  const { error } = await admin.from("fan_team_member_left_push_deliveries").insert({
    event_id: eventId,
    recipient_user_id: recipientUserId,
    team_id: teamId,
    delivery_status: "queued",
  })
  if (!error) return "claimed"
  if ((error as { code?: string }).code === "23505") {
    const { data: raced } = await admin
      .from("fan_team_member_left_push_deliveries")
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
    .from("fan_team_member_left_push_deliveries")
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
  const cronEnvNames = ["FAN_TEAM_MEMBER_LEFT_PUSH_CRON_SECRET"]
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
    sportsWorkerAuthLog("FanTeamMemberLeavePush", "unauthorized", {
      reason: invocation.reason,
      attempted,
    })
    return json({ error: "unauthorized" }, 401)
  }
  sportsWorkerAuthLog("FanTeamMemberLeavePush", "authorized", {
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
    .from("fan_team_member_left_events")
    .select(
      "id,team_id,left_user_id,actor_user_id,reason,team_name,left_display_name,recipient_user_ids",
    )
    .eq("id", eventId)
    .maybeSingle()

  if (eventError) {
    console.error(`${LOG_PREFIX} event_lookup_failed`, eventError)
    return json({ error: "event_lookup_failed" }, 500)
  }

  const row = event as MemberLeftEventRow | null
  if (!row) {
    return json({ ok: true, skipped: true, reason: "event_not_found" })
  }

  const leftUserId = row.left_user_id.trim().toLowerCase()
  const recipients = (row.recipient_user_ids ?? [])
    .map((id) => id.trim().toLowerCase())
    .filter((id) => isUuid(id) && id !== leftUserId)

  console.log(
    `${LOG_PREFIX} event=${eventId} team_id=${row.team_id} leaving_user_id=${leftUserId} ` +
      `team_name=${row.team_name} recipient_snapshot=${recipients.length} ` +
      `notification_event=yes`,
  )

  if (recipients.length === 0) {
    console.warn(`${LOG_PREFIX} no_recipients eventId=${eventId} teamId=${row.team_id}`)
    return json({ ok: true, skipped: true, reason: "no_recipients", sent: 0 })
  }

  const muted = await loadMutedFanTeamMemberIds(admin, row.team_id, recipients)
  console.log(
    `${LOG_PREFIX} mute_filtering muted_count=${muted.size} installation_recipients=${recipients.length}`,
  )

  const alert = buildMemberLeftTeamAlert({
    teamName: row.team_name ?? "",
    leftDisplayName: row.left_display_name ?? "",
    locale: "en",
  })

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

    if (muted.has(recipientId)) {
      await finalizeDelivery(admin, eventId, recipientId, "skipped", "team_push_muted", 0)
      console.log(
        `${LOG_PREFIX} mute_skip eventId=${eventId} recipient=${recipientId}`,
      )
      totalSkipped += 1
      continue
    }

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
    console.log(
      `${LOG_PREFIX} installation_count recipient=${recipientId} activeTokenCount=${activeTokens.length}`,
    )
    if (activeTokens.length === 0) {
      await finalizeDelivery(admin, eventId, recipientId, "skipped", "no_active_tokens", 0)
      totalSkipped += 1
      continue
    }

    const customData: Record<string, string> = {
      source: SOURCE,
      type: SOURCE,
      team_id: row.team_id,
      event_id: eventId,
      left_user_id: row.left_user_id,
      team_name: row.team_name ?? "Team",
      destination: "team_roster",
    }
    applyPushArtwork(customData, teamLogoURL, "team", row.team_id)

    let sent = 0
    let invalidated = 0
    for (const token of activeTokens) {
      if (token.user_id === leftUserId) continue
      console.log(
        `${LOG_PREFIX} apns_attempt recipient=${recipientId} tokenId=${token.id} ` +
          `environment=${token.environment}`,
      )
      const result = await apns.send(token, alert, customData)
      if (result.ok) {
        sent += 1
        console.log(
          `${LOG_PREFIX} apns_status=accepted tokenId=${token.id} ` +
            `environment=${result.tokenEnvironment} status=${result.status} ` +
            `recipient=${recipientId} eventId=${eventId}`,
        )
        continue
      }
      console.warn(
        `${LOG_PREFIX} apns_status=failed tokenId=${token.id} ` +
          `reason=${result.reason ?? "unknown"} invalidate=${result.invalidate === true} ` +
          `recipient=${recipientId}`,
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
    kind: SOURCE,
    recipients: recipients.length,
    sent: totalSent,
    skipped: totalSkipped,
    failed: totalFailed,
  })
})
