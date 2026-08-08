import SwiftUI

// MARK: - Settings section

extension SettingsScreen {

    func profileSettingsTrustSafetySection() -> some View {
        Section {
            settingsSectionCard {
                ForEach(Array(SettingsTrustSafetyTopic.allCases.enumerated()), id: \.element.id) { index, topic in
                    if index > 0 {
                        settingsRowDivider()
                    }

                    ProfileSettingsRouteButton(route: topic.route, source: topic.id) {
                        settingsRow(
                            title: topic.title(languageCode: appLanguageRaw),
                            subtitle: topic.subtitle(languageCode: appLanguageRaw),
                            systemImage: topic.systemImage,
                            tint: topic.accent.color,
                            showsChevron: true
                        )
                    }
                    .accessibilityHint(L10n.t("settings_trust_open_topic_hint", languageCode: appLanguageRaw))
                }
            }
            .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16))
            .listRowBackground(Color.clear)
        } header: {
            settingsSectionHeader(L10n.t("settings_trust_and_safety", languageCode: appLanguageRaw))
        }
    }
}

// MARK: - Hub (legacy `.trustSafety` route + future expansion)

struct SettingsTrustSafetyHubView: View {
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var navigator: ProfileSettingsNavigator

    var body: some View {
        let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
        ScrollView {
            VStack(alignment: .leading, spacing: FGSpacing.lg) {
                SettingsTrustSafetyHeroHeader(
                    systemImage: "shield.lefthalf.filled",
                    accent: .blue,
                    title: L10n.t("settings_trust_and_safety", languageCode: languageCode),
                    subtitle: L10n.t("settings_trust_hub_subtitle", languageCode: languageCode)
                )

                VStack(spacing: 0) {
                    ForEach(Array(SettingsTrustSafetyTopic.allCases.enumerated()), id: \.element.id) { index, topic in
                        if index > 0 {
                            Divider()
                                .padding(.leading, 62)
                        }
                        Button {
                            navigator.append(topic.route, source: "trustSafetyHub:\(topic.id)")
                        } label: {
                            HStack(spacing: FGSpacing.md) {
                                SettingsTrustSafetySymbolBadge(
                                    systemImage: topic.systemImage,
                                    accent: topic.accent
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(topic.title(languageCode: languageCode))
                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                        .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                                        .multilineTextAlignment(.leading)
                                    Text(topic.subtitle(languageCode: languageCode))
                                        .font(.system(size: 12, weight: .regular, design: .rounded))
                                        .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                            }
                            .padding(.horizontal, FGSpacing.md)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(L10n.t("settings_trust_open_topic_hint", languageCode: languageCode))
                    }
                }
                .background {
                    RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                        .fill(SettingsPremiumChrome.cardFill(colorScheme))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                        .strokeBorder(SettingsPremiumChrome.cardStroke(colorScheme), lineWidth: 0.75)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.visible)
        .background(SettingsPremiumChrome.screenBackground(colorScheme).ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
        }
        .navigationTitle(L10n.t("settings_trust_and_safety", languageCode: languageCode))
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - Topic detail

struct SettingsTrustSafetyInfoView: View {
    let topic: SettingsTrustSafetyTopic

    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
        let cards = topic.cards(languageCode: languageCode)

        ScrollView {
            VStack(alignment: .leading, spacing: FGSpacing.lg) {
                SettingsTrustSafetyHeroHeader(
                    systemImage: topic.systemImage,
                    accent: topic.accent,
                    title: topic.title(languageCode: languageCode),
                    subtitle: topic.subtitle(languageCode: languageCode)
                )

                // Future-ready: append additional cards / feature rows without changing layout.
                LazyVStack(alignment: .leading, spacing: FGSpacing.md) {
                    ForEach(cards) { card in
                        SettingsTrustSafetyInfoCard(card: card, accent: topic.accent)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.visible)
        .background(SettingsPremiumChrome.screenBackground(colorScheme).ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
        }
        .navigationTitle(topic.title(languageCode: languageCode))
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - Shared chrome

private struct SettingsTrustSafetyHeroHeader: View {
    let systemImage: String
    let accent: SettingsTrustSafetyAccent
    let title: String
    let subtitle: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: FGSpacing.md) {
            SettingsTrustSafetySymbolBadge(systemImage: systemImage, accent: accent, size: 56)

            Text(title)
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text(subtitle)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsTrustSafetySymbolBadge: View {
    let systemImage: String
    let accent: SettingsTrustSafetyAccent
    var size: CGFloat = 40

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(accent.color.opacity(colorScheme == .dark ? 0.22 : 0.14))
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(accent.color)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
        }
        .frame(width: size, height: size)
    }
}

private struct SettingsTrustSafetyInfoCard: View {
    let card: SettingsTrustSafetyCardModel
    let accent: SettingsTrustSafetyAccent

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(accent.color)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(card.heading)
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(card.body)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                .fill(SettingsPremiumChrome.cardFill(colorScheme))
        }
        .overlay {
            RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            accent.color.opacity(colorScheme == .dark ? 0.35 : 0.22),
                            SettingsPremiumChrome.cardStroke(colorScheme)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
        }
        .accessibilityElement(children: .combine)
    }
}
