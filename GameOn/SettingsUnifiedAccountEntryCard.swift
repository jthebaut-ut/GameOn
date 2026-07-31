import SwiftUI

struct SettingsUnifiedAccountEntryCard: View {
    @ObservedObject var viewModel: MapViewModel
    let onSignIn: () -> Void
    let onCreateAccount: () -> Void
    let onWatchLiveWithFans: () -> Void
    let onJoinPickupGames: () -> Void
    let onVenueOwnerTools: (() -> Void)?
    var statusMessage: String = ""
    var attemptedLoginEmail: String = ""
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @State private var lastGuestBenefitNavigationAt: Date?

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var verifiedNotice: String {
        viewModel.emailVerifiedSignInNotice.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var guestBenefitCardMinHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 118 : 96
    }

    var body: some View {
        VStack(spacing: FGSpacing.md) {
            heroCard

            if !statusMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !verifiedNotice.isEmpty {
                if !verifiedNotice.isEmpty {
                    SettingsSheetStatusBanner(
                        title: L10n.t("Email verified", languageCode: appLanguageRaw),
                        message: verifiedNotice,
                        tint: FGColor.accentGreen,
                        systemImage: "checkmark.circle.fill"
                    )
                } else if DeletedAccountSupportContact.isDeletedAccountBlockMessage(statusMessage)
                            || MapViewModel.isDeletedAccountLoginBlockMessage(statusMessage)
                            || Self.isGenuineAccountAccessRestrictionMessage(statusMessage) {
                    if DeletedAccountSupportContact.isDeletedAccountBlockMessage(statusMessage) {
                        DeletedAccountSupportStatusBanner(
                            title: L10n.t("Account access blocked", languageCode: appLanguageRaw),
                            message: statusMessage,
                            attemptedLoginEmail: attemptedLoginEmail
                        )
                    } else {
                        SettingsSheetStatusBanner(
                            title: L10n.t("Account access blocked", languageCode: appLanguageRaw),
                            message: statusMessage,
                            tint: FGColor.dangerRed,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                    }
                } else {
                    SettingsSheetStatusBanner(
                        title: L10n.t("Couldn’t continue", languageCode: appLanguageRaw),
                        message: statusMessage,
                        tint: FGColor.dangerRed,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                }
            }

            fanFeatureGrid

            if let onVenueOwnerTools {
                Button(action: onVenueOwnerTools) {
                    HStack(spacing: FGSpacing.sm) {
                        Image(systemName: "building.2.crop.circle")
                        Text("Grow Your Sports Crowd")
                            .font(FGTypography.cardTitle)
                    }
                    .foregroundStyle(FGColor.accentBlue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, FGSpacing.sm)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private static func isGenuineAccountAccessRestrictionMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("disabled by fangeo")
            || lower.contains("no longer active")
            || lower.contains("suspended")
            || lower.contains("banned")
            || lower.contains("access blocked")
    }

    private func performGuestBenefitNavigation(_ action: @escaping () -> Void) {
        let now = Date()
        if let last = lastGuestBenefitNavigationAt, now.timeIntervalSince(last) < 0.45 {
            return
        }
        lastGuestBenefitNavigationAt = now
        action()
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: FGSpacing.md) {
            HStack(alignment: .top, spacing: FGSpacing.md) {
                ZStack {
                    Circle()
                        .fill(FGColor.brandGradient)
                        .frame(width: 62, height: 62)
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 25, weight: .heavy))
                        .foregroundStyle(.white)
                    Circle()
                        .fill(FGColor.accentGreen)
                        .frame(width: 18, height: 18)
                        .overlay {
                            Circle().strokeBorder(FGColor.cardBackground(colorScheme), lineWidth: 2)
                        }
                        .offset(x: 25, y: 22)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 7) {
                    Text("Find Your Sports Community")
                        .font(.system(size: 27, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Discover watch parties, pickup games, local fans, and sports venues around you.")
                        .font(FGTypography.body)
                        .foregroundStyle(.white.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: FGSpacing.sm) {
                FGPrimaryButton(
                    title: L10n.t("Sign In", languageCode: languageCode),
                    systemImage: "person.fill"
                ) {
                    onSignIn()
                }

                FGSecondaryButton(
                    title: L10n.t("Create Account", languageCode: languageCode),
                    systemImage: "person.badge.plus"
                ) {
                    onCreateAccount()
                }
            }
        }
        .padding(FGSpacing.lg)
        .background {
            ZStack {
                Image("StadiumHeroBackground")
                    .resizable()
                    .scaledToFill()
                    .opacity(colorScheme == .dark ? 0.50 : 0.62)
                LinearGradient(
                    colors: [
                        FGColor.accentBlue.opacity(colorScheme == .dark ? 0.84 : 0.74),
                        FGColor.accentBlue.opacity(colorScheme == .dark ? 0.58 : 0.42),
                        FGColor.accentGreen.opacity(colorScheme == .dark ? 0.38 : 0.24)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: FGRadius.card, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.card, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.28), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.06), radius: 14, y: 7)
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var fanFeatureGrid: some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            Text(L10n.t("Explore FanGeo", languageCode: languageCode))
                .font(FGTypography.cardTitle.weight(.heavy))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: FGSpacing.sm) {
                discoveryFeatureCard(
                    systemImage: "sportscourt.fill",
                    title: L10n.t("Watch Live With Fans", languageCode: languageCode),
                    copy: L10n.t("Discover sports bars and venues showing today’s games.", languageCode: languageCode),
                    tint: FGColor.accentBlue,
                    accessibilityHint: L10n.t("profile_guest_benefit_venues_hint", languageCode: languageCode),
                    action: { performGuestBenefitNavigation(onWatchLiveWithFans) }
                )
                discoveryFeatureCard(
                    systemImage: "figure.run",
                    title: L10n.t("Join Pickup Games", languageCode: languageCode),
                    copy: L10n.t("Find local games or organize one nearby.", languageCode: languageCode),
                    tint: FGColor.accentGreen,
                    accessibilityHint: L10n.t("profile_guest_benefit_pickup_hint", languageCode: languageCode),
                    action: { performGuestBenefitNavigation(onJoinPickupGames) }
                )
                discoveryFeatureCard(
                    systemImage: "person.2.fill",
                    title: L10n.t("Meet Local Fans", languageCode: languageCode),
                    copy: L10n.t("See who’s going, chat, and build your sports community.", languageCode: languageCode),
                    tint: Color.purple,
                    accessibilityHint: L10n.t("profile_guest_benefit_meet_fans_hint", languageCode: languageCode),
                    action: { performGuestBenefitNavigation(onCreateAccount) }
                )
            }
        }
    }

    private func discoveryFeatureCard(
        systemImage: String,
        title: String,
        copy: String,
        tint: Color,
        accessibilityHint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: FGSpacing.md) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 48, height: 48, alignment: .center)
                    .background {
                        Circle()
                            .fill(tint.opacity(colorScheme == .dark ? 0.22 : 0.14))
                    }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(FGTypography.caption.weight(.heavy))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(copy)
                        .font(FGTypography.metadata)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: guestBenefitCardMinHeight, alignment: .leading)
            .padding(.horizontal, FGSpacing.md)
            .padding(.vertical, FGSpacing.sm + 2)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                tint.opacity(colorScheme == .dark ? 0.20 : 0.10),
                                FGColor.cardBackground(colorScheme)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme).opacity(0.62), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.12 : 0.035), radius: 7, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(title). \(copy)")
        .accessibilityHint(accessibilityHint)
    }
}
