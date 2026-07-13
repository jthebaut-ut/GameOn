import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "npm:@supabase/supabase-js@2"
import { ApnsClient, type PushTokenRow } from "../_shared/apns_client.ts"

/**
 * Sends one FanGeo+ award/extension APNs alert after admin_set_user_fangeo_plus.
 *
 * Invoked asynchronously via pg_net (service role).
 * Secrets: APNS_*, optional FANGEO_PLUS_AWARD_PUSH_CRON_SECRET
 * Deploy: `supabase functions deploy notify-fangeo-plus-award`
 */

interface Payload {
  award_event_id?: string
}

type AwardEventRow = {
  id: string
  user_id: string
  change_kind: "grant" | "extension" | string
  entitlement_source: string | null
  expires_at: string | null
  push_attempted_at: string | null
}

const AWARD_SOURCE = "admin_fangeo_plus_award"
const PROJECT_TIME_ZONE = "America/Denver"

function authorizeInvocation(
  req: Request,
  serviceRoleKey: string,
): { accepted: true; source: string } | { accepted: false; reason: string } {
  const authHeader = req.headers.get("Authorization")
  const bearerToken = authHeader?.replace(/^Bearer\s+/i, "").trim() ?? ""
  if (bearerToken && bearerToken === serviceRoleKey) {
    return { accepted: true, source: "service_role_bearer" }
  }

  const cronSecret = Deno.env.get("FANGEO_PLUS_AWARD_PUSH_CRON_SECRET")?.trim()
    ?? Deno.env.get("FANGEO_ANNOUNCEMENT_PUSH_CRON_SECRET")?.trim()
  const requestCronSecret = req.headers.get("x-cron-secret")?.trim()
    ?? req.headers.get("x-fangeo-cron-secret")?.trim()
  if (cronSecret && requestCronSecret === cronSecret) {
    return { accepted: true, source: "cron_secret" }
  }

  return {
    accepted: false,
    reason: bearerToken || requestCronSecret ? "invalid_secret" : "missing_secret",
  }
}

function formatAwardExpirationDate(expiresAt: string | null | undefined): string | null {
  if (!expiresAt?.trim()) return null
  const parsed = new Date(expiresAt)
  if (Number.isNaN(parsed.getTime())) return null

  // Format the calendar date in project TZ so end-of-day UTC values still read as the intended day.
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: PROJECT_TIME_ZONE,
    year: "numeric",
    month: "short",
    day: "numeric",
  }).formatToParts(parsed)

  const month = parts.find((part) => part.type === "month")?.value
  const day = parts.find((part) => part.type === "day")?.value
  const year = parts.find((part) => part.type === "year")?.value
  if (!month || !day || !year) return null
  return `${month} ${day}, ${year}`
}

function alertCopy(changeKind: string, expiresAt: string | null): { title: string; body: string } {
  const formatted = formatAwardExpirationDate(expiresAt)
  const isExtension = changeKind === "extension"

  if (isExtension) {
    return {
      title: "Your FanGeo+ access was extended",
      body: formatted
        ? `Your FanGeo+ access now runs through ${formatted}.`
        : "Your FanGeo+ access was extended with no expiration.",
    }
  }

  return {
    title: "FanGeo+ unlocked 🎉",
    body: formatted
      ? `You’ve been awarded FanGeo+ until ${formatted}.`
      : "You’ve been awarded FanGeo+ with no expiration.",
  }
}

Deno.serve(async (req) => {
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
    console.error("[FanGeoPlusAwardPush] missing PROJECT_URL/SUPABASE_URL or service role key")
    return json({ error: "server_misconfigured" }, 500)
  }

  const invocation = authorizeInvocation(req, serviceRoleKey)
  if (!invocation.accepted) {
    console.warn(`[FanGeoPlusAwardPush] unauthorized reason=${invocation.reason}`)
    return json({ error: "unauthorized" }, 401)
  }

  let payload: Payload
  try {
    payload = await req.json()
  } catch {
    return json({ error: "invalid_json" }, 400)
  }

  const awardEventId = payload.award_event_id?.trim()
  if (!awardEventId) {
    return json({ error: "missing_fields" }, 400)
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey)

  const { data: awardEvent, error: awardError } = await supabase
    .from("fangeo_plus_award_push_events")
    .select("id,user_id,change_kind,entitlement_source,expires_at,push_attempted_at")
    .eq("id", awardEventId)
    .maybeSingle()

  if (awardError) {
    console.error("[FanGeoPlusAwardPush] award event lookup failed", awardError)
    return json({ error: "award_lookup_failed" }, 500)
  }

  if (!awardEvent) {
    return json({ ok: true, skipped: true, reason: "award_event_not_found" })
  }

  const event = awardEvent as AwardEventRow

  // Idempotency: one successful grant queues one event; Edge Function sends once.
  if (event.push_attempted_at) {
    return json({ ok: true, skipped: true, reason: "already_attempted", sent: 0 })
  }

  const attemptedAt = new Date().toISOString()
  const { data: claimed, error: claimError } = await supabase
    .from("fangeo_plus_award_push_events")
    .update({ push_attempted_at: attemptedAt })
    .eq("id", awardEventId)
    .is("push_attempted_at", null)
    .select("id")
    .maybeSingle()

  if (claimError) {
    console.error("[FanGeoPlusAwardPush] claim failed", claimError)
    return json({ error: "claim_failed" }, 500)
  }

  if (!claimed) {
    return json({ ok: true, skipped: true, reason: "already_claimed", sent: 0 })
  }

  const { data: preference, error: preferenceError } = await supabase
    .from("user_notification_preferences")
    .select("account_access_notifications_enabled")
    .eq("user_id", event.user_id)
    .maybeSingle()

  if (preferenceError) {
    console.error("[FanGeoPlusAwardPush] preference lookup failed", preferenceError)
    return json({ error: "preference_lookup_failed" }, 500)
  }

  if (preference && preference.account_access_notifications_enabled === false) {
    return json({ ok: true, skipped: true, reason: "notifications_disabled", sent: 0 })
  }

  const { data: tokens, error: tokenError } = await supabase
    .from("user_push_tokens")
    .select("id,user_id,token,environment")
    .eq("user_id", event.user_id)
    .eq("is_active", true)

  if (tokenError) {
    console.error("[FanGeoPlusAwardPush] token lookup failed", tokenError)
    return json({ error: "token_lookup_failed" }, 500)
  }

  const activeTokens = (tokens ?? []) as PushTokenRow[]
  if (activeTokens.length === 0) {
    return json({ ok: true, skipped: true, reason: "no_active_tokens", sent: 0 })
  }

  let apns: ApnsClient
  try {
    apns = await ApnsClient.fromEnvironment()
  } catch (error) {
    console.error("[FanGeoPlusAwardPush] APNs client init failed", error)
    return json({ error: "apns_misconfigured" }, 500)
  }

  const alert = alertCopy(event.change_kind, event.expires_at)
  const customData: Record<string, string> = {
    source: AWARD_SOURCE,
    user_id: event.user_id,
    entitlement_source: event.entitlement_source ?? "admin_manual",
    change_kind: event.change_kind,
    award_event_id: event.id,
  }
  if (event.expires_at) {
    customData.expires_at = event.expires_at
  }

  let sent = 0
  let invalidated = 0
  for (const token of activeTokens) {
    const result = await apns.send(token, alert, customData)
    if (result.ok) {
      sent += 1
      continue
    }
    console.warn(
      `[FanGeoPlusAwardPush] apns failed tokenId=${token.id} status=${result.status} reason=${result.reason ?? "unknown"}`,
    )
    if (result.invalidate) {
      invalidated += 1
      await supabase
        .from("user_push_tokens")
        .update({ is_active: false, invalidated_at: new Date().toISOString() })
        .eq("id", token.id)
    }
  }

  console.log(
    `[FanGeoPlusAwardPush] awardEventId=${awardEventId} userId=${event.user_id} changeKind=${event.change_kind} sent=${sent} invalidated=${invalidated}`,
  )

  return json({ ok: true, sent, invalidated, title: alert.title, body: alert.body })
})

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  })
}
