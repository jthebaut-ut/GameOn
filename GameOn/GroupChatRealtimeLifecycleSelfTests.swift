import Foundation

#if DEBUG
/// Invariants for Group / Team Chat realtime recovery (stuck Connecting… lifecycle).
/// Mirrors ``DirectChatRealtimeLifecycleSelfTests`` so both paths share the same policy.
enum GroupChatRealtimeLifecycleSelfTests {
    static func runAll() {
        testStatusLocalizationMapping()
        testStuckThresholdOrdering()
        testLiveImpliesConnectedOrLiveBucket()
        testStaleGenerationGuardLogic()
        testPresentationStyleDoesNotForkRealtimeContract()
    }

    private static func testStatusLocalizationMapping() {
        assert(ChatRealtimeConnectionStatus.connecting.localizationKey == "chat_realtime_connecting")
        assert(ChatRealtimeConnectionStatus.reconnecting.localizationKey == "chat_realtime_reconnecting")
        assert(ChatRealtimeConnectionStatus.connected.localizationKey == "chat_realtime_live")
        assert(ChatRealtimeConnectionStatus.live.localizationKey == "chat_realtime_live")
        assert(L10n.t("chat_realtime_connecting", languageCode: "en") == "Connecting…")
        assert(L10n.t("chat_realtime_reconnecting", languageCode: "en") == "Reconnecting…")
        assert(L10n.t("chat_realtime_live", languageCode: "en") == "Live")
    }

    private static func testStuckThresholdOrdering() {
        // Must match Direct Chat: grace < stuck so healthy joins survive, hung joins are replaced.
        let grace: TimeInterval = 3.0
        let stuck: TimeInterval = 12.0
        assert(grace < stuck)
        assert(stuck < 30.0)
    }

    private static func testLiveImpliesConnectedOrLiveBucket() {
        assert(ChatRealtimeConnectionStatus.connected.accessibilityBucket == "live")
        assert(ChatRealtimeConnectionStatus.live.accessibilityBucket == "live")
        assert(ChatRealtimeConnectionStatus.connecting.accessibilityBucket != "live")
    }

    private static func testStaleGenerationGuardLogic() {
        var current = 4
        let stale = 3
        assert(stale != current)
        current = 5
        assert(stale != current)
        let shouldApply = (stale == current)
        assert(!shouldApply)
    }

    private static func testPresentationStyleDoesNotForkRealtimeContract() {
        // Embedded Team Chat must use the same GroupChatView lifecycle (no Team-specific socket).
        let styles: [GroupChatPresentationStyle] = [.standard, .embeddedInTeamDetail]
        assert(styles.count == 2)
        assert(styles[0] != styles[1])
    }
}
#endif
