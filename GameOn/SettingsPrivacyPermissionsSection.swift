import SwiftUI

struct ProfileSettingsPrivacyPermissionsSection: View {
    @Environment(\.profileSettingsPrivacyRefreshToken) private var refreshToken
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @State private var snapshot = FanGeoPrivacyPermissionsSnapshot.placeholder
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        Section {
            ProfileSettingsSectionCard {
                Button {
                    openFanGeoPrivacySettings()
                } label: {
                    privacyPermissionsSettingsRow(
                        title: L10n.t("privacy_permissions_location", languageCode: appLanguageRaw),
                        subtitle: L10n.t("privacy_permissions_location_subtitle", languageCode: appLanguageRaw),
                        systemImage: "location.fill",
                        tint: FGColor.accentBlue
                    ) {
                        privacyPermissionsStatusBadge(snapshot.locationStatusLabel)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint(localizedPrivacyPermissionsStatus(snapshot.locationSettingsActionTitle))

                privacyPermissionsRowDivider()

                Button {
                    openFanGeoPrivacySettings()
                } label: {
                    privacyPermissionsSettingsRow(
                        title: L10n.t("privacy_permissions_notifications", languageCode: appLanguageRaw),
                        subtitle: L10n.t("privacy_permissions_notifications_subtitle", languageCode: appLanguageRaw),
                        systemImage: "bell.badge.fill",
                        tint: FGColor.accentGreen
                    ) {
                        privacyPermissionsStatusBadge(snapshot.notificationStatusLabel)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint(L10n.t("privacy_permissions_open_iphone_settings", languageCode: appLanguageRaw))

                privacyPermissionsRowDivider()

                Button {
                    handlePersonalizedAdsPrivacyPermissionsAction()
                } label: {
                    privacyPermissionsSettingsRow(
                        title: L10n.t("privacy_permissions_personalized_ads", languageCode: appLanguageRaw),
                        subtitle: L10n.t("privacy_permissions_personalized_ads_subtitle", languageCode: appLanguageRaw),
                        systemImage: "hand.raised.fill",
                        tint: Color(red: 0.92, green: 0.58, blue: 0.18)
                    ) {
                        privacyPermissionsStatusBadge(
                            snapshot.personalizedAdsStatusLabel,
                            accent: .personalizedAds
                        )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint(
                    snapshot.personalizedAdsPrefersSystemSettings
                        ? L10n.t("privacy_permissions_manage_in_iphone_settings", languageCode: appLanguageRaw)
                        : (snapshot.personalizedAdsUsesUMPPrivacyOptions
                            ? L10n.t("privacy_permissions_manage_choices", languageCode: appLanguageRaw)
                            : L10n.t("privacy_permissions_manage_in_iphone_settings", languageCode: appLanguageRaw))
                )
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16))
            .listRowBackground(Color.clear)
        } header: {
            ProfileSettingsSectionHeader(title: L10n.t("privacy_permissions_section_title", languageCode: appLanguageRaw))
        }
        .task(id: refreshToken) {
            await refreshSnapshotIfNeeded()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            guard oldPhase != .active, newPhase == .active else { return }
            scheduleRefresh()
        }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
        }
    }

    private enum PrivacyPermissionsBadgeAccent {
        case standard
        case personalizedAds
    }

    /// Status badges are app-mapped English tokens from permission APIs; localize for display only.
    private func localizedPrivacyPermissionsStatus(_ englishToken: String) -> String {
        switch englishToken {
        case "While Using App":
            return L10n.t("privacy_permissions_status_while_using_app", languageCode: appLanguageRaw)
        case "Always Allowed":
            return L10n.t("privacy_permissions_status_always_allowed", languageCode: appLanguageRaw)
        case "On":
            return L10n.t("privacy_permissions_status_on", languageCode: appLanguageRaw)
        case "Off":
            return L10n.t("privacy_permissions_status_off", languageCode: appLanguageRaw)
        case "Not Asked":
            return L10n.t("privacy_permissions_status_not_asked", languageCode: appLanguageRaw)
        case "Restricted":
            return L10n.t("privacy_permissions_status_restricted", languageCode: appLanguageRaw)
        case "Limited Ads":
            return L10n.t("privacy_permissions_status_limited_ads", languageCode: appLanguageRaw)
        case "Provisional":
            return L10n.t("privacy_permissions_status_provisional", languageCode: appLanguageRaw)
        case "Scheduled Summary":
            return L10n.t("privacy_permissions_status_scheduled_summary", languageCode: appLanguageRaw)
        case "Unknown":
            return L10n.t("privacy_permissions_status_unknown", languageCode: appLanguageRaw)
        case "Open iPhone Settings":
            return L10n.t("privacy_permissions_open_iphone_settings", languageCode: appLanguageRaw)
        case "Manage in iPhone Settings":
            return L10n.t("privacy_permissions_manage_in_iphone_settings", languageCode: appLanguageRaw)
        case "Manage Choices":
            return L10n.t("privacy_permissions_manage_choices", languageCode: appLanguageRaw)
        default:
            return englishToken
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            await refreshSnapshotIfNeeded()
        }
    }

    @MainActor
    private func refreshSnapshotIfNeeded() async {
        guard !Task.isCancelled else { return }
        snapshot = await FanGeoPrivacyPermissionsStatusReader.currentSnapshot()
    }

    private func openFanGeoPrivacySettings() {
#if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
#endif
    }

    private func handlePersonalizedAdsPrivacyPermissionsAction() {
        if snapshot.personalizedAdsPrefersSystemSettings {
            openFanGeoPrivacySettings()
            return
        }
        if snapshot.personalizedAdsUsesUMPPrivacyOptions {
            Task {
                await GoogleMobileAdsBootstrap.presentPrivacyOptionsIfRequired()
            }
            return
        }
        openFanGeoPrivacySettings()
    }

    @ViewBuilder
    private func privacyPermissionsSettingsRow<Trailing: View>(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: FGSpacing.md + 2) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
            }
            .frame(
                width: SettingsPremiumChrome.privacyPermissionsIconSize,
                height: SettingsPremiumChrome.privacyPermissionsIconSize
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.system(size: 12.5, weight: .regular, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            trailing()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                .frame(width: 14, height: 14, alignment: .center)
        }
        .padding(.horizontal, FGSpacing.md + 2)
        .padding(.vertical, 14)
        .frame(minHeight: SettingsPremiumChrome.privacyPermissionsRowMinHeight, alignment: .center)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func privacyPermissionsRowDivider() -> some View {
        Divider()
            .overlay(SettingsPremiumChrome.divider(colorScheme))
            .opacity(0.42)
            .padding(.leading, 68)
            .padding(.trailing, FGSpacing.md)
            .padding(.vertical, 2)
    }

    private func privacyPermissionsStatusBadge(
        _ englishToken: String,
        accent: PrivacyPermissionsBadgeAccent = .standard
    ) -> some View {
        Text(localizedPrivacyPermissionsStatus(englishToken))
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(privacyPermissionsBadgeForeground(englishToken, accent: accent))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(privacyPermissionsBadgeBackground(englishToken, accent: accent))
            )
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .animation(nil, value: englishToken)
            .accessibilityLabel(localizedPrivacyPermissionsStatus(englishToken))
    }

    private func privacyPermissionsBadgeForeground(_ label: String, accent: PrivacyPermissionsBadgeAccent) -> Color {
        if accent == .personalizedAds, label == "On" {
            return Color(red: 0.92, green: 0.58, blue: 0.18)
        }
        switch label {
        case "On", "While Using App", "Always Allowed":
            return FGColor.accentGreen
        case "Off", "Limited Ads", "Restricted":
            return FGColor.dangerRed.opacity(0.88)
        default:
            return FGColor.mutedText(colorScheme)
        }
    }

    private func privacyPermissionsBadgeBackground(_ label: String, accent: PrivacyPermissionsBadgeAccent) -> Color {
        privacyPermissionsBadgeForeground(label, accent: accent).opacity(colorScheme == .dark ? 0.18 : 0.12)
    }
}
