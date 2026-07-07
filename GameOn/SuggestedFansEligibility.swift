import Foundation
import Supabase

/// Filters Suggested Fans to match the same eligibility rules as ``PublicUserProfileService/load(userId:)``.
enum SuggestedFansEligibility {
    enum ExclusionReason: String {
        case selfUser = "self"
        case blocked = "blocked"
        case missingProfileRow = "missing_profile_row"
        case deleted = "deleted"
        case notDiscoverable = "not_discoverable"
        case businessAccount = "business_account"
        case inactiveAdmin = "inactive_admin"
        case publicIdentityHidden = "public_identity_hidden"
    }

    private static let profileSelect =
        "id,email,display_name,username,is_deleted,admin_status,is_business_account,discoverable_by_fans"

    static func fetchProfileRows(for userIds: [UUID]) async -> [UUID: UserProfileRow] {
        let ids = Array(Set(userIds))
        guard !ids.isEmpty else { return [:] }

        let rows: [UserProfileRow] = (try? await supabase
            .from("user_profiles")
            .select(profileSelect)
            .in("id", values: ids.map { $0.uuidString.lowercased() })
            .execute()
            .value) ?? []

        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let id = row.id else { return nil }
            return (id, row)
        })
    }

    static func clientExclusionReason(
        userId: UUID,
        profileRow: UserProfileRow?,
        viewerId: UUID?,
        isBlocked: Bool
    ) -> ExclusionReason? {
        if let viewerId, userId == viewerId {
            return .selfUser
        }
        if isBlocked {
            return .blocked
        }
        guard let row = profileRow else {
            return .missingProfileRow
        }
        if row.isDeletedAccount {
            return .deleted
        }
        if !row.discoverableByFans {
            return .notDiscoverable
        }
        if row.isBusinessIdentity {
            return .businessAccount
        }
        if let adminStatus = row.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !adminStatus.isEmpty,
           adminStatus != "active" {
            return .inactiveAdmin
        }
        return nil
    }

    static func filterSuggestions(
        _ suggestions: [FriendSuggestionProfile],
        viewerId: UUID?,
        profileRowsById: [UUID: UserProfileRow],
        isBlocked: (UUID) -> Bool
    ) async -> [FriendSuggestionProfile] {
#if DEBUG
        print("[SuggestedFansDebug] rawCount=\(suggestions.count)")
#endif

        var eligible: [FriendSuggestionProfile] = []
        eligible.reserveCapacity(suggestions.count)

        for suggestion in suggestions {
            let userId = suggestion.userID
            if let reason = clientExclusionReason(
                userId: userId,
                profileRow: profileRowsById[userId],
                viewerId: viewerId,
                isBlocked: isBlocked(userId)
            ) {
#if DEBUG
                print("[SuggestedFansDebug] excluded reason=\(reason.rawValue) user_id=\(userId.uuidString.lowercased())")
#endif
                continue
            }

            let visible = await PublicUserProfileService.isPublicIdentityVisible(userId: userId)
            guard visible else {
#if DEBUG
                print("[SuggestedFansDebug] excluded reason=\(ExclusionReason.publicIdentityHidden.rawValue) user_id=\(userId.uuidString.lowercased())")
#endif
                continue
            }

            eligible.append(suggestion)
        }

#if DEBUG
        print("[SuggestedFansDebug] finalCount=\(eligible.count)")
#endif
        return eligible
    }
}
