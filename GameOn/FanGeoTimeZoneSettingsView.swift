import SwiftUI

/// Primary time zone settings hub — automatic, recents, and search entry only.
struct FanGeoTimeZoneSettingsView: View {
    @Binding var selection: FanGeoTimeZonePreference
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    var automaticPresentationToken: UUID = UUID()

    private var recentPresentations: [FanGeoTimeZoneDisplayPresentation] {
        FanGeoTimeZoneStore.recentIdentifiers()
            .prefix(FanGeoTimeZoneStore.maxRecentCount)
            .map { FanGeoTimeZoneDisplayPresentation.make(for: $0, locale: .current) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FGSpacing.lg) {
                FanGeoTimeZoneAutomaticCard(
                    selection: $selection,
                    colorScheme: colorScheme
                )

                if !recentPresentations.isEmpty {
                    TimeZoneSettingsSectionHeader(title: "Recently Used", colorScheme: colorScheme)
                    TimeZoneSettingsPremiumCard(colorScheme: colorScheme) {
                        ForEach(Array(recentPresentations.enumerated()), id: \.element.identifier) { index, presentation in
                            if index > 0 {
                                timeZoneSettingsDivider
                            }
                            FanGeoTimeZoneCompactPresentationRow(
                                presentation: presentation,
                                showsCountry: false,
                                isSelected: isFixedSelection(presentation.identifier),
                                colorScheme: colorScheme
                            ) {
                                selectFixed(presentation.identifier)
                            }
                        }
                    }
                }

                NavigationLink {
                    FanGeoTimeZoneSelectionView(
                        selection: $selection,
                        automaticPresentationToken: automaticPresentationToken
                    )
                } label: {
                    TimeZoneSettingsSearchCard(colorScheme: colorScheme)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, FGSpacing.lg)
            .padding(.top, FGSpacing.lg)
            .padding(.bottom, FGSpacing.xl)
        }
        .background(SettingsPremiumChrome.screenBackground(colorScheme).ignoresSafeArea())
        .navigationTitle(L10n.t("time_zone", languageCode: appLanguageRaw))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            TimeZoneDebug.mainScreen(automaticSelected: selection.isAutomatic)
            TimeZoneDebug.recentCount(recentPresentations.count)
        }
        .onChange(of: selection) { _, newValue in
            TimeZoneDebug.mainScreen(automaticSelected: newValue.isAutomatic)
        }
    }

    private var timeZoneSettingsDivider: some View {
        Divider()
            .overlay(SettingsPremiumChrome.divider(colorScheme))
            .opacity(0.42)
            .padding(.leading, FGSpacing.md)
            .padding(.trailing, FGSpacing.md)
    }

    private func isFixedSelection(_ identifier: String) -> Bool {
        !selection.isAutomatic && selection.storageValue == identifier
    }

    private func selectFixed(_ identifier: String) {
        selection = .fixed(identifier)
        let zone = TimeZone(identifier: identifier) ?? TimeZone.autoupdatingCurrent
        TimeZoneDebug.selectedIdentifier(identifier)
        TimeZoneDebug.displayedOffset(utcOffsetLabel(for: zone, at: Date()))
    }
}

struct FanGeoTimeZoneAutomaticCard: View {
    @Binding var selection: FanGeoTimeZonePreference
    let colorScheme: ColorScheme

    var body: some View {
        let autoZone = TimeZone.autoupdatingCurrent
        let presentation = FanGeoTimeZoneDisplayPresentation.make(
            for: autoZone.identifier,
            locale: .current
        )

        Button {
            selection = .automatic
            TimeZoneDebug.automaticZone(autoZone.identifier)
            TimeZoneDebug.displayedOffset(utcOffsetLabel(for: autoZone, at: Date()))
            TimeZoneDebug.mainScreen(automaticSelected: true)
        } label: {
            HStack(alignment: .top, spacing: FGSpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                    Image(systemName: "location.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(FGColor.accentGreen)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Automatic")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                        Text("Recommended")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.accentGreen)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.12))
                            .clipShape(Capsule(style: .continuous))
                    }

                    Text("Using your device time zone")
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(presentation.city)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                        Text(presentation.timeZoneName)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                        Text(presentation.utcOffset)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                            .monospacedDigit()
                    }
                    .padding(.top, 2)

                    Text("Always updates when you travel")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                        .padding(.top, 2)
                }

                Spacer(minLength: 0)

                if selection.isAutomatic {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(FGColor.accentGreen)
                        .accessibilityHidden(true)
                }
            }
            .padding(FGSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { timeZoneSettingsCardBackground }
            .overlay {
                RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                    .strokeBorder(SettingsPremiumChrome.cardStroke(colorScheme), lineWidth: 0.75)
            }
            .contentShape(RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Automatic time zone")
        .accessibilityValue("\(presentation.city), \(presentation.timeZoneName), \(presentation.utcOffset)")
        .accessibilityHint("Uses your device time zone and updates when you travel")
        .accessibilityAddTraits(selection.isAutomatic ? .isSelected : [])
    }

    private var timeZoneSettingsCardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                .fill(SettingsPremiumChrome.cardFill(colorScheme))
            RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            SettingsPremiumChrome.cardHighlight(colorScheme),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.12 : 0.05),
            radius: SettingsPremiumChrome.scrollCardShadowRadius,
            y: SettingsPremiumChrome.scrollCardShadowYOffset
        )
    }
}

struct FanGeoTimeZoneCompactPresentationRow: View {
    let presentation: FanGeoTimeZoneDisplayPresentation
    var showsCountry: Bool
    let isSelected: Bool
    let colorScheme: ColorScheme
    let action: () -> Void

    private var tertiaryLine: String {
        if showsCountry {
            return "\(presentation.countryLabel) · \(presentation.utcOffset)"
        }
        return presentation.utcOffset
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: FGSpacing.md) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.city)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                        .multilineTextAlignment(.leading)
                    Text(presentation.timeZoneName)
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                        .multilineTextAlignment(.leading)
                    Text(tertiaryLine)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                        .monospacedDigit()
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(FGColor.accentGreen)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, FGSpacing.md)
            .padding(.vertical, 12)
            .frame(minHeight: SettingsPremiumChrome.rowMinHeight, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(presentation.city)
        .accessibilityValue("\(presentation.timeZoneName), \(tertiaryLine)")
        .accessibilityHint(presentation.identifier)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct TimeZoneSettingsSectionHeader: View {
    let title: String
    let colorScheme: ColorScheme

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
            .padding(.horizontal, FGSpacing.xs)
    }
}

struct TimeZoneSettingsPremiumCard<Content: View>: View {
    let colorScheme: ColorScheme
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                    .fill(SettingsPremiumChrome.cardFill(colorScheme))
                RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                SettingsPremiumChrome.cardHighlight(colorScheme),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                .strokeBorder(SettingsPremiumChrome.cardStroke(colorScheme), lineWidth: 0.75)
        }
        .compositingGroup()
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.12 : 0.05),
            radius: SettingsPremiumChrome.scrollCardShadowRadius,
            y: SettingsPremiumChrome.scrollCardShadowYOffset
        )
    }
}

struct TimeZoneSettingsSearchCard: View {
    let colorScheme: ColorScheme

    var body: some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(FGColor.accentGreen)
            }
            .frame(width: SettingsPremiumChrome.rowIconSize, height: SettingsPremiumChrome.rowIconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text("Search all time zones")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                Text("Find any city, country, or region")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                    .fill(SettingsPremiumChrome.cardFill(colorScheme))
                RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                SettingsPremiumChrome.cardHighlight(colorScheme),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                .strokeBorder(SettingsPremiumChrome.cardStroke(colorScheme), lineWidth: 0.75)
        }
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.12 : 0.05),
            radius: SettingsPremiumChrome.scrollCardShadowRadius,
            y: SettingsPremiumChrome.scrollCardShadowYOffset
        )
        .contentShape(RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Search all time zones")
        .accessibilityHint("Find a city, country, region, or time zone")
    }
}
