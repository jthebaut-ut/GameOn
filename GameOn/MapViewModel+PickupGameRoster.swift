import Foundation
import Supabase

extension MapViewModel {
    /// Loads the privacy-safe roster for a pickup game (one RPC; no N+1 profile fetches).
    @MainActor
    func loadPickupGameRoster(pickupGameId: UUID, force: Bool = false) async {
        guard canJoinPickupGames || currentUserAuthId != nil else { return }
        if !force, pickupGameRosterByGameId[pickupGameId] != nil {
            return
        }
        if pickupGameRosterInFlightGameIds.contains(pickupGameId) { return }
        pickupGameRosterInFlightGameIds.insert(pickupGameId)
        defer { pickupGameRosterInFlightGameIds.remove(pickupGameId) }

        struct Params: Encodable {
            let p_pickup_game_id: UUID
        }

        do {
            let payload: PickupGameRosterPayload = try await supabase
                .rpc("get_pickup_game_roster", params: Params(p_pickup_game_id: pickupGameId))
                .execute()
                .value
            pickupGameRosterByGameId[pickupGameId] = payload
            pickupGameRosterErrorByGameId[pickupGameId] = nil
#if DEBUG
            print(
                "[PickupRoster] loaded game=\(pickupGameId.uuidString.lowercased()) "
                    + "playing=\(payload.playing.count) pending=\(payload.pending.count) "
                    + "organizer=\(payload.viewer_is_organizer)"
            )
#endif
        } catch {
            pickupGameRosterErrorByGameId[pickupGameId] = error.localizedDescription
#if DEBUG
            print(
                "[PickupRoster] loadFailed game=\(pickupGameId.uuidString.lowercased()) "
                    + "error=\(error.localizedDescription)"
            )
#endif
        }
    }

    /// Loads the signed-in account's Team RSVP for one event (`pickup_games.id`).
    /// Independent of roster organizer presentation — required for Schedule correctness.
    ///
    /// Cache rules:
    /// - Definitive `.status` is kept and skips reload unless `force` (no polling).
    /// - `.unanswered` is **not** treated as terminal — a prior NULL/get miss must
    ///   revalidate on the next Schedule appear, or a sticky "Will … be there?" sticks forever.
    /// - Load failures do not write `.unanswered` (leave prior value / miss for retry).
    @MainActor
    func loadFanTeamSelfRSVP(pickupGameId: UUID, force: Bool = false) async {
        guard currentUserAuthId != nil else { return }
        if !force, case .status = fanTeamSelfRSVPByGameId[pickupGameId] {
            return
        }
        do {
            let status = try await FanTeamsService().getRSVP(gameId: pickupGameId)
            let cached = FanTeamCachedSelfRSVP.from(rpcStatus: status)
            fanTeamSelfRSVPByGameId[pickupGameId] = cached
#if DEBUG
            print(
                "[TeamRSVPDebug] self_rsvp_loaded pickup_game_id=\(pickupGameId.uuidString.lowercased()) " +
                "rpc=\(status?.rawValue ?? "NULL") " +
                "cache=\(cached.debugLabel) force=\(force)"
            )
#endif
        } catch {
#if DEBUG
            print(
                "[TeamRSVPDebug] self_rsvp_load_failed pickup_game_id=\(pickupGameId.uuidString.lowercased()) " +
                "error=\(error.localizedDescription) " +
                "cache_kept=\(fanTeamSelfRSVPByGameId[pickupGameId]?.debugLabel ?? "nil")"
            )
#endif
        }
    }

    /// Roster + event-scoped self RSVP for Team Schedule cards.
    @MainActor
    func loadTeamScheduleAttendance(pickupGameId: UUID, force: Bool = false) async {
        async let roster: Void = loadPickupGameRoster(pickupGameId: pickupGameId, force: force)
        async let selfRSVP: Void = loadFanTeamSelfRSVP(pickupGameId: pickupGameId, force: force)
        _ = await (roster, selfRSVP)
    }

    /// Fallback after batch prefetch: only hit per-game RPCs when cache is incomplete.
    @MainActor
    func loadTeamScheduleAttendanceIfMissing(pickupGameId: UUID) async {
        let hasRoster = pickupGameRosterByGameId[pickupGameId] != nil
        let hasDefinitiveRSVP: Bool = {
            if case .status = fanTeamSelfRSVPByGameId[pickupGameId] { return true }
            if case .unanswered = fanTeamSelfRSVPByGameId[pickupGameId] { return true }
            return false
        }()
        if hasRoster, hasDefinitiveRSVP { return }
        await loadTeamScheduleAttendance(pickupGameId: pickupGameId, force: false)
    }

    /// One RPC for all visible Team Schedule games (additive backend). Falls back to per-game.
    @MainActor
    func loadTeamScheduleAttendanceBatch(teamId: UUID, pickupGameIds: [UUID]) async {
        let uniqueIds = Array(Set(pickupGameIds))
        guard !uniqueIds.isEmpty else { return }
        do {
            let rows = try await FanTeamsService().listScheduleAttendance(
                teamId: teamId,
                pickupGameIds: uniqueIds
            )
            for row in rows {
                pickupGameRosterByGameId[row.pickupGameId] = row.roster
                pickupGameRosterErrorByGameId[row.pickupGameId] = nil
                fanTeamSelfRSVPByGameId[row.pickupGameId] = FanTeamCachedSelfRSVP.from(rpcStatus: row.selfRSVP)
            }
#if DEBUG
            print(
                "[TeamScheduleAttendance] batch_ok team=\(teamId.uuidString.lowercased()) " +
                "requested=\(uniqueIds.count) returned=\(rows.count)"
            )
#endif
        } catch {
#if DEBUG
            print(
                "[TeamScheduleAttendance] batch_failed team=\(teamId.uuidString.lowercased()) " +
                "error=\(error.localizedDescription) fallback=per_game"
            )
#endif
            for id in uniqueIds {
                await loadTeamScheduleAttendance(pickupGameId: id, force: false)
            }
        }
    }

    /// Forces a roster refresh after approve / decline / withdraw.
    @MainActor
    func refreshPickupGameRoster(pickupGameId: UUID) async {
        await loadPickupGameRoster(pickupGameId: pickupGameId, force: true)
    }

    func clearPickupGameRosterCaches() {
        pickupGameRosterByGameId = [:]
        pickupGameRosterInFlightGameIds = []
        pickupGameRosterErrorByGameId = [:]
        fanTeamSelfRSVPByGameId = [:]
    }
}
