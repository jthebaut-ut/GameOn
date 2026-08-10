/**
 * Run: deno test pickup_game_change_push_alert_self_test.ts
 *   or: deno run pickup_game_change_push_alert_self_test.ts
 */
import {
  buildPickupGameChangePushAlert,
  classifyPickupGameChange,
  formatStartForPush,
} from "./pickup_game_change_push_alert.ts"

let failures = 0
function expect(condition: boolean, name: string) {
  if (condition) {
    console.log(`PASS ${name}`)
  } else {
    failures += 1
    console.log(`FAIL ${name}`)
  }
}

const cancelledWithWhen = buildPickupGameChangePushAlert({
  change_kinds: ["status"],
  payload: {
    title: "Test Teams",
    before_status: "active",
    after_status: "removed",
    after_start: "2026-08-10T14:37:00.000Z",
    is_cancellation: true,
  },
})
expect(cancelledWithWhen.title === "Game cancelled", "cancel title")
expect(
  cancelledWithWhen.body.includes("Test Teams") && cancelledWithWhen.body.includes("was cancelled."),
  "cancel body includes title + cancelled",
)

const cancelledNoWhen = buildPickupGameChangePushAlert({
  change_kinds: ["status"],
  payload: {
    title: "Friday Pickup",
    before_status: "active",
    after_status: "removed",
  },
})
expect(cancelledNoWhen.title === "Game cancelled", "cancel title without when")
expect(cancelledNoWhen.body === "Friday Pickup was cancelled.", "cancel body without when")

const dateChange = buildPickupGameChangePushAlert({
  change_kinds: ["start"],
  payload: {
    title: "Sunday Soccer",
    before_status: "active",
    after_status: "active",
    after_start: "2026-08-16T21:00:00.000Z",
  },
})
expect(dateChange.title === "Schedule changed", "schedule title")
expect(dateChange.body.includes("Sunday Soccer now starts"), "schedule body")
expect(classifyPickupGameChange({ change_kinds: ["start"], payload: {} }) === "time_changed", "class time")

const endOnly = buildPickupGameChangePushAlert({
  change_kinds: ["end"],
  payload: {
    title: "Sunday Soccer",
    after_start: "2026-08-16T21:00:00.000Z",
  },
})
expect(endOnly.title === "Schedule changed", "end-only is schedule")

const locationChange = buildPickupGameChangePushAlert({
  change_kinds: ["location"],
  payload: {
    title: "Team JT",
    after_location: "Jordan River Park",
  },
})
expect(locationChange.title === "Location changed", "location title")
expect(locationChange.body === "Team JT moved to Jordan River Park.", "location body")
expect(
  classifyPickupGameChange({ change_kinds: ["location"], payload: {} }) === "location_changed",
  "class location",
)

const both = buildPickupGameChangePushAlert({
  change_kinds: ["start", "location"],
  payload: {
    title: "Team JT",
    after_start: "2026-08-16T21:00:00.000Z",
    after_location: "Lehi Sports Complex",
  },
})
expect(both.title === "Schedule & location changed", "both title")
expect(
  classifyPickupGameChange({ change_kinds: ["start", "end", "location"], payload: {} })
    === "time_and_location_changed",
  "class both",
)

const formatted = formatStartForPush("2026-08-16T21:00:00.000Z")
expect(formatted.includes(" at "), "format includes at")
expect(formatted.length > 0, "format non-empty")

const alreadyRemoved = buildPickupGameChangePushAlert({
  change_kinds: ["visibility"],
  payload: {
    title: "Old Game",
    before_status: "removed",
    after_status: "removed",
  },
})
expect(alreadyRemoved.title === "Pickup game updated", "already-removed is not cancel alert")

if (failures > 0) {
  console.error(`FAILURES=${failures}`)
  Deno.exit(1)
}
console.log("ALL PASSED")
