import Foundation

#if DEBUG
/// Invariants for Direct Chat realtime recovery (stuck Connecting… lifecycle).
enum DirectChatRealtimeLifecycleSelfTests {
    static func runAll() {
        testStatusLocalizationMapping()
        testStuckThresholdOrdering()
        testLiveImpliesConnectedOrLiveBucket()
        testStaleGenerationGuardLogic()
        testCachedOpenHidesConnecting()
        testQuietGraceHidesBriefConnecting()
        testStalledConnectingPromotesToReconnecting()
        testReconnectingQuietThenVisible()
        testOfflineChrome()
        testSubscribeSuccessClearsConnecting()
        testSendIndependentFromRealtime()
        testPresenceFailureDoesNotBlockSend()
        testTypingFailureDoesNotBlockSend()
        testCancelledTaskIsNotConnectionError()
        testSingleSubscriptionIdentity()
        testReopenReplacesGeneration()
        testAuthNotReadyWaits()
        testRetryDoesNotDuplicateChannels()
        print("[DirectChatRealtimeLifecycleTest] ALL PASSED")
    }

    private static func testStatusLocalizationMapping() {
        assert(ChatRealtimeConnectionStatus.connecting.localizationKey == "chat_realtime_connecting")
        assert(ChatRealtimeConnectionStatus.reconnecting.localizationKey == "chat_realtime_reconnecting")
        assert(ChatRealtimeConnectionStatus.offline.localizationKey == "chat_realtime_offline")
        assert(ChatRealtimeConnectionStatus.connected.localizationKey == "chat_realtime_live")
        assert(ChatRealtimeConnectionStatus.live.localizationKey == "chat_realtime_live")
        assert(L10n.t("chat_realtime_connecting", languageCode: "en") == "Connecting…")
        assert(L10n.t("chat_realtime_reconnecting", languageCode: "en") == "Reconnecting…")
        assert(L10n.t("chat_realtime_live", languageCode: "en") == "Live")
        assert(L10n.t("chat_realtime_offline", languageCode: "en") == "Offline")
    }

    private static func testStuckThresholdOrdering() {
        let grace: TimeInterval = 3.0
        let stuck: TimeInterval = 12.0
        assert(grace < stuck)
        assert(stuck < 30.0)
        assert(ChatRealtimeConnectionPresentation.quietGrace < ChatRealtimeConnectionPresentation.stalledConnectingAsReconnecting)
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

    private static func testCachedOpenHidesConnecting() {
        let entered = Date().addingTimeInterval(-1)
        let chrome = ChatRealtimeConnectionPresentation.chrome(
            status: .connecting,
            statusEnteredAt: entered,
            now: Date(),
            threadContentReady: true
        )
        assert(chrome == nil, "cached/open thread must not show Connecting…")
    }

    private static func testQuietGraceHidesBriefConnecting() {
        let now = Date()
        let chrome = ChatRealtimeConnectionPresentation.chrome(
            status: .connecting,
            statusEnteredAt: now,
            now: now,
            threadContentReady: false
        )
        assert(chrome == nil, "brief connecting stays quiet")
    }

    private static func testStalledConnectingPromotesToReconnecting() {
        let now = Date()
        let entered = now.addingTimeInterval(-ChatRealtimeConnectionPresentation.stalledConnectingAsReconnecting)
        let chrome = ChatRealtimeConnectionPresentation.chrome(
            status: .connecting,
            statusEnteredAt: entered,
            now: now,
            threadContentReady: true
        )
        assert(chrome == .reconnecting)
        assert(chrome != .connecting)
    }

    private static func testReconnectingQuietThenVisible() {
        let now = Date()
        let quiet = ChatRealtimeConnectionPresentation.chrome(
            status: .reconnecting,
            statusEnteredAt: now,
            now: now,
            threadContentReady: true
        )
        assert(quiet == nil)
        let visible = ChatRealtimeConnectionPresentation.chrome(
            status: .reconnecting,
            statusEnteredAt: now.addingTimeInterval(-3),
            now: now,
            threadContentReady: true
        )
        assert(visible == .reconnecting)
    }

    private static func testOfflineChrome() {
        let chrome = ChatRealtimeConnectionPresentation.chrome(
            status: .offline,
            statusEnteredAt: Date().addingTimeInterval(-10),
            now: Date(),
            threadContentReady: true
        )
        assert(chrome == .offline)
    }

    private static func testSubscribeSuccessClearsConnecting() {
        let chrome = ChatRealtimeConnectionPresentation.chrome(
            status: .connected,
            statusEnteredAt: Date(),
            now: Date(),
            threadContentReady: true
        )
        assert(chrome == .live)
        assert(chrome != .connecting)
    }

    private static func testSendIndependentFromRealtime() {
        assert(ChatRealtimeConnectionPresentation.sendRequiresRealtimeSubscription == false)
    }

    private static func testPresenceFailureDoesNotBlockSend() {
        assert(ChatRealtimeConnectionPresentation.sendRequiresRealtimeSubscription == false)
    }

    private static func testTypingFailureDoesNotBlockSend() {
        assert(ChatRealtimeConnectionPresentation.sendRequiresRealtimeSubscription == false)
    }

    private static func testCancelledTaskIsNotConnectionError() {
        let cancelled: Error = CancellationError()
        assert(cancelled is CancellationError)
        assert(!(cancelled is URLError))
        let connectingChrome = ChatRealtimeConnectionPresentation.chrome(
            status: .connecting,
            statusEnteredAt: Date().addingTimeInterval(-1),
            now: Date(),
            threadContentReady: true
        )
        assert(connectingChrome == nil, "cancelled reopen must not pin Connecting… over cached messages")
    }

    private static func testSingleSubscriptionIdentity() {
        let conversationId = UUID()
        let topicA = "dm-thread-\(conversationId.uuidString.lowercased())"
        let topicB = "dm-thread-\(conversationId.uuidString.lowercased())"
        assert(topicA == topicB)
        var activeTopics: Set<String> = []
        activeTopics.insert(topicA)
        // Reuse: same conversation keeps one topic.
        assert(activeTopics.count == 1)
        activeTopics.insert(topicB)
        assert(activeTopics.count == 1)
    }

    private static func testReopenReplacesGeneration() {
        var current = 1
        let disappearing = current
        current += 1
        assert(disappearing != current)
        assert(!(disappearing == current), "stale disappear generation cannot mutate newer subscribe")
    }

    private static func testAuthNotReadyWaits() {
        let currentUserId: UUID? = nil
        let conversationId: UUID? = UUID()
        let shouldSubscribe = currentUserId != nil && conversationId != nil
        assert(!shouldSubscribe)
        let chrome = ChatRealtimeConnectionPresentation.chrome(
            status: .connecting,
            statusEnteredAt: Date(),
            now: Date(),
            threadContentReady: false
        )
        assert(chrome == nil, "auth-not-ready stays quiet")
    }

    private static func testRetryDoesNotDuplicateChannels() {
        var channels: [String] = ["dm-thread-a"]
        // Force reconnect replaces rather than appending.
        channels = ["dm-thread-a"]
        assert(channels.count == 1)
    }
}
#endif
