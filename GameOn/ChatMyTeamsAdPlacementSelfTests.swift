import Foundation

#if DEBUG
enum ChatMyTeamsAdPlacementSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[ChatMyTeamsAdPlacementTest] PASS \(name)")
            } else {
                failures += 1
                print("[ChatMyTeamsAdPlacementTest] FAIL \(name)")
            }
        }

        ChatMyTeamsAdPlacement.resetCacheForTesting()

        expect(ChatMyTeamsAdPlacement.insertionPositions(for: 0).isEmpty, "0 teams → no ads")
        expect(ChatMyTeamsAdPlacement.insertionPositions(for: 1) == [1], "1 team → ad after first")
        expect(ChatMyTeamsAdPlacement.insertionPositions(for: 2) == [1], "2 teams → only after first")
        expect(ChatMyTeamsAdPlacement.insertionPositions(for: 5) == [1], "5 teams → only after first")
        expect(ChatMyTeamsAdPlacement.insertionPositions(for: 6) == [1, 6], "6 teams → after 1 and 6")
        expect(ChatMyTeamsAdPlacement.insertionPositions(for: 11) == [1, 6, 11], "11 teams → after 1, 6, 11")
        expect(ChatMyTeamsAdPlacement.insertionPositions(for: 16) == [1, 6, 11, 16], "16 teams cadence")

        expect(ChatMyTeamsAdPlacement.skippedReason(teamCount: 0) == "noTeams", "skip reason for empty")
        expect(ChatMyTeamsAdPlacement.skippedReason(teamCount: 1) == nil, "no skip when teams exist")

        let slots = ChatMyTeamsAdPlacement.nativeAdSlots(for: 11)
        expect(slots.count == 3, "three slots for 11 teams")
        expect(slots.map(\.slotIndex) == [10, 11, 12], "dedicated slot indexes from base 10")
        expect(slots.map(\.insertedAfterTeamPosition) == [1, 6, 11], "slot positions match cadence")

        if failures == 0 {
            print("[ChatMyTeamsAdPlacementTest] ALL PASSED")
        } else {
            print("[ChatMyTeamsAdPlacementTest] FAILURES=\(failures)")
        }
    }
}
#endif
