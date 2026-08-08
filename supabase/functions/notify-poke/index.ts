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
  buildPokePushAlert,
  resolveSenderIdentity,
} from "../_shared/chat_push_preview.ts"

/**
 * Trusted APNs worker for profile pokes.
 *
 * Invoked from `poke_profile` via `queue_profile_poke_push_notification`
 * (pg_net + service role). Recipient is resolved from authoritative DB rows —
 * never from client-supplied recipient IDs.
 *
 * Auth: Bearer SERVICE_ROLE_KEY / SUPABASE_SERVICE_ROLE_KEY, or
 *       x-cron-secret matching POKE_PUSH_CRON_SECRET.
 *
 * Deploy: `supabase functions deploy notify-poke --no-verify-jwt`
 */

interface Payload {
  poke_id?: string
}

type PokeRow = {
  id: string
  poker_user_id: string
  poked_user_id: string
}

type ProfileRow = {
  id: string
  display_name: string | null
  username: string | null
  avatar_url: string | null
  avatar_thumbnail_url: string | null
  is_deleted: boolean | null
}

const SOURCE = "poke"
const LOG_PREFIX = "[PokePush]"

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
  pokeId: string,
  recipientUserId: string,
  pokerUserId: string,
): Promise<"claimed" | "exists"> {
  const { error } = await admin.from("profile_poke_push_deliveries").insert({
    poke_id: pokeId,
    recipient_user_id: recipientUserId,
    poker_user_id: pokerUserId,
    delivery_status: "queued",
  })
  if (!error) return "claimed"
  if ((error as { code?: string }).code === "23505") return "exists"
  console.error(`${LOG_PREFIX} claim_failed`, error)
  throw new Error("claim_failed")
}

async function finalizeDelivery(
  admin: SupabaseClient,
  pokeId: string,
  status: "sent" | "skipped" | "failed",
  skipReason: string | null,
  sentTokenCount: number,
): Promise<void> {
  await admin
    .from("profile_poke_push_deliveries")
    .update({
      delivery_status: status,
      skip_reason: skipReason,
      sent_token_count: sentTokenCount,
      updated_at: new Date().toISOString(),
    })
    .eq("poke_id", pokeId)
}

async function isBlockedEitherDirection(
  admin: SupabaseClient,
  a: string,
  b: string,
): Promise<boolean> {
  const forward = await admin
    .from("blocked_users")
    .select("blocker_user_id")
    .eq("blocker_user_id", a)
    .eq("blocked_user_id", b)
    .limit(1)
  if (forward.error) {
    console.error(`${LOG_PREFIX} block_lookup_failed`, forward.error)
    // Fail closed — do not notify when block state cannot be verified.
    return true
  }
  if ((forward.data?.length ?? 0) > 0) return true

  const reverse = await admin
    .from("blocked_users")
    .select("blocker_user_id")
    .eq("blocker_user_id", b)
    .eq("blocked_user_id", a)
    .limit(1)
  if (reverse.error) {
    console.error(`${LOG_PREFIX} block_lookup_failed`, reverse.error)
    return true
  }
  return (reverse.data?.length ?? 0) > 0
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405)
  }

  const supabaseUrl = Deno.env.get("PROJECT_URL")?.trim()
    ?? Deno.env.get("SUPABASE_URL")?.trim()
    ?? ""
  const adminApiKey = readAdminApiKey()
  const cronEnvNames = ["POKE_PUSH_CRON_SECRET"]
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
    sportsWorkerAuthLog("PokePush", "unauthorized", {
      reason: invocation.reason,
      attempted,
    })
    return json({ error: "unauthorized" }, 401)
  }
  sportsWorkerAuthLog("PokePush", "authorized", {
    source: invocation.source,
    attempted,
  })

  let payload: Payload
  try {
    payload = await req.json()
  } catch {
    return json({ error: "invalid_json" }, 400)
  }

  const pokeId = payload.poke_id?.trim() ?? ""
  if (!pokeId || !isUuid(pokeId)) {
    return json({ error: "missing_fields" }, 400)
  }

  const admin = createClient(supabaseUrl, adminApiKey)

  const { data: poke, error: pokeError } = await admin
    .from("profile_pokes")
    .select("id,poker_user_id,poked_user_id")
    .eq("id", pokeId)
    .maybeSingle()

  if (pokeError) {
    console.error(`${LOG_PREFIX} poke_lookup_failed`, pokeError)
    return json({ error: "poke_lookup_failed" }, 500)
  }

  const row = poke as PokeRow | null
  if (!row) {
    return json({ ok: true, skipped: true, reason: "poke_not_found" })
  }

  const pokerId = row.poker_user_id
  const recipientId = row.poked_user_id
  if (!pokerId || !recipientId || pokerId === recipientId) {
    return json({ ok: true, skipped: true, reason: "invalid_participants" })
  }

  let claim: "claimed" | "exists"
  try {
    claim = await claimDelivery(admin, row.id, recipientId, pokerId)
  } catch {
    return json({ error: "claim_failed" }, 500)
  }
  if (claim === "exists") {
    return json({ ok: true, skipped: true, reason: "already_claimed", sent: 0 })
  }

  if (await isBlockedEitherDirection(admin, pokerId, recipientId)) {
    await finalizeDelivery(admin, row.id, "skipped", "blocked", 0)
    return json({ ok: true, skipped: true, reason: "blocked", sent: 0 })
  }

  const { data: prefs } = await admin
    .from("user_notification_preferences")
    .select("poke_notifications_enabled")
    .eq("user_id", recipientId)
    .maybeSingle()

  if (prefs?.poke_notifications_enabled === false) {
    await finalizeDelivery(admin, row.id, "skipped", "prefs_disabled", 0)
    return json({ ok: true, skipped: true, reason: "prefs_disabled", sent: 0 })
  }

  const { data: senderProfile } = await admin
    .from("user_profiles")
    .select("id,display_name,username,avatar_url,avatar_thumbnail_url,is_deleted")
    .eq("id", pokerId)
    .maybeSingle()

  const senderIdentity = resolveSenderIdentity(senderProfile as ProfileRow | null)
  const alert = buildPokePushAlert({
    senderDisplayName: senderIdentity.displayName,
    senderHandle: senderIdentity.handle,
    hasExplicitDisplayName: senderIdentity.hasExplicitDisplayName,
  })

  const { data: tokens, error: tokenError } = await admin
    .from("user_push_tokens")
    .select("id,user_id,token,environment")
    .eq("user_id", recipientId)
    .eq("is_active", true)

  if (tokenError) {
    console.error(`${LOG_PREFIX} token_lookup_failed`, tokenError)
    await finalizeDelivery(admin, row.id, "failed", "token_lookup_failed", 0)
    return json({ error: "token_lookup_failed" }, 500)
  }

  const activeTokens = (tokens ?? []) as PushTokenRow[]
  if (activeTokens.length === 0) {
    await finalizeDelivery(admin, row.id, "skipped", "no_active_tokens", 0)
    return json({ ok: true, skipped: true, reason: "no_active_tokens", sent: 0 })
  }

  let apns: ApnsClient
  try {
    apns = await ApnsClient.fromEnvironment()
  } catch (error) {
    console.error(`${LOG_PREFIX} apns_config_failed`, error)
    await finalizeDelivery(admin, row.id, "failed", "apns_config", 0)
    return json({ error: "apns_misconfigured" }, 500)
  }

  const customData: Record<string, string> = {
    source: SOURCE,
    type: SOURCE,
    poke_id: row.id,
    event_id: row.id,
    sender_id: pokerId,
    poker_id: pokerId,
    recipient_id: recipientId,
    sender_display_name: senderIdentity.displayName,
  }
  if (senderIdentity.username) {
    customData.sender_username = senderIdentity.username
  }
  if (senderIdentity.handle) {
    customData.sender_handle = senderIdentity.handle
  }
  if (senderIdentity.avatarURL) {
    customData.sender_avatar_url = senderIdentity.avatarURL
  }

  let sent = 0
  let invalidated = 0
  for (const token of activeTokens) {
    // Never notify the poker, even if a stale token row is somehow shared.
    if (token.user_id === pokerId) continue

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
    await finalizeDelivery(admin, row.id, "sent", null, sent)
  } else {
    await finalizeDelivery(admin, row.id, "failed", "apns_send_failed", 0)
  }

  console.log(
    `${LOG_PREFIX} done pokeId=${row.id} recipient=${recipientId} ` +
      `sent=${sent} invalidated=${invalidated} auth=${invocation.source}`,
  )

  return json({
    ok: true,
    sent,
    invalidated,
    poke_id: row.id,
  })
})
