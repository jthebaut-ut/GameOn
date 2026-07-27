import SwiftUI

struct FanGeoAppearanceSelectionView: View {
    @Binding var selectionRaw: String
    @Environment(\.colorScheme) private var colorScheme

    private var selection: FanGeoAppearancePreference {
        FanGeoAppearancePreference(rawValue: selectionRaw) ?? .system
    }

    var body: some View {
        List {
            Section {
                ForEach(FanGeoAppearancePreference.allCases) { preference in
                    Button {
                        selectionRaw = preference.rawValue
                    } label: {
                        HStack(spacing: 12) {
                            Text(preference.displayName)
                                .font(FGTypography.body.weight(.semibold))
                                .foregroundStyle(FGColor.primaryText(colorScheme))

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
                Text("System Default follows your iPhone appearance. Light and Dark override FanGeo locally on this device.")
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
        }
        .scrollContentBackground(.hidden)
        .background(FGAdaptiveSurface.sheetRoot(colorScheme).ignoresSafeArea())
        .tint(FGColor.accentGreen)
    }
}
