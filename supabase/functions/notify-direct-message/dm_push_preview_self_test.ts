/**
 * Run: deno run dm_push_preview_self_test.ts
 */
import {
  buildDirectMessagePushAlert,
  sanitizeTextMessagePreview,
  structuredMessagePreview,
} from "./dm_push_preview.ts"

let failures = 0
function expect(condition: boolean, name: string) {
  if (condition) {
    console.log(`PASS ${name}`)
  } else {
    failures += 1
    console.log(`FAIL ${name}`)
  }
}

const textAlert = buildDirectMessagePushAlert({
  senderDisplayName: "Jonathan",
  body: "Hey, are you going to watch the game tonight at my place?",
})
expect(textAlert.title === "Jonathan", "title = sender display name")
expect(textAlert.body.startsWith("Hey, are you going"), "body starts with message")
expect(!textAlert.body.includes("\n"), "body has no newlines")
expect(!textAlert.body.includes("Sent you a message"), "no redundant sent-you-a-message wording")

const withHandle = buildDirectMessagePushAlert({
  senderDisplayName: "Miriam",
  senderHandle: "miriam",
  body: "Hello",
})
expect(withHandle.title === "Miriam (@miriam)", "title includes handle in parentheses")
expect(withHandle.body === "Hello", "body is message only")

const multiline = buildDirectMessagePushAlert({
  senderDisplayName: "Jonathan",
  body: "Line one\n\nLine two\tLine three",
})
expect(multiline.body === "Line one Line two Line three", "multiline normalized")

const long = "x".repeat(200)
const longPreview = sanitizeTextMessagePreview(long, 110)
expect(longPreview.length <= 110, "long preview truncated to <=110")
expect(longPreview.endsWith("…"), "long preview ends with ellipsis")

expect(
  structuredMessagePreview("__FG_LOCATION_SHARE_V1__{}") === "Shared a location",
  "location structured preview",
)
expect(
  structuredMessagePreview("__FG_POLL_V1__{}") === "Created a poll",
  "poll structured preview",
)

const hidden = buildDirectMessagePushAlert({
  senderDisplayName: "Jonathan",
  body: "secret",
  previewMode: "never",
})
expect(hidden.body === "New message", "previewMode never hides body")

const emptyName = buildDirectMessagePushAlert({
  senderDisplayName: "   ",
  body: "Hi",
})
expect(emptyName.title === "FanGeo User", "empty sender falls back")

if (failures === 0) {
  console.log("ALL PASSED")
} else {
  console.log(`FAILURES=${failures}`)
  Deno.exit(1)
}
