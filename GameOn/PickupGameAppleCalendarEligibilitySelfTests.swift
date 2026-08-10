import Foundation

#if DEBUG
enum PickupGameAppleCalendarEligibilitySelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[PickupAppleCalendarEligibilityTest] PASS \(name)")
            } else {
                failures += 1
                print("[PickupAppleCalendarEligibilityTest] FAIL \(name)")
            }
        }

        let id = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let key = PickupGameAppleCalendarEligibility.fanGeoIdentifier(forPickupGameId: id)
        expect(key == "pickup|\(id.uuidString.lowercased())", "stable pickup| id key")
        expect(
            PickupGameAppleCalendarEligibility.pickupGameId(fromFanGeoIdentifier: key) == id,
            "round-trip identifier"
        )

        expect(PickupGameAppleCalendarEligibility.shouldSyncHostedGame(status: "active"), "hosted active")
        expect(!PickupGameAppleCalendarEligibility.shouldSyncHostedGame(status: "removed"), "hosted removed no")

        expect(
            PickupGameAppleCalendarEligibility.shouldSyncJoinPill(.approved, isTeamLinked: false),
            "approved normal"
        )
        expect(
            PickupGameAppleCalendarEligibility.shouldSyncJoinPill(.approved, isTeamLinked: true),
            "approved team Going"
        )
        expect(
            !PickupGameAppleCalendarEligibility.shouldSyncJoinPill(.pending, isTeamLinked: false),
            "pending normal join no"
        )
        expect(
            PickupGameAppleCalendarEligibility.shouldSyncJoinPill(.pending, isTeamLinked: true),
            "pending team Maybe yes"
        )
        expect(
            !PickupGameAppleCalendarEligibility.shouldSyncJoinPill(.canceledByOrganizer, isTeamLinked: true),
            "canceled no"
        )

        expect(
            PickupGameAppleCalendarEligibility.shouldSyncRequestStatus("approved", isTeamLinked: false),
            "request approved"
        )
        expect(
            PickupGameAppleCalendarEligibility.shouldSyncRequestStatus("pending", isTeamLinked: true),
            "request pending team"
        )
        expect(
            !PickupGameAppleCalendarEligibility.shouldSyncRequestStatus("withdrawn", isTeamLinked: true),
            "cant_go withdrawn no"
        )

        expect(PickupGameAppleCalendarEligibility.shouldSyncInviteStatus("accepted"), "invite accepted")
        expect(PickupGameAppleCalendarEligibility.shouldSyncInviteStatus("maybe"), "invite maybe")
        expect(!PickupGameAppleCalendarEligibility.shouldSyncInviteStatus("pending"), "invite unanswered no")

        if failures == 0 {
            print("[PickupAppleCalendarEligibilityTest] ALL PASSED")
        } else {
            print("[PickupAppleCalendarEligibilityTest] FAILED count=\(failures)")
        }
    }
}
#endif
