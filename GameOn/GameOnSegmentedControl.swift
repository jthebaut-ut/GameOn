import SwiftUI

struct GameOnSegmentedTab<Selection: Hashable>: Identifiable {
    let id: Selection
    let title: String
    var systemImage: String?
    var badge: String?
    var tint: Color?
    var showsActivityDot: Bool
    var accessibilityLabel: String?
    var activityAccessibilityLabel: String?

    init(
        id: Selection,
        title: String,
        systemImage: String? = nil,
        badge: String? = nil,
        tint: Color? = nil,
        showsActivityDot: Bool = false,
        accessibilityLabel: String? = nil,
        activityAccessibilityLabel: String? = nil
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.badge = badge
        self.tint = tint
        self.showsActivityDot = showsActivityDot
        self.accessibilityLabel = accessibilityLabel
        self.activityAccessibilityLabel = activityAccessibilityLabel
    }
}

struct GameOnSegmentedControl<Selection: Hashable>: View {
    let tabs: [GameOnSegmentedTab<Selection>]
    @Binding var selection: Selection
    var accent: Color = FGColor.accentGreen
    var animatesSelectionChanges: Bool = true
    var fillsWidth = true
    /// Allows longer tab titles (e.g. Going → Venue Games) to fit without clipping.
    var titleMinimumScaleFactor: CGFloat = 0.74
    var tabHorizontalPadding: CGFloat = 8
    /// Settings-style density (Team Schedule Visibility). Default keeps existing surfaces unchanged.
    var isCompact: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    private var chromePadding: CGFloat { isCompact ? 3 : 4 }
    private var interTabSpacing: CGFloat { isCompact ? 4 : 6 }
    private var tabMinHeight: CGFloat { isCompact ? 28 : 42 }
    private var tabVerticalPadding: CGFloat { isCompact ? 4 : 7 }
    private var resolvedTabHorizontalPadding: CGFloat {
        isCompact ? min(tabHorizontalPadding, 6) : tabHorizontalPadding
    }
    private var titleFontSize: CGFloat { isCompact ? 12 : 12.5 }
    private var iconFontSize: CGFloat { isCompact ? 10 : 11 }
    private var selectionUnderlineSpacing: CGFloat { isCompact ? 3 : 5 }
    private var chromeShadowRadius: CGFloat { isCompact ? 4 : 9 }
    private var chromeShadowY: CGFloat { isCompact ? 1 : 3 }

    var body: some View {
        HStack(spacing: interTabSpacing) {
            ForEach(tabs) { tab in
                tabButton(tab)
            }
        }
        .padding(chromePadding)
        .background {
            Capsule(style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground).opacity(colorScheme == .dark ? 0.32 : 0.64))
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.58), lineWidth: 1)
        }
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.045),
            radius: chromeShadowRadius,
            y: chromeShadowY
        )
        .accessibilityElement(children: .contain)
    }

    private func tabButton(_ tab: GameOnSegmentedTab<Selection>) -> some View {
        let isSelected = selection == tab.id
        let tint = tab.tint ?? accent

        return Button {
            if animatesSelectionChanges {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    selection = tab.id
                }
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    selection = tab.id
                }
            }
        } label: {
            VStack(spacing: selectionUnderlineSpacing) {
                HStack(spacing: tab.badge == nil ? 6 : 5) {
                    HStack(spacing: tab.systemImage == nil ? 0 : 4) {
                        if let systemImage = tab.systemImage {
                            Image(systemName: systemImage)
                                .font(.system(size: iconFontSize, weight: .semibold))
                                .foregroundStyle(isSelected ? tint : FGColor.secondaryText(colorScheme))
                                .layoutPriority(1)
                        }

                        Text(tab.title)
                            .font(.system(size: titleFontSize, weight: isSelected ? .semibold : .medium, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(titleMinimumScaleFactor)
                            .allowsTightening(true)
                            .layoutPriority(2)
                    }
                    .layoutPriority(0)

                    if let badge = tab.badge, !badge.isEmpty {
                        let badgeTint = isSelected ? tint : FGColor.secondaryText(colorScheme)
                        Text(badge)
                            .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                            .foregroundStyle(badgeTint.opacity(colorScheme == .dark ? 0.98 : 0.95))
                            .lineLimit(1)
                            .minimumScaleFactor(0.80)
                            .allowsTightening(true)
                            .multilineTextAlignment(.center)
                            .frame(minWidth: badgeMinWidth(for: badge), minHeight: 17, alignment: .center)
                            .padding(.horizontal, badgeHorizontalPadding(for: badge))
                            .padding(.vertical, 2.5)
                            .background(badgeTint.opacity(colorScheme == .dark ? 0.18 : 0.12), in: Capsule())
                            .overlay {
                                Capsule(style: .continuous)
                                    .strokeBorder(badgeTint.opacity(colorScheme == .dark ? 0.24 : 0.18), lineWidth: 0.65)
                            }
                            .accessibilityLabel(badge)
                            .layoutPriority(2)
                    }

                    if tab.showsActivityDot {
                        Circle()
                            .fill(Color.orange.opacity(0.9))
                            .frame(width: 6, height: 6)
                            .accessibilityLabel(tab.activityAccessibilityLabel ?? "New activity")
                    }
                }
                .foregroundStyle(isSelected ? FGColor.primaryText(colorScheme) : FGColor.secondaryText(colorScheme))

                Capsule(style: .continuous)
                    .fill(isSelected ? tint.opacity(0.92) : Color.clear)
                    .frame(width: isSelected ? 24 : 12, height: 2)
                    .opacity(isSelected ? 1 : 0)
            }
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(minHeight: tabMinHeight)
            .padding(.horizontal, resolvedTabHorizontalPadding)
            .padding(.vertical, tabVerticalPadding)
            .background {
                Capsule(style: .continuous)
                    .fill(isSelected ? tint.opacity(colorScheme == .dark ? 0.11 : 0.08) : Color.clear)
            }
            .shadow(color: tint.opacity(isSelected ? 0.16 : 0), radius: isCompact ? 6 : 10, y: 0)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.985))
        .accessibilityLabel(tab.accessibilityLabel ?? tab.title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func badgeMinWidth(for badge: String) -> CGFloat {
        let length = badge.trimmingCharacters(in: .whitespacesAndNewlines).count
        if length <= 2 { return 22 }
        if length <= 3 { return 28 }
        if length <= 5 { return 42 }
        return 58
    }

    private func badgeHorizontalPadding(for badge: String) -> CGFloat {
        badge.trimmingCharacters(in: .whitespacesAndNewlines).count <= 3 ? 5 : 6
    }
}
