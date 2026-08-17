import Foundation

/// DEBUG breadcrumb trail for My Teams → Team Detail open / termination.
///
/// iOS 26 can terminate without a Swift `Fatal error` / `SIGABRT` signature
/// (AttributeGraph recursion, layout watchdog, or `String(format:)` abort).
/// Markers identify the last successful stage before process death.
/// Do not log message bodies. Do not mutate shared Sets during View.body.
enum TeamDetailCrashTrace {
    static func log(_ stage: String, details: String? = nil) {
#if DEBUG
        var parts: [String] = ["[TeamDetailCrashTrace]", stage]
        if let details {
            let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                parts.append(trimmed)
            }
        }
        print(parts.joined(separator: " "))
#endif
    }

    /// Body evaluation marker — print-only, no shared mutable state.
    static func logOnceBody(teamID: UUID, tab: String, hasDetail: Bool) {
#if DEBUG
        log(
            "detailSheetBody",
            details: "teamID=\(teamID.uuidString.lowercased()) tab=\(tab) hasDetail=\(hasDetail)"
        )
#endif
    }

    static func teamOpen(teamID: UUID, teamName: String) {
        let name = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        log(
            "teamOpen",
            details: "teamID=\(teamID.uuidString.lowercased()) teamName=\(name.isEmpty ? "—" : name)"
        )
    }

    static func detailLoadSuccess(teamID: UUID, gameCount: Int, announcementCount: Int) {
        log(
            "detailLoadSuccess",
            details:
                "teamID=\(teamID.uuidString.lowercased()) gameCount=\(gameCount) " +
                "announcementCount=\(announcementCount)"
        )
    }

    static func detailLoadFailure(teamID: UUID, error: Error) {
        log(
            "detailLoadFailure",
            details: "teamID=\(teamID.uuidString.lowercased()) error=\(error.localizedDescription)"
        )
    }
}
