import SwiftUI

/// Edit-Profile picker: thumbnail grid only (never loads full 1600×900 assets).
struct ProfileBackgroundPickerSheet: View {
    @Binding var selection: ProfileBackgroundKey
    let languageCode: String
    var onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(ProfileBackgroundCatalog.sorted) { option in
                        pickerCell(option)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .fanGeoScreenBackground()
            .navigationTitle(L10n.t("choose_background", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Close", languageCode: languageCode)) {
                        onDismiss()
                        dismiss()
                    }
                }
            }
        }
    }

    private func pickerCell(_ option: ProfileBackgroundOption) -> some View {
        let isSelected = selection == option.key
        let name = option.displayName(languageCode: languageCode)

        return Button {
            FGInteractionHaptics.selection()
            selection = option.key
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Image(option.thumbnailAssetName)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 96)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(
                                    isSelected
                                        ? FGColor.accentGreen
                                        : FGColor.divider(colorScheme).opacity(0.55),
                                    lineWidth: isSelected ? 2.2 : 1
                                )
                        }

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(FGColor.accentGreen)
                            .background {
                                Circle().fill(Color.white.opacity(0.92)).padding(2)
                            }
                            .padding(8)
                            .accessibilityHidden(true)
                    }
                }

                Text(name)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pickerAccessibilityLabel(name: name, isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(L10n.t("profile_background_picker_hint", languageCode: languageCode))
    }

    private func pickerAccessibilityLabel(name: String, isSelected: Bool) -> String {
        if isSelected {
            let selected = L10n.t("profile_background_selected", languageCode: languageCode)
            return "\(name), \(selected)"
        }
        return name
    }
}
