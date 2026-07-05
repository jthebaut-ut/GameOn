import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "npm:@supabase/supabase-js@2"
import { ApnsClient, type PushTokenRow } from "../_shared/apns_client.ts"

/**
 * Sends FanGeo official announcement push notifications to opted-in users.
 *
 * Invoked via service role (pg_net queue or admin tooling).
 * Secrets: APNS_* (shared), optional FANGEO_ANNOUNCEMENT_PUSH_CRON_SECRET
 * Deploy: `supabase functions deploy notify-fangeo-announcement`
 */

interface Payload {
  announcement_id?: string
}

type AnnouncementRow = {
  id: string
  title: string | null
  subtitle: string | null
  description: string | null
  status: string | null
  audience_fans: boolean | null
  audience_businesses: boolean | null
  promotion_type: string | null
  deleted_at: string | null
  start_date: string | null
  end_date: string | null
}

type RecipientTokenRow = {
  token_id: string
  user_id: string
  token: string
  environment: "sandbox" | "production"
}

const ANNOUNCEMENT_PUSH_SOURCE = "fangeo_announcement_notification"
const SPONSORED_PROMOTION_TYPES = new Set(["venue", "sponsored", "venue_promotion"])
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

  const cronSecret = Deno.env.get("FANGEO_ANNOUNCEMENT_PUSH_CRON_SECRET")?.trim()
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

function normalizePromotionType(raw: string | null | undefined): string {
  return (raw ?? "")
    .trim()
    .toLowerCase()
    .replace(/-/g, "_")
    .replace(/ /g, "_")
}

function isSponsoredPromotionType(raw: string | null | undefined): boolean {
  return SPONSORED_PROMOTION_TYPES.has(normalizePromotionType(raw))
}

function parseTimestamp(raw: string | null | undefined): Date | null {
  if (!raw?.trim()) return null
  const parsed = new Date(raw)
  return Number.isNaN(parsed.getTime()) ? null : parsed
}

function isDateOnlyString(raw: string): boolean {
  return /^\d{4}-\d{2}-\d{2}$/.test(raw)
}

function normalizedDateOnlyComponent(raw: string): string | null {
  const trimmed = raw.trim()
  if (isDateOnlyString(trimmed)) {
    return trimmed
  }

  if (trimmed.length < 10) return null
  const datePrefix = trimmed.slice(0, 10)
  if (!isDateOnlyString(datePrefix)) return null

  const suffix = trimmed.slice(10)
  if (
    suffix === "" ||
    suffix === "T00:00:00" ||
    suffix === "T00:00:00Z" ||
    suffix === "T00:00:00.000Z" ||
    suffix === "T00:00:00+00:00" ||
    suffix === "T00:00:00.000+00:00" ||
    suffix === " 00:00:00" ||
    suffix === " 00:00:00+00" ||
    suffix === " 00:00:00+00:00"
  ) {
    return datePrefix
  }

  return null
}

function getTimeZoneOffsetMs(date: Date, timeZone: string): number {
  const formatter = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  })
  const parts = formatter.formatToParts(date)
  const values: Record<string, string> = {}
  for (const part of parts) {
    if (part.type !== "literal") {
      values[part.type] = part.value
    }
  }

  const hour = Number(values.hour === "24" ? "0" : values.hour)
  const asUtc = Date.UTC(
    Number(values.year),
    Number(values.month) - 1,
    Number(values.day),
    hour,
    Number(values.minute),
    Number(values.second),
  )
  return asUtc - date.getTime()
}

function zonedDateTimeToUtc(
  year: number,
  month: number,
  day: number,
  hour: number,
  minute: number,
  second: number,
  millisecond: number,
  timeZone: string,
): Date {
  let utcGuess = Date.UTC(year, month - 1, day, hour, minute, second, millisecond)
  for (let i = 0; i < 2; i++) {
    const offset = getTimeZoneOffsetMs(new Date(utcGuess), timeZone)
    utcGuess = Date.UTC(year, month - 1, day, hour, minute, second, millisecond) - offset
  }
  return new Date(utcGuess)
}

function endOfDateOnlyInProjectTimeZone(raw: string): Date | null {
  const dateOnly = normalizedDateOnlyComponent(raw)
  if (!dateOnly) return null

  const [year, month, day] = dateOnly.split("-").map(Number)
  return zonedDateTimeToUtc(year, month, day, 23, 59, 59, 999, PROJECT_TIME_ZONE)
}

function parseAnnouncementEndDate(raw: string | null | undefined): Date | null {
  if (!raw?.trim()) return null

  const dateOnlyEnd = endOfDateOnlyInProjectTimeZone(raw)
  if (dateOnlyEnd) {
    return dateOnlyEnd
  }

  return parseTimestamp(raw)
}

function announcementActiveReason(row: AnnouncementRow, now = new Date()): string | null {
  if (row.deleted_at) return "deleted"
  const status = (row.status ?? "").trim().toLowerCase()
  if (status !== "active") return `status(${row.status ?? "unknown"})`
  const start = parseTimestamp(row.start_date)
  if (start && now < start) return "before_start"
  const end = parseAnnouncementEndDate(row.end_date)
  if (end && now > end) return "after_end"
  return null
}

function announcementPushBody(row: AnnouncementRow): string {
  const subtitle = row.subtitle?.trim()
  if (subtitle) return subtitle
  const description = row.description?.trim()
  if (description) return description
  return "Open FanGeo for details."
}

function tokenPrefixForDebug(token: string): string {
  const trimmed = token.trim()
  if (!trimmed) return "<empty>"
  return trimmed.slice(0, 12)
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
    console.error("[FanGeoAnnouncementPush] missing PROJECT_URL/SUPABASE_URL or service role key")
    return json({ error: "server_misconfigured" }, 500)
  }

  const invocation = authorizeInvocation(req, serviceRoleKey)
  if (!invocation.accepted) {
    console.warn(`[FanGeoAnnouncementPush] unauthorized reason=${invocation.reason}`)
    return json({ error: "unauthorized" }, 401)
  }

  let payload: Payload
  try {
    payload = await req.json()
  } catch {
    return json({ error: "invalid_json" }, 400)
  }

  const announcementId = payload.announcement_id?.trim()
  if (!announcementId) {
    return json({ error: "missing_fields" }, 400)
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey)

  const { data: announcement, error: announcementError } = await supabase
    .from("announcements")
    .select("id,title,subtitle,description,status,audience_fans,audience_businesses,promotion_type,deleted_at,start_date,end_date")
    .eq("id", announcementId)
    .maybeSingle()

  if (announcementError) {
    console.error("[FanGeoAnnouncementPush] announcement lookup failed", announcementError)
    return json({ error: "announcement_lookup_failed" }, 500)
  }

  if (!announcement) {
    return json({ ok: true, skipped: true, reason: "announcement_not_found" })
  }

  const row = announcement as AnnouncementRow

  if (isSponsoredPromotionType(row.promotion_type)) {
    return json({ ok: true, skipped: true, reason: "sponsored_promotion_not_allowed" })
  }

  const inactiveReason = announcementActiveReason(row)
  if (inactiveReason) {
    return json({ ok: true, skipped: true, reason: inactiveReason })
  }

  const title = row.title?.trim()
  if (!title) {
    return json({ ok: true, skipped: true, reason: "missing_title" })
  }

  const includeFans = row.audience_fans !== false
  const includeBusinesses = row.audience_businesses === true
  if (!includeFans && !includeBusinesses) {
    return json({ ok: true, skipped: true, reason: "no_audience_selected" })
  }

  const { data: recipients, error: recipientError } = await supabase.rpc(
    "list_fangeo_announcement_push_tokens",
    {
      p_include_fans: includeFans,
      p_include_businesses: includeBusinesses,
    },
  )

  if (recipientError) {
    console.error("[FanGeoAnnouncementPush] recipient lookup failed", recipientError)
    return json({ error: "recipient_lookup_failed" }, 500)
  }

  const tokens = (recipients ?? []) as RecipientTokenRow[]
  console.log(
    `[FanGeoAnnouncementPushDebug] recipientsLoaded=${tokens.length} announcementId=${announcementId}`,
  )
  for (const recipient of tokens) {
    console.log(
      `[FanGeoAnnouncementPushDebug] recipient userId=${recipient.user_id} ` +
        `environment=${recipient.environment} tokenPrefix=${tokenPrefixForDebug(recipient.token)} ` +
        `tokenId=${recipient.token_id}`,
    )
  }

  if (tokens.length === 0) {
    return json({ ok: true, skipped: true, reason: "no_eligible_tokens", sent: 0 })
  }

  let apns: ApnsClient
  try {
    apns = await ApnsClient.fromEnvironment()
  } catch (error) {
    console.error("[FanGeoAnnouncementPush] APNs client init failed", error)
    return json({ error: "apns_misconfigured" }, 500)
  }

  const alertBody = announcementPushBody(row)
  const customData = {
    source: ANNOUNCEMENT_PUSH_SOURCE,
    announcement_id: announcementId,
  }

  let sent = 0
  let invalidated = 0
  for (const recipient of tokens) {
    const token: PushTokenRow = {
      id: recipient.token_id,
      user_id: recipient.user_id,
      token: recipient.token,
      environment: recipient.environment,
    }
    console.log(
      `[FanGeoAnnouncementPushDebug] apnsSendAttempted tokenId=${token.id} userId=${token.user_id} ` +
        `environment=${token.environment} tokenPrefix=${tokenPrefixForDebug(token.token)}`,
    )
    const result = await apns.send(
      token,
      { title, body: alertBody },
      customData,
    )
    if (result.ok) {
      console.log(
        `[FanGeoAnnouncementPushDebug] apnsResult tokenId=${token.id} userId=${token.user_id} ` +
          `environment=${result.tokenEnvironment} status=${result.status} ok=true`,
      )
      sent += 1
      continue
    }
    console.warn(
      `[FanGeoAnnouncementPush] apns failed tokenId=${token.id} status=${result.status} reason=${result.reason ?? "unknown"}`,
    )
    console.warn(
      `[FanGeoAnnouncementPushDebug] apnsResult tokenId=${token.id} userId=${token.user_id} ` +
        `environment=${result.tokenEnvironment} status=${result.status} ok=false ` +
        `reason=${result.reason ?? "unknown"} invalidate=${Boolean(result.invalidate)}`,
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
    `[FanGeoAnnouncementPush] announcementId=${announcementId} recipients=${tokens.length} sent=${sent} invalidated=${invalidated}`,
  )

  return json({ ok: true, sent, invalidated, recipients: tokens.length })
})

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  })
}
