import Foundation
import SwiftUI

/// Product constants and copy helpers for Suggested Fans.
enum SuggestedFansProduct {
    /// Authoritative nearby radius for location-backed Suggested Fans ranking.
    /// Always pass this explicitly to `get_profile_friend_suggestions` (server default is also 45).
    nonisolated static let nearbyRadiusMiles: Double = 45

    /// Locale-aware display for ``nearbyRadiusMiles`` (miles or kilometers).
    static func localizedNearbyRadiusLabel(languageCode: String) -> String {
        let code = L10n.normalizedLanguageCode(languageCode)
        // FanGeo's English product language uses U.S. customary miles in user-facing help copy.
        let usesMetric: Bool
        if code == "en" {
            usesMetric = false
        } else if #available(iOS 16.0, *) {
            usesMetric = Locale(identifier: code).measurementSystem == .metric
        } else {
            usesMetric = Locale(identifier: code).usesMetricSystem
        }

        let miles = Measurement(value: nearbyRadiusMiles, unit: UnitLength.miles)
        let display = usesMetric ? miles.converted(to: .kilometers) : miles
        let locale = Locale(identifier: code)

        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitStyle = .medium
        formatter.unitOptions = .providedUnit
        formatter.numberFormatter.maximumFractionDigits = 0
        formatter.numberFormatter.minimumFractionDigits = 0
        return formatter.string(from: display)
    }
}

/// Compact Apple-style explanation of Suggested Fans matching and privacy.
struct SuggestedFansHowItWorksSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var languageCode: String { L10n.normalizedLanguageCode(appLanguageRaw) }

    private var nearbyRadiusLabel: String {
        SuggestedFansProduct.localizedNearbyRadiusLabel(languageCode: languageCode)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    introBlock

                    section(
                        title: L10n.t("suggested_fans_info_section_matches", languageCode: languageCode),
                        rows: [
                            ("person.2.fill", L10n.t("suggested_fans_info_signal_mutual", languageCode: languageCode)),
                            ("figure.run", L10n.t("suggested_fans_info_signal_activity", languageCode: languageCode)),
                            ("location.fill", L10n.t("suggested_fans_info_signal_nearby", languageCode: languageCode)),
                            ("sportscourt.fill", L10n.t("suggested_fans_info_signal_teams", languageCode: languageCode)),
                            ("building.2.fill", L10n.t("suggested_fans_info_signal_venues", languageCode: languageCode)),
                            ("bolt.fill", L10n.t("suggested_fans_info_signal_recent", languageCode: languageCode)),
                            ("star.fill", L10n.t("suggested_fans_info_signal_reputation", languageCode: languageCode))
                        ]
                    )

                    nearbySection

                    section(
                        title: L10n.t("suggested_fans_info_section_exclusions", languageCode: languageCode),
                        bodyText: L10n.t("suggested_fans_info_exclusions_body", languageCode: languageCode)
                    )

                    section(
                        title: L10n.t("suggested_fans_info_section_privacy", languageCode: languageCode),
                        bodyText: L10n.t("suggested_fans_info_privacy_body", languageCode: languageCode)
                    )
                }
                .padding(.horizontal, FGSpacing.lg)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(FGAdaptiveSurface.sheetRoot.ignoresSafeArea())
            .navigationTitle(L10n.t("suggested_fans_how_it_works", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("suggested_fans_info_done", languageCode: languageCode)) { dismiss() }
                        .accessibilityLabel(L10n.t("suggested_fans_info_done", languageCode: languageCode))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(FGAdaptiveSurface.sheetRoot)
        .onAppear {
            FanGeoAnalyticsService.record(
                eventName: "suggested_fans_info_opened",
                metadata: [:],
                updateLastActive: false
            )
        }
    }

    private var introBlock: some View {
        Text(L10n.t("suggested_fans_info_intro", languageCode: languageCode))
            .font(.system(size: 15, weight: .regular, design: .rounded))
            .foregroundStyle(FGColor.secondaryText(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var nearbySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("suggested_fans_info_section_nearby", languageCode: languageCode))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .textCase(.uppercase)
                .tracking(0.4)

            VStack(alignment: .leading, spacing: 8) {
                infoRow(
                    symbol: "location.fill",
                    text: String(
                        format: L10n.t("suggested_fans_info_nearby_when_available_format", languageCode: languageCode),
                        locale: Locale(identifier: languageCode),
                        nearbyRadiusLabel
                    )
                )
                infoRow(
                    symbol: "globe",
                    text: L10n.t("suggested_fans_info_nearby_without_location", languageCode: languageCode)
                )
                infoRow(
                    symbol: "eye.slash.fill",
                    text: L10n.t("suggested_fans_info_nearby_exact_hidden", languageCode: languageCode)
                )
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(sectionCardBackground)
        }
        .accessibilityElement(children: .contain)
    }

    private func section(title: String, bodyText: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .textCase(.uppercase)
                .tracking(0.4)

            Text(bodyText)
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(sectionCardBackground)
        }
        .accessibilityElement(children: .combine)
    }

    private func section(title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .textCase(.uppercase)
                .tracking(0.4)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    infoRow(symbol: row.0, text: row.1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(sectionCardBackground)
        }
        .accessibilityElement(children: .contain)
    }

    private func infoRow(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FGColor.accentBlue)
                .frame(width: 18, alignment: .center)
                .padding(.top, 1)
                .accessibilityHidden(true)

            Text(text)
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var sectionCardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(SettingsPremiumChrome.cardFill(colorScheme))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(SettingsPremiumChrome.cardStroke(colorScheme), lineWidth: 0.75)
            }
    }
}
