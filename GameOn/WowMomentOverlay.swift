import Combine
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Lightweight positive-feedback moment shown above the tab bar.
struct WowMoment: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case favoriteTeam = "favorite_team"
        case mapActivity = "map_activity"
        case going = "going"
    }

    enum Icon: Equatable {
        case emoji(String)
        case systemImage(String)
    }

    let id: UUID
    let kind: Kind
    let icon: Icon
    let title: String
    let message: String?
    /// Suppression / analytics key (e.g. team id, map day+sport, venue event id).
    let dedupeKey: String

    init(
        kind: Kind,
        icon: Icon,
        title: String,
        message: String? = nil,
        dedupeKey: String,
        id: UUID = UUID()
    ) {
        self.id = id
        self.kind = kind
        self.icon = icon
        self.title = title
        self.message = message
        self.dedupeKey = dedupeKey
    }
}

/// Serializes wow moments so banners never stack; replace-or-suppress overlapping presentations.
@MainActor
final class WowMomentOverlayManager: ObservableObject {
    @Published private(set) var presentation: WowMoment?

    private var dismissTask: Task<Void, Never>?
    private var lastPresentedKey: String?
    private var lastPresentedAt: Date = .distantPast

    private var favoriteCoalesceTask: Task<Void, Never>?
    private var pendingFavoriteMoment: WowMoment?

    /// Map wow: at most 2 per process session; 1st is the daily “general”, 2nd is optional sport-filter bonus.
    private(set) var mapSessionShownCount: Int = 0
    private var lastMapMessageFingerprint: String?

    private static let visibleDurationNanoseconds: UInt64 = 2_800_000_000
    /// Compact confirmation used by pre-auth onboarding selection feedback.
    static let onboardingFavoriteVisibleDurationNanoseconds: UInt64 = 1_800_000_000
    /// Short Going confirmation (~1.35s) — lighter than map/favorite settle toasts.
    static let goingVisibleDurationNanoseconds: UInt64 = 1_350_000_000
    private static let minRepeatInterval: TimeInterval = 4.0
    private static let favoriteCoalesceNanoseconds: UInt64 = 350_000_000
    private static let mapDailyShownKeyPrefix = "wowMoment.mapActivity.generalDay."
    private static let mapSessionCap = 2

    /// Returns `true` only when the moment became visible (analytics emit here only when requested).
    @discardableResult
    func present(
        _ moment: WowMoment,
        force: Bool = false,
        recordAnalytics: Bool = true,
        visibleDurationNanoseconds: UInt64? = nil
    ) -> Bool {
        let now = Date()
        if !force,
           lastPresentedKey == moment.dedupeKey,
           now.timeIntervalSince(lastPresentedAt) < Self.minRepeatInterval {
            return false
        }
        dismissTask?.cancel()
        lastPresentedKey = moment.dedupeKey
        lastPresentedAt = now
        presentation = moment
        playSuccessHaptic()
        if recordAnalytics {
            FanGeoAnalyticsService.record(
                eventName: "wow_moment_shown",
                sport: nil,
                metadata: [
                    "type": moment.kind.rawValue,
                    "dedupe": String(moment.dedupeKey.prefix(64))
                ],
                updateLastActive: false
            )
        }
        let duration = visibleDurationNanoseconds ?? Self.visibleDurationNanoseconds
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: duration)
            guard let self, !Task.isCancelled else { return }
            if self.presentation?.id == moment.id {
                self.presentation = nil
            }
        }
        return true
    }

    /// Collapses rapid multi-team adds into a single toast (last team wins).
    func presentFavoriteCoalesced(
        _ moment: WowMoment,
        recordAnalytics: Bool = true,
        visibleDurationNanoseconds: UInt64? = nil
    ) {
        pendingFavoriteMoment = moment
        favoriteCoalesceTask?.cancel()
        favoriteCoalesceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.favoriteCoalesceNanoseconds)
            guard let self, !Task.isCancelled else { return }
            guard let pending = self.pendingFavoriteMoment else { return }
            self.pendingFavoriteMoment = nil
            _ = self.present(
                pending,
                recordAnalytics: recordAnalytics,
                visibleDurationNanoseconds: visibleDurationNanoseconds
            )
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        favoriteCoalesceTask?.cancel()
        favoriteCoalesceTask = nil
        pendingFavoriteMoment = nil
        presentation = nil
    }

    // MARK: - Frequency (map)

    enum MapWowTrigger: Equatable {
        case dataSettled
        case sportFilterChanged(from: String, to: String)
    }

    static func mapGeneralDayKey(day: Date) -> String {
        let dayKey = ISO8601DateFormatter.wowMomentDay.string(from: Calendar.current.startOfDay(for: day))
        return "\(mapDailyShownKeyPrefix)\(dayKey)"
    }

    static func hasShownGeneralMapActivity(day: Date) -> Bool {
        UserDefaults.standard.bool(forKey: mapGeneralDayKey(day: day))
    }

    static func markGeneralMapActivityShown(day: Date) {
        UserDefaults.standard.set(true, forKey: mapGeneralDayKey(day: day))
    }

    /// Evaluates map frequency rules. Returns whether a new presentation was allowed to start.
    func allowAndRecordMapPresentation(
        trigger: MapWowTrigger,
        day: Date,
        messageFingerprint: String
    ) -> Bool {
        guard mapSessionShownCount < Self.mapSessionCap else { return false }

        switch trigger {
        case .dataSettled:
            guard !Self.hasShownGeneralMapActivity(day: day) else { return false }
            Self.markGeneralMapActivityShown(day: day)
            mapSessionShownCount += 1
            lastMapMessageFingerprint = messageFingerprint
            return true

        case .sportFilterChanged(let from, let to):
            let fromN = from.trimmingCharacters(in: .whitespacesAndNewlines)
            let toN = to.trimmingCharacters(in: .whitespacesAndNewlines)
            // Deliberate filter only — not returning to All Sports / tab churn.
            guard toN.caseInsensitiveCompare("All") != .orderedSame else { return false }
            guard fromN.caseInsensitiveCompare(toN) != .orderedSame else { return false }
            // Bonus only after the daily general has already been shown (this session or earlier today).
            guard Self.hasShownGeneralMapActivity(day: day) else { return false }
            guard mapSessionShownCount >= 1 else { return false }
            guard mapSessionShownCount < Self.mapSessionCap else { return false }
            guard messageFingerprint != lastMapMessageFingerprint else { return false }
            mapSessionShownCount += 1
            lastMapMessageFingerprint = messageFingerprint
            return true
        }
    }

    private func playSuccessHaptic() {
#if canImport(UIKit)
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.prepare()
        impact.impactOccurred(intensity: 0.8)
#endif
    }
}

private extension ISO8601DateFormatter {
    static let wowMomentDay: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = .current
        return formatter
    }()
}

// MARK: - Host view

struct WowMomentToastHost: View {
    @ObservedObject var manager: WowMomentOverlayManager
    /// Defaults to the floating tab-bar clearance used by ``MainTabView``.
    var bottomInset: CGFloat = MainTabViewFloatingTabBarMetrics.wowMomentBottomInset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .bottom) {
            if let moment = manager.presentation {
                WowMomentToastCard(moment: moment, reduceMotion: reduceMotion)
                    .padding(.horizontal, 18)
                    .padding(.bottom, bottomInset)
                    .transition(toastTransition)
                    .zIndex(9_500)
                    // Hit-test only the toast card — never the full-screen host (which sat over the
                    // floating tab bar and ate the first tab tap as a dismiss).
                    .allowsHitTesting(true)
                    .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .onTapGesture { manager.dismiss() }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityLabel(accessibilityLabel(for: moment))
                    .accessibilityHint(L10n.t("wow_moment_dismiss_hint"))
                    .onAppear {
                        guard moment.kind == .going else { return }
                        AccessibilityNotification.Announcement(accessibilityLabel(for: moment)).post()
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(manager.presentation != nil)
        .animation(reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.42, dampingFraction: 0.82), value: manager.presentation?.id)
    }

    private var toastTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 18)).combined(with: .scale(scale: 0.96)),
            removal: .opacity.combined(with: .offset(y: 10))
        )
    }

    private func accessibilityLabel(for moment: WowMoment) -> String {
        // Going: speak a calm "You're going." then the adaptive subtitle (no celebration emoji).
        if moment.kind == .going {
            let spokenTitle = L10n.t("wow_going_a11y_title")
            if let message = moment.message, !message.isEmpty {
                return "\(spokenTitle) \(message)"
            }
            return spokenTitle
        }
        if let message = moment.message, !message.isEmpty {
            return "\(moment.title). \(message)"
        }
        return moment.title
    }
}

/// Isolated so ``MainTabView`` can keep a single source of truth for floating-tab inset without circular type access issues.
enum MainTabViewFloatingTabBarMetrics {
    /// Visual height of the floating capsule + its bottom inset (`FloatingTabBarLayout`:
    /// avatarOuter 52 + barVerticalPadding 10×2 + screenBottomInset 6).
    /// Use this for Discover content clearance under the bar — not ``MainTabView/floatingTabBarStackHeight``.
    static let overlayHeight: CGFloat = 78

    /// Sole vertical gap between Discover AdMob strip bottom and floating tab bar top.
    static let discoverAdToBarGap: CGFloat = 10

    /// Matches ``MainTabView/floatingTabBarStackHeight`` with a little air above the capsule.
    /// Keep toast clear of the ~108pt floating tab bar so taps land on tabs, not the toast.
    static let wowMomentBottomInset: CGFloat = 134
}

private struct WowMomentToastCard: View {
    let moment: WowMoment
    let reduceMotion: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var appeared = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            iconView
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(moment.title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)

                if let message = moment.message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.94 : 0.98))
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.12), radius: 14, y: 6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.28 : 0.2), lineWidth: 1)
        }
        .opacity(appeared || reduceMotion ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 12)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.97)
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                    appeared = true
                }
            }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch moment.icon {
        case .emoji(let emoji):
            Text(emoji)
                .font(.system(size: 22))
        case .systemImage(let name):
            Image(systemName: name)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(FGColor.accentGreen)
                .frame(width: 36, height: 36)
                .background(Circle().fill(FGColor.accentGreen.opacity(0.14)))
        }
    }
}

// MARK: - Copy builders (localized)

enum WowMomentCopy {
    /// Converts a going total into “other fans,” depending on whether `total` includes the current user.
    static func otherFans(fromTotal total: Int, includesCurrentUser: Bool) -> Int {
        let safe = max(total, 0)
        if includesCurrentUser {
            return max(safe - 1, 0)
        }
        return safe
    }

    static func onboardingFavoriteAdded(
        teamName: String,
        sport: FavoriteTeamSport,
        languageCode: String,
        dedupeKey: String
    ) -> WowMoment {
        let title = L10n.t("onboarding_favorite_added_title", languageCode: languageCode)
        return WowMoment(
            kind: .favoriteTeam,
            icon: .emoji(sportEmoji(for: sport)),
            title: title,
            message: teamName,
            dedupeKey: dedupeKey
        )
    }

    static func favoriteTeam(
        teamName: String,
        sport: FavoriteTeamSport,
        languageCode: String
    ) -> WowMoment {
        let title = L10n.t("wow_favorite_great_choice", languageCode: languageCode)
        let message = String(
            format: L10n.t("wow_favorite_feed_more_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            teamName
        )
        return WowMoment(
            kind: .favoriteTeam,
            icon: .emoji(sportEmoji(for: sport)),
            title: title,
            message: message,
            // Shared key so multi-add batches coalesce instead of rapidly replacing.
            dedupeKey: "favorite_team"
        )
    }

    static func mapActivity(
        placeCount: Int,
        sportLabel: String?,
        languageCode: String,
        dedupeKey: String
    ) -> WowMoment? {
        guard placeCount > 0 else { return nil }
        let title = L10n.t("wow_map_today_near_you", languageCode: languageCode)
        let countText = placeCount.formatted(.number.locale(Locale(identifier: languageCode)))
        let message: String
        if let sportLabel,
           !sportLabel.isEmpty,
           sportLabel.caseInsensitiveCompare("All") != .orderedSame {
            let formatKey = placeCount == 1
                ? "wow_map_places_sport_today_one_format"
                : "wow_map_places_sport_today_other_format"
            message = String(
                format: L10n.t(formatKey, languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                countText,
                sportLabel
            )
        } else {
            let formatKey = placeCount == 1
                ? "wow_map_places_today_one_format"
                : "wow_map_places_today_other_format"
            message = String(
                format: L10n.t(formatKey, languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                countText
            )
        }
        return WowMoment(
            kind: .mapActivity,
            icon: .emoji("📍"),
            title: title,
            message: message,
            dedupeKey: dedupeKey
        )
    }

    static func mapMessageFingerprint(placeCount: Int, sportLabel: String?) -> String {
        let sport = (sportLabel ?? "all").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(placeCount)|\(sport)"
    }

    static func mapExploreFallback(languageCode: String, dedupeKey: String) -> WowMoment {
        WowMoment(
            kind: .mapActivity,
            icon: .emoji("🗺️"),
            title: L10n.t("wow_map_explore_title", languageCode: languageCode),
            message: L10n.t("wow_map_explore_message", languageCode: languageCode),
            dedupeKey: dedupeKey
        )
    }

    static func going(otherFans: Int, languageCode: String, eventKey: String) -> WowMoment {
        let title = L10n.t("wow_going_title", languageCode: languageCode)
        let message: String?
        if otherFans > 0 {
            let countText = otherFans.formatted(.number.locale(Locale(identifier: languageCode)))
            let formatKey = otherFans == 1
                ? "wow_going_join_one_format"
                : "wow_going_join_other_format"
            message = String(
                format: L10n.t(formatKey, languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                countText
            )
        } else {
            message = L10n.t("wow_going_first", languageCode: languageCode)
        }
        return WowMoment(
            kind: .going,
            icon: .emoji("🎉"),
            title: title,
            message: message,
            dedupeKey: "going:\(eventKey)"
        )
    }

    static func sportEmoji(for sport: FavoriteTeamSport) -> String {
        switch sport {
        case .soccer: return "⚽️"
        case .basketball: return "🏀"
        case .football: return "🏈"
        case .baseball: return "⚾️"
        case .hockey: return "🏒"
        case .tennis: return "🎾"
        case .badminton: return "🏸"
        case .golf: return "⛳️"
        case .combat: return "🥊"
        case .racing: return "🏎️"
        case .dance: return "💃"
        case .ncaa: return "🏟"
        case .cricket: return "🏏"
        case .rugby: return "🏉"
        case .olympics: return "🏅"
        }
    }
}
