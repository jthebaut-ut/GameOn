import Foundation

#if DEBUG
/// DEBUG self-tests for pickup roster presentation + privacy helpers.
enum PickupGameRosterSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[PickupRosterTest] PASS \(name)")
            } else {
                failures += 1
                print("[PickupRosterTest] FAIL \(name)")
            }
        }

        let organizerId = UUID()
        let approvedA = UUID()
        let approvedB = UUID()
        let pendingId = UUID()

        let organizer = PickupGameRosterMember(
            user_id: organizerId,
            request_id: nil,
            display_name: "Host",
            username: "host",
            avatar_url: nil,
            avatar_thumbnail_url: nil,
            role: "organizer",
            status: nil
        )
        let playing = [
            PickupGameRosterMember(
                user_id: approvedA,
                request_id: UUID(),
                display_name: "Alex",
                username: nil,
                avatar_url: nil,
                avatar_thumbnail_url: nil,
                role: "playing",
                status: "approved"
            ),
            PickupGameRosterMember(
                user_id: approvedB,
                request_id: UUID(),
                display_name: "Blake",
                username: nil,
                avatar_url: "https://example.com/b.jpg",
                avatar_thumbnail_url: nil,
                role: "playing",
                status: "approved"
            )
        ]
        let pending = [
            PickupGameRosterMember(
                user_id: pendingId,
                request_id: UUID(),
                display_name: "Casey",
                username: nil,
                avatar_url: nil,
                avatar_thumbnail_url: nil,
                role: "pending",
                status: "pending"
            )
        ]

        let publicPayload = PickupGameRosterPayload(
            pickup_game_id: UUID(),
            viewer_is_organizer: false,
            organizer: organizer,
            playing: playing,
            pending: [],
            approved_join_count: 2,
            playing_total_count: 3
        )
        expect(publicPayload.stackMembers.count == 3, "public_stack_organizer_plus_approved")
        expect(publicPayload.playing.count == 2, "public_playing_excludes_organizer_duplicate")
        expect(publicPayload.pending.isEmpty, "public_pending_empty")
        expect(
            PickupGameRosterPresentation.pendingVisibleToViewer(isOrganizer: false, pendingCount: 5) == 0,
            "public_never_sees_pending_count"
        )
        expect(publicPayload.playingTotal == 3, "playing_total_includes_organizer")
        expect(publicPayload.approvedJoinerCount == 2, "approved_joiners_only")
        expect(
            !publicPayload.stackMembers.contains(where: { $0.user_id == pendingId }),
            "pending_absent_from_stack"
        )

        let organizerPayload = PickupGameRosterPayload(
            pickup_game_id: UUID(),
            viewer_is_organizer: true,
            organizer: organizer,
            playing: playing,
            pending: pending,
            approved_join_count: 2,
            playing_total_count: 3
        )
        expect(organizerPayload.viewer_is_organizer, "organizer_flag")
        expect(organizerPayload.pending.count == 1, "organizer_sees_pending")
        expect(
            PickupGameRosterPresentation.pendingVisibleToViewer(isOrganizer: true, pendingCount: 1) == 1,
            "organizer_pending_visible"
        )

        expect(
            PickupGameRosterPresentation.playingDisplayCount(approvedJoinCount: 0) == 1,
            "organizer_only_playing_count"
        )
        expect(
            PickupGameRosterPresentation.playingDisplayCount(approvedJoinCount: 4) == 5,
            "playing_count_not_double_organizer"
        )
        expect(
            PickupGameRosterPresentation.visibleStackCount(total: 1) == 1,
            "stack_one"
        )
        expect(
            PickupGameRosterPresentation.visibleStackCount(total: 4) == 4,
            "stack_four"
        )
        expect(
            PickupGameRosterPresentation.overflowCount(total: 6) == 2,
            "stack_overflow_plus_n"
        )

        // Simulate approve: pending moves to playing
        var simPlaying = playing
        var simPending = pending
        if let moved = simPending.first {
            simPending.removeAll()
            simPlaying.append(
                PickupGameRosterMember(
                    user_id: moved.user_id,
                    request_id: moved.request_id,
                    display_name: moved.display_name,
                    username: moved.username,
                    avatar_url: moved.avatar_url,
                    avatar_thumbnail_url: moved.avatar_thumbnail_url,
                    role: "playing",
                    status: "approved"
                )
            )
        }
        expect(simPending.isEmpty, "approve_clears_pending")
        expect(simPlaying.count == 3, "approve_adds_playing")
        expect(simPlaying.contains(where: { $0.user_id == pendingId }), "approve_moves_user")

        // Simulate decline: pending removed, playing unchanged
        let declinePlaying = playing
        var declinePending = pending
        declinePending.removeAll { $0.user_id == pendingId }
        expect(declinePending.isEmpty, "decline_clears_pending")
        expect(declinePlaying.count == 2, "decline_keeps_playing")

        // Rejected/cancelled/withdrawn never appear in public payload shapes
        let rejectedStatuses = ["rejected", "cancelled", "canceled", "withdrawn"]
        for status in rejectedStatuses {
            expect(
                status != "approved" && status != "pending",
                "status_\(status)_not_public_roster"
            )
        }

        let missingAvatar = PickupGameRosterMember(
            user_id: UUID(),
            request_id: nil,
            display_name: "NoPic",
            username: nil,
            avatar_url: nil,
            avatar_thumbnail_url: nil,
            role: "playing",
            status: "approved"
        )
        expect(missingAvatar.resolvedDisplayName == "NoPic", "missing_avatar_name_fallback")
        expect(
            (missingAvatar.avatar_url ?? "").isEmpty && (missingAvatar.avatar_thumbnail_url ?? "").isEmpty,
            "missing_avatar_urls_empty"
        )

        expect(organizer.isOrganizer, "organizer_role_flag")
        expect(!playing[0].isOrganizer, "player_not_organizer_role")

        print("[PickupRosterTest] failures=\(failures)")
    }
}
#endif
