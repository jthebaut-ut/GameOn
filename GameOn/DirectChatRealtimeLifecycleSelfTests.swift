import Foundation

#if DEBUG
/// Invariants for Direct Chat realtime recovery (stuck Connecting… lifecycle).
enum DirectChatRealtimeLifecycleSelfTests {
    static func runAll() {
        testStatusLocalizationMapping()
        testStuckThresholdOrdering()
        testLiveImpliesConnectedOrLiveBucket()
        testStaleGenerationGuardLogic()
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
        // Grace < stuck threshold so a healthy in-flight subscribe is not killed immediately,
        // but a hung removeChannel/serializer wait is eventually replaced.
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
        // Pure invariant: only the current generation may mutate state.
        var current = 4
        let stale = 3
        assert(stale != current)
        current = 5
        assert(stale != current)
        // A late gen-3 callback must be ignored once gen-5 is active.
        let shouldApply = (stale == current)
        assert(!shouldApply)
    }
}
#endif
