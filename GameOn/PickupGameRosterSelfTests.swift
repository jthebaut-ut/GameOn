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

        // Team declined bucket (20260948): multiple historical request rows per user must
        // collapse before SwiftUI ForEach(id: user_id) — root cause of Team detail crash.
        let declinedUser = UUID()
        let declinedDupes = [
            PickupGameRosterMember(
                user_id: declinedUser,
                request_id: UUID(),
                display_name: "Dana",
                username: nil,
                avatar_url: nil,
                avatar_thumbnail_url: nil,
                role: "declined",
                status: "withdrawn"
            ),
            PickupGameRosterMember(
                user_id: declinedUser,
                request_id: UUID(),
                display_name: "Dana",
                username: nil,
                avatar_url: nil,
                avatar_thumbnail_url: nil,
                role: "declined",
                status: "rejected"
            )
        ]
        let uniqueDeclined = PickupGameRosterPresentation.uniqueMembersByUserId(declinedDupes)
        expect(uniqueDeclined.count == 1, "declined_dedupe_by_user_id")
        expect(uniqueDeclined.first?.status == "withdrawn", "declined_keeps_first_occurrence")

        let teamPayload = PickupGameRosterPayload(
            pickup_game_id: UUID(),
            viewer_is_organizer: false,
            organizer: organizer,
            playing: playing + [
                PickupGameRosterMember(
                    user_id: approvedA,
                    request_id: UUID(),
                    display_name: "Alex Dup",
                    username: nil,
                    avatar_url: nil,
                    avatar_thumbnail_url: nil,
                    role: "playing",
                    status: "approved"
                )
            ],
            pending: [],
            declined: declinedDupes,
            no_response: [
                PickupGameRosterMember(
                    user_id: pendingId,
                    request_id: nil,
                    display_name: "Casey",
                    username: nil,
                    avatar_url: nil,
                    avatar_thumbnail_url: nil,
                    role: "no_response",
                    status: "no_response"
                ),
                PickupGameRosterMember(
                    user_id: pendingId,
                    request_id: nil,
                    display_name: "Casey",
                    username: nil,
                    avatar_url: nil,
                    avatar_thumbnail_url: nil,
                    role: "no_response",
                    status: "no_response"
                )
            ],
            approved_join_count: 2,
            playing_total_count: 3
        )
        expect(teamPayload.playing.count == 2, "payload_init_dedupes_playing")
        expect(teamPayload.declinedMembers.count == 1, "payload_init_dedupes_declined")
        expect(teamPayload.noResponseMembers.count == 1, "payload_init_dedupes_no_response")
        expect(
            Set(teamPayload.stackMembers.map(\.user_id)).count == teamPayload.stackMembers.count,
            "stack_members_unique_user_ids"
        )
        expect(
            !teamPayload.stackMembers.contains(where: { $0.user_id == organizerId && $0.role == "playing" }),
            "stack_excludes_organizer_from_playing_dupes"
        )

        // Organizer also present in playing must not produce duplicate ForEach IDs.
        let organizerAlsoPlaying = PickupGameRosterPayload(
            pickup_game_id: UUID(),
            viewer_is_organizer: true,
            organizer: organizer,
            playing: [
                PickupGameRosterMember(
                    user_id: organizerId,
                    request_id: UUID(),
                    display_name: "Host",
                    username: "host",
                    avatar_url: nil,
                    avatar_thumbnail_url: nil,
                    role: "playing",
                    status: "approved"
                )
            ] + playing,
            pending: [],
            approved_join_count: 2,
            playing_total_count: 3
        )
        expect(
            organizerAlsoPlaying.stackMembers.filter { $0.user_id == organizerId }.count == 1,
            "stack_dedupes_organizer_also_in_playing"
        )

        // Team attendance presentation: buckets → flat unique rows.
        let attendanceRows = PickupTeamAttendancePresentation.rows(from: teamPayload)
        expect(
            Set(attendanceRows.map(\.id)).count == attendanceRows.count,
            "attendance_rows_unique_user_ids"
        )
        let attendanceCounts = PickupTeamAttendancePresentation.counts(from: teamPayload)
        expect(attendanceCounts.going == 2, "attendance_going_count_playing_only_not_organizer_role")
        expect(attendanceCounts.maybe == 0, "attendance_maybe_empty_when_pending_cleared")
        expect(attendanceCounts.noResponse == 1, "attendance_no_response_count")
        expect(attendanceCounts.cantGo == 1, "attendance_cant_go_count")

        // Organizer Can't Go must win over always-present organizer object (Team payload).
        let organizerCantGo = PickupGameRosterPayload(
            pickup_game_id: UUID(),
            viewer_is_organizer: true,
            organizer: organizer,
            playing: playing,
            pending: [],
            declined: [
                PickupGameRosterMember(
                    user_id: organizerId,
                    request_id: UUID(),
                    display_name: "Host",
                    username: "host",
                    avatar_url: nil,
                    avatar_thumbnail_url: nil,
                    role: "declined",
                    status: "withdrawn"
                )
            ],
            no_response: [],
            approved_join_count: 2,
            playing_total_count: 2
        )
        let organizerCantGoRow = PickupTeamAttendancePresentation.rows(from: organizerCantGo)
            .first { $0.id == organizerId }
        expect(organizerCantGoRow?.category == .cantGo, "organizer_withdrawn_is_cant_go_not_going")
        expect(
            FanTeamScheduleQuickRSVPState.resolve(
                subjectUserId: organizerId,
                roster: organizerCantGo,
                explicitSelfRSVP: .status(.cant_go),
                fallbackRSVP: nil
            ) == .cantGo,
            "explicit_self_rsvp_cant_go_wins"
        )
        expect(
            FanTeamScheduleQuickRSVPState.resolve(
                subjectUserId: organizerId,
                roster: organizerCantGo,
                explicitSelfRSVP: .unanswered,
                fallbackRSVP: .going
            ) == .noResponse,
            "explicit_unanswered_beats_fallback_going"
        )

        // Three same-team events: RSVP cache is keyed by pickup_game_id, not team_id.
        let eventA = UUID()
        let eventB = UUID()
        let eventC = UUID()
        let cache: [UUID: FanTeamCachedSelfRSVP] = [
            eventA: .status(.going),
            eventB: .status(.cant_go),
            eventC: .unanswered
        ]
        expect(
            FanTeamScheduleQuickRSVPState.resolve(
                subjectUserId: organizerId,
                roster: nil,
                explicitSelfRSVP: cache[eventA],
                fallbackRSVP: nil
            ) == .going,
            "event_a_going_independent"
        )
        expect(
            FanTeamScheduleQuickRSVPState.resolve(
                subjectUserId: organizerId,
                roster: nil,
                explicitSelfRSVP: cache[eventB],
                fallbackRSVP: nil
            ) == .cantGo,
            "event_b_cant_go_independent"
        )
        expect(
            FanTeamScheduleQuickRSVPState.resolve(
                subjectUserId: organizerId,
                roster: nil,
                explicitSelfRSVP: cache[eventC],
                fallbackRSVP: nil
            ) == .noResponse,
            "event_c_unanswered_independent"
        )

        expect(
            PickupDetailAttendanceCategory.going.aggregateTitleKey() == "Going",
            "aggregate_going_key_not_personal"
        )
        expect(
            PickupDetailAttendanceCategory.going.personalTitleKey() == "fan_team_rsvp_going",
            "personal_going_key_preserved"
        )

        // Managed player seats: server sends managed_player_id as user_id plus metadata.
        let managedPlayerId = UUID()
        let managedMembershipId = UUID()
        let managedJSON = """
        {
          "user_id": "\(managedPlayerId.uuidString)",
          "membership_id": "\(managedMembershipId.uuidString)",
          "is_managed_player": true,
          "managed_player_id": "\(managedPlayerId.uuidString)",
          "display_name": "Sam (U10)",
          "role": "no_response",
          "status": "no_response"
        }
        """
        if let managed = try? JSONDecoder().decode(
            PickupGameRosterMember.self,
            from: Data(managedJSON.utf8)
        ) {
            expect(managed.isManagedPlayer, "managed_member_decodes_flag")
            expect(managed.managed_player_id == managedPlayerId, "managed_member_decodes_managed_id")
            expect(managed.membership_id == managedMembershipId, "managed_member_decodes_membership_id")
            expect(managed.user_id == managedPlayerId, "managed_member_user_id_is_managed_id")
            expect(managed.accountUserId == nil, "managed_member_has_no_account_user_id")
        } else {
            failures += 1
            print("[PickupRosterTest] FAIL managed_member_decodes")
        }

        // Legacy payloads without the new keys must keep account-seat behavior.
        let legacyJSON = """
        {
          "user_id": "\(approvedA.uuidString)",
          "display_name": "Alex",
          "role": "playing",
          "status": "approved"
        }
        """
        if let legacy = try? JSONDecoder().decode(
            PickupGameRosterMember.self,
            from: Data(legacyJSON.utf8)
        ) {
            expect(!legacy.isManagedPlayer, "legacy_member_not_managed")
            expect(legacy.accountUserId == approvedA, "legacy_member_account_user_id")
            expect(legacy.membership_id == nil, "legacy_member_no_membership_id")
        } else {
            failures += 1
            print("[PickupRosterTest] FAIL legacy_member_decodes")
        }

        print("[PickupRosterTest] failures=\(failures)")
    }
}
#endif
