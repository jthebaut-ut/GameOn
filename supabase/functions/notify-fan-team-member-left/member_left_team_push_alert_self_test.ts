import { buildMemberLeftTeamAlert, memberLeftTeamAlertSelfTest } from "./member_left_team_push_alert.ts"

memberLeftTeamAlertSelfTest()

const zh = buildMemberLeftTeamAlert({
  teamName: "JT",
  leftDisplayName: "Enea",
  locale: "zh-Hans",
})
if (!zh.title.includes("JT") || !zh.body.includes("Enea")) {
  throw new Error("zh_hans_alert_failed")
}

console.log("[FanTeamMemberLeaveDebug] alert_self_test_ok")
