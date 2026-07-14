import Foundation
import Combine
import StoreKit

enum BusinessMembershipPolicy {
    static let freeVenueListingLimit = 5
    static let freeMonthlyVenueGameLimit = 5

    static func currentMonthWindow(now: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date) {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now))
            ?? calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .month, value: 1, to: start)
            ?? now.addingTimeInterval(31 * 24 * 60 * 60)
        return (start, end)
    }
}

enum BusinessLimitCopy {
    enum Token {
        static let venueLimitReached = "business_venue_limit_reached"
        static let hostedGameLimitReached = "business_hosted_game_limit_reached"
        static let planLockedVenueBanner = "business_plan_locked_venue_banner"
        static let planLockedVenueBadge = "business_plan_locked_venue_badge"
        static let planLockedVenueSubtitle = "business_plan_locked_venue_subtitle"
        static let planLockedVenueHostedGameBlocked = "business_plan_locked_venue_hosted_game_blocked"
        static let backendCompatibilityRequired = "business_backend_compatibility_required"
    }

    static func venueLimitReached(languageCode: String? = nil) -> String {
        L10n.t(Token.venueLimitReached, languageCode: languageCode)
    }

    static func hostedGameLimitReached(languageCode: String? = nil) -> String {
        L10n.t(Token.hostedGameLimitReached, languageCode: languageCode)
    }

    static func planLockedVenueBanner(languageCode: String? = nil) -> String {
        L10n.t(Token.planLockedVenueBanner, languageCode: languageCode)
    }

    static func planLockedVenueBadge(languageCode: String? = nil) -> String {
        L10n.t(Token.planLockedVenueBadge, languageCode: languageCode)
    }

    static func planLockedVenueSubtitle(languageCode: String? = nil) -> String {
        L10n.t(Token.planLockedVenueSubtitle, languageCode: languageCode)
    }

    static func planLockedVenueHostedGameBlocked(languageCode: String? = nil) -> String {
        L10n.t(Token.planLockedVenueHostedGameBlocked, languageCode: languageCode)
    }

    static func backendCompatibilityRequired(languageCode: String? = nil) -> String {
        L10n.t(Token.backendCompatibilityRequired, languageCode: languageCode)
    }
}

/// User-facing plan limit copy. Backend may return sentinel values (e.g. 999999) for unlimited capacity;
/// never surface those integers directly in business UI.
enum BusinessPlanLimitPresentation {
    static let sentinelThreshold = 10_000

    enum DisplayLimit: Equatable {
        case unlimited
        case regular(limit: Int)
    }

    static func isSentinelLimit(_ value: Int?) -> Bool {
        guard let value else { return false }
        return value >= sentinelThreshold
    }

    static func activeVenueLimit(for status: BusinessVenueGamePostingStatus) -> DisplayLimit {
        guard !status.computedIsPro else { return .unlimited }
        if isSentinelLimit(status.venueLimit) || (status.unlimitedVenues && !status.computedIsPro) {
            return .regular(limit: BusinessMembershipPolicy.freeVenueListingLimit)
        }
        return .regular(limit: max(1, min(status.venueLimit, BusinessMembershipPolicy.freeVenueListingLimit)))
    }

    static func hostedGameLimit(for status: BusinessVenueGamePostingStatus) -> DisplayLimit {
        guard !status.computedIsPro else { return .unlimited }
        let raw = status.hostedGamesEffectiveMonthlyHostLimitForDisplay ?? status.monthlyHostLimit
        if isSentinelLimit(raw) || (status.unlimitedHosting && !status.computedIsPro) {
            return .regular(limit: BusinessMembershipPolicy.freeMonthlyVenueGameLimit)
        }
        return .regular(limit: max(1, min(raw, BusinessMembershipPolicy.freeMonthlyVenueGameLimit)))
    }

    static func activeVenuesFeatureText(
        for status: BusinessVenueGamePostingStatus,
        languageCode: String? = nil
    ) -> String {
        switch activeVenueLimit(for: status) {
        case .unlimited:
            return L10n.t("business_unlimited_active_venues", languageCode: languageCode)
        case .regular(let limit):
            return String(
                format: L10n.t("business_up_to_active_venues_format", languageCode: languageCode),
                limit
            )
        }
    }

    static func hostedGamesFeatureText(
        for status: BusinessVenueGamePostingStatus,
        languageCode: String? = nil
    ) -> String {
        switch hostedGameLimit(for: status) {
        case .unlimited:
            return L10n.t("business_unlimited_hosted_games", languageCode: languageCode)
        case .regular(let limit):
            return String(
                format: L10n.t("business_up_to_hosted_games_month_format", languageCode: languageCode),
                limit
            )
        }
    }

    static func activeVenuesCountNounText(
        for status: BusinessVenueGamePostingStatus,
        languageCode: String? = nil
    ) -> String {
        switch activeVenueLimit(for: status) {
        case .unlimited:
            return L10n.t("business_unlimited_active_venues", languageCode: languageCode)
        case .regular(let limit):
            return String(
                format: L10n.t("business_active_venues_count_format", languageCode: languageCode),
                limit
            )
        }
    }

    static func hostedGamesCountNounText(
        for status: BusinessVenueGamePostingStatus,
        languageCode: String? = nil
    ) -> String {
        switch hostedGameLimit(for: status) {
        case .unlimited:
            return L10n.t("business_unlimited_hosted_games", languageCode: languageCode)
        case .regular(let limit):
            return String(
                format: L10n.t("business_hosted_games_count_month_format", languageCode: languageCode),
                limit
            )
        }
    }

    static func planLimitsSummarySubtitle(
        for status: BusinessVenueGamePostingStatus,
        languageCode: String? = nil
    ) -> String {
        guard !status.computedIsPro else { return status.businessPlanDisplaySubtitle(languageCode: languageCode) }
        return "\(activeVenuesFeatureText(for: status, languageCode: languageCode)) • \(hostedGamesFeatureText(for: status, languageCode: languageCode))"
    }

    static func regularPlanFeatureBullets(languageCode: String? = nil) -> [String] {
        [
            String(
                format: L10n.t("business_up_to_active_venues_format", languageCode: languageCode),
                BusinessMembershipPolicy.freeVenueListingLimit
            ),
            String(
                format: L10n.t("business_up_to_hosted_games_month_format", languageCode: languageCode),
                BusinessMembershipPolicy.freeMonthlyVenueGameLimit
            )
        ]
    }

    static func proPlanFeatureBullets(languageCode: String? = nil) -> [String] {
        [
            L10n.t("business_unlimited_active_venues", languageCode: languageCode),
            L10n.t("business_unlimited_hosted_games", languageCode: languageCode)
        ]
    }

    static func resolvedActiveVenueCap(for status: BusinessVenueGamePostingStatus) -> Int? {
        switch activeVenueLimit(for: status) {
        case .unlimited:
            return nil
        case .regular(let limit):
            return limit
        }
    }

    static func resolvedHostedGameCap(for status: BusinessVenueGamePostingStatus) -> Int? {
        switch hostedGameLimit(for: status) {
        case .unlimited:
            return nil
        case .regular(let limit):
            return limit
        }
    }
}

enum BusinessProPromoDisplay {
    private static let expiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    static func formattedExpiry(from raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let date = SupabaseTimestampParsing.parseTimestamptz(raw) else {
            return nil
        }
        return expiryFormatter.string(from: date)
    }

    static func includedThroughText(from raw: String?, languageCode: String? = nil) -> String? {
        formattedExpiry(from: raw).map {
            String(format: L10n.t("business_pro_included_through_format", languageCode: languageCode), $0)
        }
    }

    static func activeUntilText(from raw: String?, languageCode: String? = nil) -> String? {
        formattedExpiry(from: raw).map {
            String(format: L10n.t("business_pro_promo_active_until_format", languageCode: languageCode), $0)
        }
    }
}

struct BusinessEntitlementSnapshot: Decodable, Equatable {
    let business_id: UUID
    let plan_type: String?
    let plan_status: String?
    let pro_expires_at: String?
    let is_pro_active: Bool
    let days_remaining: Int?
    let statistics_enabled: Bool
    let sponsored_enabled: Bool
    let unlimited_venues: Bool
    let unlimited_hosting: Bool
    let venue_limit: Int?
    let monthly_host_limit: Int?
    let hosted_game_cycle_bonus_games: Int?
    let effective_monthly_host_limit: Int?
    let venues_used: Int
    let hosted_games_this_month: Int?
    let hosted_games_used_this_cycle: Int?
    let hosted_game_cycle_start_at: String?
    let hosted_game_cycle_end_at: String?
    let next_reset_at: String?
    let entitlement_source: String?
    let entitlement_updated_at: String?
}

struct BusinessVenueGamePostingStatus: Equatable {
    let promoActive: Bool
    let businessVenueCount: Int
    let monthlyHostedGameCount: Int
    let freeVenueListingLimitReached: Bool
    let freeMonthlyVenueGameLimitReached: Bool
    let limitsOverriddenBySummerPromo: Bool
    let businessProActive: Bool
    let businessId: UUID?
    let planType: String
    let planStatus: String
    let proExpiresAt: String?
    let daysRemaining: Int?
    let statisticsEnabled: Bool
    let sponsoredEnabled: Bool
    let unlimitedVenues: Bool
    let unlimitedHosting: Bool
    let venueLimit: Int
    let monthlyHostLimit: Int
    let hostedGameCycleBonusGames: Int?
    let effectiveMonthlyHostLimit: Int?
    let hostedGamesUsedThisCycle: Int?
    let hostedGameCycleStartAt: String?
    let hostedGameCycleEndAt: String?
    let nextResetAt: String?
    let entitlementSource: String?
    let entitlementUpdatedAt: String?
    let loadedFromServer: Bool

    var computedIsPro: Bool { businessProActive }
    var isBusinessPro: Bool { computedIsPro }
    var isStatisticsLocked: Bool { !(computedIsPro || statisticsEnabled) }
    var statisticsAccessGranted: Bool { !isStatisticsLocked }
    var sponsoredPlacementAllowed: Bool { sponsoredEnabled || computedIsPro || planType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "free" }
    var activeVenueCount: Int { businessVenueCount }
    var activeVenueLimit: Int? {
        // Honor Free admin unlimited override (unlimitedVenues true while remaining Free).
        if unlimitedVenues || isBusinessPro { return nil }
        return venueLimit
    }
    var monthlyHostedGameLimit: Int? { unlimitedHosting || isBusinessPro ? nil : monthlyHostLimit }
    var currentMonthHostedGameCount: Int { monthlyHostedGameCount }
    var hostedGamesUsedForDisplay: Int { hostedGamesUsedThisCycle ?? monthlyHostedGameCount }
    var hostedGamesEffectiveMonthlyHostLimitForDisplay: Int? {
        guard !(unlimitedHosting || isBusinessPro) else { return nil }
        return effectiveMonthlyHostLimit ?? monthlyHostLimit
    }
    var hostedGamesCycleLimit: Int { monthlyHostLimit }
    var hostedGameLimit: Int { monthlyHostLimit }
    var monthlyPostCount: Int { monthlyHostedGameCount }
    var freeLimitReached: Bool { freeMonthlyVenueGameLimitReached }
    var normalizedEntitlementSource: String {
        entitlementSource?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }
    var isBusinessProPromo: Bool {
        guard computedIsPro else { return false }
        return !isBusinessSubscriptionPro
    }
    var isBusinessSubscriptionPro: Bool {
        guard computedIsPro else { return false }
        let source = normalizedEntitlementSource
        let plan = planType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return source == "subscription_pro"
            || source == "pro_paid"
            || plan == "subscription_pro"
            || plan == "pro_paid"
    }

    /// Paid/subscription Pro that grants business FanGeo+ (excludes launch promo / `pro_promo`).
    var includesFanGeoPlusWithPaidPro: Bool {
        Self.includesFanGeoPlusWithPaidPro(from: self)
    }

    static func includesFanGeoPlusWithPaidPro(from status: BusinessVenueGamePostingStatus) -> Bool {
        guard status.computedIsPro else { return false }
        let planStatus = status.planStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard planStatus == "active" else { return false }
        let planType = status.planType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard planType == "pro_paid" || planType == "subscription_pro" else { return false }
        let source = status.normalizedEntitlementSource
        return source == "pro_paid" || source == "subscription_pro"
    }
    static let launchPromoComplimentaryAccessSubtitleKey = "business_launch_promotion_complimentary_access"

    /// Set to `true` only after StoreKit-verified Apple IAP Business Pro subscriptions ship.
    static let useAppleSubscriptionPlanDisplay = false

    func businessPlanDisplayTitle(languageCode: String? = nil) -> String {
        guard computedIsPro else { return L10n.t("business_regular", languageCode: languageCode) }
        if Self.useAppleSubscriptionPlanDisplay, isBusinessSubscriptionPro {
            return L10n.t("business_pro_active", languageCode: languageCode)
        }
        return L10n.t("business_pro", languageCode: languageCode)
    }

    var businessPlanDisplayTitle: String { businessPlanDisplayTitle(languageCode: nil) }

    func businessPlanDisplaySubtitle(languageCode: String? = nil) -> String {
        guard computedIsPro else { return normalizedPlanStatusForDisplay(languageCode: languageCode) }
        if Self.useAppleSubscriptionPlanDisplay, isBusinessSubscriptionPro {
            var parts = [L10n.t("business_apple_subscription", languageCode: languageCode)]
            if let formatted = BusinessProPromoDisplay.formattedExpiry(from: proExpiresAt) {
                parts.append(String(format: L10n.t("business_expires_format", languageCode: languageCode), formatted))
            }
            return parts.joined(separator: " • ")
        }
        var parts = [L10n.t(Self.launchPromoComplimentaryAccessSubtitleKey, languageCode: languageCode)]
        if let formatted = BusinessProPromoDisplay.formattedExpiry(from: proExpiresAt) {
            parts.append(String(format: L10n.t("business_expires_format", languageCode: languageCode), formatted))
        }
        return parts.joined(separator: " • ")
    }

    var businessPlanDisplaySubtitle: String { businessPlanDisplaySubtitle(languageCode: nil) }

    func businessProPromoIncludedThroughText(languageCode: String? = nil) -> String? {
        guard isBusinessProPromo else { return nil }
        return BusinessProPromoDisplay.includedThroughText(from: proExpiresAt, languageCode: languageCode)
    }

    var businessProPromoIncludedThroughText: String? { businessProPromoIncludedThroughText(languageCode: nil) }

    func businessProPromoEndDateText(languageCode: String? = nil) -> String? {
        guard isBusinessProPromo,
              let formatted = BusinessProPromoDisplay.formattedExpiry(from: proExpiresAt) else {
            return nil
        }
        return String(format: L10n.t("business_promotion_ends_format", languageCode: languageCode), formatted)
    }

    var businessProPromoEndDateText: String? { businessProPromoEndDateText(languageCode: nil) }

    func businessProPromoActiveUntilText(languageCode: String? = nil) -> String? {
        guard isBusinessProPromo else { return nil }
        return BusinessProPromoDisplay.activeUntilText(from: proExpiresAt, languageCode: languageCode)
    }

    var businessProPromoActiveUntilText: String? { businessProPromoActiveUntilText(languageCode: nil) }

    func businessProSubscriptionExpiryText(languageCode: String? = nil) -> String? {
        guard isBusinessSubscriptionPro,
              let formatted = BusinessProPromoDisplay.formattedExpiry(from: proExpiresAt) else {
            return nil
        }
        return String(format: L10n.t("business_expires_format", languageCode: languageCode), formatted)
    }

    var businessProSubscriptionExpiryText: String? { businessProSubscriptionExpiryText(languageCode: nil) }

    func displayPlanLimitsSummarySubtitle(languageCode: String? = nil) -> String {
        BusinessPlanLimitPresentation.planLimitsSummarySubtitle(for: self, languageCode: languageCode)
    }

    var displayPlanLimitsSummarySubtitle: String { displayPlanLimitsSummarySubtitle(languageCode: nil) }

    func displayActiveVenuesFeatureText(languageCode: String? = nil) -> String {
        BusinessPlanLimitPresentation.activeVenuesFeatureText(for: self, languageCode: languageCode)
    }

    var displayActiveVenuesFeatureText: String { displayActiveVenuesFeatureText(languageCode: nil) }

    func displayHostedGamesFeatureText(languageCode: String? = nil) -> String {
        BusinessPlanLimitPresentation.hostedGamesFeatureText(for: self, languageCode: languageCode)
    }

    var displayHostedGamesFeatureText: String { displayHostedGamesFeatureText(languageCode: nil) }

    /// Effective unlimited venue capacity (Pro, promo Pro, paid Pro, manual Pro, or admin unlimited override).
    var hasUnlimitedVenueCapacity: Bool {
        computedIsPro || unlimitedVenues
    }

    /// When false, approved venues beyond the Regular cap may remain backend `plan_locked`.
    var shouldApplyRegularVenueCap: Bool {
        !hasUnlimitedVenueCapacity
    }

    private func normalizedPlanStatusForDisplay(languageCode: String? = nil) -> String {
        let value = planStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty || value == "active" {
            return L10n.t("business_status_active", languageCode: languageCode)
        }
        return value
    }

    private static let proPlanTypes: Set<String> = ["pro_promo", "pro_paid", "manual_pro", "subscription_pro"]
    private static let effectivelyUnlimitedMonthlyHostLimit = 10_000
    private static let effectivelyUnlimitedVenueLimit = 10_000

    var canAddVenue: Bool {
        if isBusinessPro || unlimitedVenues { return true }
        return activeVenueCount < max(1, venueLimit)
    }

    var canAddHostedGame: Bool {
        if isBusinessPro || unlimitedHosting { return true }
        return monthlyHostedGameCount < max(1, monthlyHostLimit)
    }

    var canHostBusinessGames: Bool { canAddHostedGame }

    var venueLimitReason: String {
        if isBusinessPro { return "business_pro" }
        if unlimitedVenues { return "unlimited_venues" }
        if activeVenueCount < max(1, venueLimit) { return "within_active_venue_limit" }
        return "active_venue_limit_reached"
    }

    var hostedGameLimitReason: String {
        if isBusinessPro { return "business_pro" }
        if unlimitedHosting {
            if monthlyHostLimitIsEffectivelyUnlimited { return "monthly_host_limit_unlimited" }
            return "unlimited_hosting"
        }
        if monthlyHostedGameCount < max(1, monthlyHostLimit) {
            return "within_monthly_host_limit"
        }
        return "monthly_host_limit_reached"
    }

    var canHostBusinessGamesReason: String { hostedGameLimitReason }

    private var monthlyHostLimitIsEffectivelyUnlimited: Bool {
        monthlyHostLimit >= Self.effectivelyUnlimitedMonthlyHostLimit
    }

    static func freeFallback(
        businessId: UUID?,
        venuesUsed: Int = 0,
        hostedGamesThisMonth: Int = 0,
        planStatus: String = "active"
    ) -> BusinessVenueGamePostingStatus {
        BusinessVenueGamePostingStatus(
            promoActive: false,
            businessVenueCount: venuesUsed,
            monthlyHostedGameCount: hostedGamesThisMonth,
            freeVenueListingLimitReached: venuesUsed >= BusinessMembershipPolicy.freeVenueListingLimit,
            freeMonthlyVenueGameLimitReached: hostedGamesThisMonth >= BusinessMembershipPolicy.freeMonthlyVenueGameLimit,
            limitsOverriddenBySummerPromo: false,
            businessProActive: false,
            businessId: businessId,
            planType: "free",
            planStatus: planStatus,
            proExpiresAt: nil,
            daysRemaining: nil,
            statisticsEnabled: false,
            sponsoredEnabled: true,
            unlimitedVenues: false,
            unlimitedHosting: false,
            venueLimit: BusinessMembershipPolicy.freeVenueListingLimit,
            monthlyHostLimit: BusinessMembershipPolicy.freeMonthlyVenueGameLimit,
            hostedGameCycleBonusGames: nil,
            effectiveMonthlyHostLimit: nil,
            hostedGamesUsedThisCycle: nil,
            hostedGameCycleStartAt: nil,
            hostedGameCycleEndAt: nil,
            nextResetAt: nil,
            entitlementSource: nil,
            entitlementUpdatedAt: nil,
            loadedFromServer: false
        )
    }

    static func fromServer(
        _ entitlement: BusinessEntitlementSnapshot,
        activeVenueCount: Int? = nil
    ) -> BusinessVenueGamePostingStatus {
        let rawPlanType = entitlement.plan_type ?? "free"
        let rawPlanStatus = entitlement.plan_status ?? "active"
        let planType = rawPlanType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let planStatus = rawPlanStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let planStatusAllowsProAccess = planStatus.isEmpty || planStatus == "active"
        let expirationAllowsProAccess: Bool = {
            guard let raw = entitlement.pro_expires_at?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                return true
            }
            guard let expiry = SupabaseTimestampParsing.parseTimestamptz(raw) else {
                return false
            }
            return expiry > Date()
        }()
        let venueLimitIsUnlimited = entitlement.venue_limit == nil
            || (entitlement.venue_limit ?? 0) >= effectivelyUnlimitedVenueLimit
        let monthlyLimitIsUnlimited = entitlement.monthly_host_limit == nil
            || (entitlement.monthly_host_limit ?? 0) >= effectivelyUnlimitedMonthlyHostLimit
        let activeProPlan = proPlanTypes.contains(planType)
            && planStatusAllowsProAccess
            && expirationAllowsProAccess
        let rawUnlimitedVenuesIsActive = entitlement.unlimited_venues && planStatusAllowsProAccess && expirationAllowsProAccess
        let rawUnlimitedHostingIsActive = entitlement.unlimited_hosting && planStatusAllowsProAccess && expirationAllowsProAccess
        let normalizedBusinessProActive = (entitlement.is_pro_active && planStatusAllowsProAccess && expirationAllowsProAccess)
            || activeProPlan
            || rawUnlimitedVenuesIsActive
            || rawUnlimitedHostingIsActive
        // Free admin unlimited venue override returns venue_limit=999999 with unlimited_venues=false
        // and is_pro_active=false. Honor the capacity without labeling the business Pro.
        let freeAdminUnlimitedVenues = !normalizedBusinessProActive
            && planType == "free"
            && venueLimitIsUnlimited
        let venueLimitGrantsUnlimitedVenues = venueLimitIsUnlimited
            && planStatusAllowsProAccess
            && expirationAllowsProAccess
            && (normalizedBusinessProActive || planType != "free")
        let monthlyLimitGrantsUnlimitedHosting = monthlyLimitIsUnlimited
            && planStatusAllowsProAccess
            && expirationAllowsProAccess
            && (normalizedBusinessProActive || planType != "free")
        let normalizedUnlimitedVenues = normalizedBusinessProActive
            || venueLimitGrantsUnlimitedVenues
            || freeAdminUnlimitedVenues
        let normalizedUnlimitedHosting = normalizedBusinessProActive
            || monthlyLimitGrantsUnlimitedHosting
        let normalizedVenueLimit: Int
        if normalizedUnlimitedVenues {
            normalizedVenueLimit = entitlement.venue_limit ?? effectivelyUnlimitedVenueLimit
        } else if venueLimitIsUnlimited {
            normalizedVenueLimit = BusinessMembershipPolicy.freeVenueListingLimit
        } else {
            normalizedVenueLimit = entitlement.venue_limit ?? BusinessMembershipPolicy.freeVenueListingLimit
        }
        let normalizedMonthlyHostLimit: Int
        if normalizedUnlimitedHosting {
            normalizedMonthlyHostLimit = entitlement.monthly_host_limit ?? effectivelyUnlimitedMonthlyHostLimit
        } else if monthlyLimitIsUnlimited {
            normalizedMonthlyHostLimit = BusinessMembershipPolicy.freeMonthlyVenueGameLimit
        } else {
            normalizedMonthlyHostLimit = entitlement.monthly_host_limit ?? BusinessMembershipPolicy.freeMonthlyVenueGameLimit
        }
        let entitlementSource = entitlement.entitlement_source?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let isPromo = normalizedBusinessProActive
            && !(
                entitlementSource == "subscription_pro"
                || entitlementSource == "pro_paid"
                || planType == "subscription_pro"
                || planType == "pro_paid"
            )
        let venueCount = activeVenueCount ?? entitlement.venues_used
        let legacyHostedGameCount = entitlement.hosted_games_this_month
            ?? entitlement.hosted_games_used_this_cycle
            ?? 0
        let hostedGameDisplayCount = entitlement.hosted_games_used_this_cycle ?? legacyHostedGameCount
        return BusinessVenueGamePostingStatus(
            promoActive: isPromo,
            businessVenueCount: venueCount,
            monthlyHostedGameCount: legacyHostedGameCount,
            freeVenueListingLimitReached: !normalizedUnlimitedVenues && venueCount >= normalizedVenueLimit,
            freeMonthlyVenueGameLimitReached: !normalizedUnlimitedHosting && hostedGameDisplayCount >= normalizedMonthlyHostLimit,
            limitsOverriddenBySummerPromo: isPromo,
            businessProActive: normalizedBusinessProActive,
            businessId: entitlement.business_id,
            planType: rawPlanType,
            planStatus: rawPlanStatus,
            proExpiresAt: entitlement.pro_expires_at,
            daysRemaining: entitlement.days_remaining,
            statisticsEnabled: entitlement.statistics_enabled,
            sponsoredEnabled: entitlement.sponsored_enabled || normalizedBusinessProActive || planType == "free",
            unlimitedVenues: normalizedUnlimitedVenues,
            unlimitedHosting: normalizedUnlimitedHosting,
            venueLimit: normalizedVenueLimit,
            monthlyHostLimit: normalizedMonthlyHostLimit,
            hostedGameCycleBonusGames: entitlement.hosted_game_cycle_bonus_games,
            effectiveMonthlyHostLimit: entitlement.effective_monthly_host_limit,
            hostedGamesUsedThisCycle: entitlement.hosted_games_used_this_cycle,
            hostedGameCycleStartAt: entitlement.hosted_game_cycle_start_at,
            hostedGameCycleEndAt: entitlement.hosted_game_cycle_end_at ?? entitlement.next_reset_at,
            nextResetAt: entitlement.next_reset_at,
            entitlementSource: entitlement.entitlement_source,
            entitlementUpdatedAt: entitlement.entitlement_updated_at,
            loadedFromServer: true
        )
    }
}

struct BusinessHostedGameCycleAudit: Equatable {
    let businessId: UUID
    let cycleStartAt: String?
    let cycleEndAt: String?
    let nextResetAt: String?
    let hostedGamesUsedThisCycle: Int
    let monthlyHostLimit: Int
    let isUnlimitedHosting: Bool
    let games: [BusinessHostedGameCycleGame]
}

struct BusinessHostedGameCycleGame: Identifiable, Equatable {
    let id: UUID
    let title: String
    let sport: String?
    let scheduledStartAt: String?
    let eventDate: String?
    let eventTime: String?
    let status: String?
    let venueName: String?
}

@MainActor
final class BusinessProPurchaseService: ObservableObject {
    static let shared = BusinessProPurchaseService()
    static let productID = "com.fangeo.businesspro.monthly"

    @Published private(set) var product: Product?
    @Published private(set) var isLoadingProduct = false
    @Published private(set) var isPurchasing = false
    @Published private(set) var isRestoring = false
    @Published private(set) var productLoadFailed = false
    @Published var purchaseMessage = ""

    private var didLoadProducts = false
    private var updatesTask: Task<Void, Never>?

    /// Compatibility value for older call sites. Business Pro activation must come from Supabase entitlements only.
    var businessProActive: Bool { false }

    var canPurchase: Bool {
        product != nil && !isLoadingProduct && !isPurchasing
    }

    var billingUnavailableMessage: String {
        "Business Pro billing is coming soon."
    }

    var manageSubscriptionURL: URL? {
        URL(string: "https://apps.apple.com/account/subscriptions")
    }

    private init() {
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                await self.handleTransactionUpdate(result)
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func prepare() async {
        await loadProductIfNeeded()
    }

    func loadProductIfNeeded() async {
        guard !didLoadProducts, !isLoadingProduct else { return }
        didLoadProducts = true
        isLoadingProduct = true
        productLoadFailed = false
        defer { isLoadingProduct = false }

        do {
            let products = try await Product.products(for: [Self.productID])
            product = products.first(where: { $0.id == Self.productID })
            productLoadFailed = product == nil
            if product == nil {
                purchaseMessage = billingUnavailableMessage
#if DEBUG
                print("[BusinessProPurchase] productLoad productId=\(Self.productID) found=false")
#endif
            } else {
#if DEBUG
                print("[BusinessProPurchase] productLoad productId=\(Self.productID) found=true")
#endif
            }
        } catch {
            product = nil
            productLoadFailed = true
            purchaseMessage = billingUnavailableMessage
#if DEBUG
            print("[BusinessProPurchase] productLoad error=\(error.localizedDescription)")
#endif
        }
    }

    @discardableResult
    func purchaseBusinessPro() async -> Bool {
        await loadProductIfNeeded()
#if DEBUG
        print("[BusinessProPurchase] purchaseStarted productId=\(Self.productID)")
#endif
        guard let product else {
            purchaseMessage = billingUnavailableMessage
#if DEBUG
            print("[BusinessProPurchase] purchaseUnavailable reason=product_not_found")
#endif
            return false
        }

        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try verified(verification)
                await sendTransactionToBackendPlaceholder(transaction)
                await transaction.finish()
                purchaseMessage = "Purchase received. Activation will be verified shortly."
#if DEBUG
                print("[BusinessProPurchase] purchaseSucceeded transactionId=\(transaction.id)")
                print("[BusinessProPurchase] localUnlock=false sourceOfTruth=supabase")
#endif
                return true
            case .pending:
                purchaseMessage = "Purchase pending."
#if DEBUG
                print("[BusinessProPurchase] purchasePending=true")
#endif
                return false
            case .userCancelled:
                purchaseMessage = ""
#if DEBUG
                print("[BusinessProPurchase] purchaseCancelled=true")
#endif
                return false
            @unknown default:
                purchaseMessage = "Purchase unavailable."
#if DEBUG
                print("[BusinessProPurchase] purchaseFailed=unknown_result")
#endif
                return false
            }
        } catch {
            purchaseMessage = error.localizedDescription
#if DEBUG
            print("[BusinessProPurchase] purchaseFailed error=\(error.localizedDescription)")
#endif
            return false
        }
    }

    func restorePurchases() async {
        isRestoring = true
        defer { isRestoring = false }
        do {
#if DEBUG
            print("[BusinessProPurchase] restoreStarted=true")
#endif
            try await AppStore.sync()
            let foundBusinessProTransaction = await sendCurrentBusinessProTransactionsToBackendPlaceholder()
            purchaseMessage = foundBusinessProTransaction
                ? "Purchase received. Activation will be verified shortly."
                : "No Business Pro purchases found."
#if DEBUG
            print("[BusinessProPurchase] restoreFinished foundBusinessProTransaction=\(foundBusinessProTransaction)")
            print("[BusinessProPurchase] localUnlock=false sourceOfTruth=supabase")
#endif
        } catch {
            purchaseMessage = error.localizedDescription
#if DEBUG
            print("[BusinessProPurchase] restoreFailed error=\(error.localizedDescription)")
#endif
        }
    }

    func refreshPurchasedEntitlements() async {
#if DEBUG
        print("[BusinessProPurchase] refreshPurchasedEntitlements localUnlock=false")
#endif
    }

    private func handleTransactionUpdate(_ result: VerificationResult<Transaction>) async {
        guard let transaction = try? verified(result) else { return }
        if transaction.productID == Self.productID {
            await sendTransactionToBackendPlaceholder(transaction)
            await transaction.finish()
#if DEBUG
            print("[BusinessProPurchase] transactionUpdate transactionId=\(transaction.id)")
            print("[BusinessProPurchase] localUnlock=false sourceOfTruth=supabase")
#endif
        }
    }

    @discardableResult
    private func sendCurrentBusinessProTransactionsToBackendPlaceholder() async -> Bool {
        var foundBusinessProTransaction = false
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? verified(result), transaction.productID == Self.productID else {
                continue
            }
            foundBusinessProTransaction = true
            await sendTransactionToBackendPlaceholder(transaction)
        }
        return foundBusinessProTransaction
    }

    private func sendTransactionToBackendPlaceholder(_ transaction: Transaction) async {
#if DEBUG
        print("[BusinessProPurchase] backendPlaceholder notImplemented=true")
        print("[BusinessProPurchase] transactionId=\(transaction.id) originalId=\(transaction.originalID) productId=\(transaction.productID)")
#endif
        // Real activation must be performed later by backend App Store Server validation updating Supabase.
    }

    private func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified(_, let error):
            throw error
        }
    }
}

typealias BusinessProEntitlementManager = BusinessProPurchaseService
