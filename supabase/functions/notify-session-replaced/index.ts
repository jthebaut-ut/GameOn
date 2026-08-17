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

/**
 * Trusted APNs worker for single-active-session takeover.
 *
 * Invoked from `claim_active_session` → `notify_replaced_session_device` →
 * `queue_security_session_replaced_notification` (pg_net + service role).
 *
 * Recipients are the OLD-device tokens captured on the event row — never the
 * newly claimed installation. No artwork. No access/refresh tokens in payload.
 *
 * Auth: Bearer SERVICE_ROLE_KEY / fangeo_service_role_key, or x-cron-secret.
 *
 * Deploy (do not run from the agent):
 *   supabase functions deploy notify-session-replaced --no-verify-jwt
 */

interface Payload {
  event_id?: string
}

type CapturedToken = {
  id?: string
  token?: string
  environment?: "sandbox" | "production"
  installation_id?: string | null
}

type EventRow = {
  id: string
  user_id: string
  new_installation_id: string | null
  new_device_family: string | null
  dedupe_key: string
  captured_tokens: CapturedToken[] | null
  apns_status: string | null
  old_token_count: number | null
}

const SOURCE = "security_session_replaced"
const LOG_PREFIX = "[SecuritySessionReplaced]"

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

function sanitizeDeviceFamily(raw: string | null | undefined): string | null {
  const value = (raw ?? "").trim().toLowerCase()
  if (value === "ipad") return "iPad"
  if (value === "iphone" || value === "ipod") return "iPhone"
  return null
}

async function markEvent(
  admin: SupabaseClient,
  eventId: string,
  patch: Record<string, unknown>,
): Promise<void> {
  await admin
    .from("security_session_replaced_events")
    .update({
      ...patch,
      updated_at: new Date().toISOString(),
    })
    .eq("id", eventId)
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405)
  }

  const supabaseUrl = Deno.env.get("PROJECT_URL")?.trim()
    ?? Deno.env.get("SUPABASE_URL")?.trim()
    ?? ""
  const adminApiKey = readAdminApiKey()
  const cronEnvNames = ["SESSION_REPLACED_PUSH_CRON_SECRET", "POKE_PUSH_CRON_SECRET"]
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
    sportsWorkerAuthLog("SecuritySessionReplaced", "unauthorized", {
      reason: invocation.reason,
      attempted,
    })
    return json({ error: "unauthorized" }, 401)
  }
  sportsWorkerAuthLog("SecuritySessionReplaced", "authorized", {
    source: invocation.source,
    attempted,
  })

  let payload: Payload
  try {
    payload = await req.json()
  } catch {
    return json({ error: "invalid_json" }, 400)
  }

  const eventId = (payload.event_id ?? "").trim()
  if (!isUuid(eventId)) {
    return json({ error: "missing_fields" }, 400)
  }

  const admin = createClient(supabaseUrl, adminApiKey)
  const { data: event, error: eventError } = await admin
    .from("security_session_replaced_events")
    .select(
      "id,user_id,new_installation_id,new_device_family,dedupe_key,captured_tokens,apns_status,old_token_count",
    )
    .eq("id", eventId)
    .maybeSingle()

  if (eventError) {
    console.error(`${LOG_PREFIX} event_lookup_failed`, eventError)
    return json({ error: "event_lookup_failed" }, 500)
  }

  const row = event as EventRow | null
  if (!row) {
    return json({ ok: true, skipped: true, reason: "event_not_found" })
  }
  if (row.apns_status === "sent") {
    return json({ ok: true, skipped: true, reason: "already_sent", sent: row.old_token_count ?? 0 })
  }

  const newInstall = (row.new_installation_id ?? "").trim().toLowerCase()
  const captured = Array.isArray(row.captured_tokens) ? row.captured_tokens : []
  const tokens: PushTokenRow[] = []
  for (const item of captured) {
    const token = (item.token ?? "").trim()
    const environment = item.environment === "production" ? "production" : "sandbox"
    const install = (item.installation_id ?? "").trim().toLowerCase()
    if (token.length < 16) continue
    if (newInstall && install && install === newInstall) continue
    tokens.push({
      id: (item.id ?? token).toString(),
      user_id: row.user_id,
      token,
      environment,
    })
  }

  console.log(
    `${LOG_PREFIX} event=${row.id} user=${row.user_id} ` +
      `oldTokenCount=${captured.length} targeted=${tokens.length} ` +
      `newInstallationPresent=${newInstall ? "true" : "false"}`,
  )

  if (tokens.length === 0) {
    await markEvent(admin, row.id, {
      apns_attempted: false,
      apns_status: "skipped",
      apns_reason: "no_old_tokens",
      sent_token_count: 0,
    })
    return json({ ok: true, skipped: true, reason: "no_old_tokens", sent: 0 })
  }

  let apns: ApnsClient
  try {
    apns = await ApnsClient.fromEnvironment()
  } catch (error) {
    console.error(`${LOG_PREFIX} apns_config_failed`, error)
    await markEvent(admin, row.id, {
      apns_attempted: true,
      apns_status: "failed",
      apns_reason: "apns_config",
    })
    return json({ error: "apns_misconfigured" }, 500)
  }

  const deviceFamily = sanitizeDeviceFamily(row.new_device_family)
  const alert = {
    title: "New sign-in detected",
    body: "Your FanGeo account was signed in on another device. This device has been signed out.",
    ...(deviceFamily ? { subtitle: `Signed in on ${deviceFamily}` } : {}),
  }
  const customData: Record<string, string> = {
    source: SOURCE,
    type: SOURCE,
    security_event: "new_sign_in",
    event_id: row.id,
    dedupe_key: row.dedupe_key,
    inbox_dedupe_key: row.dedupe_key,
  }
  if (deviceFamily) {
    customData.new_device_type = deviceFamily
  }

  let sent = 0
  let invalidated = 0
  let lastReason = ""
  for (const token of tokens) {
    const result = await apns.send(token, alert, customData)
    if (result.ok) {
      sent += 1
      continue
    }
    lastReason = result.reason ?? `status_${result.status}`
    console.warn(
      `${LOG_PREFIX} apns_failed tokenId=${token.id} status=${result.status} reason=${lastReason}`,
    )
    if (result.invalidate && token.id) {
      invalidated += 1
      await admin
        .from("user_push_tokens")
        .update({ is_active: false, invalidated_at: new Date().toISOString() })
        .eq("id", token.id)
    }
  }

  await markEvent(admin, row.id, {
    apns_attempted: true,
    apns_status: sent > 0 ? "sent" : "failed",
    apns_reason: sent > 0 ? null : (lastReason || "apns_send_failed"),
    sent_token_count: sent,
  })

  console.log(
    `${LOG_PREFIX} done event=${row.id} user=${row.user_id} ` +
      `sent=${sent} invalidated=${invalidated} targeted=${tokens.length} auth=${invocation.source}`,
  )

  return json({
    ok: true,
    sent,
    invalidated,
    event_id: row.id,
  })
})
