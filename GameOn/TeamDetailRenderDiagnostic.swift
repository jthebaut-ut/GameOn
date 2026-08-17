import Foundation

/// DEBUG-only Team Detail Overview bisect for physical-device isolation.
///
/// Physical result (2026-08-11): `.overviewInfo` opened successfully on device.
/// That mode intentionally showed Team Info only — it must never be forced by default,
/// and must never replace Schedule / Chat / Roster.
///
/// Override without rebuilding (DEBUG):
/// ```
/// UserDefaults.standard.set("overviewInfo", forKey: TeamDetailRenderDiagnostic.defaultsKey)
/// ```
/// Or temporarily set ``forcedMode`` (keep `nil` for product builds).
enum TeamDetailRenderDiagnosticMode: String, CaseIterable, Sendable {
    /// Production-equivalent tree (default).
    case full
    /// NavigationStack + static Text only (sheet architecture proof).
    case placeholder
    /// Header only (mark + title + meta + badges/actions).
    case headerOnly
    /// Header + tab picker; empty content below (tabs themselves still route normally if used carefully).
    case headerAndTabs
    /// Overview content = Team Info only (does not affect Schedule/Chat/Roster).
    case overviewInfo
    /// Overview content = Announcement card only.
    case announcementOnly
    /// Overview = full loaded dashboard (same as full Overview branch).
    case fullOverview
    /// Overview omits Next Event section only.
    case overviewWithoutNextEvent
    /// Overview omits Announcement card only.
    case overviewWithoutAnnouncement
    /// Full tree but trailing toolbar Menu omitted.
    case noToolbar
    /// Full tree but Owner/Manager role badge omitted.
    case noRoleBadge
    /// Full tree but FanTeamMarkView replaced with static Circle + soccer icon.
    case noMark
}

enum TeamDetailRenderDiagnostic {
    static let defaultsKey = "TeamDetailRenderDiagnosticMode"

#if DEBUG
    /// Compile-time override. Non-nil wins over UserDefaults.
    /// **Must stay `nil` for product Debug builds** after the overviewInfo proof.
    static let forcedMode: TeamDetailRenderDiagnosticMode? = nil

    static var mode: TeamDetailRenderDiagnosticMode {
        if let forcedMode { return forcedMode }
        if let raw = UserDefaults.standard.string(forKey: defaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let mode = TeamDetailRenderDiagnosticMode(rawValue: raw) {
            return mode
        }
        return .full
    }

    /// Overview-only: omit Next Event section.
    static var omitsOverviewNextEvent: Bool {
        switch mode {
        case .overviewWithoutNextEvent, .overviewInfo, .announcementOnly:
            return true
        default:
            return false
        }
    }

    /// Overview-only: omit Announcement card.
    static var omitsOverviewAnnouncement: Bool {
        switch mode {
        case .overviewWithoutAnnouncement, .overviewInfo:
            return true
        default:
            return false
        }
    }

    /// Overview-only: Team Info card alone (no loaded dashboard children).
    static var overviewInfoOnly: Bool {
        mode == .overviewInfo
    }

    /// Overview-only: Announcement card alone.
    static var announcementOnly: Bool {
        mode == .announcementOnly
    }

    static func logMode() {
        print("[TeamDetailRenderBisect] diagnosticMode=\(mode.rawValue)")
    }
#else
    static var mode: TeamDetailRenderDiagnosticMode { .full }
    static var omitsOverviewNextEvent: Bool { false }
    static var omitsOverviewAnnouncement: Bool { false }
    static var overviewInfoOnly: Bool { false }
    static var announcementOnly: Bool { false }
    static func logMode() {}
#endif
}

/// Synchronous pre-appear breadcrumbs. Print-only; no shared mutable Sets / @State.
enum TeamDetailRenderBisect {
    static func mark(_ stage: String, details: String? = nil) {
#if DEBUG
        var parts: [String] = ["[TeamDetailRenderBisect]", stage]
        if let details {
            let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                parts.append(trimmed)
            }
        }
        // Flush immediately — AttributeGraph / watchdog kills often abort before stdout drains,
        // which made the last visible checkpoint look earlier than the real failure site.
        print(parts.joined(separator: " "))
        fflush(stdout)
#endif
    }
}

/// Safe `String(format:)` for Team Detail titles constructed during body evaluation.
/// Mismatched placeholder counts fall back instead of risking process abort.
enum TeamDetailLocalizedFormat {
    private static let placeholderRegex: NSRegularExpression = {
        // Matches %@, %lld, %d, %1$@, etc. Skips %%.
        try! NSRegularExpression(
            pattern: #"(?<!%)%(?:\d+\$)?(?:ll)?[dDuUxXoOfFeEgGaAcCsSp@]"#,
            options: []
        )
    }()

    static func placeholderCount(in format: String) -> Int {
        let range = NSRange(format.startIndex..<format.endIndex, in: format)
        return placeholderRegex.numberOfMatches(in: format, options: [], range: range)
    }

    static func format(
        _ key: String,
        languageCode: String,
        stringArgs: [String] = [],
        int64Args: [Int64] = []
    ) -> String {
        let format = L10n.t(key, languageCode: languageCode)
        let locale = Locale(identifier: languageCode)
        let expected = placeholderCount(in: format)
        let provided = stringArgs.count + int64Args.count
        guard expected == provided, expected > 0 || provided == 0 else {
#if DEBUG
            print(
                "[TeamDetailLocalizedFormat] mismatch key=\(key) expected=\(expected) " +
                "provided=\(provided) format=\(format)"
            )
#endif
            if !stringArgs.isEmpty {
                return stringArgs.joined(separator: " ")
            }
            if let first = int64Args.first {
                return "\(first)"
            }
            return format
        }

        var args: [CVarArg] = []
        args.append(contentsOf: stringArgs.map { $0 as CVarArg })
        args.append(contentsOf: int64Args.map { $0 as CVarArg })
        return String(format: format, locale: locale, arguments: args)
    }
}
