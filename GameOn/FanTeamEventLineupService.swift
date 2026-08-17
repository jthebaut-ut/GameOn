import Foundation
import Supabase

/// Coarse-grained Team event lineup RPCs (`get` / `save` / `publish`).
final class FanTeamEventLineupService {
    private let client: SupabaseClient

    init(client: SupabaseClient = supabase) {
        self.client = client
    }

    func getLineup(pickupGameId: UUID, teamId: UUID?) async throws -> FanTeamEventLineup {
        struct Params: Encodable {
            let p_pickup_game_id: UUID
            let p_team_id: UUID?
        }
        let rows: [RPCRow] = try await client
            .rpc(
                "get_fan_team_event_lineup",
                params: Params(p_pickup_game_id: pickupGameId, p_team_id: teamId)
            )
            .execute()
            .value
        guard let row = rows.first else {
            throw FanTeamEventLineupServiceError.emptyResponse
        }
        return row.asModel(parseDate: FanTeamsService.parseDate)
    }

    @discardableResult
    func saveLineup(
        pickupGameId: UUID,
        teamId: UUID,
        status: FanTeamLineupPublicationStatus,
        formation: String?,
        members: [FanTeamLineupMemberDraft]
    ) async throws -> UUID {
        let unique = FanTeamLineupOrdering.deduped(members)
        let starting = FanTeamLineupOrdering.renumber(
            FanTeamLineupOrdering.sorted(unique.filter { $0.lineupStatus == .starting })
        )
        let bench = FanTeamLineupOrdering.renumber(
            FanTeamLineupOrdering.sorted(unique.filter { $0.lineupStatus == .bench })
        )
        let payload = starting + bench

        struct Params: Encodable {
            let p_pickup_game_id: UUID
            let p_team_id: UUID
            let p_status: String
            let p_formation: String?
            let p_members: [FanTeamLineupMemberDraft]
        }
        let id: UUID = try await client
            .rpc(
                "save_fan_team_event_lineup",
                params: Params(
                    p_pickup_game_id: pickupGameId,
                    p_team_id: teamId,
                    p_status: status.rawValue,
                    p_formation: formation,
                    p_members: payload
                )
            )
            .execute()
            .value
        return id
    }

    @discardableResult
    func publishLineup(pickupGameId: UUID, teamId: UUID) async throws -> UUID {
        struct Params: Encodable {
            let p_pickup_game_id: UUID
            let p_team_id: UUID
        }
        let id: UUID = try await client
            .rpc(
                "publish_fan_team_event_lineup",
                params: Params(p_pickup_game_id: pickupGameId, p_team_id: teamId)
            )
            .execute()
            .value
        return id
    }

    // MARK: - Decode

    /// `user_id` is absent/null for guardian-managed seats (20260961), which carry
    /// `managed_player_id` instead.
    private struct RPCMember: Decodable {
        let user_id: UUID?
        let managed_player_id: UUID?
        let lineup_status: String
        let position_code: String?
        let sort_order: Int?

        enum CodingKeys: String, CodingKey {
            case user_id
            case managed_player_id
            case lineup_status
            case position_code
            case sort_order
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            user_id = try c.decodeIfPresent(UUID.self, forKey: .user_id)
            managed_player_id = try c.decodeIfPresent(UUID.self, forKey: .managed_player_id)
            lineup_status = try c.decode(String.self, forKey: .lineup_status)
            position_code = try c.decodeIfPresent(String.self, forKey: .position_code)
            sort_order = try c.decodeIfPresent(Int.self, forKey: .sort_order)
        }
    }

    private struct RPCRow: Decodable {
        let lineup_id: UUID?
        let team_id: UUID
        let pickup_game_id: UUID
        let status: String?
        let formation: String?
        let published_at: String?
        let published_by: UUID?
        let updated_at: String?
        let viewer_can_manage: Bool
        let members: MembersPayload

        func asModel(parseDate: (String?) -> Date?) -> FanTeamEventLineup {
            let drafts: [FanTeamLineupMemberDraft] = members.values.compactMap { raw in
                guard let status = FanTeamLineupPlayerStatus(rawValue: raw.lineup_status.lowercased()) else {
                    return nil
                }
                guard raw.user_id != nil || raw.managed_player_id != nil else { return nil }
                let code = raw.position_code?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return FanTeamLineupMemberDraft(
                    userId: raw.user_id,
                    managedPlayerId: raw.managed_player_id,
                    lineupStatus: status,
                    positionCode: (code?.isEmpty == false) ? code?.uppercased() : nil,
                    sortOrder: raw.sort_order ?? 0
                )
            }
            let pubStatus = status
                .flatMap { FanTeamLineupPublicationStatus(rawValue: $0.lowercased()) }
            return FanTeamEventLineup(
                id: lineup_id,
                teamId: team_id,
                pickupGameId: pickup_game_id,
                status: pubStatus,
                formation: {
                    let t = formation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return t.isEmpty ? nil : t
                }(),
                publishedAt: parseDate(published_at),
                publishedBy: published_by,
                updatedAt: parseDate(updated_at),
                viewerCanManage: viewer_can_manage,
                members: FanTeamLineupOrdering.deduped(drafts)
            )
        }
    }

    /// PostgREST may deliver jsonb as a decoded array or as a JSON string.
    private struct MembersPayload: Decodable {
        let values: [RPCMember]

        init(from decoder: Decoder) throws {
            if let arr = try? decoder.singleValueContainer().decode([RPCMember].self) {
                values = arr
                return
            }
            if let raw = try? decoder.singleValueContainer().decode(String.self),
               let data = raw.data(using: .utf8),
               let arr = try? JSONDecoder().decode([RPCMember].self, from: data) {
                values = arr
                return
            }
            values = []
        }
    }
}

enum FanTeamEventLineupServiceError: LocalizedError {
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "Lineup response was empty."
        }
    }
}
