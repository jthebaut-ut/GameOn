import SwiftUI

struct FanGeoAppearanceSelectionView: View {
    @Binding var selectionRaw: String
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @Environment(\.colorScheme) private var colorScheme

    private var selection: FanGeoAppearancePreference {
        FanGeoAppearancePreference(rawValue: selectionRaw) ?? .system
    }

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    var body: some View {
        List {
            Section {
                ForEach(FanGeoAppearancePreference.allCases) { preference in
                    Button {
                        selectionRaw = preference.rawValue
                    } label: {
                        HStack(spacing: 12) {
                            Text(preference.displayName(languageCode: languageCode))
                                .font(FGTypography.body.weight(.semibold))
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 0)

                            if preference == selection {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(FGColor.accentGreen)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(FGAdaptiveSurface.cardElevated(colorScheme))
                }
            } footer: {
                Text(
                    L10n.t(
                        "System Default follows your iPhone appearance. Light and Dark override FanGeo locally on this device.",
                        languageCode: languageCode
                    )
                )
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .scrollContentBackground(.hidden)
        .background(FGAdaptiveSurface.sheetRoot(colorScheme).ignoresSafeArea())
        .tint(FGColor.accentGreen)
    }
}
