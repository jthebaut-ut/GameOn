import SwiftUI

/// Searchable ISO 3166-1 alpha-2 country picker reused by Team manual location entry.
/// Canonical stored value is the ISO code from `BusinessLocationCountryPolicy` (not a new country model).
struct FanGeoISOCountryPickerSheet: View {
    @Binding var selectedCountryCode: String
    let languageCode: String
    var allowEmpty: Bool = false
    var onDismiss: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var query = ""

    private var choices: [(code: String, label: String)] {
        BusinessLocationCountryPolicy.supportedCountryChoices.filter { $0.code != "OTHER" }
    }

    private var filtered: [(code: String, label: String)] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return choices }
        return choices.filter {
            $0.label.localizedCaseInsensitiveContains(q)
                || $0.code.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if allowEmpty {
                    Button {
                        selectedCountryCode = ""
                        dismissSheet()
                    } label: {
                        countryRow(
                            flag: nil,
                            title: L10n.t("team_location_select_country", languageCode: languageCode),
                            subtitle: nil,
                            selected: selectedCountryCode.isEmpty
                        )
                    }
                    .buttonStyle(.plain)
                }

                ForEach(filtered, id: \.code) { option in
                    Button {
                        selectedCountryCode = BusinessLocationCountryPolicy.normalizedStoredCountryCode(option.code)
                        dismissSheet()
                    } label: {
                        countryRow(
                            flag: CountryFlagHelper.flagEmoji(forRegionCode: option.code),
                            title: option.label,
                            subtitle: option.code,
                            selected: BusinessLocationCountryPolicy.normalizedStoredCountryCode(selectedCountryCode) == option.code
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(option.label), \(option.code)")
                    .accessibilityAddTraits(
                        BusinessLocationCountryPolicy.normalizedStoredCountryCode(selectedCountryCode) == option.code
                            ? [.isSelected, .isButton]
                            : .isButton
                    )
                }
            }
            .listStyle(.plain)
            .searchable(
                text: $query,
                prompt: L10n.t("team_location_country_search", languageCode: languageCode)
            )
            .navigationTitle(L10n.t("team_location_country", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("done", languageCode: languageCode)) { dismissSheet() }
                }
            }
        }
    }

    @ViewBuilder
    private func countryRow(
        flag: String?,
        title: String,
        subtitle: String?,
        selected: Bool
    ) -> some View {
        HStack(spacing: 10) {
            if let flag, !flag.isEmpty {
                Text(flag)
                    .font(.title3)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(FGTypography.body.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.bold))
                    .foregroundStyle(FGColor.accentBlue)
            }
        }
    }

    private func dismissSheet() {
        onDismiss?()
        dismiss()
    }
}

/// Form row that opens `FanGeoISOCountryPickerSheet` and persists ISO alpha-2.
struct FanGeoISOCountryFieldRow: View {
    @Binding var countryCode: String
    let languageCode: String
    var onCountryChange: ((String) -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @State private var showPicker = false

    private var displayLabel: String {
        let code = BusinessLocationCountryPolicy.normalizedStoredCountryCode(countryCode)
        guard code.count == 2, code != "OTHER" else {
            return L10n.t("team_location_select_country", languageCode: languageCode)
        }
        let name = BusinessLocationCountryPolicy.countryName(for: code)
        return "\(CountryFlagHelper.flagEmoji(forRegionCode: code)) \(name)"
    }

    var body: some View {
        Button {
            showPicker = true
        } label: {
            HStack {
                Text(L10n.t("team_location_country", languageCode: languageCode))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Spacer()
                Text(displayLabel)
                    .foregroundStyle(
                        countryCode.isEmpty
                            ? FGColor.secondaryText(colorScheme)
                            : FGColor.primaryText(colorScheme)
                    )
                    .multilineTextAlignment(.trailing)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("team_location_country", languageCode: languageCode))
        .accessibilityValue(displayLabel)
        .sheet(isPresented: $showPicker) {
            FanGeoISOCountryPickerSheet(
                selectedCountryCode: Binding(
                    get: { countryCode },
                    set: { newValue in
                        let normalized = BusinessLocationCountryPolicy.normalizedStoredCountryCode(newValue)
                        countryCode = normalized
                        onCountryChange?(normalized)
                    }
                ),
                languageCode: languageCode
            )
        }
    }
}
