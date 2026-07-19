import SwiftUI

extension SettingsScreen {

    func profileSettingsLegalSection() -> some View {
        Section {
            settingsSectionCard {
                ProfileSettingsRouteButton(route: .privacyPolicy, source: "privacyPolicy") {
                    settingsRow(
                        title: SettingsLegalDocumentKind.privacyPolicy.title,
                        subtitle: SettingsLegalDocumentKind.privacyPolicy.rowSubtitle,
                        systemImage: SettingsLegalDocumentKind.privacyPolicy.systemImage,
                        showsChevron: true
                    )
                }

                settingsRowDivider()

                ProfileSettingsRouteButton(route: .termsOfService, source: "termsOfService") {
                    settingsRow(
                        title: SettingsLegalDocumentKind.termsOfService.title,
                        subtitle: SettingsLegalDocumentKind.termsOfService.rowSubtitle,
                        systemImage: SettingsLegalDocumentKind.termsOfService.systemImage,
                        showsChevron: true
                    )
                }
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
            .listRowBackground(Color.clear)
        } header: {
            settingsSectionHeader(L10n.t("settings_legal", languageCode: appLanguageRaw))
        }
    }
}
