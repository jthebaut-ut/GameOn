import SwiftUI

/// Compact Discover overlay: Top venues for the focused professional game.
struct DiscoverTopVenuesForGamePanel: View {
    @ObservedObject var viewModel: MapViewModel
    let onSelectVenue: (BarVenue) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var showVenueEnergyInfo = false

    private var focus: DiscoverFocusedProGame? {
        viewModel.discoverFocusedProGame
    }

    var body: some View {
        if let focus {
            VStack(alignment: .leading, spacing: 10) {
                header(focus)

                switch viewModel.discoverTopVenuesForFocusedGameState {
                case .idle, .loading:
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Finding watch spots…")
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                    .padding(.vertical, 4)

                case .unavailable:
                    emptyMessage(
                        title: "Watch spots unavailable",
                        supporting: "Try again in a moment."
                    )

                case .loaded(let spots) where spots.isEmpty:
                    emptyMessage(
                        title: "No watch spots found in this area",
                        supporting: "Pan the map or pick another game."
                    )

                case .loaded:
                    let spots = viewModel.discoverTopVenuesForFocusedGame
                    VStack(spacing: 8) {
                        ForEach(Array(spots.enumerated()), id: \.element.id) { index, spot in
                            Button {
                                onSelectVenue(spot.bar)
                            } label: {
                                row(rank: index + 1, spot: spot)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.92))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.10), radius: 14, y: 6)
            .sheet(isPresented: $showVenueEnergyInfo) {
                VenueEnergyHowItWorksSheet(audience: .fan)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Top venues for \(focus.displayTitle)")
        }
    }

    private func header(_ focus: DiscoverFocusedProGame) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Top venues for this game")
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .accessibilityAddTraits(.isHeader)

                HStack(spacing: 4) {
                    Text("Based on live fan activity")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)

                    VenueEnergyInfoButton(action: {
                        showVenueEnergyInfo = true
                    })
                }

                Text(focus.displayTitle)
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.accentBlue)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button {
                viewModel.clearDiscoverFocusedProGame(reason: "panelDismiss")
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear selected game")
        }
    }

    private func row(rank: Int, spot: MapViewModel.DiscoverProGameWatchSpot) -> some View {
        let caption = spot.energyCaption
        let distanceText = spot.distanceFromRegionCenterMiles.map { miles -> String in
            if miles < 10 {
                return String(format: "%.1f mi", miles)
            }
            return String(format: "%.0f mi", miles)
        }

        return HStack(alignment: .center, spacing: 10) {
            Text("\(rank)")
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                Text(spot.bar.name)
                    .font(FGTypography.body.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 8) {
                    if !caption.isEmpty {
                        Text(caption)
                            .font(FGTypography.metadata.weight(.bold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(1)
                    } else if spot.isLiveNow {
                        Text("LIVE")
                            .font(FGTypography.metadata.weight(.bold))
                            .foregroundStyle(FGColor.dangerRed)
                            .lineLimit(1)
                    }

                    if spot.goingCount > 0 {
                        Text(spot.goingCount == 1 ? "1 Going" : "\(spot.goingCount) Going")
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    }

                    if let distanceText {
                        Text(distanceText)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FGColor.mutedText(colorScheme))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.35 : 0.55))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(rank: rank, spot: spot, distanceText: distanceText))
        .accessibilityHint("Shows this venue on the map")
    }

    private func accessibilityLabel(
        rank: Int,
        spot: MapViewModel.DiscoverProGameWatchSpot,
        distanceText: String?
    ) -> String {
        var parts = ["Rank \(rank)", spot.bar.name]
        if !spot.energyCaption.isEmpty {
            parts.append(spot.energyCaption)
        }
        if spot.goingCount > 0 {
            parts.append("\(spot.goingCount) Going")
        }
        if let distanceText {
            parts.append(distanceText)
        }
        return parts.joined(separator: ", ")
    }

    private func emptyMessage(title: String, supporting: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(FGTypography.body.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
            Text(supporting)
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
        }
        .accessibilityElement(children: .combine)
    }
}
