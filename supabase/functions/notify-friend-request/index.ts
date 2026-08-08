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
  buildFriendRequestPushAlert,
  resolveSenderIdentity,
} from "../_shared/chat_push_preview.ts"

/**
 * Trusted APNs worker for pending friend requests.
 *
 * Invoked from `friendship_ensure_pending` via
 * `queue_friend_request_push_notification` (pg_net + service role).
 *
 * Auth: Bearer SERVICE_ROLE_KEY / SUPABASE_SERVICE_ROLE_KEY, or
 *       x-cron-secret matching FRIEND_REQUEST_PUSH_CRON_SECRET.
 *
 * Deploy: `supabase functions deploy notify-friend-request --no-verify-jwt`
 */

interface Payload {
  friendship_id?: string
  event_id?: string
}

type FriendshipRow = {
  id: string
  requester_id: string
  addressee_id: string
  status: string
  requester_entity_type: string | null
  addressee_entity_type: string | null
}

type ProfileRow = {
  id: string
  display_name: string | null
  username: string | null
  is_deleted: boolean | null
}

const SOURCE = "friend_request"
const LOG_PREFIX = "[FriendRequestPush]"

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
  friendshipId: string,
  recipientUserId: string,
  requesterUserId: string,
): Promise<"claimed" | "exists"> {
  const { error } = await admin.from("friend_request_push_deliveries").insert({
    event_id: eventId,
    friendship_id: friendshipId,
    recipient_user_id: recipientUserId,
    requester_user_id: requesterUserId,
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
    .from("friend_request_push_deliveries")
    .update({
      delivery_status: status,
      skip_reason: skipReason,
      sent_token_count: sentTokenCount,
      updated_at: new Date().toISOString(),
    })
    .eq("event_id", eventId)
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405)
  }

  const supabaseUrl = Deno.env.get("PROJECT_URL")?.trim()
    ?? Deno.env.get("SUPABASE_URL")?.trim()
    ?? ""
  const adminApiKey = readAdminApiKey()
  const cronEnvNames = ["FRIEND_REQUEST_PUSH_CRON_SECRET"]
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
    sportsWorkerAuthLog("FriendRequestPush", "unauthorized", {
      reason: invocation.reason,
      attempted,
    })
    return json({ error: "unauthorized" }, 401)
  }
  sportsWorkerAuthLog("FriendRequestPush", "authorized", {
    source: invocation.source,
    attempted,
  })

  let payload: Payload
  try {
    payload = await req.json()
  } catch {
    return json({ error: "invalid_json" }, 400)
  }

  const friendshipId = payload.friendship_id?.trim() ?? ""
  const eventId = payload.event_id?.trim() ?? ""
  if (!friendshipId || !eventId || !isUuid(friendshipId) || !isUuid(eventId)) {
    return json({ error: "missing_fields" }, 400)
  }

  const admin = createClient(supabaseUrl, adminApiKey)

  const { data: friendship, error: friendshipError } = await admin
    .from("friendships")
    .select("id,requester_id,addressee_id,status,requester_entity_type,addressee_entity_type")
    .eq("id", friendshipId)
    .maybeSingle()

  if (friendshipError) {
    console.error(`${LOG_PREFIX} friendship_lookup_failed`, friendshipError)
    return json({ error: "friendship_lookup_failed" }, 500)
  }

  const row = friendship as FriendshipRow | null
  if (!row) {
    return json({ ok: true, skipped: true, reason: "friendship_not_found" })
  }

  // Only notify for a currently pending user→user request.
  if (row.status !== "pending") {
    return json({ ok: true, skipped: true, reason: `status_${row.status}` })
  }

  const requesterEntity = (row.requester_entity_type ?? "user").toLowerCase()
  const addresseeEntity = (row.addressee_entity_type ?? "user").toLowerCase()
  if (requesterEntity !== "user" || addresseeEntity !== "user") {
    return json({ ok: true, skipped: true, reason: "non_user_entity" })
  }

  const requesterId = row.requester_id
  const recipientId = row.addressee_id
  if (!requesterId || !recipientId || requesterId === recipientId) {
    return json({ ok: true, skipped: true, reason: "invalid_participants" })
  }

  let claim: "claimed" | "exists"
  try {
    claim = await claimDelivery(admin, eventId, row.id, recipientId, requesterId)
  } catch {
    return json({ error: "claim_failed" }, 500)
  }
  if (claim === "exists") {
    return json({ ok: true, skipped: true, reason: "already_claimed", sent: 0 })
  }

  const { data: prefs } = await admin
    .from("user_notification_preferences")
    .select("friend_request_notifications_enabled")
    .eq("user_id", recipientId)
    .maybeSingle()

  if (prefs?.friend_request_notifications_enabled === false) {
    await finalizeDelivery(admin, eventId, "skipped", "prefs_disabled", 0)
    return json({ ok: true, skipped: true, reason: "prefs_disabled", sent: 0 })
  }

  const { data: senderProfile } = await admin
    .from("user_profiles")
    .select("id,display_name,username,is_deleted")
    .eq("id", requesterId)
    .maybeSingle()

  const requesterIdentity = resolveSenderIdentity(senderProfile as ProfileRow | null)
  const alert = buildFriendRequestPushAlert({
    requesterDisplayName: requesterIdentity.displayName,
    requesterHandle: requesterIdentity.handle,
    hasExplicitDisplayName: requesterIdentity.hasExplicitDisplayName,
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
    return json({ ok: true, skipped: true, reason: "no_active_tokens", sent: 0 })
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
    type: "friend_request",
    request_id: row.id,
    friendship_id: row.id,
    requester_id: requesterId,
    event_id: eventId,
  }

  let sent = 0
  let invalidated = 0
  for (const token of activeTokens) {
    if (token.user_id === requesterId) continue

    const result = await apns.send(
      token,
      alert,
      customData,
    )
    if (result.ok) {
      sent += 1
      continue
    }
    console.warn(
      `${LOG_PREFIX} apns_failed tokenId=${token.id} status=${result.status} reason=${result.reason ?? "unknown"}`,
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
    await finalizeDelivery(admin, eventId, "failed", "apns_send_failed", 0)
  }

  console.log(
    `${LOG_PREFIX} done friendshipId=${row.id} eventId=${eventId} recipient=${recipientId} ` +
      `sent=${sent} invalidated=${invalidated} auth=${invocation.source}`,
  )

  return json({
    ok: true,
    sent,
    invalidated,
    friendship_id: row.id,
    event_id: eventId,
  })
})
