import type { SupabaseClient } from "npm:@supabase/supabase-js@2"

/**
 * Per-Team push mute helpers (fan_team_members.push_notifications_muted).
 *
 * Critical lifecycle pushes (Team deleted) must NOT call these filters.
 * Pending Team invitation push must NOT call these (invitee is not a member).
 * member_left_team DOES call these — respect each Owner/Manager recipient mute.
 * Never use the departed member's mute preference for leadership recipients.
 * member_change: informational kinds (number/position/role) respect mute;
 *   removed_from_team / removed_from_event / added_back_to_event /
 *   team_admin_granted / team_admin_removed ignore mute.
 */

/** Pure: build a Set of muted user ids from membership rows. */
export function mutedUserIdSet(
  rows: Array<{ user_id?: string | null } | null> | null | undefined,
): Set<string> {
  const out = new Set<string>()
  for (const row of rows ?? []) {
    const id = row?.user_id?.trim()
    if (id) out.add(id)
  }
  return out
}

/**
 * Resolve fan_teams.id for a group conversation (Team Chat), if linked.
 */
export async function resolveFanTeamIdForConversation(
  admin: SupabaseClient,
  conversationId: string,
): Promise<string | null> {
  const { data, error } = await admin
    .from("fan_teams")
    .select("id")
    .eq("group_conversation_id", conversationId)
    .eq("is_active", true)
    .maybeSingle()
  if (error) {
    console.error("[FanTeamPushMute] conversation_team_lookup_failed", error)
    return null
  }
  return (data as { id?: string } | null)?.id ?? null
}

/**
 * Active members among `userIds` who muted Team push for `teamId`.
 */
export async function loadMutedFanTeamMemberIds(
  admin: SupabaseClient,
  teamId: string,
  userIds: string[],
): Promise<Set<string>> {
  if (!teamId || userIds.length === 0) return new Set()
  const { data, error } = await admin
    .from("fan_team_members")
    .select("user_id")
    .eq("team_id", teamId)
    .eq("push_notifications_muted", true)
    .is("left_at", null)
    .in("user_id", userIds)
  if (error) {
    console.error("[FanTeamPushMute] muted_members_lookup_failed", error)
    return new Set()
  }
  return mutedUserIdSet(data as Array<{ user_id?: string | null }>)
}

/**
 * Users who muted ANY Team linked to this pickup game via fan_team_game_links.
 */
export async function loadMutedUserIdsForPickupGame(
  admin: SupabaseClient,
  pickupGameId: string,
  userIds: string[],
): Promise<Set<string>> {
  if (!pickupGameId || userIds.length === 0) return new Set()

  const { data: links, error: linksError } = await admin
    .from("fan_team_game_links")
    .select("team_id")
    .eq("pickup_game_id", pickupGameId)

  if (linksError) {
    console.error("[FanTeamPushMute] pickup_team_links_lookup_failed", linksError)
    return new Set()
  }

  const teamIds = [
    ...new Set(
      (links ?? [])
        .map((row) => (row as { team_id?: string }).team_id?.trim())
        .filter((id): id is string => Boolean(id)),
    ),
  ]
  if (teamIds.length === 0) return new Set()

  const { data, error } = await admin
    .from("fan_team_members")
    .select("user_id,team_id")
    .in("team_id", teamIds)
    .eq("push_notifications_muted", true)
    .is("left_at", null)
    .in("user_id", userIds)

  if (error) {
    console.error("[FanTeamPushMute] pickup_muted_members_lookup_failed", error)
    return new Set()
  }

  return mutedUserIdSet(data as Array<{ user_id?: string | null }>)
}
