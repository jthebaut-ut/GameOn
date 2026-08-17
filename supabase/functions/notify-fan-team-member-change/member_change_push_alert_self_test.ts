import { buildMemberChangePushAlert, memberChangePushAlertSelfTest } from "./member_change_push_alert.ts"

memberChangePushAlertSelfTest()

const zh = buildMemberChangePushAlert({
  kind: "player_number_changed",
  teamName: "JT",
  locale: "zh-Hans",
  playerNumber: 7,
})
if (!zh.title.includes("JT") || !zh.body.includes("7")) {
  throw new Error("zh_hans_alert_failed")
}

const fr = buildMemberChangePushAlert({
  kind: "preferred_position_set",
  teamName: "JT",
  locale: "fr",
  positionCode: "st",
})
if (!fr.body.includes("ST")) {
  throw new Error("fr_alert_failed")
}

console.log("[FanTeamMemberChangeDebug] alert_self_test_ok")
