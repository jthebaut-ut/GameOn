import Foundation

#if DEBUG
enum GoingActionCenterSelfTests {
    /// Projection tests only. Going no longer presents this list; FanGeo Inbox is authoritative.
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[GoingActionCenterTest] PASS \(name)")
            } else {
                failures += 1
                print("[GoingActionCenterTest] FAIL \(name)")
            }
        }

        let language = "en"
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let signedOut = GoingActionCenter.summary(
            from: .init(
                pickupInvites: [
                    invite(gameTitle: "Saturday Match")
                ],
                isSignedIn: false
            ),
            languageCode: language,
            now: now
        )
        expect(signedOut.isEmpty, "signed-out → no Going actions")
        expect(signedOut.badgeCount == 0, "signed-out badge is 0")

        let empty = GoingActionCenter.summary(
            from: .init(isSignedIn: true),
            languageCode: language,
            now: now
        )
        expect(empty.isEmpty, "no actionable inputs → empty")
        expect(empty.badgeCount == 0, "empty badge is 0")

        let inviteGameId = UUID()
        let joinGameId = UUID()
        let timeGameId = UUID()
        let mixed = GoingActionCenter.summary(
            from: .init(
                pickupInvites: [
                    invite(
                        pickupGameId: inviteGameId,
                        gameTitle: "Saturday Match",
                        startAt: now.addingTimeInterval(86_400 * 3)
                    )
                ],
                joinApprovals: [
                    joinApproval(pickupGameId: joinGameId, requesterName: "Emma", gameTitle: "Practice")
                ],
                scheduleActivities: [
                    scheduleActivity(
                        pickupGameId: timeGameId,
                        title: "Saturday Match",
                        details: [
                            FanGeoActionChangeDetail(
                                labelKey: "action_center_change_time",
                                oldValue: "6:00 PM",
                                newValue: "7:30 PM"
                            )
                        ]
                    )
                ],
                isSignedIn: true
            ),
            languageCode: language,
            now: now
        )
        expect(mixed.count == 3, "invite + join + time change = 3")
        expect(mixed.badgeCount == mixed.items.count, "badge equals Action Needed count")
        expect(mixed.items.contains { $0.kind == .newInvitation }, "future invite is newInvitation")
        expect(mixed.items.contains { $0.kind == .confirmationNeeded }, "join is confirmationNeeded")
        expect(
            mixed.items.contains { $0.kind == .scheduleChanged && $0.titleKey == "going_action_needed_time_changed_format" },
            "time-only change uses time-changed copy"
        )
        expect(
            mixed.items.contains { $0.destination == .pickupInvites },
            "invite routes to pickup invites"
        )

        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        let rsvp = GoingActionCenter.summary(
            from: .init(
                pickupInvites: [
                    invite(gameTitle: "Practice", startAt: tomorrowStart)
                ],
                isSignedIn: true
            ),
            languageCode: language,
            now: now,
            calendar: calendar
        )
        expect(
            rsvp.items.count == 1 && rsvp.items[0].kind == .requiresRSVP,
            "tomorrow invite is requiresRSVP"
        )
        expect(
            rsvp.items[0].titleKey == "going_action_needed_rsvp_tomorrow_format",
            "tomorrow invite uses RSVP tomorrow copy"
        )

        let location = GoingActionCenter.summary(
            from: .init(
                scheduleActivities: [
                    scheduleActivity(
                        title: "League Game",
                        details: [
                            FanGeoActionChangeDetail(
                                labelKey: "action_center_change_location",
                                oldValue: "Park A",
                                newValue: "Park B"
                            )
                        ]
                    )
                ],
                isSignedIn: true
            ),
            languageCode: language,
            now: now
        )
        expect(
            location.items.count == 1 && location.items[0].kind == .locationChanged,
            "location-only change is locationChanged"
        )

        let both = GoingActionCenter.summary(
            from: .init(
                scheduleActivities: [
                    scheduleActivity(
                        title: "League Game",
                        details: [
                            FanGeoActionChangeDetail(
                                labelKey: "action_center_change_time",
                                oldValue: nil,
                                newValue: nil
                            ),
                            FanGeoActionChangeDetail(
                                labelKey: "action_center_change_location",
                                oldValue: nil,
                                newValue: nil
                            )
                        ]
                    )
                ],
                isSignedIn: true
            ),
            languageCode: language,
            now: now
        )
        expect(
            both.items.count == 1 && both.items[0].kind == .scheduleChanged,
            "time+location on one game is a single scheduleChanged row"
        )

        let cancelled = GoingActionCenter.summary(
            from: .init(
                scheduleActivities: [
                    scheduleActivity(title: "Saturday Match", isCancellation: true)
                ],
                isSignedIn: true
            ),
            languageCode: language,
            now: now
        )
        expect(
            cancelled.items.count == 1 && cancelled.items[0].kind == .cancelled,
            "cancellation maps to cancelled"
        )

        let rating = GoingActionCenter.summary(
            from: .init(
                pendingRatings: [
                    FanGeoActionPendingRatingInput(
                        pickupGameId: UUID(),
                        organizerUserId: UUID(),
                        organizerName: "Alex",
                        organizerAvatarURL: nil,
                        gameTitle: "Rock Climbing",
                        teamName: nil,
                        eventTypeLabel: nil,
                        matchupLabel: nil,
                        startAt: nil
                    )
                ],
                isSignedIn: true
            ),
            languageCode: language,
            now: now
        )
        expect(
            rating.badgeCount == 1 && rating.items[0].kind == .pendingRating,
            "pending rating is an Action Needed row"
        )
        expect(rating.items[0].destination == .pendingRating, "rating routes to pendingRating")

        let aggregate = GoingActionCenter.summary(
            from: .init(
                pendingJoinApprovalCount: 2,
                isSignedIn: true
            ),
            languageCode: language,
            now: now
        )
        expect(
            aggregate.badgeCount == 1 && aggregate.items[0].kind == .confirmationNeeded,
            "join-count fallback is one confirmation row"
        )

        let soonPickupId = UUID()
        let soonWatchId = UUID()
        let soon = GoingActionCenter.summary(
            from: .init(
                startsSoon: [
                    GoingActionStartsSoonInput(
                        id: soonPickupId,
                        title: "Lunch Run",
                        startAt: now.addingTimeInterval(20 * 60),
                        surface: .pickup
                    ),
                    GoingActionStartsSoonInput(
                        id: soonWatchId,
                        title: "Watch party",
                        startAt: now.addingTimeInterval(50 * 60),
                        surface: .watch
                    ),
                    GoingActionStartsSoonInput(
                        id: UUID(),
                        title: "Too far",
                        startAt: now.addingTimeInterval(2 * 3600),
                        surface: .pickup
                    )
                ],
                isSignedIn: true
            ),
            languageCode: language,
            now: now
        )
        expect(soon.badgeCount == 2, "startsSoon only includes the 1-hour window")
        expect(soon.items.contains { $0.destination == .watching }, "watch party routes to watching")
        expect(
            soon.items.contains { $0.titleKey == "going_action_needed_starts_soon_minutes_format" },
            "under 45 minutes uses minute copy"
        )
        expect(
            soon.items.contains { $0.titleKey == "going_action_needed_starts_soon_hour_format" },
            "45–60 minutes uses 1-hour copy"
        )

        let overlapGameId = UUID()
        let overlap = GoingActionCenter.summary(
            from: .init(
                pickupInvites: [
                    invite(pickupGameId: overlapGameId, gameTitle: "Overlap")
                ],
                startsSoon: [
                    GoingActionStartsSoonInput(
                        id: overlapGameId,
                        title: "Overlap",
                        startAt: now.addingTimeInterval(30 * 60),
                        surface: .pickup
                    )
                ],
                isSignedIn: true
            ),
            languageCode: language,
            now: now
        )
        expect(overlap.badgeCount == 1, "startsSoon does not double-count an invited game")
        expect(overlap.items[0].kind == .newInvitation, "invite wins over startsSoon")

        let custom = GoingActionCenter.summary(
            from: .init(
                customItems: [
                    GoingActionItem(
                        id: "going_custom:demo",
                        kind: .custom("venueEvent"),
                        titleKey: "going_action_needed_confirmation_needed",
                        destination: .watching
                    )
                ],
                isSignedIn: true
            ),
            languageCode: language,
            now: now
        )
        expect(
            custom.badgeCount == 1 && custom.items[0].kind == .custom("venueEvent"),
            "custom items are first-class Action Needed rows"
        )

        let savedContentDoesNotBadge = GoingActionCenter.summary(
            from: .init(isSignedIn: true),
            languageCode: language,
            now: now
        )
        expect(
            savedContentDoesNotBadge.badgeCount == 0,
            "no invites/changes/ratings → badge stays 0 (saved content is not an action)"
        )

        if failures == 0 {
            print("[GoingActionCenterTest] ALL PASSED")
        } else {
            print("[GoingActionCenterTest] FAILURES=\(failures)")
            assertionFailure("GoingActionCenterSelfTests failed: \(failures)")
        }
    }

    private static func invite(
        inviteId: UUID = UUID(),
        pickupGameId: UUID = UUID(),
        gameTitle: String,
        startAt: Date? = nil
    ) -> FanGeoActionPickupInviteInput {
        FanGeoActionPickupInviteInput(
            inviteId: inviteId,
            pickupGameId: pickupGameId,
            gameTitle: gameTitle,
            teamName: nil,
            eventTypeLabel: nil,
            startAt: startAt,
            locationLabel: nil,
            inviterName: nil
        )
    }

    private static func joinApproval(
        requestId: UUID = UUID(),
        pickupGameId: UUID,
        requesterName: String,
        gameTitle: String
    ) -> FanGeoActionJoinApprovalInput {
        FanGeoActionJoinApprovalInput(
            requestId: requestId,
            pickupGameId: pickupGameId,
            requesterUserId: UUID(),
            requesterName: requesterName,
            requesterAvatarURL: nil,
            gameTitle: gameTitle,
            teamName: nil,
            teamId: nil,
            eventTypeLabel: nil,
            startAt: nil,
            locationLabel: nil
        )
    }

    private static func scheduleActivity(
        pickupGameId: UUID = UUID(),
        title: String,
        isCancellation: Bool = false,
        details: [FanGeoActionChangeDetail] = []
    ) -> FanGeoActionScheduleActivityInput {
        FanGeoActionScheduleActivityInput(
            pickupGameId: pickupGameId,
            title: title,
            teamName: nil,
            eventTypeLabel: nil,
            startAt: nil,
            locationLabel: nil,
            isCancellation: isCancellation,
            changeDetails: details,
            moreChangesCount: 0
        )
    }
}
#endif
