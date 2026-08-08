import Foundation
import Supabase

enum PickupGamePollServiceError: LocalizedError {
    case notAuthenticated
    case createFailed
    case voteFailed
    case closeFailed
    case deleteFailed
    case pinFailed
    case snapshotFailed

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not authenticated"
        case .createFailed: return "Could not create poll"
        case .voteFailed: return "Could not update vote"
        case .closeFailed: return "Could not close poll"
        case .deleteFailed: return "Could not delete poll"
        case .pinFailed: return "Could not pin poll"
        case .snapshotFailed: return "Could not load poll"
        }
    }
}

final class PickupGamePollService {
    private let client: SupabaseClient

    init(client: SupabaseClient = supabase) {
        self.client = client
    }

    func currentUserId() async throws -> UUID {
        try await client.auth.session.user.id
    }

    func createPoll(
        conversationId: UUID,
        question: String,
        options: [String],
        allowMultiple: Bool,
        isAnonymous: Bool,
        autoCloseAtGameStart: Bool
    ) async throws -> UUID {
        struct Params: Encodable {
            let p_conversation_id: UUID
            let p_question: String
            let p_options: [String]
            let p_allow_multiple: Bool
            let p_is_anonymous: Bool
            let p_auto_close_at_game_start: Bool
        }
        let params = Params(
            p_conversation_id: conversationId,
            p_question: PickupGamePollValidation.normalizeQuestion(question),
            p_options: options.map(PickupGamePollValidation.normalizeOption),
            p_allow_multiple: allowMultiple,
            p_is_anonymous: isAnonymous,
            p_auto_close_at_game_start: autoCloseAtGameStart
        )
        do {
            let data = try await client
                .rpc("create_pickup_game_poll", params: params)
                .execute()
                .data
            return try decodeUUID(from: data)
        } catch {
#if DEBUG
            print("[PickupPoll] create failed error=\(error)")
#endif
            throw mapError(error, fallback: .createFailed)
        }
    }

    func attachMessage(pollId: UUID, messageId: UUID) async throws {
        struct Params: Encodable {
            let p_poll_id: UUID
            let p_message_id: UUID
        }
        try await client
            .rpc("attach_pickup_game_poll_message", params: Params(p_poll_id: pollId, p_message_id: messageId))
            .execute()
    }

    func setVote(pollId: UUID, optionIds: [UUID]) async throws {
        struct Params: Encodable {
            let p_poll_id: UUID
            let p_option_ids: [UUID]
        }
        do {
            try await client
                .rpc("set_pickup_game_poll_vote", params: Params(p_poll_id: pollId, p_option_ids: optionIds))
                .execute()
        } catch {
#if DEBUG
            print("[PickupPoll] vote failed poll=\(pollId.uuidString.lowercased())")
#endif
            throw mapError(error, fallback: .voteFailed)
        }
    }

    func closePoll(pollId: UUID) async throws {
        struct Params: Encodable { let p_poll_id: UUID }
        do {
            try await client
                .rpc("close_pickup_game_poll", params: Params(p_poll_id: pollId))
                .execute()
        } catch {
            throw mapError(error, fallback: .closeFailed)
        }
    }

    func deletePoll(pollId: UUID) async throws {
        struct Params: Encodable { let p_poll_id: UUID }
        do {
            try await client
                .rpc("delete_pickup_game_poll", params: Params(p_poll_id: pollId))
                .execute()
        } catch {
            throw mapError(error, fallback: .deleteFailed)
        }
    }

    /// Future-ready pin hook.
    func setPinned(pollId: UUID, pinned: Bool) async throws {
        struct Params: Encodable {
            let p_poll_id: UUID
            let p_pinned: Bool
        }
        do {
            try await client
                .rpc("pin_pickup_game_poll", params: Params(p_poll_id: pollId, p_pinned: pinned))
                .execute()
        } catch {
            throw mapError(error, fallback: .pinFailed)
        }
    }

    func fetchSnapshot(pollId: UUID) async throws -> PickupGamePollSnapshot {
        struct Params: Encodable { let p_poll_id: UUID }
        do {
            return try await client
                .rpc("get_pickup_game_poll_snapshot", params: Params(p_poll_id: pollId))
                .execute()
                .value
        } catch {
#if DEBUG
            print("[PickupPoll] snapshot failed poll=\(pollId.uuidString.lowercased())")
#endif
            throw mapError(error, fallback: .snapshotFailed)
        }
    }

    /// Vote RPCs bump `pickup_game_polls.updated_at`, so poll UPDATE realtime covers vote changes.
    func pollUpdatesChannel(conversationId: UUID) -> (RealtimeChannelV2, AsyncStream<UpdateAction>) {
        let cid = conversationId.uuidString.lowercased()
        let channel = client.channel("pickup-polls-\(cid)")
        let filter = RealtimePostgresFilter.eq("conversation_id", value: cid)
        let updates = channel.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "pickup_game_polls",
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
        throw PickupGamePollServiceError.createFailed
    }

    private func mapError(_ error: Error, fallback: PickupGamePollServiceError) -> Error {
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("not authenticated") {
            return PickupGamePollServiceError.notAuthenticated
        }
        if !text.isEmpty, text != "The operation couldn’t be completed." {
            return error
        }
        return fallback
    }
}
