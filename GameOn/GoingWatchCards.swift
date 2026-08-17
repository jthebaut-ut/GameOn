import SwiftUI

struct GoingWatchFavoriteSpotBadge: View {
    let languageCode: String

    var body: some View {
        Text(L10n.t("favorite_spot_card_subtitle", languageCode: languageCode))
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(FGColor.intentWatch, in: Capsule(style: .continuous))
            .accessibilityLabel(L10n.t("favorite_spot_card_subtitle", languageCode: languageCode))
    }
}

struct GoingWatchStatusChip: View {
    let isGoing: Bool
    let languageCode: String

    var body: some View {
        let title = isGoing
            ? L10n.t("Going", languageCode: languageCode)
            : L10n.t("Interested", languageCode: languageCode)
        let tint = isGoing ? FGColor.accentGreen : Color.orange
        HStack(spacing: 5) {
            if isGoing {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.16), in: Capsule(style: .continuous))
        .accessibilityLabel(title)
    }
}

enum GoingWatchFilterChipMetrics {
    static let height: CGFloat = 44
    static let iconPointSize: CGFloat = 12
    static let labelPointSize: CGFloat = 14
    static let countPointSize: CGFloat = 12
    static let horizontalPadding: CGFloat = 9
    static let contentSpacing: CGFloat = 4
    static let rowSpacing: CGFloat = 8
    static let minimumTapTarget: CGFloat = 44
}

struct GoingWatchFilterChip: View {
    let filter: GoingWatchFilter
    let count: Int
    let selected: Bool
    let languageCode: String
    let colorScheme: ColorScheme
    let action: () -> Void

    @ScaledMetric(relativeTo: .footnote) private var iconPointSize = GoingWatchFilterChipMetrics.iconPointSize
    @ScaledMetric(relativeTo: .footnote) private var labelPointSize = GoingWatchFilterChipMetrics.labelPointSize
    @ScaledMetric(relativeTo: .caption) private var countPointSize = GoingWatchFilterChipMetrics.countPointSize
    @ScaledMetric(relativeTo: .body) private var chipHeight = GoingWatchFilterChipMetrics.height

    private var title: String {
        L10n.t(filter.chipTitleKey, languageCode: languageCode)
    }

    private var tint: Color { FGColor.intentWatch }

    private var resolvedHeight: CGFloat {
        max(GoingWatchFilterChipMetrics.minimumTapTarget, chipHeight)
    }

    private var accessibilityLabelText: String {
        let key = count == 1 ? "going_watch_chip_a11y_one" : "going_watch_chip_a11y_other"
        return String(
            format: L10n.t(key, languageCode: languageCode),
            locale: Locale(identifier: languageCode.replacingOccurrences(of: "-", with: "_")),
            title,
            max(0, count)
        )
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: GoingWatchFilterChipMetrics.contentSpacing) {
                Image(systemName: filter.systemImage)
                    .font(.system(size: iconPointSize, weight: .semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: labelPointSize, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(selected ? tint : FGColor.primaryText(colorScheme))
                Text("\(max(0, count))")
                    .font(.system(size: countPointSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(selected ? tint : FGColor.secondaryText(colorScheme))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, GoingWatchFilterChipMetrics.horizontalPadding)
            .frame(minHeight: resolvedHeight)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        selected
                            ? tint.opacity(colorScheme == .dark ? 0.22 : 0.14)
                            : Color(.systemBackground).opacity(colorScheme == .dark ? 0.55 : 1)
                    )
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        selected ? tint.opacity(0.55) : FGColor.divider(colorScheme).opacity(0.85),
                        lineWidth: 1
                    )
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.10 : 0.04), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
