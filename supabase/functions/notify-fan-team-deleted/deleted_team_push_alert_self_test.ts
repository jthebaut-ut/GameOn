/**
 * Run: deno test deleted_team_push_alert_self_test.ts
 */
import { buildDeletedTeamAlert } from "./deleted_team_push_alert.ts"

function assert(cond: unknown, msg: string): void {
  if (!cond) throw new Error(msg)
}

Deno.test("deletion copy is lifecycle-accurate", () => {
  const alert = buildDeletedTeamAlert("JT")
  assert(alert.title === "Team deleted", "title")
  assert(alert.body === "Team JT was deleted by the Team owner.", "body")
  assert(!alert.body.toLowerCase().includes("you've been removed"), "not membership-removal wording")
})

Deno.test("empty team name falls back", () => {
  const alert = buildDeletedTeamAlert("  ")
  assert(alert.body === "Team was deleted by the Team owner.", "fallback body")
})

if (import.meta.main) {
  const a = buildDeletedTeamAlert("JT")
  assert(a.title === "Team deleted", "main title")
  console.log("[FanTeamDeletedPushAlert] ALL PASSED")
}
