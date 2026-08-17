import SwiftUI

/// Compact professional-game Inbox matchup. Snapshot-only — no live-game lookup.
struct FanGeoProGameInboxCard: View, Equatable {
    let snapshot: FanGeoProGameInboxSnapshot
    let languageCode: String
    let colorScheme: ColorScheme

    static func == (lhs: FanGeoProGameInboxCard, rhs: FanGeoProGameInboxCard) -> Bool {
        lhs.snapshot == rhs.snapshot
            && lhs.languageCode == rhs.languageCode
            && lhs.colorScheme == rhs.colorScheme
    }

    private var artworkDiameter: CGFloat { FanGeoProGameInboxPresentation.artworkDiameter }
    private var rows: [FanGeoProGameInboxScoreboardRow] {
        FanGeoProGameInboxPresentation.scoreboardRows(for: snapshot)
    }

    var body: some View {
        let _ = FanGeoInboxOpenPerf.proGameCardBody()
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.side) { row in
                    teamRow(row)
                }
            }
            if let context = FanGeoProGameInboxPresentation.contextLine(
                for: snapshot,
                languageCode: languageCode
            ) {
                Text(context)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
            }
            Text(FanGeoProGameInboxPresentation.footerLine(for: snapshot, languageCode: languageCode))
                .font(.caption.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            FanGeoProGameInboxPresentation.accessibilitySummary(
                for: snapshot,
                languageCode: languageCode
            )
        )
    }

    private func teamRow(_ row: FanGeoProGameInboxScoreboardRow) -> some View {
        HStack(alignment: .center, spacing: 8) {
            SportsIdentityArtworkView(
                teamName: row.artwork.teamName,
                badgeURL: row.artwork.badgeURL,
                entityID: row.artwork.providerId,
                league: row.artwork.league,
                source: "proGameInbox",
                diameter: artworkDiameter,
                plate: .neutralLogo
            )
            .equatable()
            .frame(width: artworkDiameter, height: artworkDiameter)
            .accessibilityHidden(true)

            Text(row.teamName)
                .font(.subheadline.weight(row.isWinner ? .semibold : .regular))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(0)

            Text("\(row.score)")
                .font(.system(
                    size: row.isWinner ? 20 : 16,
                    weight: row.isWinner ? .bold : .semibold,
                    design: .rounded
                ))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .monospacedDigit()
                .frame(
                    minWidth: FanGeoProGameInboxPresentation.scoreColumnMinWidth,
                    alignment: .trailing
                )
                .layoutPriority(1)
        }
    }
}
