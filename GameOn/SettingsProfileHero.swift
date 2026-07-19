import SwiftUI

struct SettingsProfileHero: View {
    @ObservedObject var viewModel: MapViewModel
    var businessMembershipStatus: BusinessVenueGamePostingStatus?
    var businessVenueSelectorOnAddLocation: (() -> Void)?
    var businessVenueSelectorIsHydrating = false
    var businessVenueSelectorHydrationReason = "ready"
    var businessVenueSelectorOnBlockedEarlyTap: ((String, String) -> Void)?
    var managedVenuesSheetPresentationToken: UInt = 0
    var venueOwnerOnNotifications: () -> Void
    var venueOwnerOnResetPassword: () -> Void
    var venueOwnerOnDismissSheetsAfterLogout: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var isBusinessProfile: Bool {
        viewModel.venueOwnerMode || viewModel.isVenueOwnerLoggedIn || viewModel.currentUserIsBusinessAccount
    }

    private var managedVenueCount: Int {
        viewModel.managedVenuesForOwner().count
    }

    private var businessHasManagedVenues: Bool {
        managedVenueCount > 0
    }

    private var currentBusinessRow: BusinessRow? {
        if let businessId = viewModel.currentBusinessIdForAddLocation(),
           let business = viewModel.ownedBusinesses.first(where: { $0.id == businessId }) {
            return business
        }
        return viewModel.ownedBusinesses.first
    }

    private var businessHeaderName: String {
        if let name = trimmedNonEmpty(currentBusinessRow?.display_name) {
            return name
        }
        return venueOwnerBusinessHeroTitle
    }

    private var businessHeaderHandleLine: String? {
        guard let stored = trimmedNonEmpty(currentBusinessRow?.business_handle) else { return nil }
        let display = FanGeoHandleRules.displayHandle(stored: stored)
        guard !display.isEmpty else { return nil }
        return "\(L10n.t("handle", languageCode: appLanguageRaw)): \(display)"
    }

    private var businessHeaderLocation: String {
        if let line = businessLocationLine {
            return "\(L10n.t("venue", languageCode: appLanguageRaw)): \(line)"
        }
        return "Business dashboard"
    }

    private var businessHeaderMemberSince: String {
        guard let raw = trimmedNonEmpty(currentBusinessRow?.created_at),
              let date = SupabaseTimestampParsing.parseTimestamptz(raw) else {
            return String(
                format: L10n.t("business_joined_format", languageCode: appLanguageRaw),
                "FanGeo"
            )
        }
        return String(
            format: L10n.t("business_joined_format", languageCode: appLanguageRaw),
            Self.businessHeaderMemberSinceFormatter.string(from: date)
        )
    }

    private var businessHeaderIsPro: Bool {
        businessMembershipStatus?.computedIsPro == true
    }

    private var businessHeaderHasPendingVenueClaim: Bool {
        !viewModel.pendingVenueClaimsForSettings.isEmpty
    }

    private var businessStatusIconColor: Color {
        BusinessStatusIconChrome.statusColor(
            isPro: businessHeaderIsPro,
            hasPendingVenueClaim: businessHeaderHasPendingVenueClaim,
            colorScheme: colorScheme
        )
    }

    private var businessStatusIconDeepColor: Color {
        BusinessStatusIconChrome.deepColor(for: businessStatusIconColor)
    }

    private var businessStatusShowsPendingClaimDot: Bool {
        BusinessStatusIconChrome.showsPendingClaimDot(
            isPro: businessHeaderIsPro,
            hasPendingVenueClaim: businessHeaderHasPendingVenueClaim
        )
    }

    private var businessHeaderActiveVenueCount: Int {
        if let businessMembershipStatus {
            return businessMembershipStatus.activeVenueCount
        }
        var seen = Set<UUID>()
        return viewModel.managedVenuesForOwner().reduce(0) { count, row in
            guard let id = row.id, seen.insert(id).inserted else { return count }
            return MapViewModel.venueIsActiveForBusinessLimit(row) ? count + 1 : count
        }
    }

    private var businessHeaderActiveVenueValue: String {
        let total = max(managedVenueCount, businessHeaderActiveVenueCount)
        if total > businessHeaderActiveVenueCount {
            return "\(businessHeaderActiveVenueCount) / \(total)"
        }
        return "\(businessHeaderActiveVenueCount)"
    }

    private var businessHeaderHostedGamesValue: String {
        if let businessMembershipStatus {
            return "\(businessMembershipStatus.monthlyHostedGameCount)"
        }
        return "0"
    }

    private static let businessHeaderMemberSinceFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM yyyy"
        return formatter
    }()

    private var selectedVenueForHero: VenueProfileRow? {
        let managed = viewModel.managedVenuesForOwner()
        if let id = viewModel.ownerVenueDatabaseId,
           let selected = managed.first(where: { $0.id == id }) {
            return selected
        }
        return managed.first
    }

    /// Email shown in the hero: fan session vs venue-owner session (existing ``MapViewModel`` flags; no auth changes).
    private var heroEmailLine: String {
        if viewModel.isLoggedIn {
            return viewModel.currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail)
    }

    private func trimmedNonEmpty(_ raw: String?) -> String? {
        let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    private func businessOwnerEmailPrefixTitle() -> String {
        let email = OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail)
        let local = email.split(separator: "@").first.map(String.init) ?? ""
        guard !local.isEmpty else { return "" }
        return local.prefix(1).uppercased() + local.dropFirst()
    }

    /// Business-account title for the hero (never the selected venue name; venue stays in the Business section).
    private var venueOwnerBusinessHeroTitle: String {
        let businesses = viewModel.ownedBusinesses
        if businesses.count == 1 {
            if let name = trimmedNonEmpty(businesses.first?.display_name) {
                return name
            }
            let prefix = businessOwnerEmailPrefixTitle()
            return prefix.isEmpty ? "Business account" : prefix
        }
        if businesses.count > 1 {
            if let vid = viewModel.ownerVenueDatabaseId {
                let managed = viewModel.managedVenuesForOwner()
                if let row = managed.first(where: { $0.id == vid }),
                   let bid = row.business_id,
                   let biz = businesses.first(where: { $0.id == bid }),
                   let name = trimmedNonEmpty(biz.display_name) {
                    return name
                }
            }
            return "Business account"
        }
        let prefix = businessOwnerEmailPrefixTitle()
        return prefix.isEmpty ? "Business account" : prefix
    }

    private var resolvedDisplayName: String {
        if isBusinessProfile {
            if let venueName = trimmedNonEmpty(selectedVenueForHero?.venue_name) {
                return venueName
            }
            return venueOwnerBusinessHeroTitle
        }
        let current = viewModel.currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty { return current }
        let email = heroEmailLine
        let local = email.split(separator: "@").first.map(String.init) ?? ""
        guard !local.isEmpty else { return "" }
        return local.prefix(1).uppercased() + local.dropFirst()
    }

    /// Prefer venue-owner label when both flags are true (defensive; login paths normally keep them exclusive).
    private var accountTypeBadgeText: String {
        isBusinessProfile ? L10n.t("official_venue_dashboard", languageCode: appLanguageRaw) : "User account"
    }

    private var activityBadgeText: String {
        if isBusinessProfile {
            return managedVenueCount == 1 ? "1 managed venue" : "\(managedVenueCount) managed venues"
        }
        let favoritesCount = viewModel.favoriteVenueIDs.count
        return favoritesCount == 1 ? "1 saved venue" : "\(favoritesCount) saved venues"
    }

    private var activityBadgeTint: Color {
        if isBusinessProfile {
            return businessHasManagedVenues ? FGColor.accentGreen : FGColor.accentBlue
        }
        return FGColor.accentYellow
    }

    private var businessLocationLine: String? {
        guard isBusinessProfile else { return nil }
        guard let venue = selectedVenueForHero else { return nil }
        let city = venue.city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let state = venue.state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let country = venue.country.map(BusinessLocationCountryPolicy.countryName(for:)) ?? ""
        let parts = [city, state, country].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private var businessHeroImageSource: String {
        isBusinessProfile ? "forcedBusinessIcon" : "fanAvatar"
    }

    private var businessStatusLabel: String {
        if businessHeroShowsVerifiedVenue {
            return L10n.t("verified_venue", languageCode: appLanguageRaw).uppercased()
        }
        return "BUSINESS ACCOUNT"
    }

    private var businessHeroShowsVerifiedVenue: Bool {
        isBusinessProfile
            && selectedVenueForHero != nil
            && viewModel.businessSettingsLocationChrome() == .approved
    }

    private var accountTypeCapsule: some View {
        heroGlassPill(title: accountTypeBadgeText)
            .accessibilityLabel(accountTypeBadgeText)
    }

    private var activityCapsule: some View {
        heroGlassPill(title: activityBadgeText, accent: activityBadgeTint)
            .accessibilityLabel(activityBadgeText)
    }

    private var heroBackgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.04, green: 0.05, blue: 0.07).opacity(colorScheme == .dark ? 0.96 : 0.90),
                Color(red: 0.09, green: 0.12, blue: 0.17).opacity(colorScheme == .dark ? 0.98 : 0.93),
                Color(red: 0.16, green: 0.22, blue: 0.30).opacity(colorScheme == .dark ? 0.92 : 0.86)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var heroBlueHighlight: some View {
        RadialGradient(
            colors: [
                Color(red: 0.74, green: 0.88, blue: 0.99).opacity(colorScheme == .dark ? 0.12 : 0.08),
                Color.clear
            ],
            center: .topTrailing,
            startRadius: 8,
            endRadius: 220
        )
    }

    private func heroGlassPill(title: String, accent: Color? = nil) -> some View {
        HStack(spacing: 6) {
            if let accent {
                Circle()
                    .fill(accent.opacity(0.95))
                    .frame(width: 6, height: 6)
                    .shadow(color: accent.opacity(0.28), radius: 4, y: 0)
            }

            Text(title)
                .font(FGTypography.metadata.weight(.semibold))
                .foregroundStyle(.white.opacity(accent == nil ? 0.78 : 0.90))
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background {
            Capsule(style: .continuous)
                .fill(Color(red: 0.82, green: 0.90, blue: 1.0).opacity(colorScheme == .dark ? 0.08 : 0.10))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.15), lineWidth: 1)
                }
        }
    }

    private var heroCard: some View {
        ZStack(alignment: .bottomTrailing) {
            heroBackgroundGradient
            heroBlueHighlight

            VStack(alignment: .leading, spacing: FGSpacing.lg) {
                HStack(alignment: .top, spacing: FGSpacing.md) {
                    heroAvatar

                    VStack(alignment: .leading, spacing: FGSpacing.xs) {
                        if isBusinessProfile {
                            businessAccountLabel
                        } else {
                            Text("FanGeo profile")
                                .font(FGTypography.metadata.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.72))
                        }

                        HStack(spacing: 8) {
                            Text(resolvedDisplayName.isEmpty ? "My profile" : resolvedDisplayName)
                                .font(isBusinessProfile ? .title2.weight(.black) : FGTypography.sectionTitle)
                                .foregroundStyle(.white)
                                .lineLimit(2)

                            if businessHeroShowsVerifiedVenue {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.headline.weight(.bold))
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(FGColor.accentGreen)
                            }
                        }

                        if let location = businessLocationLine {
                            Label(location, systemImage: "mappin.and.ellipse")
                                .font(FGTypography.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.84))
                                .lineLimit(1)
                        } else if !heroEmailLine.isEmpty {
                            Text(heroEmailLine)
                                .font(FGTypography.caption)
                                .foregroundStyle(.white.opacity(0.82))
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)

                    if !isBusinessProfile {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white.opacity(0.86))
                            .frame(width: 34, height: 34)
                            .background(Color(red: 0.82, green: 0.90, blue: 1.0).opacity(colorScheme == .dark ? 0.08 : 0.10))
                            .clipShape(Circle())
                            .overlay {
                                Circle()
                                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.15), lineWidth: 1)
                            }
                    }
                }

                HStack(spacing: FGSpacing.sm) {
                    accountTypeCapsule
                    activityCapsule
                    if isBusinessProfile {
                        heroGlassPill(title: L10n.t("venue_owner_account", languageCode: appLanguageRaw), accent: FGColor.accentBlue)
                    }
                }
            }
            .padding(FGSpacing.xl)

            FanGeoLogoWatermark(variant: .white, width: 62, opacity: 0.055)
                .padding(.trailing, 12)
                .padding(.bottom, 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.11 : 0.14), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.14), radius: 16, y: 9)
        .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.08 : 0.04), radius: 12, y: 2)
    }

    private var businessDashboardHeaderCard: some View {
        ZStack(alignment: .bottomTrailing) {
            heroBackgroundGradient
            heroBlueHighlight

            VStack(alignment: .leading, spacing: FGSpacing.md) {
                HStack(alignment: .top, spacing: FGSpacing.md) {
                    VStack(spacing: 6) {
                        businessHeaderAvatar

                        Text("Business Account")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(businessStatusIconColor)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.78)
                            .frame(width: 72)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        if businessHeaderIsPro {
                            businessHeaderBadge(
                                title: "Pro Business",
                                systemImage: "crown.fill",
                                tint: SettingsPremiumChrome.proGold(colorScheme)
                            )
                        }

                        Text(businessHeaderName.isEmpty ? "Business profile" : businessHeaderName)
                            .font(.system(size: 26, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)

                        if let businessHeaderHandleLine {
                            Text(businessHeaderHandleLine)
                                .font(FGTypography.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.84))
                                .lineLimit(1)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.t("selected_venue", languageCode: appLanguageRaw))
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.70))
                                .lineLimit(1)

                            businessHeaderVenueSelector
                        }

                        Text("We bring fans together with the best sports atmosphere.")
                            .font(FGTypography.caption)
                            .foregroundStyle(.white.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(businessHeaderLocation, systemImage: "mappin.and.ellipse")
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Label(businessHeaderMemberSince, systemImage: "calendar")
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 9) {
                        businessHeaderMetric(
                            title: "Active Venues",
                            value: businessHeaderActiveVenueValue,
                            systemImage: "checkmark.seal.fill"
                        )
                        businessHeaderMetric(
                            title: "Hosted Games This Month",
                            value: businessHeaderHostedGamesValue,
                            systemImage: "sportscourt.fill"
                        )
                    }
                    .padding(.leading, FGSpacing.md)
                    .frame(minWidth: 118, alignment: .leading)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.white.opacity(0.10))
                            .frame(width: 1)
                    }
                }
            }
            .padding(.horizontal, FGSpacing.lg)
            .padding(.vertical, FGSpacing.lg)

            FanGeoLogoWatermark(variant: .white, width: 54, opacity: 0.045)
                .padding(.trailing, 12)
                .padding(.bottom, 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.11 : 0.14), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.14), radius: 16, y: 9)
        .shadow(color: businessStatusIconColor.opacity(colorScheme == .dark ? 0.10 : 0.06), radius: 14, y: 2)
    }

    @ViewBuilder
    private var businessHeaderVenueSelector: some View {
        BusinessLocationVenuePicker(
            viewModel: viewModel,
            chrome: .headerCompact,
            onRequestAddNewLocation: businessVenueSelectorOnAddLocation,
            isHydrating: businessVenueSelectorIsHydrating,
            hydrationReason: businessVenueSelectorHydrationReason,
            onBlockedEarlyTap: businessVenueSelectorOnBlockedEarlyTap,
            venueListPresentationToken: managedVenuesSheetPresentationToken
        )
        .padding(.top, 1)
    }

    private var businessHeaderAvatar: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            businessStatusIconColor.opacity(0.98),
                            businessStatusIconDeepColor.opacity(0.82)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Image(systemName: "building.2.fill")
                .font(.system(size: 34, weight: .black))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)

            Image(systemName: "shield.checkered")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(businessStatusIconColor)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.86), lineWidth: 1.5)
                }
                .offset(x: 5, y: 5)

        }
        .frame(width: 72, height: 72)
        .overlay(alignment: .topTrailing) {
            if businessStatusShowsPendingClaimDot {
                pendingVenueClaimDot(diameter: 13, borderColor: .white)
                    .offset(x: 3, y: -3)
            }
        }
        .shadow(color: businessStatusIconColor.opacity(0.25), radius: 12, y: 6)
    }

    private func businessHeaderBadge(title: String, systemImage: String, tint: Color) -> some View {
        Label(title.uppercased(), systemImage: systemImage)
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(colorScheme == .dark ? 0.32 : 0.26))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                    }
            )
    }

    private func businessHeaderMetric(title: String, value: String, systemImage: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(FGColor.accentGreen)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.70))
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var heroAvatar: some View {
        if isBusinessProfile {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.10))

                businessBuildingFallbackIcon
            }
            .frame(width: 78, height: 78)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
            }
            .overlay(alignment: .topTrailing) {
                if businessStatusShowsPendingClaimDot {
                    pendingVenueClaimDot(diameter: 13, borderColor: Color.white.opacity(0.92))
                        .offset(x: 3, y: -3)
                }
            }
        } else {
            UserAvatarView(
                avatarThumbnailURL: viewModel.currentUserAvatarThumbnailURL,
                avatarURL: viewModel.currentUserAvatarURL,
                avatarDisplayRefreshToken: viewModel.currentUserAvatarDisplayRefreshToken,
                displayName: resolvedDisplayName,
                email: heroEmailLine,
                size: 72,
                fallbackStyle: .darkCardTranslucent,
                imagePlaceholderTint: .white
            )
        }
    }

    private var businessBuildingFallbackIcon: some View {
        ZStack {
            LinearGradient(
                colors: [
                    businessStatusIconColor.opacity(0.95),
                    businessStatusIconDeepColor.opacity(0.78)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: "building.2.fill")
                .font(.system(size: 34, weight: .black))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
        }
    }

    private var businessAccountLabel: some View {
        Label(businessStatusLabel, systemImage: businessHeroShowsVerifiedVenue ? "shield.checkered" : "building.2.fill")
            .font(.caption.weight(.black))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                LinearGradient(
                    colors: businessHeroShowsVerifiedVenue
                        ? [businessStatusIconColor.opacity(0.95), FGColor.accentBlue.opacity(0.85)]
                        : [FGColor.accentBlue.opacity(0.86), Color.white.opacity(0.16)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(Capsule())
    }

    private func pendingVenueClaimDot(diameter: CGFloat, borderColor: Color) -> some View {
        Circle()
            .fill(Color.orange)
            .frame(width: diameter, height: diameter)
            .overlay {
                Circle()
                    .strokeBorder(borderColor, lineWidth: 2)
            }
            .shadow(color: Color.orange.opacity(0.28), radius: 4, y: 1)
            .accessibilityHidden(true)
    }

    private func logBusinessProfileHeaderIfZeroVenues() {
#if DEBUG
        guard isBusinessProfile, managedVenueCount == 0 else { return }
        print("[BusinessProfileHeaderDebug] clearedStaleVenueHeader=true")
        print("[BusinessProfileHeaderDebug] managedVenueCount=0")
#endif
    }

    var body: some View {
        Group {
            if isBusinessProfile {
                businessDashboardHeaderCard
            } else {
                heroCard
            }
        }
            .onAppear {
#if DEBUG
                if isBusinessProfile {
                    print("[BusinessDashboardCleanup] removedLegacyFanLevel=true")
                    print("[BusinessDashboardCleanup] unifiedHeroCard=true")
                    print("[BusinessDashboardCleanup] businessIdentityEnhanced=true")
                    print("[BusinessDashboardCleanup] businessAccountStylingApplied=true")
                    print("[BusinessDashboardCleanup] businessHeroImageSource=\(businessHeroImageSource)")
                    print("[BusinessDashboardCleanup] blockedFanAvatarInBusinessHero=true")
                    print("[BusinessDashboardCleanup] forcedBusinessIconHero=true")
                }
#endif
                logBusinessProfileHeaderIfZeroVenues()
            }
            .onChange(of: managedVenueCount) { _, _ in
                logBusinessProfileHeaderIfZeroVenues()
            }
    }
}
