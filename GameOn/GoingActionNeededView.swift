import SwiftUI

/// Legacy Going Action Needed list. Not presented — FanGeo Inbox is the single Action Needed surface.
struct GoingActionNeededSection: View {
    let summary: GoingActionSummary
    let languageCode: String
    let onSelect: (GoingActionItem) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if !summary.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FGColor.accentYellow)
                    Text(headerTitle)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Spacer(minLength: 0)
                }
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(headerTitle)

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(summary.items) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Text("•")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                                Text(item.title(languageCode: languageCode))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(FGColor.primaryText(colorScheme))
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(FGColor.mutedText(colorScheme))
                                    .padding(.top, 2)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(L10n.t("going_action_needed_row_a11y_hint", languageCode: languageCode))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(FGColor.accentYellow.opacity(colorScheme == .dark ? 0.12 : 0.10))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(FGColor.accentYellow.opacity(0.35), lineWidth: 1)
            }
        }
    }

    private var headerTitle: String {
        String(
            format: L10n.t("going_action_needed_count_format", languageCode: languageCode),
            locale: Locale(identifier: L10n.normalizedLanguageCode(languageCode)),
            Int64(summary.count)
        )
    }
}
