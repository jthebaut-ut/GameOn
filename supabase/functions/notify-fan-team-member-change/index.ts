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
import { buildMemberChangePushAlert } from "./member_change_push_alert.ts"

/**
 * Trusted APNs worker for Fan Team player-info / role / event-roster / team-removal
 * member-change events.
 *
 * Invoked from emit_fan_team_member_change_notification via
 * queue_fan_team_member_change_push_notification.
 *
 * Auth: Bearer SERVICE_ROLE_KEY, or x-cron-secret matching
 *       FAN_TEAM_MEMBER_CHANGE_PUSH_CRON_SECRET.
 *
 * Recipients: fan_team_member_change_events.recipient_user_ids
 *   (always exactly [target_user_id] — never a leadership fan-out).
 *
 * Mute policy (centralized here — the source of truth for member-change mute):
 *   Mandatory (ignore Team push mute): removed_from_team, removed_from_event,
 *     added_back_to_event, team_admin_granted, team_admin_removed.
 *   Respect Team push mute (fan_team_members.push_notifications_muted):
 *     player_number_*, preferred_position_*, team_role_changed.
 *
 * Deploy: `supabase functions deploy notify-fan-team-member-change --no-verify-jwt`
 */

interface Payload {
  event_id?: string
}

type MemberChangeEventRow = {
  id: string
  team_id: string
  kind: string
  actor_user_id: string
  target_user_id: string
  team_name: string
  payload: Record<string, unknown> | null
  recipient_user_ids: string[] | null
}

const SOURCE = "member_change"
const LOG_PREFIX = "[FanTeamMemberChangeDebug]"

/** These lifecycle pushes must reach the member regardless of Team push mute. */
const MANDATORY_KINDS = new Set([
  "removed_from_team",
  "removed_from_event",
  "added_back_to_event",
  "team_admin_granted",
  "team_admin_removed",
])

function pushDestination(kind: string): string {
  if (kind === "removed_from_team" || kind === "team_admin_removed") return "my_teams"
  return "team_roster"
}

function inboxDedupeKey(
  kind: string,
  teamId: string,
  userId: string,
  eventId: string,
): string {
  const t = teamId.toLowerCase()
  const u = userId.toLowerCase()
  const e = eventId.toLowerCase()
  switch (kind) {
    case "removed_from_team":
      return `team_removed:${t}:${u}:${e}`
    case "team_role_changed":
      return `team_role_changed:${t}:${u}:${e}`
    case "team_admin_granted":
      return `team_admin_granted:${t}:${u}:${e}`
    case "team_admin_removed":
      return `team_admin_removed:${t}:${u}:${e}`
    default:
      return `team_member_change:${e}:${u}`
  }
}

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

function asString(value: unknown): string {
  return typeof value === "string" ? value.trim() : ""
}

function asNumberOrNull(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value
  if (typeof value === "string" && value.trim() !== "" && Number.isFinite(Number(value))) {
    return Number(value)
  }
  return null
}

async function claimDelivery(
  admin: SupabaseClient,
  eventId: string,
  recipientUserId: string,
  teamId: string,
): Promise<"claimed" | "exists"> {
  const { data: existing, error: existingError } = await admin
    .from("fan_team_member_change_push_deliveries")
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

  const { error } = await admin.from("fan_team_member_change_push_deliveries").insert({
    event_id: eventId,
    recipient_user_id: recipientUserId,
    team_id: teamId,
    delivery_status: "queued",
  })
  if (!error) return "claimed"
  if ((error as { code?: string }).code === "23505") {
    const { data: raced } = await admin
      .from("fan_team_member_change_push_deliveries")
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
    .from("fan_team_member_change_push_deliveries")
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
  const cronEnvNames = ["FAN_TEAM_MEMBER_CHANGE_PUSH_CRON_SECRET"]
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
    sportsWorkerAuthLog("FanTeamMemberChangePush", "unauthorized", {
      reason: invocation.reason,
      attempted,
    })
    return json({ error: "unauthorized" }, 401)
  }
  sportsWorkerAuthLog("FanTeamMemberChangePush", "authorized", {
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
    .from("fan_team_member_change_events")
    .select(
      "id,team_id,kind,actor_user_id,target_user_id,team_name,payload,recipient_user_ids",
    )
    .eq("id", eventId)
    .maybeSingle()

  if (eventError) {
    console.error(`${LOG_PREFIX} event_lookup_failed`, eventError)
    return json({ error: "event_lookup_failed" }, 500)
  }

  const row = event as MemberChangeEventRow | null
  if (!row) {
    return json({ ok: true, skipped: true, reason: "event_not_found" })
  }

  const recipients = (row.recipient_user_ids ?? [])
    .map((id) => id.trim().toLowerCase())
    .filter((id) => isUuid(id))

  const { data: inboxRows } = await admin
    .from("fan_notification_inbox")
    .select("id,deduplication_key,user_id")
    .eq("source_type", "member_change")
    .eq("source_id", eventId)

  const inboxByUser = new Map<string, { id: string; dedupe: string }>()
  for (const inbox of inboxRows ?? []) {
    const uid = asString((inbox as { user_id?: string }).user_id).toLowerCase()
    const id = asString((inbox as { id?: string }).id)
    const dedupe = asString((inbox as { deduplication_key?: string }).deduplication_key)
    if (uid && id) inboxByUser.set(uid, { id, dedupe })
  }

  console.log(
    `${LOG_PREFIX} event=${eventId} team_id=${row.team_id} kind=${row.kind} ` +
      `actor_user_id=${row.actor_user_id} target_user_id=${row.target_user_id} ` +
      `recipient_snapshot=${recipients.length} inbox_rows=${inboxByUser.size} ` +
      `notification_event=yes`,
  )

  if (recipients.length === 0) {
    console.warn(`${LOG_PREFIX} no_recipients eventId=${eventId} teamId=${row.team_id}`)
    return json({ ok: true, skipped: true, reason: "no_recipients", sent: 0 })
  }

  const isMandatory = MANDATORY_KINDS.has(row.kind)
  const muted = isMandatory
    ? new Set<string>()
    : await loadMutedFanTeamMemberIds(admin, row.team_id, recipients)
  console.log(
    `${LOG_PREFIX} mute_filtering kind=${row.kind} mandatory=${isMandatory} ` +
      `muted_count=${muted.size} installation_recipients=${recipients.length}`,
  )

  const p = row.payload ?? {}
  const alert = buildMemberChangePushAlert({
    kind: row.kind,
    teamName: row.team_name ?? "",
    locale: "en",
    playerNumber: asNumberOrNull(p.player_number),
    positionCode: asString(p.position_code) || null,
    role: asString(p.role) || null,
    previousRole: asString(p.previous_role) || null,
    gameFormat: asString(p.game_format) || null,
    eventTitle: asString(p.event_title) || null,
    gameStartAt: asString(p.game_start_at) || null,
  })

  const pickupGameId = asString(p.pickup_game_id)

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

    if (!isMandatory && muted.has(recipientId)) {
      await finalizeDelivery(admin, eventId, recipientId, "skipped", "team_push_muted", 0)
      console.log(
        `${LOG_PREFIX} mute_skip eventId=${eventId} recipient=${recipientId} kind=${row.kind}`,
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

    const dedupe = inboxByUser.get(recipientId)?.dedupe
      || inboxDedupeKey(row.kind, row.team_id, recipientId, eventId)
    const inboxId = inboxByUser.get(recipientId)?.id ?? ""
    console.log(
      `${LOG_PREFIX} deliver event=${eventId} kind=${row.kind} ` +
        `actor=${row.actor_user_id} target=${row.target_user_id} ` +
        `inbox_id=${inboxId || "none"} dedupe=${dedupe} token_count=${activeTokens.length}`,
    )

    const customData: Record<string, string> = {
      source: SOURCE,
      type: row.kind,
      kind: row.kind,
      team_id: row.team_id,
      team_name: row.team_name ?? "",
      event_id: eventId,
      target_user_id: row.target_user_id,
      destination: pushDestination(row.kind),
      deduplication_key: dedupe,
      inbox_dedupe_key: dedupe,
    }
    if (pickupGameId) {
      customData.pickup_game_id = pickupGameId
    }
    applyPushArtwork(customData, teamLogoURL, "team", row.team_id)

    let sent = 0
    let invalidated = 0
    for (const token of activeTokens) {
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
            `apns_id=${result.apnsId ?? "none"} recipient=${recipientId} eventId=${eventId}`,
        )
        continue
      }
      console.warn(
        `${LOG_PREFIX} apns_status=failed tokenId=${token.id} ` +
          `http=${result.status} reason=${result.reason ?? "unknown"} ` +
          `apns_id=${result.apnsId ?? "none"} invalidate=${result.invalidate === true} ` +
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
    `${LOG_PREFIX} done eventId=${eventId} teamId=${row.team_id} kind=${row.kind} ` +
      `recipients=${recipients.length} sentTokens=${totalSent} skipped=${totalSkipped} ` +
      `failed=${totalFailed} auth=${invocation.source}`,
  )

  return json({
    ok: true,
    event_id: eventId,
    team_id: row.team_id,
    kind: row.kind,
    recipients: recipients.length,
    sent: totalSent,
    skipped: totalSkipped,
    failed: totalFailed,
  })
})
