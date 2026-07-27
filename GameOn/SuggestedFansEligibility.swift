import Foundation
import Supabase

/// Filters Suggested Fans using server-authoritative eligibility plus local block/self checks.
///
/// `get_profile_friend_suggestions` already excludes undiscoverable, deleted, business,
/// inactive, blocked, friended/pending/declined, dismissed, and under-13 candidates.
/// Optional profile-row reads still apply when RLS returns a readable row. Public-identity
/// N+1 RPCs are intentionally skipped — the suggestion RPC is the eligibility authority.
enum SuggestedFansEligibility {
    enum ExclusionReason: String {
        case selfUser = "self"
        case blocked = "blocked"
        case deleted = "deleted"
        case notDiscoverable = "not_discoverable"
        case businessAccount = "business_account"
        case inactiveAdmin = "inactive_admin"
        case publicIdentityHidden = "public_identity_hidden"
        /// Row absent because of RLS or transient fetch — not an exclusion by itself.
        case profileRowUnavailable = "profile_row_unavailable"
    }

    struct FilterSummary: Sendable {
        var backendRows: Int = 0
        var decodedRows: Int = 0
        var clientVisibleRows: Int = 0
        var blocked: Int = 0
        var selfExcluded: Int = 0
        var deleted: Int = 0
        var notDiscoverable: Int = 0
        var businessAccount: Int = 0
        var inactiveAdmin: Int = 0
        var publicIdentityHidden: Int = 0
        var profileRowUnavailable: Int = 0
        var alreadyFriends: Int = 0
        var banned: Int = 0
        var missingLocation: Int = 0
        var outsideRadius: Int = 0
        var belowScore: Int = 0
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

        return Dictionary(
            rows.compactMap { row -> (UUID, UserProfileRow)? in
                guard let id = row.id else { return nil }
                return (id, row)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Returns an exclusion reason when the optional readable profile row proves ineligibility.
    /// Returns `nil` when the candidate should proceed to the public-identity visibility check.
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
            // Own-row RLS prevents reading other fans — defer to public identity RPC.
            return nil
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
    ) async -> (eligible: [FriendSuggestionProfile], summary: FilterSummary) {
        var summary = FilterSummary(
            backendRows: suggestions.count,
            decodedRows: suggestions.count
        )
        var eligible: [FriendSuggestionProfile] = []
        eligible.reserveCapacity(suggestions.count)

        for suggestion in suggestions {
            let userId = suggestion.userID
            let row = profileRowsById[userId]
            if row == nil {
                summary.profileRowUnavailable += 1
            }

            if let reason = clientExclusionReason(
                userId: userId,
                profileRow: row,
                viewerId: viewerId,
                isBlocked: isBlocked(userId)
            ) {
                switch reason {
                case .selfUser: summary.selfExcluded += 1
                case .blocked: summary.blocked += 1
                case .deleted: summary.deleted += 1
                case .notDiscoverable: summary.notDiscoverable += 1
                case .businessAccount: summary.businessAccount += 1
                case .inactiveAdmin: summary.inactiveAdmin += 1
                case .publicIdentityHidden, .profileRowUnavailable:
                    break
                }
#if DEBUG
                print("[SuggestedFansDebug] excluded reason=\(reason.rawValue) user_id=\(userId.uuidString.lowercased())")
#endif
                continue
            }

            // Server RPC already enforced discoverable / soft-deleted / business / age / blocks.
            // Preserve order; do not re-rank or N+1 public-identity lookups.
            eligible.append(suggestion)
        }

        summary.clientVisibleRows = eligible.count
        return (eligible, summary)
    }
}
