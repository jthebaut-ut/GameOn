import SwiftUI

// MARK: - Compact Open To tile (Profile preview + editor + public read-only)

/// Shared visual metrics for Open To cards. Own-profile / editor keep the full size;
/// public profile uses a slightly more compact read-only variant (~15% smaller).
enum FanOpenToCompactTileStyle {
    case ownProfile
    case publicCompact

    var height: CGFloat {
        switch self {
        case .ownProfile: return 84
        case .publicCompact: return 72
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .ownProfile: return 18
        case .publicCompact: return 16
        }
    }

    var iconPointSize: CGFloat {
        switch self {
        case .ownProfile: return 24
        case .publicCompact: return 21
        }
    }

    var sportBadgeSize: CGFloat {
        switch self {
        case .ownProfile: return 30
        case .publicCompact: return 26
        }
    }

    var iconFrameHeight: CGFloat {
        switch self {
        case .ownProfile: return 28
        case .publicCompact: return 24
        }
    }

    var titleFontSize: CGFloat {
        switch self {
        case .ownProfile, .publicCompact: return 9
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .ownProfile: return 6
        case .publicCompact: return 5
        }
    }
}

enum FanOpenToCompactTileMetrics {
    static let height: CGFloat = FanOpenToCompactTileStyle.ownProfile.height
    static let cornerRadius: CGFloat = FanOpenToCompactTileStyle.ownProfile.cornerRadius
    static let iconPointSize: CGFloat = FanOpenToCompactTileStyle.ownProfile.iconPointSize
    static let sportBadgeSize: CGFloat = FanOpenToCompactTileStyle.ownProfile.sportBadgeSize
}

struct FanOpenToCompactTile: View {
    let itemID: String
    let title: String
    let systemImage: String
    let isSocial: Bool
    var style: FanOpenToCompactTileStyle = .ownProfile

    @Environment(\.colorScheme) private var colorScheme

    private var tint: Color {
        FanOpenToCatalog.tint(for: itemID, colorScheme: colorScheme)
    }

    var body: some View {
        VStack(spacing: 4) {
            if isSocial {
                Image(systemName: systemImage)
                    .font(.system(size: style.iconPointSize, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(height: style.iconFrameHeight)
            } else {
                FanGeoSportBadgeView(
                    sport: itemID,
                    size: style.sportBadgeSize,
                    style: .profile
                )
                .frame(height: style.iconFrameHeight)
            }

            Text(title)
                .font(.system(size: style.titleFontSize, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: style.height)
        .padding(.horizontal, style.horizontalPadding)
        .background {
            RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                .fill(FanOpenToCatalog.compactTileFill(for: itemID, colorScheme: colorScheme))
        }
        .overlay {
            RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                .strokeBorder(tint.opacity(colorScheme == .dark ? 0.28 : 0.18), lineWidth: 0.75)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

struct FanOpenToCompactAddTile: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "plus")
                .font(.system(size: FanOpenToCompactTileMetrics.iconPointSize, weight: .semibold))
                .foregroundStyle(FGColor.accentBlue)
                .frame(height: 28)

            Text("Add")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: FanOpenToCompactTileMetrics.height)
        .padding(.horizontal, 6)
        .background {
            RoundedRectangle(cornerRadius: FanOpenToCompactTileMetrics.cornerRadius, style: .continuous)
                .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: FanOpenToCompactTileMetrics.cornerRadius, style: .continuous)
                .strokeBorder(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.28 : 0.20), lineWidth: 0.75)
        }
    }
}

// MARK: - Open To activity card (editor)

struct FanOpenToActivityCard: View {
    let activity: FanOpenToActivityDefinition
    let isSelected: Bool
    var showsRemoveButton: Bool = false
    var onTap: () -> Void = {}
    var onRemove: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    private var tint: Color {
        activity.tint(colorScheme: colorScheme)
    }

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topTrailing) {
                FanOpenToCompactTile(
                    itemID: activity.id,
                    title: activity.title,
                    systemImage: activity.systemImage,
                    isSocial: activity.isSocial
                )
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: FanOpenToCompactTileMetrics.cornerRadius, style: .continuous)
                            .strokeBorder(tint.opacity(0.65), lineWidth: 1.5)
                            .shadow(color: tint.opacity(0.22), radius: 4, y: 1)
                    }
                }

                if showsRemoveButton, let onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(FGColor.primaryText(colorScheme).opacity(0.92))
                            .frame(width: 20, height: 20)
                            .background {
                                Circle()
                                    .fill(Color.black.opacity(colorScheme == .dark ? 0.32 : 0.10))
                                    .overlay {
                                        Circle()
                                            .strokeBorder(
                                                Color.white.opacity(colorScheme == .dark ? 0.22 : 0.65),
                                                lineWidth: 0.75
                                            )
                                    }
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(5)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Open To picker grid (editor)

struct FanOpenToPickerGrid: View {
    let activities: [FanOpenToActivityDefinition]
    let selectedIDs: Set<String>
    let onSelect: (FanOpenToActivityDefinition) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(activities) { activity in
                if !selectedIDs.contains(activity.id) {
                    FanOpenToActivityCard(
                        activity: activity,
                        isSelected: false,
                        onTap: { onSelect(activity) }
                    )
                }
            }
        }
    }
}

struct FanOpenToSelectedGrid: View {
    let selectedIDs: [String]
    let onRemove: (String) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if selectedIDs.isEmpty {
            Text("Tap a sport or activity below to add it.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(FGColor.mutedText(colorScheme))
        } else {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(selectedIDs, id: \.self) { id in
                    if let activity = FanOpenToCatalog.definition(id: id) {
                        FanOpenToActivityCard(
                            activity: activity,
                            isSelected: true,
                            showsRemoveButton: true,
                            onTap: {},
                            onRemove: { onRemove(id) }
                        )
                    }
                }
            }
        }
    }
}
