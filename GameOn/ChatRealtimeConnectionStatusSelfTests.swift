#if DEBUG
import Foundation

/// Lightweight checks for shared chat realtime status presentation.
enum ChatRealtimeConnectionStatusSelfTests {
    static func run() {
        assert(ChatRealtimeConnectionStatus.connected.localizationKey == "chat_realtime_live")
        assert(ChatRealtimeConnectionStatus.live.localizationKey == "chat_realtime_live")
        assert(ChatRealtimeConnectionStatus.connecting.localizationKey == "chat_realtime_connecting")
        assert(ChatRealtimeConnectionStatus.reconnecting.localizationKey == "chat_realtime_reconnecting")
        assert(ChatRealtimeConnectionStatus.offline.localizationKey == "chat_realtime_offline")

        assert(ChatRealtimeConnectionStatus.connected.accessibilityBucket == "live")
        assert(ChatRealtimeConnectionStatus.live.accessibilityBucket == "live")
        assert(ChatRealtimeConnectionStatus.connecting.accessibilityBucket == "connecting")
        assert(ChatRealtimeConnectionStatus.reconnecting.accessibilityBucket == "reconnecting")
        assert(ChatRealtimeConnectionStatus.offline.accessibilityBucket == "offline")

        // connected ↔ live must not be treated as a meaningful VoiceOver change.
        assert(
            ChatRealtimeConnectionStatus.connected.accessibilityBucket
                == ChatRealtimeConnectionStatus.live.accessibilityBucket
        )

        let live = L10n.t("chat_realtime_live", languageCode: "en")
        let connecting = L10n.t("chat_realtime_connecting", languageCode: "en")
        let reconnecting = L10n.t("chat_realtime_reconnecting", languageCode: "en")
        let offline = L10n.t("chat_realtime_offline", languageCode: "en")
        assert(live == "Live")
        assert(connecting == "Connecting…")
        assert(reconnecting == "Reconnecting…")
        assert(offline == "Offline")
        assert(offline != "Connecting…")
    }
}
#endif
