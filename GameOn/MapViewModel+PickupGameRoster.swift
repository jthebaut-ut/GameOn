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

    /// Forces a roster refresh after approve / decline / withdraw.
    @MainActor
    func refreshPickupGameRoster(pickupGameId: UUID) async {
        await loadPickupGameRoster(pickupGameId: pickupGameId, force: true)
    }

    func clearPickupGameRosterCaches() {
        pickupGameRosterByGameId = [:]
        pickupGameRosterInFlightGameIds = []
        pickupGameRosterErrorByGameId = [:]
    }
}
