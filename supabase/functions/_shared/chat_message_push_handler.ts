import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2"
import { ApnsClient, type PushTokenRow } from "./apns_client.ts"
import {
  authorizeSportsWorkerRequest,
  describeAuthCandidateClasses,
  readAdminApiKey,
  readRequestCredentialPresence,
  sportsWorkerAuthLog,
} from "./sports_worker_auth.ts"
import {
  buildDirectChatPushAlert,
  buildGroupChatPushAlert,
  resolveSenderIdentity,
  sanitizeConversationTitle,
  type ChatPreviewMode,
  type ChatPushKind,
  type SenderIdentity,
} from "./chat_push_preview.ts"
import {
  loadMutedFanTeamMemberIds,
  resolveFanTeamIdForConversation,
} from "./fan_team_push_mute.ts"

export type ChatMessagePushPayload = {
  message_id?: string
  /** direct | group — inferred when omitted */
  message_source?: string
  /** direct | venue | group | pickup — inferred when omitted */
  chat_type?: string
}

type ProfileRow = {
  id: string
  display_name: string | null
  username: string | null
  avatar_url: string | null
  avatar_thumbnail_url: string | null
  is_deleted: boolean | null
}

const LOG_PREFIX = "[ChatMessagePush]"

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

function normalizePreviewMode(raw: unknown): ChatPreviewMode {
  const value = typeof raw === "string" ? raw.trim().toLowerCase() : ""
  if (value === "never" || value === "when_unlocked") return value
  return "always"
}

function appendSenderIdentityToPayload(
  customData: Record<string, string>,
  identity: SenderIdentity,
): void {
  customData.sender_display_name = identity.displayName
  if (identity.username) customData.sender_username = identity.username
  if (identity.handle) customData.sender_handle = identity.handle
  if (identity.avatarURL) customData.sender_avatar_url = identity.avatarURL
}

async function claimDelivery(
  admin: SupabaseClient,
  messageSource: "direct" | "group",
  messageId: string,
  recipientUserId: string,
  conversationId: string,
  senderUserId: string,
  chatType: ChatPushKind,
): Promise<"claimed" | "exists"> {
  const { error } = await admin.from("chat_message_push_deliveries").insert({
    message_source: messageSource,
    message_id: messageId,
    recipient_user_id: recipientUserId,
    conversation_id: conversationId,
    sender_user_id: senderUserId,
    chat_type: chatType,
    delivery_status: "queued",
  })
  if (!error) return "claimed"
  if ((error as { code?: string }).code === "23505") return "exists"
  // Fallback: legacy DM ledger during transition if unified table missing columns.
  console.error(`${LOG_PREFIX} claim_failed`, error)
  throw new Error("claim_failed")
}

async function finalizeDelivery(
  admin: SupabaseClient,
  messageSource: "direct" | "group",
  messageId: string,
  recipientUserId: string,
  status: "sent" | "skipped" | "failed",
  skipReason: string | null,
  sentTokenCount: number,
): Promise<void> {
  await admin
    .from("chat_message_push_deliveries")
    .update({
      delivery_status: status,
      skip_reason: skipReason,
      sent_token_count: sentTokenCount,
      updated_at: new Date().toISOString(),
    })
    .eq("message_source", messageSource)
    .eq("message_id", messageId)
    .eq("recipient_user_id", recipientUserId)
}

async function loadSenderProfile(
  admin: SupabaseClient,
  senderId: string,
): Promise<ProfileRow | null> {
  const { data } = await admin
    .from("user_profiles")
    .select("id,display_name,username,avatar_url,avatar_thumbnail_url,is_deleted")
    .eq("id", senderId)
    .maybeSingle()
  return (data as ProfileRow | null) ?? null
}

async function sendToRecipientTokens(
  admin: SupabaseClient,
  apns: ApnsClient,
  recipientUserId: string,
  senderUserId: string,
  alert: { title: string; body: string },
  customData: Record<string, string>,
): Promise<{ sent: number; invalidated: number }> {
  const { data: tokens, error: tokenError } = await admin
    .from("user_push_tokens")
    .select("id,user_id,token,environment")
    .eq("user_id", recipientUserId)
    .eq("is_active", true)

  if (tokenError) throw tokenError
  const activeTokens = (tokens ?? []) as PushTokenRow[]
  // Defensive: never send the same APNs token string twice in one logical notification
  // (ownership bugs / duplicate rows). Not a substitute for exclusive token claim.
  const seenTokenKeys = new Set<string>()
  const dedupedTokens = activeTokens.filter((token) => {
    const key = `${token.environment}:${token.token}`
    if (seenTokenKeys.has(key)) return false
    seenTokenKeys.add(key)
    return true
  })
  let sent = 0
  let invalidated = 0
  for (const token of dedupedTokens) {
    if (token.user_id === senderUserId) continue
    const result = await apns.send(token, alert, customData)
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
  return { sent, invalidated }
}

async function handleDirectMessage(
  admin: SupabaseClient,
  apns: ApnsClient,
  messageId: string,
): Promise<Response> {
  const { data: message, error: messageError } = await admin
    .from("direct_messages")
    .select("id,conversation_id,sender_id,body,deleted_at,is_deleted")
    .eq("id", messageId)
    .maybeSingle()

  if (messageError) {
    console.error(`${LOG_PREFIX} dm_message_lookup_failed`, messageError)
    return json({ error: "message_lookup_failed" }, 500)
  }
  if (!message) return json({ ok: true, skipped: true, reason: "message_not_found" })
  if (message.deleted_at || message.is_deleted === true) {
    return json({ ok: true, skipped: true, reason: "message_deleted" })
  }

  const { data: conversation, error: conversationError } = await admin
    .from("direct_conversations")
    .select("id,user_a_id,user_b_id,business_id,venue_id")
    .eq("id", message.conversation_id)
    .maybeSingle()

  if (conversationError) {
    console.error(`${LOG_PREFIX} dm_conversation_lookup_failed`, conversationError)
    return json({ error: "conversation_lookup_failed" }, 500)
  }
  if (!conversation) return json({ ok: true, skipped: true, reason: "conversation_not_found" })

  const senderId = message.sender_id as string
  if (senderId !== conversation.user_a_id && senderId !== conversation.user_b_id) {
    return json({ ok: true, skipped: true, reason: "sender_not_participant" })
  }

  const recipientId = conversation.user_a_id === senderId
    ? conversation.user_b_id
    : conversation.user_a_id
  if (!recipientId || recipientId === senderId) {
    return json({ ok: true, skipped: true, reason: "recipient_unresolved" })
  }

  const chatType: ChatPushKind =
    conversation.business_id || conversation.venue_id ? "venue" : "direct"

  let claim: "claimed" | "exists"
  try {
    claim = await claimDelivery(
      admin,
      "direct",
      message.id,
      recipientId,
      conversation.id,
      senderId,
      chatType,
    )
  } catch {
    return json({ error: "claim_failed" }, 500)
  }
  if (claim === "exists") {
    return json({ ok: true, skipped: true, reason: "already_claimed", sent: 0 })
  }

  const { data: prefs } = await admin
    .from("user_notification_preferences")
    .select("direct_message_notifications_enabled,direct_message_preview_mode")
    .eq("user_id", recipientId)
    .maybeSingle()

  if (prefs?.direct_message_notifications_enabled === false) {
    await finalizeDelivery(admin, "direct", message.id, recipientId, "skipped", "prefs_disabled", 0)
    return json({ ok: true, skipped: true, reason: "prefs_disabled", sent: 0 })
  }

  const senderIdentity = resolveSenderIdentity(await loadSenderProfile(admin, senderId))
  let venueTitle = ""
  if (chatType === "venue" && conversation.business_id) {
    const { data: business } = await admin
      .from("businesses")
      .select("display_name")
      .eq("id", conversation.business_id)
      .maybeSingle()
    venueTitle = sanitizeConversationTitle(
      (business?.display_name as string | undefined) ?? "",
      "Venue Chat",
    )
  }

  const previewMode = normalizePreviewMode(prefs?.direct_message_preview_mode)
  const alert = chatType === "venue"
    ? buildGroupChatPushAlert({
      conversationTitle: venueTitle,
      senderDisplayName: senderIdentity.displayName,
      senderHandle: senderIdentity.handle,
      hasExplicitDisplayName: senderIdentity.hasExplicitDisplayName,
      body: message.body as string,
      previewMode,
      titleFallback: "Venue Chat",
    })
    : buildDirectChatPushAlert({
      senderDisplayName: senderIdentity.displayName,
      senderHandle: senderIdentity.handle,
      hasExplicitDisplayName: senderIdentity.hasExplicitDisplayName,
      body: message.body as string,
      previewMode,
    })

  const customData: Record<string, string> = {
    // Prefer legacy source so currently-released FanGeo builds keep routing DMs.
    source: "direct_message",
    type: "direct_message",
    chat_type: chatType,
    conversation_id: conversation.id,
    message_id: message.id,
    sender_id: senderId,
  }
  appendSenderIdentityToPayload(customData, senderIdentity)
  if (conversation.business_id) customData.business_id = conversation.business_id
  if (conversation.venue_id) customData.venue_id = conversation.venue_id
  if (chatType === "venue") customData.conversation_title = alert.title

  try {
    const { sent, invalidated } = await sendToRecipientTokens(
      admin,
      apns,
      recipientId,
      senderId,
      alert,
      customData,
    )
    if (sent > 0) {
      await finalizeDelivery(admin, "direct", message.id, recipientId, "sent", null, sent)
    } else {
      await finalizeDelivery(admin, "direct", message.id, recipientId, "failed", "apns_send_failed", 0)
    }
    console.log(
      `${LOG_PREFIX} dm done messageId=${message.id} chatType=${chatType} recipient=${recipientId} sent=${sent} invalidated=${invalidated}`,
    )
    return json({ ok: true, sent, invalidated, chat_type: chatType, message_id: message.id })
  } catch (error) {
    console.error(`${LOG_PREFIX} dm_token_or_send_failed`, error)
    await finalizeDelivery(admin, "direct", message.id, recipientId, "failed", "token_lookup_failed", 0)
    return json({ error: "token_lookup_failed" }, 500)
  }
}

async function handleGroupMessage(
  admin: SupabaseClient,
  apns: ApnsClient,
  messageId: string,
): Promise<Response> {
  const { data: message, error: messageError } = await admin
    .from("group_messages")
    .select("id,conversation_id,sender_id,body,message_type,deleted_at,is_deleted")
    .eq("id", messageId)
    .maybeSingle()

  if (messageError) {
    console.error(`${LOG_PREFIX} group_message_lookup_failed`, messageError)
    return json({ error: "message_lookup_failed" }, 500)
  }
  if (!message) return json({ ok: true, skipped: true, reason: "message_not_found" })
  if (message.deleted_at || message.is_deleted === true) {
    return json({ ok: true, skipped: true, reason: "message_deleted" })
  }
  if ((message.message_type as string | null) === "system") {
    return json({ ok: true, skipped: true, reason: "system_message" })
  }

  const { data: conversation, error: conversationError } = await admin
    .from("group_conversations")
    .select("id,title,pickup_game_id,is_active")
    .eq("id", message.conversation_id)
    .maybeSingle()

  if (conversationError) {
    console.error(`${LOG_PREFIX} group_conversation_lookup_failed`, conversationError)
    return json({ error: "conversation_lookup_failed" }, 500)
  }
  if (!conversation || conversation.is_active === false) {
    return json({ ok: true, skipped: true, reason: "conversation_inactive" })
  }

  const chatType: ChatPushKind = conversation.pickup_game_id ? "pickup" : "group"
  const senderId = message.sender_id as string

  const { data: members, error: membersError } = await admin
    .from("group_conversation_members")
    .select("user_id,left_at,muted_until")
    .eq("conversation_id", conversation.id)
    .is("left_at", null)

  if (membersError) {
    console.error(`${LOG_PREFIX} members_lookup_failed`, membersError)
    return json({ error: "members_lookup_failed" }, 500)
  }

  const now = Date.now()
  const recipientIds = (members ?? [])
    .map((row) => ({
      userId: row.user_id as string,
      mutedUntil: row.muted_until as string | null,
    }))
    .filter((row) => row.userId && row.userId !== senderId)
    .filter((row) => {
      if (!row.mutedUntil) return true
      const mutedMs = Date.parse(row.mutedUntil)
      return !Number.isFinite(mutedMs) || mutedMs <= now
    })
    .map((row) => row.userId)

  if (recipientIds.length === 0) {
    return json({ ok: true, skipped: true, reason: "no_recipients", sent: 0 })
  }

  // Team Chat = group conversation linked via fan_teams.group_conversation_id.
  // Per-Team mute suppresses APNs for that Team only; regular Group Chat unchanged.
  const fanTeamId = chatType === "group"
    ? await resolveFanTeamIdForConversation(admin, conversation.id as string)
    : null
  const teamMutedRecipientIds = fanTeamId
    ? await loadMutedFanTeamMemberIds(admin, fanTeamId, recipientIds)
    : new Set<string>()

  const senderIdentity = resolveSenderIdentity(await loadSenderProfile(admin, senderId))
  let conversationTitle = (conversation.title as string | null) ?? ""
  if (chatType === "pickup" && conversation.pickup_game_id) {
    const { data: pickup } = await admin
      .from("pickup_games")
      .select("title")
      .eq("id", conversation.pickup_game_id)
      .maybeSingle()
    const pickupTitle = (pickup?.title as string | undefined)?.trim()
    if (pickupTitle) conversationTitle = pickupTitle
  }

  let totalSent = 0
  let totalInvalidated = 0
  let deliveredRecipients = 0

  for (const recipientId of recipientIds) {
    let claim: "claimed" | "exists"
    try {
      claim = await claimDelivery(
        admin,
        "group",
        message.id,
        recipientId,
        conversation.id,
        senderId,
        chatType,
      )
    } catch {
      continue
    }
    if (claim === "exists") continue

    if (teamMutedRecipientIds.has(recipientId)) {
      console.log(
        `${LOG_PREFIX} team_push_muted_skip team_id=${fanTeamId} recipient_user_id=${recipientId} ` +
          `conversation_id=${conversation.id} message_id=${message.id}`,
      )
      await finalizeDelivery(admin, "group", message.id, recipientId, "skipped", "team_push_muted", 0)
      continue
    }

    const { data: prefs } = await admin
      .from("user_notification_preferences")
      .select(
        "group_chat_notifications_enabled,pickup_chat_notifications_enabled,direct_message_preview_mode",
      )
      .eq("user_id", recipientId)
      .maybeSingle()

    const enabled = chatType === "pickup"
      ? prefs?.pickup_chat_notifications_enabled !== false
      : prefs?.group_chat_notifications_enabled !== false

    if (!enabled) {
      await finalizeDelivery(admin, "group", message.id, recipientId, "skipped", "prefs_disabled", 0)
      continue
    }

    const previewMode = normalizePreviewMode(prefs?.direct_message_preview_mode)
    const alert = buildGroupChatPushAlert({
      conversationTitle,
      senderDisplayName: senderIdentity.displayName,
      senderHandle: senderIdentity.handle,
      hasExplicitDisplayName: senderIdentity.hasExplicitDisplayName,
      body: message.body as string,
      previewMode,
      titleFallback: chatType === "pickup" ? "Pickup Chat" : "Group Chat",
    })

    const customData: Record<string, string> = {
      source: "chat_message",
      type: "chat_message",
      chat_type: chatType,
      conversation_id: conversation.id,
      message_id: message.id,
      sender_id: senderId,
      conversation_title: alert.title,
    }
    appendSenderIdentityToPayload(customData, senderIdentity)
    if (conversation.pickup_game_id) {
      customData.pickup_game_id = conversation.pickup_game_id as string
    }

    try {
      const { sent, invalidated } = await sendToRecipientTokens(
        admin,
        apns,
        recipientId,
        senderId,
        alert,
        customData,
      )
      totalSent += sent
      totalInvalidated += invalidated
      if (sent > 0) {
        deliveredRecipients += 1
        await finalizeDelivery(admin, "group", message.id, recipientId, "sent", null, sent)
      } else {
        await finalizeDelivery(admin, "group", message.id, recipientId, "failed", "apns_send_failed", 0)
      }
    } catch (error) {
      console.error(`${LOG_PREFIX} group_send_failed recipient=${recipientId}`, error)
      await finalizeDelivery(admin, "group", message.id, recipientId, "failed", "token_lookup_failed", 0)
    }
  }

  console.log(
    `${LOG_PREFIX} group done messageId=${message.id} chatType=${chatType} ` +
      `recipients=${recipientIds.length} delivered=${deliveredRecipients} sent=${totalSent} invalidated=${totalInvalidated}`,
  )

  return json({
    ok: true,
    sent: totalSent,
    invalidated: totalInvalidated,
    recipients: recipientIds.length,
    delivered_recipients: deliveredRecipients,
    chat_type: chatType,
    message_id: message.id,
  })
}

/**
 * Unified chat message push entrypoint used by notify-chat-message and
 * the notify-direct-message compatibility adapter.
 */
export async function handleChatMessagePushRequest(
  req: Request,
  options?: { forceMessageSource?: "direct" | "group" },
): Promise<Response> {
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405)
  }

  const supabaseUrl = Deno.env.get("PROJECT_URL")?.trim()
    ?? Deno.env.get("SUPABASE_URL")?.trim()
    ?? ""
  const adminApiKey = readAdminApiKey()
  const cronEnvNames = [
    "CHAT_MESSAGE_PUSH_CRON_SECRET",
    "DIRECT_MESSAGE_PUSH_CRON_SECRET",
  ]
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
    sportsWorkerAuthLog("ChatMessagePush", "unauthorized", {
      reason: invocation.reason,
      attempted,
    })
    return json({ error: "unauthorized" }, 401)
  }
  sportsWorkerAuthLog("ChatMessagePush", "authorized", {
    source: invocation.source,
    attempted,
  })

  let payload: ChatMessagePushPayload
  try {
    payload = await req.json()
  } catch {
    return json({ error: "invalid_json" }, 400)
  }

  const messageId = payload.message_id?.trim() ?? ""
  if (!messageId || !isUuid(messageId)) {
    return json({ error: "missing_fields" }, 400)
  }

  const rawSource = (options?.forceMessageSource
    ?? payload.message_source
    ?? payload.chat_type
    ?? "direct").toString().trim().toLowerCase()

  const messageSource: "direct" | "group" =
    rawSource === "group" || rawSource === "pickup" ? "group" : "direct"

  const admin = createClient(supabaseUrl, adminApiKey)

  let apns: ApnsClient
  try {
    apns = await ApnsClient.fromEnvironment()
  } catch (error) {
    console.error(`${LOG_PREFIX} apns_config_failed`, error)
    return json({ error: "apns_misconfigured" }, 500)
  }

  if (messageSource === "group") {
    return await handleGroupMessage(admin, apns, messageId)
  }
  return await handleDirectMessage(admin, apns, messageId)
}
