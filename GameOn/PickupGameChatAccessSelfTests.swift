import Foundation

/// Shared UI gate used by the pickup detail sheet. Must stay aligned with
/// `is_pickup_game_chat_authorized` on the server (organizer ∪ approved).
/// Server RLS/RPC remain authoritative — this only controls entry-point visibility.
enum PickupGameChatAccessPolicy {
    static func canAccess(
        isAuthenticated: Bool,
        isCreator: Bool,
        joinRequestStatus: String?
    ) -> Bool {
        guard isAuthenticated else { return false }
        if isCreator { return true }
        let status = joinRequestStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return status == "approved"
    }

    static func showsLockedHint(
        isAuthenticated: Bool,
        isCreator: Bool,
        joinRequestStatus: String?
    ) -> Bool {
        guard isAuthenticated, !isCreator else { return false }
        guard !canAccess(isAuthenticated: isAuthenticated, isCreator: isCreator, joinRequestStatus: joinRequestStatus) else {
            return false
        }
        let status = joinRequestStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return status == "pending"
    }
}

#if DEBUG
/// Client-side access-policy regression tests for pickup-game chat.
enum PickupGameChatAccessSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[PickupGameChatAccessTest] PASS \(name)")
            } else {
                failures += 1
                print("[PickupGameChatAccessTest] FAIL \(name)")
            }
        }

        expect(
            PickupGameChatAccessPolicy.canAccess(
                isAuthenticated: true,
                isCreator: true,
                joinRequestStatus: nil
            ),
            "organizer_access"
        )

        expect(
            PickupGameChatAccessPolicy.canAccess(
                isAuthenticated: true,
                isCreator: false,
                joinRequestStatus: "approved"
            ),
            "approved_access"
        )

        for status in ["pending", "rejected", "cancelled", "canceled", "withdrawn", "declined", nil] as [String?] {
            expect(
                !PickupGameChatAccessPolicy.canAccess(
                    isAuthenticated: true,
                    isCreator: false,
                    joinRequestStatus: status
                ),
                "deny_\(status ?? "nil")"
            )
        }

        expect(
            !PickupGameChatAccessPolicy.canAccess(
                isAuthenticated: false,
                isCreator: true,
                joinRequestStatus: nil
            ),
            "deny_signed_out_even_if_creator_flag"
        )

        expect(
            PickupGameChatAccessPolicy.showsLockedHint(
                isAuthenticated: true,
                isCreator: false,
                joinRequestStatus: "pending"
            ),
            "pending_locked_hint"
        )
        expect(
            !PickupGameChatAccessPolicy.showsLockedHint(
                isAuthenticated: true,
                isCreator: false,
                joinRequestStatus: "rejected"
            ),
            "rejected_no_locked_hint"
        )
        expect(
            !PickupGameChatAccessPolicy.showsLockedHint(
                isAuthenticated: true,
                isCreator: false,
                joinRequestStatus: nil
            ),
            "stranger_no_locked_hint"
        )
        expect(
            !PickupGameChatAccessPolicy.showsLockedHint(
                isAuthenticated: true,
                isCreator: true,
                joinRequestStatus: nil
            ),
            "organizer_no_locked_hint"
        )

        let context = PickupGameChatContext(
            pickupGameId: UUID(),
            title: "Saturday Soccer",
            sportLabel: "Soccer",
            whenLabel: "Jul 26 · 5:00 PM",
            locationLabel: "Central Park",
            approvedParticipantCount: 4
        )
        expect(context.headerSubtitle.contains("Soccer"), "context_sport")
        expect(context.headerSubtitle.contains("4 approved"), "context_count")

        print("[PickupGameChatAccessTest] completed failures=\(failures)")
    }
}
#endif
