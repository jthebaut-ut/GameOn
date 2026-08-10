/**
 * Pure claim state machine for fan_team_invitation_push_deliveries.
 * Queue may pre-insert status='queued' with pg_net_request_id; Edge must not
 * treat that as already_claimed (which would skip APNs).
 */

export type ClaimOutcome = "claimed" | "exists"

/**
 * Resolve claim after inspecting an existing delivery row (if any).
 * - null → caller should INSERT (legacy / race where Edge beat queue insert)
 * - "queued" → Edge may proceed (queue pre-claimed the event_id)
 * - any other status → already processed for this event_id
 */
export function resolveExistingDeliveryClaim(
  existingStatus: string | null | undefined,
): ClaimOutcome | "insert" {
  if (existingStatus == null || existingStatus === "") return "insert"
  if (existingStatus === "queued") return "claimed"
  return "exists"
}
