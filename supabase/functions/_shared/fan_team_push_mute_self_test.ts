/**
 * Run: deno test fan_team_push_mute_self_test.ts
 *   or: deno run fan_team_push_mute_self_test.ts
 */
import { mutedUserIdSet } from "./fan_team_push_mute.ts"

function assert(cond: unknown, msg: string): void {
  if (!cond) throw new Error(msg)
}

Deno.test("mutedUserIdSet collects unique ids", () => {
  const set = mutedUserIdSet([
    { user_id: "aaa" },
    { user_id: "bbb" },
    { user_id: "aaa" },
    { user_id: "  " },
    { user_id: null },
    null,
  ])
  assert(set.size === 2, "size")
  assert(set.has("aaa") && set.has("bbb"), "members")
})

Deno.test("mutedUserIdSet empty inputs", () => {
  assert(mutedUserIdSet(null).size === 0, "null")
  assert(mutedUserIdSet(undefined).size === 0, "undefined")
  assert(mutedUserIdSet([]).size === 0, "empty")
})

if (import.meta.main) {
  assert(mutedUserIdSet([{ user_id: "x" }]).has("x"), "main")
  console.log("[FanTeamPushMute] ALL PASSED")
}
