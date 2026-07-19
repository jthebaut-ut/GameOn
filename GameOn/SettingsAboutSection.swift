import SwiftUI

struct ProfileSettingsAboutSection: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    var body: some View {
        Section {
            ProfileSettingsSectionCard {
                VStack(spacing: 14) {
                    Image("FanGeoPremiumLoadingLogo")
                        .resizable()
                        .interpolation(.medium)
                        .antialiased(true)
                        .scaledToFit()
                        .frame(width: 76, height: 76)
                        .accessibilityLabel("FanGeo")

                    VStack(spacing: 4) {
                        Text("Version \(SettingsAboutFanGeoMetadata.version)")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                        Text("Build \(SettingsAboutFanGeoMetadata.build)")
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                    }

                    VStack(spacing: 4) {
                        Text("Support")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                            .textCase(.uppercase)
                            .tracking(0.6)
                        Text(SettingsAboutFanGeoMetadata.supportEmail)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                    }

                    Button {
                        openFanGeoWebsite()
                    } label: {
                        VStack(spacing: 4) {
                            Text("Website")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                                .textCase(.uppercase)
                                .tracking(0.6)
                            Text("www.fangeosports.com")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(FGColor.accentBlue)
                        }
                    }
                    .buttonStyle(.plain)

                    Text(
                        L10n.t(
                            "about_fangeo_independence_disclosure",
                            languageCode: L10n.normalizedLanguageCode(appLanguageRaw)
                        )
                    )
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)

                    Text("© 2026 FanGeo Sports")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                        .padding(.top, 4)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, FGSpacing.lg)
                .padding(.vertical, 28)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 14, trailing: 16))
            .listRowBackground(Color.clear)
        } header: {
            ProfileSettingsSectionHeader(title: "About FanGeo")
        }
    }

    private func openFanGeoWebsite() {
#if canImport(UIKit)
        guard let url = URL(string: "https://www.fangeosports.com/") else { return }
        UIApplication.shared.open(url)
#endif
    }
}
