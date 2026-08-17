/**
 * Run: deno test pickup_game_change_push_alert_self_test.ts
 *   or: deno run pickup_game_change_push_alert_self_test.ts
 *
 * Auth for this worker is authorizeSportsWorkerRequest (not a local
 * SERVICE_ROLE_KEY-only compare). Dual-key cases live in
 * ../_shared/sports_worker_auth_test.ts.
 */
import {
  buildPickupGameChangePushAlert,
  buildTeamGameCreatedPushAlert,
  buildTeamAnnouncementPushAlert,
  classifyPickupGameChange,
  formatStartForPush,
  isFanTeamGameCreatePushFormat,
  isFanTeamScheduleCreatePushFormat,
  isJoinRequestDecisionType,
  isTeamEventScoreNotificationType,
  teamEventTypeLabel,
  teamEventTypeShortNoun,
  teamGameCreatedMatchup,
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

// --- Team-linked copy (taxonomy-aware) ---
const teamCtx = {
  teamId: "11111111-1111-1111-1111-111111111111",
  teamName: "JT",
  eventTitle: "JT vs Eagles",
  gameFormat: "league_game",
}

const teamCreated = buildPickupGameChangePushAlert(
  {
    change_kinds: ["created"],
    payload: {
      title: "Should not invent opponent from title",
      after_opponent: "Eagles",
      after_start: "2026-08-20T00:30:00.000Z",
      notification_type: "team_game_created",
      is_team_game_created: true,
      matchup: "JT vs Eagles",
    },
  },
  teamCtx,
)
expect(teamCreated.title === "JT · New Game", "team create title")
expect(
  teamCreated.body.startsWith("JT vs Eagles") && teamCreated.body.includes("—"),
  "team create body uses opponent field matchup",
)
expect(
  classifyPickupGameChange({
    change_kinds: ["created"],
    payload: { notification_type: "team_game_created" },
  }) === "created",
  "class created",
)
expect(isFanTeamGameCreatePushFormat("league_game"), "format league_game")
expect(isFanTeamGameCreatePushFormat("scrimmage"), "format scrimmage")
expect(!isFanTeamGameCreatePushFormat("practice"), "format practice not competitive")
expect(!isFanTeamGameCreatePushFormat("tryout"), "format tryout not competitive")
expect(isFanTeamScheduleCreatePushFormat("practice"), "schedule format practice")
expect(isFanTeamScheduleCreatePushFormat("team_meeting"), "schedule format meeting")
expect(!isFanTeamScheduleCreatePushFormat("announcement"), "announcement not schedule-create")
expect(teamGameCreatedMatchup("JT", "Eagles") === "JT vs Eagles", "matchup builder")

const practiceCreated = buildTeamGameCreatedPushAlert({
  teamName: "JT",
  gameFormat: "practice",
  afterStart: "2026-08-20T00:30:00.000Z",
  locale: "en",
})
expect(practiceCreated.title === "JT · New Practice", "practice create title")
expect(practiceCreated.body.includes("Practice"), "practice create body type")
expect(practiceCreated.body.includes("scheduled"), "practice create body schedule")

const meetingCreated = buildPickupGameChangePushAlert(
  {
    change_kinds: ["created"],
    payload: {
      title: "Weekly Check-in",
      notification_type: "team_event_created",
      is_team_event_created: true,
      game_format: "team_meeting",
      after_start: "2026-08-20T00:30:00.000Z",
    },
  },
  { ...teamCtx, eventTitle: "Weekly Check-in", gameFormat: "team_meeting" },
)
expect(meetingCreated.title.includes("Meeting") || meetingCreated.title.includes("Team Meeting"), "meeting create title")
expect(
  classifyPickupGameChange({
    change_kinds: ["created"],
    payload: { notification_type: "team_event_created" },
  }) === "created",
  "class team_event_created",
)

const esCreated = buildTeamGameCreatedPushAlert({
  teamName: "JT",
  gameFormat: "league_game",
  opponent: "Eagles",
  afterStart: "2026-08-20T00:30:00.000Z",
  locale: "es",
})
expect(esCreated.title === "JT · Nuevo partido", "es create title")
expect(esCreated.body.includes("JT vs Eagles"), "es create matchup")

const announcementPush = buildPickupGameChangePushAlert(
  {
    change_kinds: ["created"],
    payload: {
      title: "Practice Location Changed",
      description_preview: "Tonight’s practice has been moved to Field 3.",
      notification_type: "team_announcement",
      is_team_announcement: true,
      game_format: "announcement",
    },
  },
  { ...teamCtx, eventTitle: "Practice Location Changed", gameFormat: "announcement" },
)
expect(announcementPush.title === "JT · Announcement", "announcement title")
expect(
  announcementPush.body.includes("Practice Location Changed")
    && announcementPush.body.includes("Field 3"),
  "announcement body",
)
expect(!isFanTeamGameCreatePushFormat("announcement"), "announcement not game-create format")

const teamSchedule = buildPickupGameChangePushAlert(
  {
    change_kinds: ["start"],
    payload: {
      title: "JT vs Eagles",
      after_start: "2026-08-12T00:30:00.000Z",
      rsvp_reset_required: true,
    },
  },
  teamCtx,
)
expect(teamSchedule.title === "League Game time changed", "team schedule title")
expect(
  teamSchedule.body.includes("JT · JT vs Eagles")
    && teamSchedule.body.includes("confirm your attendance again"),
  "team schedule body has Team · Game + reconfirm",
)

const teamLocation = buildPickupGameChangePushAlert(
  {
    change_kinds: ["location"],
    payload: {
      title: "JT vs Eagles",
      after_location: "Field 3",
    },
  },
  teamCtx,
)
expect(teamLocation.title === "League Game location changed", "team location title")
expect(
  teamLocation.body.includes("JT · JT vs Eagles") && teamLocation.body.includes("Field 3"),
  "team location body has Team · Game + new place",
)
expect(!teamLocation.body.includes("confirm your attendance"), "location keeps RSVP copy")

const teamBoth = buildPickupGameChangePushAlert(
  {
    change_kinds: ["start", "end", "location"],
    payload: {
      title: "JT vs Eagles",
      after_start: "2026-08-12T00:30:00.000Z",
      after_location: "Field 3",
      rsvp_reset_required: true,
    },
  },
  teamCtx,
)
expect(teamBoth.title === "League Game updated", "team multi title")
expect(
  teamBoth.body.includes("JT · JT vs Eagles") && teamBoth.body.includes("Field 3")
    && teamBoth.body.includes("confirm your attendance again"),
  "team multi body",
)

const teamCancel = buildPickupGameChangePushAlert(
  {
    change_kinds: ["status"],
    payload: {
      title: "JT vs Eagles",
      before_status: "active",
      after_status: "removed",
      after_start: "2026-08-12T00:30:00.000Z",
    },
  },
  teamCtx,
)
expect(teamCancel.title === "League Game cancelled", "team cancel title")
expect(teamCancel.body.includes("JT · JT vs Eagles"), "team cancel body has identity")

expect(
  classifyPickupGameChange({
    change_kinds: ["status"],
    payload: { before_status: "active", after_status: "cancelled" },
  }) === "cancelled",
  "cancelled status class",
)

expect(teamEventTypeLabel("practice", "") === "Practice", "type practice")
expect(teamEventTypeLabel("team_meeting", "") === "Team Meeting", "type meeting")
expect(teamEventTypeLabel("other", "Custom Night") === "Event", "type other uses map before title")
expect(teamEventTypeLabel("", "Custom Night") === "Custom Night", "type empty falls back to title")
expect(teamEventTypeShortNoun("practice") === "Practice", "short practice")
expect(teamEventTypeShortNoun("league_game") === "Game", "short game")

const practiceCtx = { ...teamCtx, eventTitle: "", gameFormat: "practice" }
const practicePush = buildPickupGameChangePushAlert(
  {
    change_kinds: ["start"],
    payload: { after_start: "2026-08-12T00:30:00.000Z", rsvp_reset_required: true },
  },
  practiceCtx,
)
expect(practicePush.title === "Practice time changed", "practice title")
expect(practicePush.body.includes("JT · Practice"), "practice taxonomy in body")

const meetingCtx = { ...teamCtx, eventTitle: "", gameFormat: "team_meeting" }
const meetingPush = buildPickupGameChangePushAlert(
  {
    change_kinds: ["location"],
    payload: { after_location: "Clubhouse" },
  },
  meetingCtx,
)
expect(
  meetingPush.title === "Team Meeting location changed"
    && meetingPush.body.includes("Clubhouse"),
  "meeting taxonomy in body",
)

expect(isJoinRequestDecisionType("join_request_approved"), "join approved type")
expect(isJoinRequestDecisionType("join_request_rejected"), "join rejected type")
expect(!isJoinRequestDecisionType("time_changed"), "time change is not join decision")

const joinApproved = buildPickupGameChangePushAlert({
  change_kinds: ["join_request_decision"],
  payload: {
    notification_type: "join_request_approved",
    title: "Friday Night Practice",
    recipient_user_ids: ["00000000-0000-4000-8000-000000000001"],
  },
})
expect(joinApproved.title === "Your request to join", "join approved title")
expect(
  joinApproved.body === "Friday Night Practice was approved.",
  "join approved body names the event",
)

const joinRejected = buildPickupGameChangePushAlert({
  change_kinds: ["join_request_decision"],
  payload: {
    notification_type: "join_request_rejected",
    title: "Friday Night Practice",
  },
})
expect(joinRejected.title === "Your request to join", "join rejected title")
expect(
  joinRejected.body === "Friday Night Practice was declined.",
  "join rejected body names the event",
)

expect(isTeamEventScoreNotificationType("team_event_scored"), "score type")
expect(isTeamEventScoreNotificationType("team_event_final"), "final type")
expect(!isTeamEventScoreNotificationType("team_game_created"), "create is not score")

const scored = buildPickupGameChangePushAlert({
  change_kinds: ["team_event_scored"],
  payload: {
    notification_type: "team_event_scored",
    team_name: "Sandy Strikers",
    after_opponent: "Riverton FC",
    team_score: 3,
    opponent_score: 2,
    score_line: "Sandy Strikers 3 – 2 Riverton FC",
  },
})
expect(scored.title === "Sandy Strikers scored", "score increment title")
expect(scored.body === "Sandy Strikers 3 – 2 Riverton FC", "score increment body")

const soccerGoal = buildPickupGameChangePushAlert({
  change_kinds: ["team_event_scored"],
  payload: {
    notification_type: "team_event_scored",
    team_name: "Sandy Strikers",
    after_opponent: "Riverton FC",
    team_score: 3,
    opponent_score: 2,
    score_line: "Sandy Strikers 3 – 2 Riverton FC",
    scorer_display_name: "Amelia Martin",
    scorer_attribution_kind: "goal",
    sport: "Soccer",
  },
})
expect(soccerGoal.title === "Goal — Amelia Martin", "soccer scorer title")
expect(soccerGoal.body === "Sandy Strikers 3 – 2 Riverton FC", "soccer scorer body")

const hockeyGoal = buildPickupGameChangePushAlert({
  change_kinds: ["team_event_scored"],
  payload: {
    notification_type: "team_event_scored",
    team_name: "Sandy Ice",
    score_line: "Sandy Ice 2 – 1 Riverton",
    scorer_display_name: "Amelia Martin",
    sport: "NHL",
  },
})
expect(hockeyGoal.title === "Goal — Amelia Martin", "hockey scorer title")

const baseballRun = buildPickupGameChangePushAlert({
  change_kinds: ["team_event_scored"],
  payload: {
    notification_type: "team_event_scored",
    team_name: "Sandy Sluggers",
    score_line: "Sandy Sluggers 5 – 3 Riverton",
    scorer_display_name: "Amelia Martin",
    scorer_attribution_kind: "run",
    sport: "Baseball",
  },
})
expect(baseballRun.title === "Run scored — Amelia Martin", "baseball run title")

const basketballScore = buildPickupGameChangePushAlert({
  change_kinds: ["team_event_scored"],
  payload: {
    notification_type: "team_event_scored",
    team_name: "Sandy Hoops",
    score_line: "Sandy Hoops 44 – 41 Riverton",
    scorer_display_name: "Amelia Martin",
    scorer_attribution_kind: "score",
    sport: "NBA",
  },
})
expect(basketballScore.title === "Amelia Martin scored", "basketball scorer title")

const footballScore = buildPickupGameChangePushAlert({
  change_kinds: ["team_event_scored"],
  payload: {
    notification_type: "team_event_scored",
    team_name: "Sandy Football",
    score_line: "Sandy Football 14 – 7 Riverton",
    scorer_display_name: "Amelia Martin",
    scorer_attribution_kind: "touchdown_or_score",
    sport: "NFL",
  },
})
expect(footballScore.title === "Score — Amelia Martin", "football scorer title")

const skipScorer = buildPickupGameChangePushAlert({
  change_kinds: ["team_event_scored"],
  payload: {
    notification_type: "team_event_scored",
    team_name: "Sandy Strikers",
    score_line: "Sandy Strikers 2 – 0 Opponent",
  },
})
expect(skipScorer.title === "Sandy Strikers scored", "no-scorer fallback")

const decrementPayload = {
  notification_type: "team_event_updated",
  scorer_display_name: "Amelia Martin",
  scorer_attribution_kind: "goal",
}
expect(!isTeamEventScoreNotificationType("team_event_updated"), "decrement is not scored push")
expect(
  buildPickupGameChangePushAlert({
    change_kinds: ["decrement"],
    payload: decrementPayload,
  }).title !== "Goal — Amelia Martin",
  "decrement does not emit scorer push",
)

const correction = buildPickupGameChangePushAlert({
  change_kinds: ["team_event_updated"],
  payload: {
    notification_type: "correct_final",
    scorer_display_name: "Amelia Martin",
  },
})
expect(correction.title !== "Goal — Amelia Martin", "correction does not emit scorer push")

const scorerArtworkFallback = buildPickupGameChangePushAlert({
  change_kinds: ["team_event_scored"],
  payload: {
    notification_type: "team_event_scored",
    team_name: "Sandy Strikers",
    score_line: "Sandy Strikers 1 – 0 Riverton FC",
    scorer_display_name: "Amelia Martin",
    scorer_attribution_kind: "goal",
    scorer_avatar_url: "http://evil.example/avatar.png",
  },
})
expect(scorerArtworkFallback.title === "Goal — Amelia Martin", "untrusted avatar still uses scorer copy")

const finalPush = buildPickupGameChangePushAlert({
  change_kinds: ["team_event_final"],
  payload: {
    notification_type: "team_event_final",
    team_name: "Sandy Strikers",
    score_line: "Sandy Strikers 3 – 2 Riverton FC",
  },
})
expect(finalPush.title === "Final", "final title")
expect(finalPush.body === "Sandy Strikers 3 – 2 Riverton FC", "final body")

if (failures > 0) {
  console.error(`FAILED ${failures}`)
  Deno.exit(1)
}
console.log("ALL PASS")
