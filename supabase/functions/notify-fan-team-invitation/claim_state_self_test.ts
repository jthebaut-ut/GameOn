/**
 * Run: deno test --allow-none claim_state_self_test.ts
 *   or: deno run --allow-none claim_state_self_test.ts
 */
import { resolveExistingDeliveryClaim } from "./claim_state.ts"

function assert(cond: unknown, msg: string): void {
  if (!cond) throw new Error(msg)
}

Deno.test("pre-queued row is claimable (not already_claimed)", () => {
  assert(resolveExistingDeliveryClaim("queued") === "claimed", "queued → claimed")
})

Deno.test("sent/skipped/failed are already processed", () => {
  assert(resolveExistingDeliveryClaim("sent") === "exists", "sent")
  assert(resolveExistingDeliveryClaim("skipped") === "exists", "skipped")
  assert(resolveExistingDeliveryClaim("failed") === "exists", "failed")
})

Deno.test("missing row means insert (legacy path)", () => {
  assert(resolveExistingDeliveryClaim(null) === "insert", "null")
  assert(resolveExistingDeliveryClaim(undefined) === "insert", "undefined")
  assert(resolveExistingDeliveryClaim("") === "insert", "empty")
})

if (import.meta.main) {
  assert(resolveExistingDeliveryClaim("queued") === "claimed", "main queued")
  assert(resolveExistingDeliveryClaim("sent") === "exists", "main sent")
  assert(resolveExistingDeliveryClaim(null) === "insert", "main insert")
  console.log("[FanTeamInvitationClaim] ALL PASSED")
}
