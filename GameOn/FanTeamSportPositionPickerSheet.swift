import SwiftUI

/// Shared sport position picker for Team preferred positions and event lineups.
/// Catalog source: ``FanTeamSportPositions`` only (no duplicate options).
struct FanTeamSportPositionPickerSheet: View {
    let sportToken: String
    let selectedCode: String?
    let onSelect: (String?) -> Void
    /// Optional Team preferred position shown for lineup event overrides only.
    var teamDefaultCode: String? = nil
    var navigationTitleKey: String = "fan_team_lineup_select_position"
    var clearTitleKey: String = "fan_team_lineup_no_position"
    var showsTeamDefaultActions: Bool = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var groups: [FanTeamSportPositions.Group] {
        FanTeamSportPositions.groups(forSportToken: sportToken)
    }

    private var resolvedTeamDefault: FanTeamSportPositions.Position? {
        FanTeamSportPositions.position(code: teamDefaultCode, sportToken: sportToken)
    }

    private var normalizedSelected: String? {
        let raw = selectedCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        return raw.isEmpty ? nil : raw
    }

    private var canResetToTeamDefault: Bool {
        guard showsTeamDefaultActions, let def = resolvedTeamDefault else { return false }
        return normalizedSelected != def.code
    }

    var body: some View {
        NavigationStack {
            List {
                if showsTeamDefaultActions, let def = resolvedTeamDefault {
                    Section {
                        Text(
                            String(
                                format: L10n.t(
                                    "fan_team_lineup_team_default_format",
                                    languageCode: languageCode
                                ),
                                locale: Locale(identifier: languageCode),
                                def.shortLabel()
                            )
                        )
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .accessibilityLabel(
                            String(
                                format: L10n.t(
                                    "fan_team_lineup_team_default_format",
                                    languageCode: languageCode
                                ),
                                locale: Locale(identifier: languageCode),
                                def.accessibilityLabel(languageCode: languageCode)
                            )
                        )

                        if canResetToTeamDefault {
                            Button {
                                onSelect(def.code)
                                dismiss()
                            } label: {
                                Label(
                                    L10n.t(
                                        "fan_team_lineup_reset_to_team_default",
                                        languageCode: languageCode
                                    ),
                                    systemImage: "arrow.counterclockwise"
                                )
                            }
                        }
                    } header: {
                        Text(L10n.t("fan_team_lineup_team_default", languageCode: languageCode))
                    }
                }

                Section {
                    Button {
                        onSelect(nil)
                        dismiss()
                    } label: {
                        HStack {
                            Text(L10n.t(clearTitleKey, languageCode: languageCode))
                            Spacer()
                            if normalizedSelected == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .accessibilityLabel(L10n.t(clearTitleKey, languageCode: languageCode))
                }

                ForEach(groups) { group in
                    Section {
                        ForEach(group.positions) { position in
                            Button {
                                onSelect(position.code)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(position.pickerLabel(languageCode: languageCode))
                                    Spacer()
                                    if normalizedSelected == position.code {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            .accessibilityLabel(position.accessibilityLabel(languageCode: languageCode))
                            .accessibilityValue(position.code)
                        }
                    } header: {
                        Text(L10n.t(group.localizedTitleKey, languageCode: languageCode))
                    }
                }
            }
            .navigationTitle(L10n.t(navigationTitleKey, languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel", languageCode: languageCode)) { dismiss() }
                }
            }
        }
    }
}
