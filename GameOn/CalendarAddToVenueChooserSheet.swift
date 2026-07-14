import SwiftUI

/// Carries the tapped Pro game into the multi-venue chooser (stable id; not array index).
struct CalendarAddToVenueChooserContext: Identifiable {
    let id: UUID
    let match: LiveMatch

    init(match: LiveMatch, id: UUID = UUID()) {
        self.id = id
        self.match = match
    }
}

/// Compact venue picker for Schedule → Add to Venue (business accounts with multiple managed venues).
struct CalendarAddToVenueChooserSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let match: LiveMatch
    let venues: [VenueProfileRow]
    let onSelect: (UUID) -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var uniqueRows: [VenueProfileRow] {
        var seen = Set<UUID>()
        return venues.compactMap { row in
            guard let id = row.id, seen.insert(id).inserted else { return nil }
            return row
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.t("Choose a Venue", languageCode: appLanguageRaw))
                            .font(.title3.weight(.heavy))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                        Text(L10n.t("Select where you want to show this game.", languageCode: appLanguageRaw))
                            .font(.subheadline)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(proGameSummaryLine)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                            .lineLimit(2)
                    }

                    VStack(spacing: 10) {
                        ForEach(uniqueRows, id: \.id) { row in
                            venueRow(row)
                        }
                    }
                }
                .padding(FGSpacing.lg)
                .padding(.bottom, FGSpacing.xl)
            }
            .background(FGAdaptiveSurface.sheetRoot)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel", languageCode: appLanguageRaw)) {
                        onCancel()
                        dismiss()
                    }
                }
            }
        }
    }

    private var proGameSummaryLine: String {
        let home = match.homeTeam.trimmingCharacters(in: .whitespacesAndNewlines)
        let away = match.awayTeam.trimmingCharacters(in: .whitespacesAndNewlines)
        if !home.isEmpty, !away.isEmpty { return "\(away) @ \(home)" }
        return [away, home].filter { !$0.isEmpty }.joined(separator: " vs ")
    }

    @ViewBuilder
    private func venueRow(_ row: VenueProfileRow) -> some View {
        let isSelectable = MapViewModel.venueIsActiveForBusinessLimit(row)
        let isLocked = MapViewModel.venueIsBackendPlanLocked(row)
        let name = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (name?.isEmpty == false) ? name! : "Venue"
        let location = venueLocationLine(row)

        Button {
            guard isSelectable, let id = row.id else { return }
            onSelect(id)
            dismiss()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                SelectedVenueThumbnailView(venue: row, style: .managedVenueList)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if !location.isEmpty {
                        Text(location)
                            .font(.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(2)
                    }

                    if isLocked {
                        Text(L10n.t("venue_plan_locked", languageCode: appLanguageRaw))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.orange)
                    } else if isSelectable {
                        Text(L10n.t("venue_status_verified", languageCode: appLanguageRaw))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(FGColor.accentGreen)
                    }
                }

                Spacer(minLength: 0)

                if isSelectable {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                } else {
                    Image(systemName: "lock.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                }
            }
            .padding(12)
            .background(FGAdaptiveSurface.cardElevated)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme).opacity(0.55), lineWidth: 1)
            }
            .opacity(isSelectable ? 1 : 0.72)
        }
        .buttonStyle(.plain)
        .disabled(!isSelectable)
        .accessibilityLabel(title)
        .accessibilityHint(isSelectable ? "Select venue" : "Venue unavailable")
    }

    private func venueLocationLine(_ row: VenueProfileRow) -> String {
        let city = row.city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let region = (row.state ?? row.region)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return [city, region].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
