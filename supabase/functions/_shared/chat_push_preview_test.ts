/**
 * Notification copy / identity resolution for unified chat push.
 *
 * Run:
 *   deno test supabase/functions/_shared/chat_push_preview_test.ts
 */
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts"
import {
  buildDirectChatPushAlert,
  buildFanTeamInvitationPushAlert,
  buildFriendRequestPushAlert,
  buildGroupChatPushAlert,
  buildPokePushAlert,
  formatDirectPushTitle,
  formatGroupBodySender,
  normalizeSenderHandle,
  resolveSenderIdentity,
  sanitizePublicAvatarURL,
  sanitizeTextMessagePreview,
  structuredMessagePreview,
} from "./chat_push_preview.ts"

Deno.test("1) direct: display name + handle + short text", () => {
  const alert = buildDirectChatPushAlert({
    senderDisplayName: "Jonathan Thebaut",
    senderHandle: "jonathan",
    body: "Are you watching the game tonight?",
  })
  assertEquals(alert.title, "Jonathan Thebaut (@jonathan)")
  assertEquals(alert.body, "Are you watching the game tonight?")
})

Deno.test("2) direct: display name, no handle", () => {
  const alert = buildDirectChatPushAlert({
    senderDisplayName: "Jonathan Thebaut",
    senderHandle: null,
    body: "Hello",
  })
  assertEquals(alert.title, "Jonathan Thebaut")
  assertEquals(alert.body, "Hello")
})

Deno.test("3) direct: long text truncates", () => {
  const alert = buildDirectChatPushAlert({
    senderDisplayName: "Jonathan",
    senderHandle: "@jonathan",
    body: "x".repeat(200),
  })
  assertEquals(alert.body.length <= 110, true)
  assertEquals(alert.body.endsWith("…"), true)
})

Deno.test("4) direct: multiline normalized", () => {
  const alert = buildDirectChatPushAlert({
    senderDisplayName: "Jonathan",
    senderHandle: "jonathan",
    body: "Hey\nthere\tfriend",
  })
  assertEquals(alert.title, "Jonathan (@jonathan)")
  assertEquals(alert.body, "Hey there friend")
})

Deno.test("5) direct: preview mode never hides text", () => {
  const alert = buildDirectChatPushAlert({
    senderDisplayName: "Jonathan",
    senderHandle: "jonathan",
    body: "secret text",
    previewMode: "never",
  })
  assertEquals(alert.title, "Jonathan (@jonathan)")
  assertEquals(alert.body, "New message")
})

Deno.test("6) deleted/missing profile fallback", () => {
  const deleted = resolveSenderIdentity({ is_deleted: true, display_name: "X", username: "y" })
  assertEquals(deleted.displayName, "FanGeo User")
  assertEquals(deleted.handle, null)
  assertEquals(deleted.hasExplicitDisplayName, false)
  const missing = resolveSenderIdentity(null)
  assertEquals(missing.displayName, "FanGeo User")
})

Deno.test("7) username already begins with @", () => {
  assertEquals(normalizeSenderHandle("@@jonathan"), "@jonathan")
  const identity = resolveSenderIdentity({
    display_name: "Jonathan Thebaut",
    username: "@jonathan",
  })
  assertEquals(identity.handle, "@jonathan")
  assertEquals(identity.username, "jonathan")
  assertEquals(identity.hasExplicitDisplayName, true)
})

Deno.test("8) group: title + sender + text", () => {
  const alert = buildGroupChatPushAlert({
    conversationTitle: "Utah Soccer Fans",
    senderDisplayName: "Jonathan",
    senderHandle: "jonathan",
    body: "Anyone going tonight?",
  })
  assertEquals(alert.title, "Utah Soccer Fans")
  assertEquals(alert.body, "Jonathan: Anyone going tonight?")
})

Deno.test("9) group: no handle", () => {
  const alert = buildGroupChatPushAlert({
    conversationTitle: "Utah Soccer Fans",
    senderDisplayName: "Jonathan",
    body: "Hello",
  })
  assertEquals(alert.body, "Jonathan: Hello")
})

Deno.test("10) group: structured location", () => {
  const alert = buildGroupChatPushAlert({
    conversationTitle: "Utah Soccer Fans",
    senderDisplayName: "Jonathan",
    senderHandle: "jonathan",
    body: "__FG_LIVE_LOCATION_V1__{}",
  })
  assertEquals(alert.body, "Jonathan: Shared a live location")
})

Deno.test("11) group: poll", () => {
  const alert = buildGroupChatPushAlert({
    conversationTitle: "Utah Soccer Fans",
    senderDisplayName: "Jonathan",
    senderHandle: "jonathan",
    body: "__FG_POLL_V1__{}",
  })
  assertEquals(alert.body, "Jonathan: Created a poll")
})

Deno.test("12) group: long message clamped", () => {
  const alert = buildGroupChatPushAlert({
    conversationTitle: "Utah Soccer Fans",
    senderDisplayName: "Jonathan",
    senderHandle: "jonathan",
    body: "y".repeat(200),
  })
  assertEquals(alert.body.length <= 110, true)
})

Deno.test("13) pickup: title + sender identity", () => {
  const alert = buildGroupChatPushAlert({
    conversationTitle: "Lehi Friday Pickup",
    senderDisplayName: "Jonathan",
    senderHandle: "jonathan",
    body: "I'll be there in 10 minutes.",
    titleFallback: "Pickup Chat",
  })
  assertEquals(alert.title, "Lehi Friday Pickup")
  assertEquals(alert.body, "Jonathan: I'll be there in 10 minutes.")
})

Deno.test("14) pickup: title fallback", () => {
  const alert = buildGroupChatPushAlert({
    conversationTitle: "",
    senderDisplayName: "Jonathan",
    body: "Hi",
    titleFallback: "Pickup Chat",
  })
  assertEquals(alert.title, "Pickup Chat")
})

Deno.test("15) venue: business title + sender", () => {
  const alert = buildGroupChatPushAlert({
    conversationTitle: "Buffalo Wild Wings",
    senderDisplayName: "Jonathan",
    senderHandle: "jonathan",
    body: "Happy hour starts at 6 PM.",
    titleFallback: "Venue Chat",
  })
  assertEquals(alert.title, "Buffalo Wild Wings")
  assertEquals(alert.body, "Jonathan: Happy hour starts at 6 PM.")
})

Deno.test("16) valid avatar metadata", () => {
  const identity = resolveSenderIdentity({
    display_name: "Jonathan",
    username: "jonathan",
    avatar_thumbnail_url: "https://cdn.example.com/thumb.jpg",
    avatar_url: "https://cdn.example.com/full.jpg",
  })
  assertEquals(identity.avatarURL, "https://cdn.example.com/thumb.jpg")
})

Deno.test("17) no avatar", () => {
  const identity = resolveSenderIdentity({
    display_name: "Jonathan",
    username: "jonathan",
  })
  assertEquals(identity.avatarURL, null)
})

Deno.test("18) broken avatar URL rejected", () => {
  assertEquals(sanitizePublicAvatarURL("not-a-url"), null)
  assertEquals(sanitizePublicAvatarURL("http://insecure.example.com/a.jpg"), null)
})

Deno.test("19/20) avatar enrichment failure does not affect copy", () => {
  const identity = resolveSenderIdentity({
    display_name: "Jonathan",
    username: "jonathan",
    avatar_url: "file:///local/path.jpg",
  })
  assertEquals(identity.avatarURL, null)
  const alert = buildDirectChatPushAlert({
    senderDisplayName: identity.displayName,
    senderHandle: identity.handle,
    hasExplicitDisplayName: identity.hasExplicitDisplayName,
    body: "Still works",
  })
  assertEquals(alert.title, "Jonathan (@jonathan)")
  assertEquals(alert.body, "Still works")
})

Deno.test("sanitizeTextMessagePreview whitespace", () => {
  assertEquals(sanitizeTextMessagePreview("Hey\nthere\tfriend"), "Hey there friend")
})

Deno.test("direct: handle-only title when display missing", () => {
  const identity = resolveSenderIdentity({
    display_name: "",
    username: "miriam",
  })
  const alert = buildDirectChatPushAlert({
    senderDisplayName: identity.displayName,
    senderHandle: identity.handle,
    hasExplicitDisplayName: identity.hasExplicitDisplayName,
    body: "Hello",
  })
  assertEquals(alert.title, "@miriam")
  assertEquals(alert.body, "Hello")
})

Deno.test("direct: structured poll / photo / voice", () => {
  assertEquals(structuredMessagePreview("__FG_POLL_V1__{}"), "Created a poll")
  assertEquals(structuredMessagePreview("__FG_IMAGE_V1__{}"), "Sent a photo")
  assertEquals(structuredMessagePreview("__FG_VIDEO_V1__{}"), "Sent a video")
  assertEquals(structuredMessagePreview("__FG_VOICE_V1__{}"), "Sent a voice message")
  assertEquals(
    structuredMessagePreview("__FG_PICKUP_INVITE_V1__{}"),
    "Invited you to a pickup game",
  )
  const alert = buildDirectChatPushAlert({
    senderDisplayName: "Miriam",
    senderHandle: "miriam",
    body: "__FG_LIVE_LOCATION_V1__{}",
  })
  assertEquals(alert.title, "Miriam (@miriam)")
  assertEquals(alert.body, "Shared a live location")
})

Deno.test("group: handle-only sender when display missing", () => {
  const alert = buildGroupChatPushAlert({
    conversationTitle: "Utah Soccer Fans",
    senderDisplayName: "jtapple",
    senderHandle: "jtapple",
    hasExplicitDisplayName: false,
    body: "Hello",
  })
  assertEquals(alert.body, "@jtapple: Hello")
})

Deno.test("group: preview never", () => {
  const alert = buildGroupChatPushAlert({
    conversationTitle: "Utah Soccer Fans",
    senderDisplayName: "Jonathan",
    body: "secret",
    previewMode: "never",
  })
  assertEquals(alert.body, "Jonathan: New message")
})

Deno.test("friend request copy", () => {
  const alert = buildFriendRequestPushAlert({
    requesterDisplayName: "Miriam",
    requesterHandle: "miriam",
  })
  assertEquals(alert.title, "New Friend Request")
  assertEquals(alert.body, "Miriam (@miriam) wants to connect with you.")
})

Deno.test("poke: display name + handle", () => {
  const alert = buildPokePushAlert({
    senderDisplayName: "Michiel",
    senderHandle: "michiel",
  })
  assertEquals(alert.title, "Michiel (@michiel)")
  assertEquals(alert.body, "Poked you 👋")
})

Deno.test("poke: display name only", () => {
  const alert = buildPokePushAlert({
    senderDisplayName: "Michiel",
    senderHandle: null,
  })
  assertEquals(alert.title, "Michiel")
  assertEquals(alert.body, "Poked you 👋")
})

Deno.test("poke: handle only", () => {
  const alert = buildPokePushAlert({
    senderDisplayName: "michiel",
    senderHandle: "michiel",
    hasExplicitDisplayName: false,
  })
  assertEquals(alert.title, "@michiel")
  assertEquals(alert.body, "Poked you 👋")
})

Deno.test("poke: deleted/missing fallback", () => {
  const identity = resolveSenderIdentity({ is_deleted: true, display_name: "X", username: "y" })
  const alert = buildPokePushAlert({
    senderDisplayName: identity.displayName,
    senderHandle: identity.handle,
    hasExplicitDisplayName: identity.hasExplicitDisplayName,
  })
  assertEquals(alert.title, "FanGeo User")
  assertEquals(alert.body, "Poked you 👋")
})

Deno.test("team invitation: display name + username", () => {
  const alert = buildFanTeamInvitationPushAlert({
    inviterDisplayName: "Jennifer",
    inviterHandle: "jennifer",
    teamName: "Team A",
  })
  assertEquals(alert.title, "Jennifer (@jennifer)")
  assertEquals(alert.body, "Invited you to join Team A")
})

Deno.test("team invitation: display name only", () => {
  const alert = buildFanTeamInvitationPushAlert({
    inviterDisplayName: "Jennifer",
    inviterHandle: null,
    teamName: "Team A",
  })
  assertEquals(alert.title, "Jennifer")
  assertEquals(alert.body, "Invited you to join Team A")
})

Deno.test("team invitation: username only", () => {
  const alert = buildFanTeamInvitationPushAlert({
    inviterDisplayName: "jennifer",
    inviterHandle: "jennifer",
    teamName: "Team A",
    hasExplicitDisplayName: false,
  })
  assertEquals(alert.title, "@jennifer")
  assertEquals(alert.body, "Invited you to join Team A")
})

Deno.test("team invitation: missing profile identity", () => {
  const identity = resolveSenderIdentity(null)
  const alert = buildFanTeamInvitationPushAlert({
    inviterDisplayName: identity.displayName,
    inviterHandle: identity.handle,
    teamName: "Team A",
    hasExplicitDisplayName: identity.hasExplicitDisplayName,
  })
  assertEquals(alert.title, "FanGeo User")
  assertEquals(alert.body, "Invited you to join Team A")
})

Deno.test("team invitation: long team name truncates cleanly", () => {
  const alert = buildFanTeamInvitationPushAlert({
    inviterDisplayName: "Jennifer",
    inviterHandle: "jennifer",
    teamName: "A".repeat(200),
  })
  assertEquals(alert.title, "Jennifer (@jennifer)")
  assertEquals(alert.body.startsWith("Invited you to join "), true)
  assertEquals(alert.body.length <= 110, true)
  assertEquals(alert.body.includes("\n"), false)
})

Deno.test("title helpers", () => {
  assertEquals(formatDirectPushTitle("Miriam", "@miriam", true), "Miriam (@miriam)")
  assertEquals(formatDirectPushTitle("miriam", "@miriam", false), "@miriam")
  assertEquals(formatGroupBodySender("Jonathan", "@jtapple", true), "Jonathan")
  assertEquals(formatGroupBodySender("jtapple", "@jtapple", false), "@jtapple")
})
