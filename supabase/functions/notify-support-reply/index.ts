import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "npm:@supabase/supabase-js@2"
import { ApnsClient, type PushTokenRow } from "../_shared/apns_client.ts"

/**
 * Sends an APNs alert to the ticket owner when an admin posts a support reply.
 *
 * Invoked asynchronously from `admin_send_support_message` via pg_net (service role).
 * Secrets: APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID, APNS_PRIVATE_KEY, APNS_ENVIRONMENT (optional)
 * Auth: SERVICE_ROLE_KEY / SUPABASE_SERVICE_ROLE_KEY bearer, or SUPPORT_REPLY_PUSH_CRON_SECRET header.
 * Deploy: `supabase functions deploy notify-support-reply`
 */

interface Payload {
  conversation_id?: string
  message_id?: string
}

const SUPPORT_REPLY_SOURCE = "support_reply_notification"
const ALERT_TITLE = "FanGeo Support replied"
const ALERT_BODY = "Open your support ticket to view the message."

function authorizeInvocation(
  req: Request,
  serviceRoleKey: string,
): { accepted: true; source: string } | { accepted: false; reason: string } {
  const authHeader = req.headers.get("Authorization")
  const bearerToken = authHeader?.replace(/^Bearer\s+/i, "").trim() ?? ""
  if (bearerToken && bearerToken === serviceRoleKey) {
    return { accepted: true, source: "service_role_bearer" }
  }

  const cronSecret = Deno.env.get("SUPPORT_REPLY_PUSH_CRON_SECRET")?.trim()
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
  const supabaseServiceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim() ?? ""
  const serviceRoleKeyEnv = Deno.env.get("SERVICE_ROLE_KEY")?.trim() ?? ""
  const cronSecretConfigured = Boolean(Deno.env.get("SUPPORT_REPLY_PUSH_CRON_SECRET")?.trim())

  const authHeader = req.headers.get("Authorization")
  const bearerToken = authHeader?.replace(/^Bearer\s+/i, "").trim() ?? ""
  const requestCronSecret = req.headers.get("x-cron-secret")?.trim()
    ?? req.headers.get("x-fangeo-cron-secret")?.trim()
    ?? ""

  console.log(`[SupportReplyPush] authHeaderExists=${Boolean(authHeader)}`)
  console.log(`[SupportReplyPush] cronSecretHeaderExists=${Boolean(requestCronSecret)}`)
  console.log(`[SupportReplyPush] SERVICE_ROLE_KEY_exists=${Boolean(serviceRoleKeyEnv)}`)
  console.log(`[SupportReplyPush] SUPABASE_SERVICE_ROLE_KEY_exists=${Boolean(supabaseServiceRoleKey)}`)
  console.log(`[SupportReplyPush] SUPPORT_REPLY_PUSH_CRON_SECRET_exists=${cronSecretConfigured}`)

  if (!supabaseUrl || !serviceRoleKey) {
    console.error("[SupportReplyPush] missing PROJECT_URL/SUPABASE_URL or service role key")
    return json({ error: "server_misconfigured" }, 500)
  }

  const invocation = authorizeInvocation(req, serviceRoleKey)
  if (!invocation.accepted) {
    console.warn(
      `[SupportReplyPush] unauthorized reason=${invocation.reason} ` +
        `bearerTokenLength=${bearerToken.length} ` +
        `resolvedServiceRoleKeyLength=${serviceRoleKey.length} ` +
        `SUPABASE_SERVICE_ROLE_KEY_length=${supabaseServiceRoleKey.length} ` +
        `SERVICE_ROLE_KEY_length=${serviceRoleKeyEnv.length} ` +
        `cronSecretHeaderLength=${requestCronSecret.length}`,
    )
    return json({ error: "unauthorized" }, 401)
  }

  console.log(`[SupportReplyPush] authMatchedSource=${invocation.source}`)

  let payload: Payload
  try {
    payload = await req.json()
  } catch {
    return json({ error: "invalid_json" }, 400)
  }

  const conversationId = payload.conversation_id?.trim()
  const messageId = payload.message_id?.trim()
  if (!conversationId || !messageId) {
    return json({ error: "missing_fields" }, 400)
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey)

  const { data: message, error: messageError } = await supabase
    .from("support_messages")
    .select("id,conversation_id,sender_kind")
    .eq("id", messageId)
    .maybeSingle()

  if (messageError) {
    console.error("[SupportReplyPush] message lookup failed", messageError)
    return json({ error: "message_lookup_failed" }, 500)
  }

  if (!message) {
    return json({ ok: true, skipped: true, reason: "message_not_found" })
  }

  if (message.conversation_id !== conversationId) {
    return json({ ok: true, skipped: true, reason: "conversation_mismatch" })
  }

  if (message.sender_kind !== "support") {
    return json({ ok: true, skipped: true, reason: "not_support_sender" })
  }

  const { data: conversation, error: conversationError } = await supabase
    .from("support_conversations")
    .select("id,user_id,status")
    .eq("id", conversationId)
    .maybeSingle()

  if (conversationError) {
    console.error("[SupportReplyPush] conversation lookup failed", conversationError)
    return json({ error: "conversation_lookup_failed" }, 500)
  }

  if (!conversation?.user_id) {
    return json({ ok: true, skipped: true, reason: "conversation_not_found" })
  }

  if (conversation.status === "cancelled") {
    return json({ ok: true, skipped: true, reason: "ticket_cancelled" })
  }

  const { data: tokens, error: tokenError } = await supabase
    .from("user_push_tokens")
    .select("id,user_id,token,environment")
    .eq("user_id", conversation.user_id)
    .eq("is_active", true)

  if (tokenError) {
    console.error("[SupportReplyPush] token lookup failed", tokenError)
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
    console.error("[SupportReplyPush] APNs client init failed", error)
    return json({ error: "apns_misconfigured" }, 500)
  }

  const customData = {
    source: SUPPORT_REPLY_SOURCE,
    support_conversation_id: conversationId,
  }

  let sent = 0
  let invalidated = 0
  for (const token of activeTokens) {
    const result = await apns.send(
      token,
      { title: ALERT_TITLE, body: ALERT_BODY },
      customData,
    )
    if (result.ok) {
      sent += 1
      continue
    }
    console.warn(
      `[SupportReplyPush] apns failed tokenId=${token.id} status=${result.status} reason=${result.reason ?? "unknown"}`,
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
    `[SupportReplyPush] conversationId=${conversationId} messageId=${messageId} sent=${sent} invalidated=${invalidated}`,
  )

  return json({ ok: true, sent, invalidated })
})

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  })
}
