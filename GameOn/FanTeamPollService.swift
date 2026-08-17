import Foundation
import Supabase

enum FanTeamPollServiceError: LocalizedError {
    case notAuthenticated
    case createFailed
    case permissionFailed
    case accessFailed

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not authenticated"
        case .createFailed: return "Could not create poll"
        case .permissionFailed: return "Could not update poll permission"
        case .accessFailed: return "Could not load poll permission"
        }
    }
}

final class FanTeamPollService {
    private let client: SupabaseClient

    init(client: SupabaseClient = supabase) {
        self.client = client
    }

    func fetchAccess(teamId: UUID) async throws -> FanTeamPollAccessSnapshot {
        struct Params: Encodable { let p_team_id: UUID }
        do {
            let snap: FanTeamPollAccessSnapshot = try await client
                .rpc("get_fan_team_poll_access", params: Params(p_team_id: teamId))
                .execute()
                .value
            TeamChatPollDebug.log(
                "pollPermissionLoaded",
                detail: "teamID=\(teamId.uuidString.lowercased()) permission=\(snap.permission.rawValue) canCreate=\(snap.viewerCanCreate) canManage=\(snap.viewerCanManage)"
            )
            return snap
        } catch {
            TeamChatPollDebug.log(
                "pollPermissionLoaded",
                detail: "teamID=\(teamId.uuidString.lowercased()) error=\(error.localizedDescription)"
            )
            throw mapError(error, fallback: .accessFailed)
        }
    }

    func setCreatePermission(
        teamId: UUID,
        permission: FanTeamPollCreatePermission
    ) async throws -> FanTeamPollCreatePermission {
        struct Params: Encodable {
            let p_team_id: UUID
            let p_permission: String
        }
        do {
            let data = try await client
                .rpc(
                    "set_fan_team_poll_create_permission",
                    params: Params(p_team_id: teamId, p_permission: permission.rawValue)
                )
                .execute()
                .data
            let resolved = FanTeamPollCreatePermission.resolved(decodeString(from: data))
            TeamChatPollDebug.log(
                "pollPermissionChanged",
                detail: "teamID=\(teamId.uuidString.lowercased()) permission=\(resolved.rawValue)"
            )
            return resolved
        } catch {
            throw mapError(error, fallback: .permissionFailed)
        }
    }

    func createPoll(
        conversationId: UUID,
        question: String,
        options: [String],
        allowMultiple: Bool,
        isAnonymous: Bool
    ) async throws -> UUID {
        struct Params: Encodable {
            let p_conversation_id: UUID
            let p_question: String
            let p_options: [String]
            let p_allow_multiple: Bool
            let p_is_anonymous: Bool
        }
        let params = Params(
            p_conversation_id: conversationId,
            p_question: PickupGamePollValidation.normalizeQuestion(question),
            p_options: options.map(PickupGamePollValidation.normalizeOption),
            p_allow_multiple: allowMultiple,
            p_is_anonymous: isAnonymous
        )
        do {
            let data = try await client
                .rpc("create_fan_team_poll", params: params)
                .execute()
                .data
            let pollId = try decodeUUID(from: data)
            TeamChatPollDebug.log(
                "pollCreated",
                detail: "conversationID=\(conversationId.uuidString.lowercased()) pollID=\(pollId.uuidString.lowercased())"
            )
            return pollId
        } catch {
            TeamChatPollDebug.log(
                "pollCreateDenied",
                detail: "conversationID=\(conversationId.uuidString.lowercased()) error=\(error.localizedDescription)"
            )
            throw mapError(error, fallback: .createFailed)
        }
    }

    func teamPollUpdatesChannel(conversationId: UUID) -> (RealtimeChannelV2, AsyncStream<UpdateAction>) {
        let cid = conversationId.uuidString.lowercased()
        let channel = client.channel("fan-team-polls-\(cid)")
        let filter = RealtimePostgresFilter.eq("conversation_id", value: cid)
        let updates = channel.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "fan_team_polls",
            filter: filter
        )
        return (channel, updates)
    }

    func teamPermissionUpdatesChannel(teamId: UUID) -> (RealtimeChannelV2, AsyncStream<UpdateAction>) {
        let tid = teamId.uuidString.lowercased()
        let channel = client.channel("fan-team-poll-perm-\(tid)")
        let filter = RealtimePostgresFilter.eq("id", value: tid)
        let updates = channel.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "fan_teams",
            filter: filter
        )
        return (channel, updates)
    }

    func removeRealtimeChannel(_ channel: RealtimeChannelV2) async {
        await client.removeChannel(channel)
    }

    private func decodeUUID(from data: Data) throws -> UUID {
        if let id = try? JSONDecoder().decode(UUID.self, from: data) {
            return id
        }
        if let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .lowercased(),
           let id = UUID(uuidString: raw) {
            return id
        }
        throw FanTeamPollServiceError.createFailed
    }

    private func decodeString(from data: Data) -> String? {
        if let s = try? JSONDecoder().decode(String.self, from: data) {
            return s
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private func mapError(_ error: Error, fallback: FanTeamPollServiceError) -> Error {
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("not authenticated") {
            return FanTeamPollServiceError.notAuthenticated
        }
        if !text.isEmpty, text != "The operation couldn’t be completed." {
            return error
        }
        return fallback
    }
}
