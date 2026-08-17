import Foundation

enum ManagedPlayerTeamAccessDebug {
    static func log(_ event: String, detail: String? = nil) {
#if DEBUG
        if let detail, !detail.isEmpty {
            print("[ManagedPlayerTeamAccess] \(event) \(detail)")
        } else {
            print("[ManagedPlayerTeamAccess] \(event)")
        }
#endif
    }
}
