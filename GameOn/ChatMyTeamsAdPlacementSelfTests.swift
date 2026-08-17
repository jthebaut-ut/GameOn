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
        expect(ChatMyTeamsAdPlacement.insertionPositions(for: 2) == [2], "2 teams → ad after second")
        expect(ChatMyTeamsAdPlacement.insertionPositions(for: 3) == [2], "3 teams → only after second")
        expect(ChatMyTeamsAdPlacement.insertionPositions(for: 4) == [2], "4 teams → only after second")
        expect(ChatMyTeamsAdPlacement.insertionPositions(for: 5) == [2, 5], "5 teams → after 2 and 5")
        expect(ChatMyTeamsAdPlacement.insertionPositions(for: 8) == [2, 5, 8], "8 teams → after 2, 5, 8")
        expect(ChatMyTeamsAdPlacement.insertionPositions(for: 11) == [2, 5, 8, 11], "11 teams cadence every 3")

        expect(ChatMyTeamsAdPlacement.skippedReason(teamCount: 0) == "noTeams", "skip reason for empty")
        expect(ChatMyTeamsAdPlacement.skippedReason(teamCount: 1) == nil, "no skip when teams exist")

        let slots = ChatMyTeamsAdPlacement.nativeAdSlots(for: 8)
        expect(slots.count == 3, "three slots for 8 teams")
        expect(slots.map(\.slotIndex) == [10, 11, 12], "dedicated slot indexes from base 10")
        expect(slots.map(\.insertedAfterTeamPosition) == [2, 5, 8], "slot positions match cadence")
        expect(
            slots.map(\.id) == [
                "chat-my-teams-native-ad-ordinal-0",
                "chat-my-teams-native-ad-ordinal-1",
                "chat-my-teams-native-ad-ordinal-2"
            ],
            "ordinal-stable ids for filter reuse"
        )

        // Pipeline simulation: same insertion helper for each relationship filter list.
        let managingIDs = (0..<5).map { _ in UUID() }
        let joinedIDs = (0..<4).map { _ in UUID() }
        func stubTeams(_ ids: [UUID]) -> [FanTeamSummary] {
            ids.map { id in
                FanTeamSummary(
                    id: id,
                    name: "T",
                    sport: "Soccer",
                    logoURL: nil,
                    logoThumbnailURL: nil,
                    colorHex: nil,
                    competitionLevel: nil,
                    ownerUserId: UUID(),
                    groupConversationId: UUID(),
                    myRole: .member,
                    memberCount: 1,
                    pendingInvitationCount: 0,
                    pushNotificationsMuted: false,
                    nextGameStartsAt: nil,
                    nextGameTitle: nil,
                    nextGameVenue: nil,
                    createdAt: nil
                )
            }
        }

        ChatMyTeamsAdPlacement.resetCacheForTesting()
        let managingItems = ChatMyTeamsAdPlacement.listItems(for: stubTeams(managingIDs))
        let managingAds = managingItems.compactMap { item -> ChatMyTeamsNativeAdSlot? in
            if case .nativeAd(let slot) = item { return slot }
            return nil
        }
        expect(managingAds.map(\.insertedAfterTeamPosition) == [2, 5], "Managing filter inserts ads")

        ChatMyTeamsAdPlacement.resetCacheForTesting()
        let joinedItems = ChatMyTeamsAdPlacement.listItems(for: stubTeams(joinedIDs))
        let joinedAds = joinedItems.compactMap { item -> ChatMyTeamsNativeAdSlot? in
            if case .nativeAd(let slot) = item { return slot }
            return nil
        }
        expect(joinedAds.map(\.insertedAfterTeamPosition) == [2], "Joined filter inserts ads")

        ChatMyTeamsAdPlacement.resetCacheForTesting()
        let emptyItems = ChatMyTeamsAdPlacement.listItems(for: [])
        expect(emptyItems.isEmpty, "empty filtered list → no ads")

        // Switching filter fingerprints must not duplicate ad rows for one list build.
        ChatMyTeamsAdPlacement.resetCacheForTesting()
        let allOnce = ChatMyTeamsAdPlacement.listItems(for: stubTeams(managingIDs + joinedIDs))
        let allAds = allOnce.compactMap { item -> Int? in
            if case .nativeAd(let slot) = item { return slot.ordinal }
            return nil
        }
        expect(Set(allAds).count == allAds.count, "no duplicate ordinals in one list")
        expect(allOnce.filter { if case .team = $0 { return true }; return false }.count == 9, "teams preserved")

        if failures == 0 {
            print("[ChatMyTeamsAdPlacementTest] ALL PASSED")
        } else {
            print("[ChatMyTeamsAdPlacementTest] FAILURES=\(failures)")
        }
    }
}
#endif
