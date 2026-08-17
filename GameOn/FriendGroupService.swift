import Foundation
import Supabase

/// Server-backed private Friend Groups. Mutations are RPC-only; reads prefer RPCs.
final class FriendGroupService {
    private let client: SupabaseClient

    init(client: SupabaseClient = supabase) {
        self.client = client
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return isoFractional.date(from: raw) ?? isoPlain.date(from: raw)
    }

    // MARK: - Rows

    private struct GroupRow: Decodable {
        let id: UUID
        let name: String
        let member_count: Int
        let created_at: String?
        let updated_at: String?

        func asModel() -> FriendGroup {
            FriendGroup(
                id: id,
                name: name,
                memberCount: member_count,
                createdAt: FriendGroupService.parseDate(created_at),
                updatedAt: FriendGroupService.parseDate(updated_at)
            )
        }
    }

    private struct MemberRow: Decodable {
        let friend_user_id: UUID
        let created_at: String?
    }

    // MARK: - API

    func listMyFriendGroups() async throws -> [FriendGroup] {
        let rows: [GroupRow] = try await client
            .rpc("list_my_friend_groups")
            .execute()
            .value
        return rows.map { $0.asModel() }
    }

    func createFriendGroup(name: String) async throws -> FriendGroup {
        struct Params: Encodable {
            let p_name: String
        }
        let normalized = FriendGroupNameValidation.normalized(name)
        let rows: [GroupRow] = try await client
            .rpc("create_friend_group", params: Params(p_name: normalized))
            .execute()
            .value
        guard let row = rows.first else {
            throw FriendGroupServiceError.emptyResponse
        }
        return row.asModel()
    }

    func renameFriendGroup(groupId: UUID, name: String) async throws -> FriendGroup {
        struct Params: Encodable {
            let p_group_id: UUID
            let p_name: String
        }
        let normalized = FriendGroupNameValidation.normalized(name)
        let rows: [GroupRow] = try await client
            .rpc(
                "rename_friend_group",
                params: Params(p_group_id: groupId, p_name: normalized)
            )
            .execute()
            .value
        guard let row = rows.first else {
            throw FriendGroupServiceError.emptyResponse
        }
        return row.asModel()
    }

    func deleteFriendGroup(groupId: UUID) async throws {
        struct Params: Encodable {
            let p_group_id: UUID
        }
        try await client
            .rpc("delete_friend_group", params: Params(p_group_id: groupId))
            .execute()
    }

    /// Returns accepted-friend member user ids for an owned group (one RPC).
    func listFriendGroupMemberIds(groupId: UUID) async throws -> [UUID] {
        struct Params: Encodable {
            let p_group_id: UUID
        }
        let rows: [MemberRow] = try await client
            .rpc("list_friend_group_members", params: Params(p_group_id: groupId))
            .execute()
            .value
        return rows.map(\.friend_user_id)
    }

    /// Batch replace membership. Backend rejects any non-friend id.
    @discardableResult
    func setFriendGroupMembers(groupId: UUID, friendUserIds: [UUID]) async throws -> [UUID] {
        struct Params: Encodable {
            let p_group_id: UUID
            let p_friend_user_ids: [UUID]
        }
        let unique = Array(Set(friendUserIds))
        let rows: [MemberRow] = try await client
            .rpc(
                "set_friend_group_members",
                params: Params(p_group_id: groupId, p_friend_user_ids: unique)
            )
            .execute()
            .value
        return rows.map(\.friend_user_id)
    }

    /// Multi-group assignment for one friend (••• → Add to Friend Group).
    func setFriendMembershipInGroups(friendUserId: UUID, groupIds: [UUID]) async throws {
        struct Params: Encodable {
            let p_friend_user_id: UUID
            let p_group_ids: [UUID]
        }
        try await client
            .rpc(
                "set_friend_membership_in_groups",
                params: Params(
                    p_friend_user_id: friendUserId,
                    p_group_ids: Array(Set(groupIds))
                )
            )
            .execute()
    }

    func listMyFriendGroupsContainingFriend(friendUserId: UUID) async throws -> [FriendGroup] {
        struct Params: Encodable {
            let p_friend_user_id: UUID
        }
        let rows: [GroupRow] = try await client
            .rpc(
                "list_my_friend_groups_containing_friend",
                params: Params(p_friend_user_id: friendUserId)
            )
            .execute()
            .value
        return rows.map { $0.asModel() }
    }
}

enum FriendGroupServiceError: LocalizedError {
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "Friend group response was empty."
        }
    }
}
