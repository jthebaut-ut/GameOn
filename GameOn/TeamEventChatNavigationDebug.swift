import Foundation

/// DEBUG-only breadcrumbs for Team Event detail → embedded Team Chat tab routing.
enum TeamEventChatNavigationDebug {
    static func log(_ event: String, detail: String = "") {
#if DEBUG
        if detail.isEmpty {
            print("[TeamEventChatNavigation] \(event)")
        } else {
            print("[TeamEventChatNavigation] \(event) \(detail)")
        }
#endif
    }
}
