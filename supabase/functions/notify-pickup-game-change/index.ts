import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2"
import { ApnsClient, type PushTokenRow } from "../_shared/apns_client.ts"
import { applyPushArtwork, pickTeamLogo, pickUserAvatar } from "../_shared/push_artwork.ts"
import {
  authorizeSportsWorkerRequest,
  describeAuthCandidateClasses,
  readAdminApiKey,
  readRequestCredentialPresence,
  sportsWorkerAuthLog,
} from "../_shared/sports_worker_auth.ts"
import { loadMutedUserIdsForPickupGame } from "../_shared/fan_team_push_mute.ts"
import {
  buildPickupGameChangePushAlert,
  classifyPickupGameChange,
  isJoinRequestDecisionType,
  isTeamEventScoreNotificationType,
  type TeamEventPushContext,
} from "./pickup_game_change_push_alert.ts"

/**
 * Preference-gated APNs worker for meaningful pickup-game / Team-event edits/cancels.
 *
 * Invocation (internal only) — same dual-key worker auth as other Team push
 * functions (`authorizeSportsWorkerRequest`):
 *   - Authorization: Bearer <legacy service_role JWT>
 *   - apikey: <sb_secret_...>
 *   - optional x-cron-secret matching PICKUP_GAME_CHANGE_PUSH_CRON_SECRET
 *
 * Postgres/pg_net sends Vault `fangeo_service_role_key` as Bearer. Do NOT
 * compare that value only against hosted `SERVICE_ROLE_KEY` (often an
 * `sb_secret_*` now) — that is `invalid_secret` and APNs never runs.
 *
 * Chat system messages are written by the SQL trigger. This worker only pushes.
 *
 * Recipients (after 20260954): list_pickup_game_change_push_tokens
 *   - Standalone: approved joiners + accepted/maybe invites
 *   - Team-linked: ALL active fan_team_members (RSVP-independent) + outside recruits
 * Team mute via fan_team_push_mute.ts (ordinary game-change only).
 *
 * Multi-device: ALL active tokens per recipient are attempted (no first-token break).
 *
 * Deploy: `supabase functions deploy notify-pickup-game-change --no-verify-jwt`
 */

interface Payload {
  update_event_id?: string
}

type UpdateEventRow = {
  id: string
  pickup_game_id: string
  editor_user_id: string | null
  change_kinds: string[] | null
  payload: Record<string, unknown> | null
  push_delivery_status?: string | null
  push_sent_at?: string | null
}

type RecipientTokenRow = {
  token_id: string
  user_id: string
  token: string
  environment: "sandbox" | "production"
}

const SOURCE = "pickup_game_change_notification"
const LOG_PREFIX = "[PickupGameChangePush]"
const TEAM_DEBUG = "[TeamEventChangePushDebug]"
const TEAM_SCHEDULE_DEBUG = "[TeamScheduleNotification]"
const TEAM_GAME_DEBUG = "[TeamGameNotification]"
const TEAM_ANNOUNCEMENT_DEBUG = "[TeamAnnouncement]"

function json(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      // Internal worker — deny browser credentialed cross-origin use.
      "Cache-Control": "no-store",
    },
  })
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value)
}

function asString(value: unknown): string {
  return typeof value === "string" ? value.trim() : ""
}

function payloadRecipientUserIds(payload: Record<string, unknown> | null): string[] {
  const raw = payload?.recipient_user_ids
  if (!Array.isArray(raw)) return []
  return [
    ...new Set(
      raw
        .map((value) => asString(value))
        .filter((value) => isUuid(value)),
    ),
  ]
}

/**
 * Authoritative Team link for this pickup_game_id (never trust client Team id).
 * Inactive / missing Team → null (standalone copy + mute path still works).
 */
async function resolveTeamEventPushContext(
  admin: SupabaseClient,
  pickupGameId: string,
  eventPayload: Record<string, unknown> | null,
): Promise<TeamEventPushContext | null> {
  const { data: links, error: linksError } = await admin
    .from("fan_team_game_links")
    .select("team_id")
    .eq("pickup_game_id", pickupGameId)
    .limit(8)

  if (linksError) {
    console.error(`${TEAM_DEBUG} team_link_lookup_failed reason=${linksError.message}`)
    return null
  }

  const teamIds = [
    ...new Set(
      (links ?? [])
        .map((row) => asString((row as { team_id?: string }).team_id))
        .filter(Boolean),
    ),
  ]
  if (teamIds.length === 0) {
    console.log(`${TEAM_DEBUG} team_id resolved=none (standalone pickup)`)
    return null
  }

  const { data: team, error: teamError } = await admin
    .from("fan_teams")
    .select("id,name,is_active,logo_url,logo_thumbnail_url")
    .in("id", teamIds)
    .eq("is_active", true)
    .limit(1)
    .maybeSingle()

  if (teamError) {
    console.error(`${TEAM_DEBUG} team_row_lookup_failed reason=${teamError.message}`)
    return null
  }
  if (!team) {
    console.log(`${TEAM_DEBUG} team_id resolved=inactive_or_missing suppress_team_copy=true`)
    return null
  }

  const teamRow = team as {
    id: string
    name?: string | null
    logo_url?: string | null
    logo_thumbnail_url?: string | null
  }
  const teamId = asString(teamRow.id)
  const teamName = asString(teamRow.name) || "Team"

  const { data: game } = await admin
    .from("pickup_games")
    .select("title,game_format")
    .eq("id", pickupGameId)
    .maybeSingle()

  const gameRow = (game ?? {}) as { title?: string | null; game_format?: string | null }
  const eventTitle = asString(gameRow.title)
    || asString(eventPayload?.title)
    || asString(eventPayload?.after_title)
  const gameFormat = asString(gameRow.game_format)
    || asString(eventPayload?.game_format)
    || asString(eventPayload?.after_game_format)

  console.log(
    `${TEAM_DEBUG} team_id resolved=${teamId} teamName=${teamName.slice(0, 48)} ` +
      `eventTitle=${eventTitle.slice(0, 48)} gameFormat=${gameFormat || "none"}`,
  )

  return {
    teamId,
    teamName,
    eventTitle,
    gameFormat,
    logoURL: pickTeamLogo(teamRow.logo_thumbnail_url, teamRow.logo_url),
  }
}

async function finalize(
  admin: SupabaseClient,
  updateEventId: string,
  status: "sent" | "failed" | "retryable" | "skipped",
  error?: string,
  skipReason?: string,
): Promise<void> {
  const { error: finalizeError } = await admin.rpc("finalize_pickup_game_change_push_event", {
    p_update_event_id: updateEventId,
    p_status: status,
    p_error: error ?? null,
    p_skip_reason: skipReason ?? null,
  })
  if (finalizeError) {
    console.error(`${LOG_PREFIX} finalize_failed status=${status} reason=${finalizeError.message}`)
    console.error(`${TEAM_DEBUG} notification_finalize_failed status=${status}`)
  } else {
    console.log(`${TEAM_DEBUG} notification_marked status=${status} skip=${skipReason ?? "none"}`)
  }
}

async function recordDelivery(
  admin: SupabaseClient,
  updateEventId: string,
  userId: string,
  tokenId: string | null,
  status: "sent" | "failed" | "skipped",
  errorReason: string | null,
): Promise<void> {
  const { error } = await admin.rpc("record_pickup_game_change_push_delivery", {
    p_update_event_id: updateEventId,
    p_user_id: userId,
    p_token_id: tokenId,
    p_status: status,
    p_error_reason: errorReason,
  })
  if (error) {
    console.error(
      `${LOG_PREFIX} delivery_record_failed user=${userId} status=${status} reason=${error.message}`,
    )
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204 })
  }
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405)
  }

  const supabaseUrl = Deno.env.get("PROJECT_URL")?.trim()
    ?? Deno.env.get("SUPABASE_URL")?.trim()
    ?? ""
  const adminApiKey = readAdminApiKey()
  const cronEnvNames = ["PICKUP_GAME_CHANGE_PUSH_CRON_SECRET"]
  const candidateClasses = describeAuthCandidateClasses(cronEnvNames)
  const credentialPresence = readRequestCredentialPresence(req)
  const attempted = credentialPresence.apikey
    ? "apikey"
    : credentialPresence.bearer
    ? "bearer"
    : credentialPresence.cron
    ? "cron"
    : "none"

  console.log(
    `${LOG_PREFIX} auth candidates legacy=${candidateClasses.legacy} ` +
      `secretKeys=${candidateClasses.secretKeys} cron=${candidateClasses.cronConfigured}`,
  )

  if (!supabaseUrl || !adminApiKey) {
    console.error(`${LOG_PREFIX} missing PROJECT_URL/SUPABASE_URL or admin API credential`)
    return json({ error: "server_misconfigured" }, 500)
  }

  const invocation = authorizeSportsWorkerRequest(req, {
    cronSecretEnvNames: cronEnvNames,
  })
  if (!invocation.accepted) {
    sportsWorkerAuthLog("PickupGameChangePush", "unauthorized", {
      reason: invocation.reason,
      attempted,
      candidates: candidateClasses,
    })
    return json({ error: "unauthorized" }, 401)
  }
  sportsWorkerAuthLog("PickupGameChangePush", "authorized", {
    source: invocation.source,
    attempted,
  })

  let body: Payload
  try {
    body = await req.json()
  } catch {
    return json({ error: "invalid_json" }, 400)
  }

  const updateEventId = body.update_event_id?.trim() ?? ""
  if (!updateEventId || !isUuid(updateEventId)) {
    return json({ error: "missing_or_invalid_update_event_id" }, 400)
  }

  // Ignore any client-supplied title/body/recipients — only the event id is accepted.
  const admin = createClient(supabaseUrl, adminApiKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  })

  console.log(`${TEAM_DEBUG} edge_invoked update_event_id=${updateEventId}`)

  const { data: claimed, error: claimError } = await admin.rpc(
    "claim_pickup_game_change_push_event",
    { p_update_event_id: updateEventId },
  )

  if (claimError) {
    console.error(`${LOG_PREFIX} claim_failed reason=${claimError.message}`)
    console.error(`${TEAM_DEBUG} claim_failed reason=${claimError.message}`)
    return json({ error: "claim_failed" }, 500)
  }

  if (!claimed) {
    // Already sent, currently sending, or unknown id.
    const { data: existing } = await admin
      .from("pickup_game_update_events")
      .select("id,push_delivery_status,push_sent_at")
      .eq("id", updateEventId)
      .maybeSingle()

    if (!existing) {
      console.log(`${TEAM_DEBUG} claim_miss event_not_found`)
      return json({ error: "event_not_found" }, 404)
    }
    console.log(
      `${TEAM_DEBUG} claim_skipped reason=${existing.push_sent_at ? "already_sent" : "not_claimable"} ` +
        `status=${existing.push_delivery_status ?? "none"}`,
    )
    return json({
      ok: true,
      skipped: true,
      reason: existing.push_sent_at ? "already_sent" : "not_claimable",
      update_event_id: updateEventId,
    })
  }

  const updateEvent = claimed as UpdateEventRow
  const changeClass = classifyPickupGameChange(updateEvent)
  const kinds = (updateEvent.change_kinds ?? []).map((k) => String(k))
  const payload = updateEvent.payload ?? {}
  const excludeEditor = updateEvent.editor_user_id?.trim() || null

  console.log(
    `${TEAM_DEBUG} claim_ok update_event_id=${updateEventId} ` +
      `pickup_game_id=${updateEvent.pickup_game_id} editor_excluded=${excludeEditor ?? "none"}`,
  )
  console.log(
    `${TEAM_DEBUG} old_values start=${asString(payload.before_start)} ` +
      `location=${asString(payload.before_location).slice(0, 64)} ` +
      `status=${asString(payload.before_status)}`,
  )
  console.log(
    `${TEAM_DEBUG} new_values start=${asString(payload.after_start)} ` +
      `location=${asString(payload.after_location).slice(0, 64)} ` +
      `status=${asString(payload.after_status)}`,
  )
  console.log(
    `${TEAM_DEBUG} meaningful_fields detected=${kinds.join(",") || "none"} class=${changeClass}`,
  )
  console.log(
    `${TEAM_SCHEDULE_DEBUG} fanoutStart update_event_id=${updateEventId} ` +
      `pickup_game_id=${updateEvent.pickup_game_id} notificationType=${asString(payload.notification_type) || changeClass} ` +
      `changedFields=${kinds.join(",") || "none"} ` +
      `dateChanged=${kinds.includes("start")} timeChanged=${kinds.includes("start") || kinds.includes("end")} ` +
      `locationChanged=${kinds.includes("location")} ` +
      `rsvpResetRequired=${payload.rsvp_reset_required === true} ` +
      `rsvpRecordsInvalidated=${Number(payload.rsvp_records_invalidated ?? 0)}`,
  )

  const teamContext = await resolveTeamEventPushContext(
    admin,
    updateEvent.pickup_game_id,
    payload,
  )
  if (changeClass === "created" || asString(payload.notification_type) === "team_game_created") {
    const matchupPreview = asString(payload.matchup).slice(0, 80) || "(none)"
    const teamIdLog = teamContext?.teamId ?? (asString(payload.team_id) || "none")
    const eventTypeLog = teamContext?.gameFormat || asString(payload.game_format) || "none"
    console.log(
      `${TEAM_GAME_DEBUG} fanoutStart teamID=${teamIdLog} ` +
        `eventID=${updateEvent.pickup_game_id} creatorID=${excludeEditor ?? "none"} ` +
        `eventType=${eventTypeLog} ` +
        `matchup=${matchupPreview} ` +
        `gameDate=${asString(payload.after_start) || "(none)"}`,
    )
  }
  if (asString(payload.notification_type) === "team_announcement" || payload.is_team_announcement === true) {
    const teamIdLog = teamContext?.teamId ?? (asString(payload.team_id) || "none")
    console.log(
      `${TEAM_ANNOUNCEMENT_DEBUG} notificationFanoutStart teamID=${teamIdLog} ` +
        `announcementID=${updateEvent.pickup_game_id} authorID=${excludeEditor ?? "none"}`,
    )
  }
  const alert = buildPickupGameChangePushAlert(updateEvent, teamContext)

  console.log(
    `${LOG_PREFIX} claimed event=${updateEventId} pickup=${updateEvent.pickup_game_id} ` +
      `class=${changeClass} kinds=${kinds.join(",")} teamLinked=${teamContext != null}`,
  )
  console.log(
    `${TEAM_DEBUG} alert title=${alert.title.slice(0, 80)} body=${alert.body.slice(0, 120)}`,
  )

  const joinDecisionType = asString(payload.notification_type)
  const targetedRecipientIds = payloadRecipientUserIds(payload)
  const isJoinDecision = isJoinRequestDecisionType(joinDecisionType)

  let rows: RecipientTokenRow[] = []
  if (isJoinDecision && targetedRecipientIds.length > 0) {
    const { data: targetedTokens, error: targetedError } = await admin
      .from("user_push_tokens")
      .select("id,user_id,token,environment")
      .in("user_id", targetedRecipientIds)
      .eq("is_active", true)
    if (targetedError) {
      console.error(`${LOG_PREFIX} recipient_query_failed reason=${targetedError.message}`)
      console.error(`${TEAM_DEBUG} committed_recipients_failed reason=${targetedError.message}`)
      await finalize(admin, updateEventId, "retryable", "recipient_query_failed")
      return json({ error: "recipient_query_failed" }, 500)
    }
    rows = ((targetedTokens ?? []) as Array<{
      id: string
      user_id: string
      token: string
      environment: "sandbox" | "production"
    }>).map((row) => ({
      token_id: row.id,
      user_id: row.user_id,
      token: row.token,
      environment: row.environment,
    }))
  } else {
    const { data: tokens, error: tokenError } = await admin.rpc(
      "list_pickup_game_change_push_tokens",
      {
        p_pickup_game_id: updateEvent.pickup_game_id,
        p_exclude_user_id: excludeEditor,
      },
    )

    if (tokenError) {
      console.error(`${LOG_PREFIX} recipient_query_failed reason=${tokenError.message}`)
      console.error(`${TEAM_DEBUG} committed_recipients_failed reason=${tokenError.message}`)
      await finalize(admin, updateEventId, "retryable", "recipient_query_failed")
      return json({ error: "recipient_query_failed" }, 500)
    }

    rows = (tokens ?? []) as RecipientTokenRow[]
    if (targetedRecipientIds.length > 0) {
      const allow = new Set(targetedRecipientIds)
      rows = rows.filter((row) => allow.has(row.user_id))
    }
  }
  const uniqueRecipientIds = [...new Set(rows.map((r) => r.user_id))]
  console.log(
    `${TEAM_DEBUG} committed_recipients resolved userCount=${uniqueRecipientIds.length} ` +
      `installationCount=${rows.length} editorRemoved=true`,
  )
  console.log(
    `${TEAM_SCHEDULE_DEBUG} recipientCount=${rows.length} deduplicatedRecipientCount=${uniqueRecipientIds.length}`,
  )
  if (changeClass === "created" || asString(payload.notification_type) === "team_game_created") {
    console.log(
      `${TEAM_GAME_DEBUG} recipientCount=${rows.length} deduplicatedRecipientCount=${uniqueRecipientIds.length}`,
    )
  }

  if (rows.length === 0) {
    console.log(`${TEAM_DEBUG} active_push_installations found=0 → skip`)
    await finalize(admin, updateEventId, "skipped", undefined, "no_recipients")
    return json({ ok: true, sent: 0, skipped: "no_recipients", update_event_id: updateEventId })
  }

  let apns: ApnsClient
  try {
    apns = await ApnsClient.fromEnvironment()
  } catch (error) {
    const detail = error instanceof Error ? error.message : "apns_config"
    console.error(`${LOG_PREFIX} apns_config_failed`)
    console.error(`${TEAM_DEBUG} apns_config_failed`)
    await finalize(admin, updateEventId, "retryable", "apns_config")
    return json({ error: "apns_config", detail: detail.slice(0, 120) }, 500)
  }

  // Group ALL active tokens per user (iPhone + iPad + …). Do not collapse to one.
  const tokensByUser = new Map<string, RecipientTokenRow[]>()
  for (const row of rows) {
    const list = tokensByUser.get(row.user_id) ?? []
    list.push(row)
    tokensByUser.set(row.user_id, list)
  }

  console.log(
    `${TEAM_DEBUG} active_push_installations found=${rows.length} users=${tokensByUser.size}`,
  )

  // Team-linked pickup games: honor per-Team push mute for linked Team members.
  // Join-request decisions always reach the requester (they asked to join).
  // Invited non-members are not in fan_team_members mute set.
  const teamMutedUserIds = isJoinDecision
    ? new Set<string>()
    : await loadMutedUserIdsForPickupGame(
      admin,
      updateEvent.pickup_game_id,
      [...tokensByUser.keys()],
    )
  console.log(`${TEAM_DEBUG} muted_recipients removed count=${teamMutedUserIds.size}`)

  let sentUsers = 0
  let failedUsers = 0
  let skippedUsers = 0
  let sentTokens = 0
  let permanentCleanups = 0

  for (const [userId, userTokens] of tokensByUser) {
    if (teamMutedUserIds.has(userId)) {
      console.log(
        `${LOG_PREFIX} team_push_muted_skip pickup_game_id=${updateEvent.pickup_game_id} ` +
          `recipient_user_id=${userId} update_event_id=${updateEventId}`,
      )
      console.log(
        `${TEAM_DEBUG} muted_skip recipientUserId=${userId} installations=${userTokens.length}`,
      )
      await recordDelivery(
        admin,
        updateEventId,
        userId,
        userTokens[0]?.token_id ?? null,
        "skipped",
        "team_push_muted",
      )
      skippedUsers += 1
      continue
    }

    const { data: alreadySent, error: alreadyError } = await admin.rpc(
      "pickup_game_change_push_already_sent",
      {
        p_update_event_id: updateEventId,
        p_user_id: userId,
      },
    )
    if (alreadyError) {
      console.error(`${LOG_PREFIX} already_sent_check_failed user=${userId}`)
      failedUsers += 1
      continue
    }
    if (alreadySent === true) {
      skippedUsers += 1
      continue
    }

    let userSentCount = 0
    let invalidated = 0
    let lastReason = "apns_send_failed"
    for (const row of userTokens) {
      const token: PushTokenRow = {
        id: row.token_id,
        user_id: row.user_id,
        token: row.token,
        environment: row.environment,
      }
      const dedupeKey = changeClass === "cancelled" || changeClass === "canceled"
        ? `pickup_cancel:${updateEvent.pickup_game_id}:${updateEvent.id}`
        : `pickup_update:${updateEvent.pickup_game_id}:${updateEvent.id}`
      const customData: Record<string, string> = {
        source: SOURCE,
        pickup_game_id: updateEvent.pickup_game_id,
        pickup_update_event_id: updateEvent.id,
        change_class: changeClass,
        notification_type: asString(payload.notification_type) || changeClass,
        deduplication_key: dedupeKey.toLowerCase(),
        inbox_dedupe_key: dedupeKey.toLowerCase(),
      }
      if (teamContext?.teamId) {
        customData.team_id = teamContext.teamId
        customData.event_id = updateEvent.pickup_game_id
        const scorerArt = pickUserAvatar(
          asString(payload.scorer_avatar_url_snapshot) || asString(payload.scorer_avatar_url),
          asString(payload.player_avatar_url),
        )
        const scorerName = asString(payload.scorer_display_name)
          || asString(payload.scorer_display_name_snapshot)
        if (
          isTeamEventScoreNotificationType(asString(payload.notification_type))
          && scorerArt
          && scorerName
        ) {
          applyPushArtwork(
            customData,
            scorerArt,
            "player",
            asString(payload.scorer_membership_id) || asString(payload.scorer_managed_player_id),
          )
        } else {
          applyPushArtwork(customData, teamContext.logoURL, "team", teamContext.teamId)
        }
      }
      const copyIfPresent = (key: string, value: unknown) => {
        const text = asString(value)
        if (text) customData[key] = text
      }
      copyIfPresent("team_name", payload.team_name ?? teamContext?.teamName)
      copyIfPresent("game_format", payload.game_format ?? teamContext?.gameFormat)
      copyIfPresent("title", payload.title ?? teamContext?.eventTitle)
      copyIfPresent("before_start", payload.before_start)
      copyIfPresent("after_start", payload.after_start)
      copyIfPresent("before_location", payload.before_location)
      copyIfPresent("after_location", payload.after_location)
      copyIfPresent("before_opponent", payload.before_opponent)
      copyIfPresent("after_opponent", payload.after_opponent)
      copyIfPresent("matchup", payload.matchup)
      copyIfPresent("score_line", payload.score_line)
      copyIfPresent("score_title", payload.score_title)
      copyIfPresent("scorer_display_name", payload.scorer_display_name ?? payload.scorer_display_name_snapshot)
      copyIfPresent("scorer_attribution_kind", payload.scorer_attribution_kind)
      copyIfPresent("scorer_membership_id", payload.scorer_membership_id)
      copyIfPresent("scorer_managed_player_id", payload.scorer_managed_player_id)
      copyIfPresent("sport", payload.sport)
      if (payload.is_team_announcement === true) {
        customData.is_team_announcement = "true"
      }
      if (payload.rsvp_reset_required === true) {
        customData.rsvp_reset_required = "true"
      }
      console.log(
        `${TEAM_DEBUG} apns_send_attempted recipientUserId=${userId} installationId=${row.token_id} ` +
          `environment=${row.environment}`,
      )
      const result = await apns.send(token, alert, customData)
      if (result.ok) {
        userSentCount += 1
        // APNs HTTP 200 = accepted for that token/environment — not proof the current
        // physical device displayed the alert (stale active tokens can still 200).
        console.log(
          `${LOG_PREFIX} apns_accepted tokenId=${row.token_id} environment=${result.tokenEnvironment} ` +
            `status=${result.status} endpoint=${result.endpoint} user=${userId}`,
        )
        console.log(
          `${TEAM_DEBUG} recipientUserId=${userId} installationId=${row.token_id} ` +
            `apnsStatus=${result.status} apnsReason=Accepted`,
        )
        continue
      }
      lastReason = result.reason ?? `status_${result.status}`
      console.warn(
        `${LOG_PREFIX} apns_failed tokenId=${row.token_id} environment=${result.tokenEnvironment} ` +
          `status=${result.status} reason=${lastReason} invalidate=${result.invalidate === true}`,
      )
      console.warn(
        `${TEAM_DEBUG} recipientUserId=${userId} installationId=${row.token_id} ` +
          `apnsStatus=${result.status} apnsReason=${lastReason}`,
      )
      if (result.invalidate) {
        invalidated += 1
        permanentCleanups += 1
        await admin
          .from("user_push_tokens")
          .update({ is_active: false, invalidated_at: new Date().toISOString() })
          .eq("id", row.token_id)
        console.log(
          `${TEAM_DEBUG} permanent_token_cleanup installationId=${row.token_id} reason=${lastReason}`,
        )
      }
    }

    if (userSentCount > 0) {
      sentTokens += userSentCount
      sentUsers += 1
      await recordDelivery(
        admin,
        updateEventId,
        userId,
        userTokens[0]?.token_id ?? null,
        "sent",
        null,
      )
    } else {
      failedUsers += 1
      const reason = invalidated > 0 && invalidated === userTokens.length
        ? "apns_invalid_token"
        : lastReason
      await recordDelivery(
        admin,
        updateEventId,
        userId,
        userTokens[0]?.token_id ?? null,
        "failed",
        reason,
      )
    }
  }

  if (sentUsers > 0) {
    await finalize(admin, updateEventId, "sent")
  } else if (failedUsers > 0) {
    await finalize(admin, updateEventId, "retryable", "apns_send_failed")
  } else {
    await finalize(admin, updateEventId, "skipped", undefined, "no_new_recipients")
  }

  console.log(
    `${LOG_PREFIX} event=${updateEventId} pickup=${updateEvent.pickup_game_id} ` +
      `class=${changeClass} auth=${auth.source} sentUsers=${sentUsers} sentTokens=${sentTokens} ` +
      `failedUsers=${failedUsers} skippedUsers=${skippedUsers}`,
  )
  console.log(
    `${TEAM_DEBUG} summary sentUsers=${sentUsers} sentTokens=${sentTokens} ` +
      `failedUsers=${failedUsers} skippedUsers=${skippedUsers} permanentCleanups=${permanentCleanups}`,
  )
  console.log(
    `${TEAM_SCHEDULE_DEBUG} fanoutComplete update_event_id=${updateEventId} ` +
      `pushSuccessCount=${sentUsers} pushFailureCount=${failedUsers} ` +
      `notificationType=${asString(payload.notification_type) || changeClass}`,
  )
  if (changeClass === "created" || asString(payload.notification_type) === "team_game_created") {
    console.log(
      `${TEAM_GAME_DEBUG} fanoutComplete eventID=${updateEvent.pickup_game_id} ` +
        `pushSuccessCount=${sentUsers} pushFailureCount=${failedUsers}`,
    )
  }
  if (asString(payload.notification_type) === "team_announcement" || payload.is_team_announcement === true) {
    console.log(
      `${TEAM_ANNOUNCEMENT_DEBUG} notificationFanoutComplete announcementID=${updateEvent.pickup_game_id} ` +
        `pushSuccessCount=${sentUsers} pushFailureCount=${failedUsers} recipientCount=${sentUsers}`,
    )
  }

  return json({
    ok: true,
    update_event_id: updateEventId,
    change_class: changeClass,
    team_linked: teamContext != null,
    team_id: teamContext?.teamId ?? null,
    sent: sentUsers,
    sent_tokens: sentTokens,
    failed: failedUsers,
    skipped: skippedUsers,
  })
})
