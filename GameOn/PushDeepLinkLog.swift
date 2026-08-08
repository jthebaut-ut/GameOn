import Foundation

#if DEBUG
/// Concise push-tap route lifecycle logs (no message bodies / sensitive content).
enum PushDeepLinkLog {
    static func received(type: String, conversation: UUID?) {
        let cid = conversation?.uuidString.lowercased() ?? "nil"
        print("[PushDeepLink] received type=\(type) conversation=\(cid)")
    }

    static func queued(type: String, conversation: UUID?) {
        let cid = conversation?.uuidString.lowercased() ?? "nil"
        print("[PushDeepLink] queued type=\(type) conversation=\(cid)")
    }

    static func waiting(reason: String) {
        print("[PushDeepLink] waiting reason=\(reason)")
    }

    static func selectingChatTab(reason: String) {
        print("[PushDeepLink] selecting_chat_tab reason=\(reason)")
    }

    static func selectingChatsSection() {
        print("[PushDeepLink] selecting_chats_section")
    }

    static func selectingRequestsSection() {
        print("[PushDeepLink] selecting_requests_section")
    }

    static func opening(conversation: UUID?, kind: String) {
        let cid = conversation?.uuidString.lowercased() ?? "nil"
        print("[PushDeepLink] opening kind=\(kind) conversation=\(cid)")
    }

    static func completed(conversation: UUID?, kind: String) {
        let cid = conversation?.uuidString.lowercased() ?? "nil"
        print("[PushDeepLink] completed kind=\(kind) conversation=\(cid)")
    }

    static func skippedDuplicate(conversation: UUID?, kind: String) {
        let cid = conversation?.uuidString.lowercased() ?? "nil"
        print("[PushDeepLink] skipped_duplicate kind=\(kind) conversation=\(cid)")
    }

    static func failed(reason: String) {
        print("[PushDeepLink] failed reason=\(reason)")
    }
}
#endif
