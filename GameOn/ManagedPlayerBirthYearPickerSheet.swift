import SwiftUI

/// Native wheel sheet for optional managed-player `birth_year`.
///
/// Cancel discards the draft. Done commits to the Add/Edit form only — it does
/// not persist the managed player row.
struct ManagedPlayerBirthYearPickerSheet: View {
    let languageCode: String
    let initialYear: Int?
    let onDone: (Int?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var draftYear: Int?

    private var years: [Int] {
        FanManagedPlayerValidation.pickerYears(including: initialYear)
    }

    private var title: String {
        L10n.t("managed_players_birth_year", languageCode: languageCode)
    }

    private var notSetLabel: String {
        L10n.t("fan_teams_not_set", languageCode: languageCode)
    }

    private var draftAccessibilityValue: String {
        draftYear.map(String.init) ?? notSetLabel
    }

    var body: some View {
        NavigationStack {
            birthYearWheel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(FGAdaptiveSurface.sheetRoot.ignoresSafeArea())
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .onAppear {
            draftYear = initialYear
        }
    }

    private var birthYearWheel: some View {
        Picker(selection: $draftYear) {
            Text(notSetLabel).tag(Optional<Int>.none)
            ForEach(years, id: \.self) { year in
                Text(verbatim: String(year)).tag(Optional(year))
            }
        } label: {
            Text(title)
        }
        .pickerStyle(.wheel)
        .labelsHidden()
        .accessibilityLabel(title)
        .accessibilityValue(draftAccessibilityValue)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(L10n.t("Cancel", languageCode: languageCode)) {
                dismiss()
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(L10n.t("Done", languageCode: languageCode)) {
                onDone(draftYear)
                dismiss()
            }
            .fontWeight(.semibold)
        }
    }
}

/// Form row that presents ``ManagedPlayerBirthYearPickerSheet``.
struct ManagedPlayerBirthYearFormRow: View {
    let languageCode: String
    @Binding var birthYear: Int?
    @State private var showingPicker = false

    @Environment(\.colorScheme) private var colorScheme

    private var title: String {
        L10n.t("managed_players_birth_year", languageCode: languageCode)
    }

    private var valueLabel: String {
        birthYear.map(String.init) ?? L10n.t("fan_teams_not_set", languageCode: languageCode)
    }

    var body: some View {
        Button {
            showingPicker = true
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Spacer(minLength: 8)
                Text(valueLabel)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(valueLabel)
        .accessibilityAddTraits(.isButton)
        .sheet(isPresented: $showingPicker) {
            ManagedPlayerBirthYearPickerSheet(
                languageCode: languageCode,
                initialYear: birthYear,
                onDone: { birthYear = $0 }
            )
        }
    }
}
