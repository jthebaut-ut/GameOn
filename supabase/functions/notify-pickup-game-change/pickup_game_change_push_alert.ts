/**
 * Authoritative APNs title/body for pickup edit/cancel events.
 * Built only from `pickup_game_update_events` payload (never client-supplied copy).
 */

export type PickupGameChangeUpdateEvent = {
  change_kinds?: string[] | null
  payload?: Record<string, unknown> | null
}

/** High-level push classification for schedule/location/cancel. */
export type PickupGameChangeClass =
  | "cancelled"
  | "time_and_location_changed"
  | "time_changed"
  | "location_changed"
  | "other"

function asString(value: unknown): string {
  return typeof value === "string" ? value.trim() : ""
}

function shortPlace(place: string, maxLen = 52): string {
  const trimmed = place.trim()
  if (!trimmed) return ""
  if (trimmed.length <= maxLen) return trimmed
  return `${trimmed.slice(0, Math.max(1, maxLen - 1)).trimEnd()}…`
}

export function formatStartForPush(raw: string): string {
  if (!raw) return ""
  const date = new Date(raw)
  if (Number.isNaN(date.getTime())) return ""
  try {
    const datePart = new Intl.DateTimeFormat("en-US", {
      weekday: "short",
      month: "short",
      day: "numeric",
    }).format(date)
    const timePart = new Intl.DateTimeFormat("en-US", {
      hour: "numeric",
      minute: "2-digit",
    }).format(date)
    return `${datePart} at ${timePart}`
  } catch {
    return ""
  }
}

export function classifyPickupGameChange(
  event: PickupGameChangeUpdateEvent,
): PickupGameChangeClass {
  const kinds = new Set((event.change_kinds ?? []).map((k) => k.toLowerCase()))
  const payload = event.payload ?? {}
  const afterStatus = asString(payload.after_status).toLowerCase()
  const beforeStatus = asString(payload.before_status).toLowerCase()
  const isCancellation =
    (beforeStatus !== "removed" && afterStatus === "removed")
    || payload.is_cancellation === true

  if (isCancellation) return "cancelled"

  const timeChanged = kinds.has("start") || kinds.has("end")
  const locationChanged = kinds.has("location")
  if (timeChanged && locationChanged) return "time_and_location_changed"
  if (timeChanged) return "time_changed"
  if (locationChanged) return "location_changed"
  return "other"
}

/** Build alert from authoritative event row only (ignore client-supplied copy). */
export function buildPickupGameChangePushAlert(
  event: PickupGameChangeUpdateEvent,
): { title: string; body: string } {
  const payload = event.payload ?? {}
  const titleName = asString(payload.title) || "Pickup game"
  const afterStart = formatStartForPush(asString(payload.after_start))
  const afterLocation = shortPlace(asString(payload.after_location))
  const beforePlayers = Number(payload.before_players_needed ?? NaN)
  const afterPlayers = Number(payload.after_players_needed ?? NaN)
  const changeClass = classifyPickupGameChange(event)

  if (changeClass === "cancelled") {
    if (afterStart) {
      return {
        title: "Game cancelled",
        body: `${titleName} on ${afterStart} was cancelled.`,
      }
    }
    return {
      title: "Game cancelled",
      body: `${titleName} was cancelled.`,
    }
  }

  if (changeClass === "time_and_location_changed") {
    if (afterStart && afterLocation) {
      return {
        title: "Schedule & location changed",
        body: `${titleName} now starts ${afterStart} at ${afterLocation}.`,
      }
    }
    return {
      title: "Schedule & location changed",
      body: `${titleName} has a new time and location.`,
    }
  }

  if (changeClass === "time_changed") {
    if (afterStart) {
      return {
        title: "Schedule changed",
        body: `${titleName} now starts ${afterStart}.`,
      }
    }
    return {
      title: "Schedule changed",
      body: `${titleName} has a new schedule.`,
    }
  }

  if (changeClass === "location_changed") {
    if (afterLocation) {
      return {
        title: "Location changed",
        body: `${titleName} moved to ${afterLocation}.`,
      }
    }
    return {
      title: "Location changed",
      body: `${titleName} moved to a new location.`,
    }
  }

  const kinds = new Set((event.change_kinds ?? []).map((k) => k.toLowerCase()))
  if (kinds.has("capacity") && Number.isFinite(beforePlayers) && Number.isFinite(afterPlayers)) {
    return {
      title: "Pickup game updated",
      body: `${titleName} capacity changed from ${beforePlayers} to ${afterPlayers}.`,
    }
  }
  return { title: "Pickup game updated", body: `${titleName} was updated.` }
}
