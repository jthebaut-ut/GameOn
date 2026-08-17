import SwiftUI

/// Compact info control for Settings privacy rows — does not toggle or navigate the parent row.
struct SettingsPrivacyInfoButton: View {
    let accessibilityLabel: String
    let accessibilityHint: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: "info.circle")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }
}

struct ProfileDiscoveryHelpSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var languageCode: String { L10n.normalizedLanguageCode(appLanguageRaw) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.t("profile_discovery_help_intro", languageCode: languageCode))
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(L10n.t("profile_discovery_help_intro", languageCode: languageCode))

                    helpSection(
                        title: L10n.t("profile_discovery_help_when_on", languageCode: languageCode),
                        rows: [
                            L10n.t("profile_discovery_help_on_search", languageCode: languageCode),
                            L10n.t("profile_discovery_help_on_suggested", languageCode: languageCode),
                            L10n.t("profile_discovery_help_on_nearby", languageCode: languageCode),
                            L10n.t("profile_discovery_help_on_signals", languageCode: languageCode)
                        ]
                    )

                    helpSection(
                        title: L10n.t("profile_discovery_help_when_off", languageCode: languageCode),
                        rows: [
                            L10n.t("profile_discovery_help_off_search", languageCode: languageCode),
                            L10n.t("profile_discovery_help_off_suggested", languageCode: languageCode),
                            L10n.t("profile_discovery_help_off_nearby", languageCode: languageCode),
                            L10n.t("profile_discovery_help_off_friends", languageCode: languageCode),
                            L10n.t("profile_discovery_help_off_unchanged", languageCode: languageCode)
                        ]
                    )

                    helpSection(
                        title: L10n.t("profile_discovery_help_privacy_section", languageCode: languageCode),
                        rows: [
                            L10n.t("profile_discovery_help_on_no_exact_location", languageCode: languageCode)
                        ]
                    )
                }
                .padding(.horizontal, FGSpacing.lg)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(FGAdaptiveSurface.sheetRoot.ignoresSafeArea())
            .navigationTitle(L10n.t("profile_discovery_help_title", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Close", languageCode: languageCode)) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(FGAdaptiveSurface.sheetRoot)
    }

    private func helpSection(title: String, rows: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .textCase(.uppercase)
                .tracking(0.4)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.55 : 0.35))
                            .frame(width: 6, height: 6)
                            .padding(.top, 6)
                            .accessibilityHidden(true)
                        Text(row)
                            .font(.system(size: 15, weight: .regular, design: .rounded))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                    .fill(SettingsPremiumChrome.cardFill(colorScheme))
            }
            .overlay {
                RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                    .strokeBorder(SettingsPremiumChrome.cardStroke(colorScheme), lineWidth: 0.75)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

struct FanActivityHelpSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var languageCode: String { L10n.normalizedLanguageCode(appLanguageRaw) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.t("fan_activity_help_intro", languageCode: languageCode))
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)

                    helpBulletSection(
                        title: L10n.t("fan_activity_help_examples", languageCode: languageCode),
                        rows: [
                            L10n.t("fan_activity_help_example_venue", languageCode: languageCode),
                            L10n.t("fan_activity_help_example_game", languageCode: languageCode),
                            L10n.t("fan_activity_help_example_going", languageCode: languageCode)
                        ],
                        bulletTint: FGColor.accentGreen
                    )

                    helpBulletSection(
                        title: L10n.t("fan_activity_help_not_shared", languageCode: languageCode),
                        rows: [
                            L10n.t("fan_activity_help_not_gps", languageCode: languageCode),
                            L10n.t("fan_activity_help_not_address", languageCode: languageCode),
                            L10n.t("fan_activity_help_not_contact", languageCode: languageCode),
                            L10n.t("fan_activity_help_not_messages", languageCode: languageCode)
                        ],
                        bulletTint: FGColor.accentGreen
                    )
                }
                .padding(.horizontal, FGSpacing.lg)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(FGAdaptiveSurface.sheetRoot.ignoresSafeArea())
            .navigationTitle(L10n.t("fan_activity_help_title", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Close", languageCode: languageCode)) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(FGAdaptiveSurface.sheetRoot)
    }

    private func helpBulletSection(title: String, rows: [String], bulletTint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .textCase(.uppercase)
                .tracking(0.4)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(bulletTint.opacity(colorScheme == .dark ? 0.55 : 0.35))
                            .frame(width: 6, height: 6)
                            .padding(.top, 6)
                            .accessibilityHidden(true)
                        Text(row)
                            .font(.system(size: 15, weight: .regular, design: .rounded))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                    .fill(SettingsPremiumChrome.cardFill(colorScheme))
            }
            .overlay {
                RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                    .strokeBorder(SettingsPremiumChrome.cardStroke(colorScheme), lineWidth: 0.75)
            }
        }
    }
}
