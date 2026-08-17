import Foundation
import Supabase

enum FanTeamAnnouncementUserStateServiceError: LocalizedError {
    case notAuthenticated
    case clearFailed
    case listFailed
    case readFailed

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not authenticated"
        case .clearFailed: return "Could not clear announcement"
        case .listFailed: return "Could not load cleared announcements"
        case .readFailed: return "Could not mark announcement read"
        }
    }
}

/// Per-user Team announcement Overview state (`fan_team_announcement_user_state`).
/// Clear is personal presentation state — never deletes the Team announcement.
enum FanTeamAnnouncementUserStateService {
    private static var client: SupabaseClient { supabase }

    struct ClearedIdRow: Decodable, Sendable {
        let announcement_id: UUID
    }

    static func listClearedAnnouncementIds(teamId: UUID) async throws -> Set<UUID> {
        struct Params: Encodable { let p_team_id: UUID }
        do {
            let rows: [ClearedIdRow] = try await client
                .rpc(
                    "list_my_cleared_fan_team_announcement_ids",
                    params: Params(p_team_id: teamId)
                )
                .execute()
                .value
            return Set(rows.map(\.announcement_id))
        } catch {
            throw map(error, fallback: .listFailed)
        }
    }

    static func clearAnnouncement(announcementId: UUID) async throws {
        struct Params: Encodable { let p_announcement_id: UUID }
        do {
            try await client
                .rpc(
                    "clear_fan_team_announcement_for_viewer",
                    params: Params(p_announcement_id: announcementId)
                )
                .execute()
        } catch {
            throw map(error, fallback: .clearFailed)
        }
    }

    /// Marks read without clearing Overview visibility.
    static func markRead(announcementId: UUID) async throws {
        struct Params: Encodable { let p_announcement_id: UUID }
        do {
            try await client
                .rpc(
                    "mark_fan_team_announcement_read_for_viewer",
                    params: Params(p_announcement_id: announcementId)
                )
                .execute()
        } catch {
            throw map(error, fallback: .readFailed)
        }
    }

    private static func map(
        _ error: Error,
        fallback: FanTeamAnnouncementUserStateServiceError
    ) -> FanTeamAnnouncementUserStateServiceError {
        let text = error.localizedDescription.lowercased()
        if text.contains("not authenticated") { return .notAuthenticated }
        return fallback
    }
}
