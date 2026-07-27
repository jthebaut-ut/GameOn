import Foundation
import SwiftUI
import Combine

// MARK: - Canonical last-active resolver (reuses `user_profiles.last_seen_at`)

/// Pure value enum: `nonisolated` opts out of the project's default MainActor isolation so the
/// synthesized `Equatable` conformance is usable from nonisolated contexts (e.g. `ChatActivityBadgeDebug.log`).
nonisolated enum ActivityStatusKind: Equatable, Sendable {
    case online
    case minutes(Int)
    case hours(Int)
    case days(Int)
    case recently
    case hidden
}

enum ActivityStatus {
    /// Matches ``PresenceOnlineStatus/onlineWindowSeconds`` (2 minutes).
    nonisolated static let onlineWindowSeconds: TimeInterval = PresenceOnlineStatus.onlineWindowSeconds
    nonisolated static let maxCompactAgeDays: Int = 6

    nonisolated static func resolve(lastSeenAt: Date?, now: Date = Date()) -> ActivityStatusKind {
        guard let lastSeenAt else { return .hidden }
        let elapsed = now.timeIntervalSince(lastSeenAt)
        guard elapsed >= 0 else { return .online }
        if elapsed <= onlineWindowSeconds { return .online }
        if elapsed < 60 * 60 {
            let minutes = max(1, Int(elapsed / 60))
            return .minutes(minutes)
        }
        if elapsed < 24 * 60 * 60 {
            let hours = max(1, Int(elapsed / 3600))
            return .hours(hours)
        }
        let days = Int(elapsed / (24 * 3600))
        if days >= 1, days <= maxCompactAgeDays {
            return .days(days)
        }
        if days >= 7 {
            return .recently
        }
        return .hidden
    }

    nonisolated static func resolve(lastSeenAtRaw: String?, now: Date = Date()) -> ActivityStatusKind {
        resolve(lastSeenAt: PresenceOnlineStatus.parse(lastSeenAtRaw), now: now)
    }

    /// Compact Facebook-style label (`Online`, `2m`, `2h`, `1d`) or nil when hidden / recently-only.
    static func compactLabel(kind: ActivityStatusKind, languageCode: String) -> String? {
        let lang = L10n.normalizedLanguageCode(languageCode)
        switch kind {
        case .online:
            return L10n.t("activity_status_online", languageCode: lang)
        case .minutes(let m):
            return String(
                format: L10n.t("activity_status_compact_minutes_format", languageCode: lang),
                locale: Locale(identifier: lang),
                m
            )
        case .hours(let h):
            return String(
                format: L10n.t("activity_status_compact_hours_format", languageCode: lang),
                locale: Locale(identifier: lang),
                h
            )
        case .days(let d):
            return String(
                format: L10n.t("activity_status_compact_days_format", languageCode: lang),
                locale: Locale(identifier: lang),
                d
            )
        case .recently:
            return nil
        case .hidden:
            return nil
        }
    }

    /// Expanded accessibility / chat subtitle.
    static func accessibilityLabel(kind: ActivityStatusKind, languageCode: String) -> String? {
        let lang = L10n.normalizedLanguageCode(languageCode)
        switch kind {
        case .online:
            return L10n.t("activity_status_active_now", languageCode: lang)
        case .minutes(let m):
            if m == 1 {
                return L10n.t("activity_status_active_one_minute_ago", languageCode: lang)
            }
            return String(
                format: L10n.t("activity_status_active_minutes_ago_format", languageCode: lang),
                locale: Locale(identifier: lang),
                m
            )
        case .hours(let h):
            if h == 1 {
                return L10n.t("activity_status_active_one_hour_ago", languageCode: lang)
            }
            return String(
                format: L10n.t("activity_status_active_hours_ago_format", languageCode: lang),
                locale: Locale(identifier: lang),
                h
            )
        case .days(let d):
            if d == 1 {
                return L10n.t("activity_status_active_yesterday", languageCode: lang)
            }
            return String(
                format: L10n.t("activity_status_active_days_ago_format", languageCode: lang),
                locale: Locale(identifier: lang),
                d
            )
        case .recently:
            return L10n.t("activity_status_active_recently", languageCode: lang)
        case .hidden:
            return nil
        }
    }

    /// Chat header secondary line (`Online` / `Active 2h ago`).
    static func chatHeaderSubtitle(kind: ActivityStatusKind, languageCode: String) -> String? {
        let lang = L10n.normalizedLanguageCode(languageCode)
        switch kind {
        case .online:
            return L10n.t("activity_status_online", languageCode: lang)
        case .minutes, .hours, .days, .recently:
            return accessibilityLabel(kind: kind, languageCode: lang)
        case .hidden:
            return nil
        }
    }
}

// MARK: - Shared 1-minute UI ticker (one task app-wide)

@MainActor
final class ActivityStatusMinuteClock: ObservableObject {
    static let shared = ActivityStatusMinuteClock()

    /// Unix minute bucket — observing views refresh relative labels without per-row timers.
    @Published private(set) var tickMinute: Int = Int(Date().timeIntervalSince1970 / 60)

    private var task: Task<Void, Never>?
    private var ownerGeneration: UInt64 = 0

    private init() {}

    func start(reason: String) {
        ownerGeneration &+= 1
        let generation = ownerGeneration
        ActivityStatusDebug.lifecycle("heartbeat started", details: "clock reason=\(reason)")
        tickMinute = Int(Date().timeIntervalSince1970 / 60)
        guard task == nil else {
            ActivityStatusDebug.lifecycle("duplicate heartbeat prevented", details: "clock")
            return
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    return
                }
                guard let self, self.ownerGeneration == generation else {
                    ActivityStatusDebug.lifecycle("stale previous-session update ignored", details: "clock")
                    return
                }
                self.tickMinute = Int(Date().timeIntervalSince1970 / 60)
            }
        }
    }

    func stop(reason: String) {
        task?.cancel()
        task = nil
        ownerGeneration &+= 1
        ActivityStatusDebug.lifecycle("heartbeat stopped", details: "clock reason=\(reason)")
    }
}

// MARK: - Compact Facebook-style pill

struct ActivityStatusCompactPill: View {
    let lastSeenAtRaw: String?
    var showRecentlyFallback: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @ObservedObject private var clock = ActivityStatusMinuteClock.shared

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var kind: ActivityStatusKind {
        _ = clock.tickMinute
        return ActivityStatus.resolve(lastSeenAtRaw: lastSeenAtRaw)
    }

    var body: some View {
        let kind = self.kind
        let compact = ActivityStatus.compactLabel(kind: kind, languageCode: languageCode)
            ?? (showRecentlyFallback && kind == .recently
                ? L10n.t("activity_status_active_recently", languageCode: languageCode)
                : nil)
        if let compact,
           let a11y = ActivityStatus.accessibilityLabel(kind: kind, languageCode: languageCode) {
            Text(compact)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(offlineTextColor(kind: kind))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background {
                    Capsule(style: .continuous)
                        .fill(offlineFillColor(kind: kind))
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(offlineBorderColor(kind: kind), lineWidth: 0.75)
                }
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.10), radius: 3, y: 1)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(a11y)
                .onAppear {
                    ActivityStatusDebug.lifecycle(
                        "compact status resolved",
                        details: "kind=\(debugKind(kind))"
                    )
                }
        }
    }

    // MARK: - Badge palette (Light Mode preserved exactly; Dark Mode contrast fix only)

    private func offlineTextColor(_ scheme: ColorScheme, kind: ActivityStatusKind) -> Color {
        if kind == .online { return .white }
        // Dark: pure white for maximum legibility over dark avatars. Light: unchanged.
        return scheme == .dark ? .white : FGColor.primaryText(scheme)
    }

    private func offlineTextColor(kind: ActivityStatusKind) -> Color {
        offlineTextColor(colorScheme, kind: kind)
    }

    private func offlineFillColor(kind: ActivityStatusKind) -> Color {
        if kind == .online { return FGColor.accentGreen }
        if colorScheme == .dark {
            // Was Color.white.opacity(0.16) — too faint over dark photos. Use an opaque,
            // near-black elevated surface so white text stays readable (Apple-style chip).
            return Color(red: 0.13, green: 0.15, blue: 0.19)
        }
        // Light Mode preserved exactly.
        return Color.white.opacity(0.92)
    }

    private func offlineBorderColor(kind: ActivityStatusKind) -> Color {
        if kind == .online { return Color.white.opacity(0.35) }
        if colorScheme == .dark {
            // Subtle hairline to separate the opaque chip from dark avatar photos.
            return Color.white.opacity(0.22)
        }
        // Light Mode preserved exactly.
        return FGColor.divider(colorScheme).opacity(0.55)
    }

    private func debugKind(_ kind: ActivityStatusKind) -> String {
        switch kind {
        case .online: return "online"
        case .minutes(let m): return "m\(m)"
        case .hours(let h): return "h\(h)"
        case .days(let d): return "d\(d)"
        case .recently: return "recently"
        case .hidden: return "hidden"
        }
    }
}

/// DEBUG-only per-row chat inbox badge diagnostics (`===== CHAT ACTIVITY BADGE =====`).
/// Never logs names, handles, timestamps, or user ids.
enum ChatActivityBadgeDebug {
    nonisolated static func log(
        isRegularFan: Bool,
        lastSeenPresent: Bool,
        visibilityAllowed: Bool?,
        kind: ActivityStatusKind,
        source: String
    ) {
#if DEBUG
        let status: String
        switch kind {
        case .online: status = "online"
        case .minutes: status = "minutes"
        case .hours: status = "hours"
        case .days: status = "days"
        case .recently: status = "recently"
        case .hidden: status = "hidden"
        }
        let hideReason: String
        if !isRegularFan {
            hideReason = "notRegularFanCounterpart"
        } else if visibilityAllowed == false {
            hideReason = "privacyHidden"
        } else if !lastSeenPresent {
            hideReason = "timestampAbsent"
        } else if kind == .recently {
            hideReason = "olderThanCompactWindow"
        } else if kind == .hidden {
            hideReason = "hidden"
        } else {
            hideReason = "none"
        }
        let visibility = visibilityAllowed.map { $0 ? "true" : "false" } ?? "unknown"
        print("===== CHAT ACTIVITY BADGE =====")
        print("[ChatActivityBadge] regularFan=\(isRegularFan) lastSeenPresent=\(lastSeenPresent) visibilityAllowed=\(visibility) status=\(status) hideReason=\(hideReason) source=\(source)")
#endif
    }
}

enum ActivityStatusDebug {
    /// Stateless print-only diagnostic; nonisolated so detached heartbeat work
    /// (`PresenceService.sendHeartbeat`) can log without crossing to the main actor.
    nonisolated static func lifecycle(_ event: String, details: String = "") {
#if DEBUG
        print("===== ACTIVITY STATUS =====")
        if details.isEmpty {
            print("[ActivityStatus] \(event)")
        } else {
            print("[ActivityStatus] \(event) \(details)")
        }
#endif
    }
}
