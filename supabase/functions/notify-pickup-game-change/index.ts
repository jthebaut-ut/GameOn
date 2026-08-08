import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2"
import { ApnsClient, type PushTokenRow } from "../_shared/apns_client.ts"
import { secretsEqual } from "../_shared/sports_worker_auth.ts"

/**
 * Preference-gated APNs worker for meaningful pickup-game edits/cancels.
 *
 * Invocation (internal only):
 *   - Authorization: Bearer <SERVICE_ROLE_KEY>
 *   - optional x-cron-secret matching PICKUP_GAME_CHANGE_PUSH_CRON_SECRET only
 *
 * Chat system messages are written by the SQL trigger. This worker only pushes.
 * Deploy: `supabase functions deploy notify-pickup-game-change --no-verify-jwt`
 */

interface Payload {
  update_event_id?: string
}

type UpdateEventRow = {
  id: string
  pickup_game_id: string
  editor_user_id: string | null
  change_kinds: string[] | null
  payload: Record<string, unknown> | null
  push_delivery_status?: string | null
  push_sent_at?: string | null
}

type RecipientTokenRow = {
  token_id: string
  user_id: string
  token: string
  environment: "sandbox" | "production"
}

const SOURCE = "pickup_game_change_notification"
const LOG_PREFIX = "[PickupGameChangePush]"

function json(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      // Internal worker — deny browser credentialed cross-origin use.
      "Cache-Control": "no-store",
    },
  })
}

function authorizeInvocation(
  req: Request,
  serviceRoleKey: string,
): { accepted: true; source: string } | { accepted: false; reason: string } {
  const authHeader = req.headers.get("Authorization")
  const bearerToken = authHeader?.replace(/^Bearer\s+/i, "").trim() ?? ""
  if (bearerToken && serviceRoleKey && secretsEqual(bearerToken, serviceRoleKey)) {
    return { accepted: true, source: "service_role_bearer" }
  }

  const cronSecret = Deno.env.get("PICKUP_GAME_CHANGE_PUSH_CRON_SECRET")?.trim() ?? ""
  const requestCronSecret = req.headers.get("x-cron-secret")?.trim()
    ?? req.headers.get("x-fangeo-cron-secret")?.trim()
  if (cronSecret && requestCronSecret && secretsEqual(requestCronSecret, cronSecret)) {
    return { accepted: true, source: "cron_secret" }
  }

  return {
    accepted: false,
    reason: bearerToken || requestCronSecret ? "invalid_secret" : "missing_secret",
  }
}

function asString(value: unknown): string {
  return typeof value === "string" ? value.trim() : ""
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value)
}

function formatStartForPush(raw: string): string {
  if (!raw) return ""
  const date = new Date(raw)
  if (Number.isNaN(date.getTime())) return ""
  try {
    return new Intl.DateTimeFormat("en-US", {
      month: "short",
      day: "numeric",
      hour: "numeric",
      minute: "2-digit",
    }).format(date)
  } catch {
    return ""
  }
}

/** Build alert from authoritative event row only (ignore client-supplied copy). */
function buildAlert(event: UpdateEventRow): { title: string; body: string } {
  const kinds = new Set((event.change_kinds ?? []).map((k) => k.toLowerCase()))
  const payload = event.payload ?? {}
  const titleName = asString(payload.title) || "Pickup game"
  const afterStart = formatStartForPush(asString(payload.after_start))
  const afterLocation = asString(payload.after_location)
  const beforePlayers = Number(payload.before_players_needed ?? NaN)
  const afterPlayers = Number(payload.after_players_needed ?? NaN)
  const afterStatus = asString(payload.after_status).toLowerCase()
  const beforeStatus = asString(payload.before_status).toLowerCase()

  const pushTitle = "Pickup game updated"
  if (beforeStatus !== "removed" && afterStatus === "removed") {
    return { title: pushTitle, body: `${titleName} was cancelled.` }
  }
  if ((kinds.has("start") || kinds.has("end")) && kinds.has("location")) {
    return { title: pushTitle, body: `${titleName} changed date and location.` }
  }
  if (kinds.has("start") || kinds.has("end")) {
    const when = afterStart || "a new time"
    return { title: pushTitle, body: `${titleName} moved to ${when}.` }
  }
  if (kinds.has("location")) {
    const place = afterLocation || "a new location"
    return { title: pushTitle, body: `${titleName} moved to ${place}.` }
  }
  if (kinds.has("capacity") && Number.isFinite(beforePlayers) && Number.isFinite(afterPlayers)) {
    return {
      title: pushTitle,
      body: `${titleName} capacity changed from ${beforePlayers} to ${afterPlayers}.`,
    }
  }
  return { title: pushTitle, body: `${titleName} was updated.` }
}

async function finalize(
  admin: SupabaseClient,
  updateEventId: string,
  status: "sent" | "failed" | "retryable" | "skipped",
  error?: string,
  skipReason?: string,
): Promise<void> {
  const { error: finalizeError } = await admin.rpc("finalize_pickup_game_change_push_event", {
    p_update_event_id: updateEventId,
    p_status: status,
    p_error: error ?? null,
    p_skip_reason: skipReason ?? null,
  })
  if (finalizeError) {
    console.error(`${LOG_PREFIX} finalize_failed status=${status} reason=${finalizeError.message}`)
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204 })
  }
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405)
  }

  const supabaseUrl = Deno.env.get("PROJECT_URL")?.trim()
    ?? Deno.env.get("SUPABASE_URL")?.trim()
    ?? ""
  const serviceRoleKey = Deno.env.get("SERVICE_ROLE_KEY")?.trim()
    ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim()
    ?? ""
  if (!supabaseUrl || !serviceRoleKey) {
    console.error(`${LOG_PREFIX} missing_supabase_env`)
    return json({ error: "server_misconfigured" }, 500)
  }

  const auth = authorizeInvocation(req, serviceRoleKey)
  if (!auth.accepted) {
    console.warn(`${LOG_PREFIX} unauthorized reason=${auth.reason}`)
    return json({ error: "unauthorized" }, 401)
  }

  let body: Payload
  try {
    body = await req.json()
  } catch {
    return json({ error: "invalid_json" }, 400)
  }

  const updateEventId = body.update_event_id?.trim() ?? ""
  if (!updateEventId || !isUuid(updateEventId)) {
    return json({ error: "missing_or_invalid_update_event_id" }, 400)
  }

  // Ignore any client-supplied title/body/recipients — only the event id is accepted.
  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  })

  const { data: claimed, error: claimError } = await admin.rpc(
    "claim_pickup_game_change_push_event",
    { p_update_event_id: updateEventId },
  )

  if (claimError) {
    console.error(`${LOG_PREFIX} claim_failed reason=${claimError.message}`)
    return json({ error: "claim_failed" }, 500)
  }

  if (!claimed) {
    // Already sent, currently sending, or unknown id.
    const { data: existing } = await admin
      .from("pickup_game_update_events")
      .select("id,push_delivery_status,push_sent_at")
      .eq("id", updateEventId)
      .maybeSingle()

    if (!existing) {
      return json({ error: "event_not_found" }, 404)
    }
    return json({
      ok: true,
      skipped: true,
      reason: existing.push_sent_at ? "already_sent" : "not_claimable",
      update_event_id: updateEventId,
    })
  }

  const updateEvent = claimed as UpdateEventRow
  const alert = buildAlert(updateEvent)
  const excludeEditor = updateEvent.editor_user_id?.trim() || null

  const { data: tokens, error: tokenError } = await admin.rpc(
    "list_pickup_game_change_push_tokens",
    {
      p_pickup_game_id: updateEvent.pickup_game_id,
      p_exclude_user_id: excludeEditor,
    },
  )

  if (tokenError) {
    console.error(`${LOG_PREFIX} recipient_query_failed reason=${tokenError.message}`)
    await finalize(admin, updateEventId, "retryable", "recipient_query_failed")
    return json({ error: "recipient_query_failed" }, 500)
  }

  const rows = (tokens ?? []) as RecipientTokenRow[]
  if (rows.length === 0) {
    await finalize(admin, updateEventId, "skipped", undefined, "no_recipients")
    return json({ ok: true, sent: 0, skipped: "no_recipients", update_event_id: updateEventId })
  }

  let apns: ApnsClient
  try {
    apns = await ApnsClient.fromEnvironment()
  } catch (error) {
    const detail = error instanceof Error ? error.message : "apns_config"
    console.error(`${LOG_PREFIX} apns_config_failed`)
    await finalize(admin, updateEventId, "retryable", "apns_config")
    return json({ error: "apns_config", detail: detail.slice(0, 120) }, 500)
  }

  // One logical push attempt per user (multi-token users: first success wins).
  const tokensByUser = new Map<string, RecipientTokenRow[]>()
  for (const row of rows) {
    const list = tokensByUser.get(row.user_id) ?? []
    list.push(row)
    tokensByUser.set(row.user_id, list)
  }

  let sentUsers = 0
  let failedUsers = 0
  let skippedUsers = 0

  for (const [userId, userTokens] of tokensByUser) {
    const { data: alreadySent, error: alreadyError } = await admin.rpc(
      "pickup_game_change_push_already_sent",
      {
        p_update_event_id: updateEventId,
        p_user_id: userId,
      },
    )
    if (alreadyError) {
      console.error(`${LOG_PREFIX} already_sent_check_failed user=${userId}`)
      failedUsers += 1
      continue
    }
    if (alreadySent === true) {
      skippedUsers += 1
      continue
    }

    let userSent = false
    let lastReason = "apns_send_failed"
    for (const row of userTokens) {
      const token: PushTokenRow = {
        id: row.token_id,
        user_id: row.user_id,
        token: row.token,
        environment: row.environment,
      }
      const result = await apns.send(token, alert, {
        source: SOURCE,
        pickup_game_id: updateEvent.pickup_game_id,
        pickup_update_event_id: updateEvent.id,
      })
      if (result.ok) {
        userSent = true
        await admin.rpc("record_pickup_game_change_push_delivery", {
          p_update_event_id: updateEventId,
          p_user_id: userId,
          p_token_id: row.token_id,
          p_status: "sent",
          p_error_reason: null,
        })
        break
      }
      lastReason = result.reason ?? `status_${result.status}`
      if (result.invalidate) {
        await admin.from("user_push_tokens").update({ is_active: false }).eq("id", row.token_id)
      }
    }

    if (userSent) {
      sentUsers += 1
    } else {
      failedUsers += 1
      await admin.rpc("record_pickup_game_change_push_delivery", {
        p_update_event_id: updateEventId,
        p_user_id: userId,
        p_token_id: userTokens[0]?.token_id ?? null,
        p_status: "failed",
        p_error_reason: lastReason,
      })
    }
  }

  if (sentUsers > 0) {
    await finalize(admin, updateEventId, "sent")
  } else if (failedUsers > 0) {
    await finalize(admin, updateEventId, "retryable", "apns_send_failed")
  } else {
    await finalize(admin, updateEventId, "skipped", undefined, "no_new_recipients")
  }

  console.log(
    `${LOG_PREFIX} event=${updateEventId} pickup=${updateEvent.pickup_game_id} ` +
      `auth=${auth.source} sentUsers=${sentUsers} failedUsers=${failedUsers} skippedUsers=${skippedUsers}`,
  )

  return json({
    ok: true,
    update_event_id: updateEventId,
    sent: sentUsers,
    failed: failedUsers,
    skipped: skippedUsers,
  })
})
