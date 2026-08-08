import SwiftUI
import UIKit

extension SettingsScreen {

    func profileSettingsHelpSafetySection() -> some View {
        Section {
            settingsSectionCard {
                ProfileSettingsRouteButton(route: .helpAndTutorial, source: "helpAndTutorial") {
                    settingsRow(
                        title: L10n.t("settings_help_and_tutorial", languageCode: appLanguageRaw),
                        subtitle: L10n.t("settings_help_and_tutorial_subtitle", languageCode: appLanguageRaw),
                        systemImage: "questionmark.circle.fill",
                        showsChevron: true
                    )
                }

                settingsRowDivider()

                ProfileSettingsRouteButton(route: .support, source: "support") {
                    settingsRow(
                        title: L10n.t("support", languageCode: appLanguageRaw),
                        subtitle: L10n.t("settings_support_subtitle", languageCode: appLanguageRaw),
                        systemImage: "envelope.open.fill",
                        showsChevron: true
                    )
                }

                settingsRowDivider()

                Button {
                    openFanGeoInstagram()
                } label: {
                    settingsRow(
                        title: L10n.t("settings_follow_fangeo_instagram", languageCode: appLanguageRaw),
                        subtitle: "@fangeosports",
                        assetImage: "FanGeoInstagramLogo",
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("settings_follow_fangeo_instagram", languageCode: appLanguageRaw))
                .accessibilityValue("@fangeosports")
                .accessibilityHint(L10n.t("settings_follow_fangeo_instagram_hint", languageCode: appLanguageRaw))

                settingsRowDivider()

                Button {
                    openFanGeoFacebook()
                } label: {
                    settingsRow(
                        title: L10n.t("settings_follow_fangeo_facebook", languageCode: appLanguageRaw),
                        subtitle: "FanGeo Sports",
                        assetImage: "FanGeoFacebookLogo",
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("settings_follow_fangeo_facebook", languageCode: appLanguageRaw))
                .accessibilityValue("FanGeo Sports")
                .accessibilityHint(L10n.t("settings_follow_fangeo_facebook_hint", languageCode: appLanguageRaw))

                settingsRowDivider()

                Button {
                    openFanGeoWebsite()
                } label: {
                    settingsRow(
                        title: L10n.t("settings_visit_fangeo_website", languageCode: appLanguageRaw),
                        subtitle: "www.fangeosports.com",
                        systemImage: "globe",
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("settings_visit_fangeo_website", languageCode: appLanguageRaw))
                .accessibilityValue("www.fangeosports.com")
                .accessibilityHint(L10n.t("settings_visit_fangeo_website_hint", languageCode: appLanguageRaw))
            }
            .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16))
            .listRowBackground(Color.clear)
        } header: {
            settingsSectionHeader(L10n.t("settings_help_and_safety", languageCode: appLanguageRaw))
        }
    }


    func openFanGeoInstagram() {
        guard let url = URL(string: "https://www.instagram.com/fangeosports") else {
            return
        }
        UIApplication.shared.open(url)
    }


    func openFanGeoFacebook() {
        guard let url = URL(string: "https://www.facebook.com/profile.php?id=61590196064767") else {
            return
        }
        UIApplication.shared.open(url)
    }


    func openFanGeoWebsite() {
        guard let url = URL(string: "https://www.fangeosports.com/") else {
            return
        }
        UIApplication.shared.open(url)
    }
}
