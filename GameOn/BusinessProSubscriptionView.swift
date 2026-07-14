import SwiftUI

struct BusinessProSubscriptionView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    let businessStatus: BusinessVenueGamePostingStatus?

    init(businessStatus: BusinessVenueGamePostingStatus? = nil) {
        self.businessStatus = businessStatus
    }

    private var proFeatureListItems: [String] {
        BusinessPlanLimitPresentation.proPlanFeatureBullets(languageCode: appLanguageRaw) + [
            L10n.t("analytics_access", languageCode: appLanguageRaw)
        ]
    }

    private var regularFeatureListItems: [String] {
        guard let businessStatus else { return BusinessPlanLimitPresentation.regularPlanFeatureBullets(languageCode: appLanguageRaw) }
        return [
            businessStatus.displayActiveVenuesFeatureText(languageCode: appLanguageRaw),
            businessStatus.displayHostedGamesFeatureText(languageCode: appLanguageRaw)
        ]
    }

    private var fallbackRegularFeatures: [String] {
        BusinessPlanLimitPresentation.regularPlanFeatureBullets(languageCode: appLanguageRaw)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                header
                entitlementPlanCard
                if !isCurrentBusinessRegular {
                    regularReferenceCard
                }
                launchInformationFooter
            }
            .padding(20)
        }
        .background(background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(FGColor.accentGreen)
                    .frame(width: 46, height: 46)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("FanGeo Business Pro")
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text("Compare free business tools with unlimited listings and hosting.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var entitlementPlanCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            planHeader(
                title: entitlementTitle,
                subtitle: entitlementSubtitle,
                badge: entitlementBadge,
                badgeColor: entitlementBadgeColor
            )

            Text(entitlementDetailText)
                .font(.title3.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            Text("Business Pro subscriptions will be available in a future update.")
                .font(.caption.weight(.heavy))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            planFeatureList(
                entitlementFeatures,
                tint: entitlementFeatureTint,
                includeProFanGeoPlusBullet: !isCurrentBusinessRegular
            )

            if !isCurrentBusinessRegular {
                Text("During the launch promotion, Business Pro accounts may continue to display advertisements. FanGeo+ will be available in a future update.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            FGColor.accentGreen.opacity(colorScheme == .dark ? 0.22 : 0.14),
                            FGColor.accentYellow.opacity(colorScheme == .dark ? 0.18 : 0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.42), lineWidth: 1)
        }
    }

    private var regularReferenceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            planHeader(
                title: L10n.t("business_regular", languageCode: appLanguageRaw),
                subtitle: L10n.t("free_business_tools_for_sports_venues", languageCode: appLanguageRaw),
                badge: L10n.t("free_badge", languageCode: appLanguageRaw),
                badgeColor: FGColor.accentBlue
            )

            Text(L10n.t("free_plan", languageCode: appLanguageRaw))
                .font(.caption.weight(.heavy))
                .foregroundStyle(FGColor.secondaryText(colorScheme))

            planFeatureList(fallbackRegularFeatures, tint: FGColor.accentBlue)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.72), lineWidth: 1)
        }
    }

    private func planHeader(
        title: String,
        subtitle: String,
        badge: String,
        badgeColor: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.black))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(subtitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Text(badge)
                .font(.caption2.weight(.black))
                .foregroundStyle(badgeColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(badgeColor.opacity(colorScheme == .dark ? 0.20 : 0.12), in: Capsule(style: .continuous))
        }
    }

    private func planFeatureList(
        _ features: [String],
        tint: Color,
        includeProFanGeoPlusBullet: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(features, id: \.self) { feature in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(feature)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            if includeProFanGeoPlusBullet {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                    Text("FanGeo+ included with future Business Pro subscriptions")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var launchInformationFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Business Pro access is currently provided through the FanGeo launch promotion.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }

    private var entitlementTitle: String {
        guard let businessStatus else { return L10n.t("business_checking_plan_status", languageCode: appLanguageRaw) }
        return businessStatus.businessPlanDisplayTitle(languageCode: appLanguageRaw)
    }

    private var entitlementSubtitle: String {
        guard let businessStatus else { return L10n.t("refreshing_entitlement", languageCode: appLanguageRaw) }
        guard businessStatus.computedIsPro else { return L10n.t("free_plan", languageCode: appLanguageRaw) }
        return businessStatus.businessPlanDisplaySubtitle(languageCode: appLanguageRaw)
    }

    private var entitlementBadge: String {
        guard let businessStatus else { return "CHECKING" }
        if businessStatus.computedIsPro {
            return businessStatus.isBusinessProPromo ? "PROMO" : "PRO"
        }
        return "REGULAR"
    }

    private var entitlementBadgeColor: Color {
        guard let businessStatus else { return FGColor.accentBlue }
        if businessStatus.computedIsPro {
            return businessStatus.isBusinessProPromo ? FGColor.accentYellow : FGColor.accentGreen
        }
        return FGColor.accentBlue
    }

    private var entitlementFeatureTint: Color {
        businessStatus?.computedIsPro == true ? FGColor.accentGreen : FGColor.accentBlue
    }

    private var entitlementFeatures: [String] {
        guard let businessStatus else { return fallbackRegularFeatures }
        return businessStatus.computedIsPro ? proFeatureListItems : regularFeatureListItems
    }

    private var entitlementDetailText: String {
        guard let businessStatus else {
            return "Business Pro details are refreshing from your business account."
        }
        if businessStatus.computedIsPro {
            if businessStatus.isBusinessProPromo {
                if let formatted = BusinessProPromoDisplay.formattedExpiry(from: businessStatus.proExpiresAt) {
                    return "Complimentary launch promotion through \(formatted)."
                }
                return "Complimentary Business Pro access through the FanGeo launch promotion."
            }
            if let formatted = BusinessProPromoDisplay.formattedExpiry(from: businessStatus.proExpiresAt) {
                return "Promotion ends on \(formatted)"
            }
            return "Promotion end date refreshes from your business account."
        }
        return "Upgrade to Business Pro for unlimited venues and hosted games."
    }

    private var isCurrentBusinessRegular: Bool {
        businessStatus?.computedIsPro != true
    }

    private var background: some View {
        ZStack {
            FGAdaptiveSurface.sheetRoot.ignoresSafeArea()
            LinearGradient(
                colors: [
                    FGColor.accentGreen.opacity(colorScheme == .dark ? 0.18 : 0.10),
                    FGColor.accentBlue.opacity(colorScheme == .dark ? 0.12 : 0.06),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
    }
}

struct BusinessProSubscriptionView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            BusinessProSubscriptionView()
                .preferredColorScheme(.light)
            BusinessProSubscriptionView()
                .preferredColorScheme(.dark)
        }
    }
}
