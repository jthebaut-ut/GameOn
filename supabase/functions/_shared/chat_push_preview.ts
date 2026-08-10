export type ChatPreviewMode = "always" | "when_unlocked" | "never"

export type PushAlertContent = {
  title: string
  body: string
}

export type ChatPushKind = "direct" | "venue" | "group" | "pickup"

export type SenderIdentity = {
  /** Title-safe display name (never empty). */
  displayName: string
  /** Normalized handle including a single leading `@`, or null when absent. */
  handle: string | null
  /** Username without `@` for payload metadata, or null. */
  username: string | null
  /** Public https avatar URL when safely usable, else null. */
  avatarURL: string | null
  /** True when a non-empty display_name was present on the profile. */
  hasExplicitDisplayName: boolean
}

const PREVIEW_MAX = 110

/** Structured chat sentinels mirrored from iOS FanGeoStructuredChatKind. */
const STRUCTURED_PREVIEWS: Array<{ needle: string; label: string }> = [
  { needle: "__FG_LOCATION_SHARE_V1__", label: "Shared a location" },
  { needle: "__FG_LIVE_LOCATION_V1__", label: "Shared a live location" },
  { needle: "__FG_ON_MY_WAY_V1__", label: "Shared an On My Way update" },
  { needle: "__FG_POLL_V1__", label: "Created a poll" },
  { needle: "__FG_PROFILE_SHARE_V1__", label: "Shared a profile" },
  { needle: "__FG_PICKUP_SHARE_V1__", label: "Shared a pickup game" },
  { needle: "__FG_PRO_SHARE_V1__", label: "Shared a pro game" },
  { needle: "__FG_VENUE_SHARE_V1__", label: "Shared a venue" },
  { needle: "__FG_IMAGE_V1__", label: "Sent a photo" },
  { needle: "__FG_PHOTO_V1__", label: "Sent a photo" },
  { needle: "__FG_VIDEO_V1__", label: "Sent a video" },
  { needle: "__FG_VOICE_V1__", label: "Sent a voice message" },
  { needle: "__FG_PICKUP_INVITE_V1__", label: "Invited you to a pickup game" },
]

export function sanitizeSenderDisplayName(raw: string | null | undefined): string {
  const trimmed = String(raw ?? "").replace(/\s+/g, " ").trim()
  if (!trimmed) return "FanGeo User"
  return trimmed.slice(0, 64)
}

export function sanitizeConversationTitle(raw: string | null | undefined, fallback: string): string {
  const trimmed = String(raw ?? "").replace(/\s+/g, " ").trim()
  if (!trimmed) return fallback
  return trimmed.slice(0, 64)
}

/** Normalize username to a single `@handle`, or null when blank. */
export function normalizeSenderHandle(raw: string | null | undefined): string | null {
  const stripped = String(raw ?? "").trim().replace(/^@+/, "").trim()
  if (!stripped) return null
  return `@${stripped.slice(0, 63)}`
}

export function sanitizePublicAvatarURL(raw: string | null | undefined): string | null {
  const value = String(raw ?? "").trim()
  if (!value) return null
  if (!/^https:\/\//i.test(value)) return null
  if (value.length > 512) return null
  return value
}

export function resolveSenderIdentity(profile: {
  display_name?: string | null
  username?: string | null
  avatar_url?: string | null
  avatar_thumbnail_url?: string | null
  is_deleted?: boolean | null
} | null): SenderIdentity {
  if (!profile || profile.is_deleted) {
    return {
      displayName: "FanGeo User",
      handle: null,
      username: null,
      avatarURL: null,
      hasExplicitDisplayName: false,
    }
  }

  const handle = normalizeSenderHandle(profile.username)
  const username = handle ? handle.slice(1) : null
  const displayRaw = String(profile.display_name ?? "").replace(/\s+/g, " ").trim()
  const hasExplicitDisplayName = displayRaw.length > 0
  const displayName = sanitizeSenderDisplayName(
    displayRaw || username || "FanGeo User",
  )
  const avatarURL = sanitizePublicAvatarURL(profile.avatar_thumbnail_url)
    ?? sanitizePublicAvatarURL(profile.avatar_url)

  return { displayName, handle, username, avatarURL, hasExplicitDisplayName }
}

export function structuredMessagePreview(body: string): string | null {
  for (const entry of STRUCTURED_PREVIEWS) {
    if (body.includes(entry.needle)) return entry.label
  }
  return null
}

export function sanitizeTextMessagePreview(body: string, maxLength = PREVIEW_MAX): string {
  const collapsed = String(body ?? "")
    .replace(/\s+/g, " ")
    .trim()
  if (!collapsed) return "New message"
  if (collapsed.length <= maxLength) return collapsed
  const slice = collapsed.slice(0, Math.max(1, maxLength - 1)).trimEnd()
  return `${slice}…`
}

function clampBody(body: string, maxLength = PREVIEW_MAX): string {
  const collapsed = String(body ?? "").replace(/\s+/g, " ").trim()
  if (!collapsed) return "New message"
  if (collapsed.length <= maxLength) return collapsed
  return `${collapsed.slice(0, Math.max(1, maxLength - 1)).trimEnd()}…`
}

/**
 * DM title: "Miriam (@miriam)" | "Miriam" | "@miriam" | "FanGeo User"
 * When display_name is absent, show @handle only (never "miriam (@miriam)").
 */
export function formatDirectPushTitle(
  displayName: string,
  handle: string | null | undefined,
  hasExplicitDisplayName = true,
): string {
  const h = normalizeSenderHandle(handle)
  const rawName = String(displayName ?? "").replace(/\s+/g, " ").trim()
  const name = rawName ? rawName.slice(0, 64) : ""

  // Username-only / missing profile → title is the handle (or FanGeo User).
  if (!hasExplicitDisplayName || !name || name === "FanGeo User") {
    if (h) return h
    return name || "FanGeo User"
  }

  if (h) return `${name} (${h})`
  return name
}

/**
 * Group/venue/pickup body speaker: prefer display name; fall back to @handle.
 * Example: "Jonathan" or "@jtapple"
 */
export function formatGroupBodySender(
  displayName: string,
  handle: string | null | undefined,
  hasExplicitDisplayName = true,
): string {
  const h = normalizeSenderHandle(handle)
  const rawName = String(displayName ?? "").replace(/\s+/g, " ").trim()
  const name = rawName ? rawName.slice(0, 64) : ""

  if (hasExplicitDisplayName && name && name !== "FanGeo User") {
    return name
  }
  if (h) return h
  if (name) return name
  return "FanGeo User"
}

function resolveContentBody(body: string, previewMode: ChatPreviewMode): string {
  if (previewMode === "never") return "New message"
  const structured = structuredMessagePreview(body)
  if (structured) return structured
  return sanitizeTextMessagePreview(body)
}

/**
 * Direct DM alert (iMessage-style):
 * title = "Miriam (@miriam)"
 * body  = message preview | structured action | "New message"
 */
export function buildDirectChatPushAlert(args: {
  senderDisplayName: string
  senderHandle?: string | null
  body: string
  previewMode?: ChatPreviewMode
  hasExplicitDisplayName?: boolean
}): PushAlertContent {
  const previewMode = args.previewMode ?? "always"
  const title = formatDirectPushTitle(
    args.senderDisplayName,
    args.senderHandle,
    args.hasExplicitDisplayName ?? true,
  )
  return {
    title,
    body: clampBody(resolveContentBody(args.body, previewMode)),
  }
}

/**
 * Group / pickup / venue alert:
 * title = conversation name
 * body  = "Jonathan: Hello" | "Jonathan: Shared a live location" | "Jonathan: New message"
 */
export function buildGroupChatPushAlert(args: {
  conversationTitle: string
  senderDisplayName: string
  senderHandle?: string | null
  body: string
  previewMode?: ChatPreviewMode
  titleFallback?: string
  hasExplicitDisplayName?: boolean
}): PushAlertContent {
  const title = sanitizeConversationTitle(
    args.conversationTitle,
    args.titleFallback ?? "Group Chat",
  )
  const sender = formatGroupBodySender(
    args.senderDisplayName,
    args.senderHandle,
    args.hasExplicitDisplayName ?? true,
  )
  const previewMode = args.previewMode ?? "always"
  const content = resolveContentBody(args.body, previewMode)
  return {
    title,
    body: clampBody(`${sender}: ${content}`),
  }
}

/**
 * Friend request:
 * title = "New Friend Request"
 * body  = "Miriam (@miriam) wants to connect with you."
 */
export function buildFriendRequestPushAlert(args: {
  requesterDisplayName: string
  requesterHandle?: string | null
  hasExplicitDisplayName?: boolean
}): PushAlertContent {
  const person = formatDirectPushTitle(
    args.requesterDisplayName,
    args.requesterHandle,
    args.hasExplicitDisplayName ?? true,
  )
  return {
    title: "New Friend Request",
    body: clampBody(`${person} wants to connect with you.`),
  }
}

/**
 * Fan Team invitation (poke-style identity title):
 * title = "Jennifer (@jennifer)" | "Jennifer" | "@jennifer" | "FanGeo User"
 * body  = "Invited you to join Team A"
 *
 * Inviter identity and team name must come from authoritative backend rows —
 * never from client-supplied display strings.
 */
export function buildFanTeamInvitationPushAlert(args: {
  inviterDisplayName: string
  inviterHandle?: string | null
  teamName: string
  hasExplicitDisplayName?: boolean
}): PushAlertContent {
  const title = formatDirectPushTitle(
    args.inviterDisplayName,
    args.inviterHandle,
    args.hasExplicitDisplayName ?? true,
  )
  const team = sanitizeConversationTitle(args.teamName, "your Team")
  return {
    title,
    body: clampBody(`Invited you to join ${team}`),
  }
}

/**
 * Profile poke (iMessage-style social):
 * title = "Michiel (@michiel)" | "Michiel" | "@michiel" | "FanGeo User"
 * body  = "Poked you 👋"
 */
export function buildPokePushAlert(args: {
  senderDisplayName: string
  senderHandle?: string | null
  hasExplicitDisplayName?: boolean
}): PushAlertContent {
  const title = formatDirectPushTitle(
    args.senderDisplayName,
    args.senderHandle,
    args.hasExplicitDisplayName ?? true,
  )
  return {
    title,
    body: "Poked you 👋",
  }
}

/** @deprecated Prefer buildDirectChatPushAlert — kept for adapters/tests. */
export function buildMessagePreviewBody(
  body: string,
  previewMode: ChatPreviewMode,
): string {
  return resolveContentBody(body, previewMode)
}

/** @deprecated Prefer buildDirectChatPushAlert */
export function buildDirectStylePushAlert(args: {
  senderDisplayName: string
  senderHandle?: string | null
  body: string
  previewMode?: ChatPreviewMode
  hasExplicitDisplayName?: boolean
}): PushAlertContent {
  return buildDirectChatPushAlert(args)
}

/** @deprecated Prefer buildGroupChatPushAlert */
export function buildGroupStylePushAlert(args: {
  conversationTitle: string
  senderDisplayName: string
  senderHandle?: string | null
  body: string
  previewMode?: ChatPreviewMode
  titleFallback?: string
  hasExplicitDisplayName?: boolean
}): PushAlertContent {
  return buildGroupChatPushAlert(args)
}

// Backward-compatible aliases used by existing DM self-tests / adapters.
export type DmPreviewMode = ChatPreviewMode
export const buildDirectMessagePushBody = buildMessagePreviewBody
export const buildDirectMessagePushAlert = buildDirectChatPushAlert
