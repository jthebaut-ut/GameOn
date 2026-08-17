import Foundation
import SwiftUI

// MARK: - Selection logic (testable)

enum DiscoverPickupGameClusterSelection {
    enum TapDecision: Equatable {
        case openDirect(UUID)
        case showSelector([PickupGameRow])
        case none
    }

    /// Deterministic list order: start time ↑, title ↑, id ↑.
    static func sorted(_ rows: [PickupGameRow]) -> [PickupGameRow] {
        rows.sorted { lhs, rhs in
            let lhsStart = PickupGameModels.parseSupabaseTimestamptz(lhs.game_start_at) ?? .distantFuture
            let rhsStart = PickupGameModels.parseSupabaseTimestamptz(rhs.game_start_at) ?? .distantFuture
            if lhsStart != rhsStart { return lhsStart < rhsStart }
            let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Re-resolve cluster rows against still-valid Discover models (stale-safe).
    static func resolveTap(
        clusterRows: [PickupGameRow],
        stillValid: (UUID) -> PickupGameRow?
    ) -> TapDecision {
        var resolved: [PickupGameRow] = []
        resolved.reserveCapacity(clusterRows.count)
        var seen = Set<UUID>()
        for row in clusterRows {
            guard !seen.contains(row.id) else { continue }
            seen.insert(row.id)
            guard let live = stillValid(row.id) else { continue }
            resolved.append(live)
        }
        let ordered = sorted(resolved)
        switch ordered.count {
        case 0:
            return .none
        case 1:
            return .openDirect(ordered[0].id)
        default:
            return .showSelector(ordered)
        }
    }

    static func accessibilityLabel(forCount count: Int) -> String {
        if count == 1 {
            return "1 pickup game at this location."
        }
        return "\(count) pickup games at this location."
    }

    static func goingCountCaption(_ count: Int) -> String? {
        let n = max(0, count)
        guard n > 0 else { return nil }
        return n == 1 ? "1 Going" : "\(n) Going"
    }

    static func sportSystemImage(for sport: String) -> String {
        let text = sport.lowercased()
        if text.contains("soccer") || text.contains("football") { return "soccerball" }
        if text.contains("basketball") { return "basketball.fill" }
        if text.contains("baseball") || text.contains("softball") { return "baseball.fill" }
        if text.contains("tennis") || text.contains("pickleball") || text.contains("badminton") || text.contains("padel") {
            return "figure.tennis"
        }
        if text.contains("volleyball") { return "volleyball.fill" }
        if text.contains("hockey") { return "hockey.puck.fill" }
        if text.contains("golf") { return "figure.golf" }
        if text.contains("rugby") { return "figure.rugby" }
        if text.contains("swim") { return "figure.pool.swim" }
        if text.contains("run") || text.contains("track") { return "figure.run" }
        return "sportscourt.fill"
    }
}

// MARK: - Sheet

/// Compact selector when one Discover map marker represents multiple pickup games.
struct DiscoverPickupGameClusterSheet: View {
    let rows: [PickupGameRow]
    let teamIdentityByGameId: [UUID: PickupDiscoverTeamIdentity]
    let languageCode: String
    let onSelectGameId: (UUID) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private var orderedRows: [PickupGameRow] {
        DiscoverPickupGameClusterSelection.sorted(rows)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(orderedRows) { row in
                        pickupGameClusterRow(row)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Pickup games here")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("Done", languageCode: languageCode)) {
                        dismiss()
                    }
                    .font(FGTypography.metadata.weight(.semibold))
                }
            }
        }
    }

    private func pickupGameClusterRow(_ row: PickupGameRow) -> some View {
        let sportLabel = row.sportIdentityLabel()
        let timeLabel = row.pickupDateWithCompactTimeRangeAndDuration(languageCode: languageCode)
            ?? PickupGameMeaningfulChange.formattedStart(row.game_start_at, languageCode: languageCode)
        let timeA11y = row.pickupDateTimeDurationAccessibilityLabel(languageCode: languageCode) ?? timeLabel
        let goingCaption = DiscoverPickupGameClusterSelection.goingCountCaption(row.approvedJoinCount)
        let teamName = teamIdentityByGameId[row.id]?.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        let accent = viewModelSafeAccent(for: row)
        let a11y = rowAccessibilityLabel(
            title: row.title,
            time: timeA11y,
            going: goingCaption
        )

        return Button {
            FGInteractionHaptics.selection()
            onSelectGameId(row.id)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: DiscoverPickupGameClusterSelection.sportSystemImage(for: row.sport))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent)
                    .frame(width: 38, height: 38)
                    .background(
                        Circle()
                            .fill(accent.opacity(colorScheme == .dark ? 0.18 : 0.10))
                    )

                VStack(alignment: .leading, spacing: 5) {
                    Text(row.title)
                        .font(FGTypography.body.weight(.heavy))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(sportMetaLine(sportLabel: sportLabel, teamName: teamName, isPrivate: !row.is_visible))
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Label(timeLabel, systemImage: "clock.fill")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)

                    if let goingCaption {
                        Text(goingCaption)
                            .font(FGTypography.caption.weight(.semibold))
                            .foregroundStyle(FGColor.accentGreen)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .padding(.top, 10)
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.42), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11y)
        .accessibilityAddTraits(.isButton)
    }

    private func sportMetaLine(sportLabel: String, teamName: String?, isPrivate: Bool) -> String {
        var parts: [String] = []
        let sport = sportLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sport.isEmpty { parts.append(sport) }
        if let teamName, !teamName.isEmpty { parts.append(teamName) }
        if isPrivate { parts.append("Private") }
        return parts.joined(separator: " • ")
    }

    private func rowAccessibilityLabel(title: String, time: String, going: String?) -> String {
        var parts = [title, time]
        if let going { parts.append(going) }
        return parts.joined(separator: ", ")
    }

    private func viewModelSafeAccent(for row: PickupGameRow) -> Color {
        if let hex = teamIdentityByGameId[row.id]?.colorHex {
            return TeamColorRegistry.colorFromHex(hex)
        }
        return FGColor.accentBlue
    }
}

#if DEBUG
enum DiscoverPickupGameClusterSelectionSelfTests {
    static func runAll() {
        let early = stub(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "B Game", start: "2026-08-11T19:00:00Z")
        let late = stub(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "A Game", start: "2026-08-11T20:00:00Z")
        let sameTimeA = stub(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, title: "Alpha", start: "2026-08-11T19:00:00Z")
        let sameTimeB = stub(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, title: "Beta", start: "2026-08-11T19:00:00Z")

        let ordered = DiscoverPickupGameClusterSelection.sorted([late, early])
        precondition(ordered.map(\.id) == [early.id, late.id], "start time ascending")

        let sameTime = DiscoverPickupGameClusterSelection.sorted([sameTimeB, sameTimeA])
        precondition(sameTime.map(\.id) == [sameTimeA.id, sameTimeB.id], "title then id tie-break")

        let live: [UUID: PickupGameRow] = [early.id: early, late.id: late]
        switch DiscoverPickupGameClusterSelection.resolveTap(clusterRows: [early, late], stillValid: { live[$0] }) {
        case .showSelector(let rows):
            precondition(rows.map(\.id) == [early.id, late.id], "two valid → selector")
        default:
            preconditionFailure("expected showSelector")
        }

        switch DiscoverPickupGameClusterSelection.resolveTap(clusterRows: [early, late], stillValid: { id in
            id == early.id ? early : nil
        }) {
        case .openDirect(let id):
            precondition(id == early.id, "one valid → direct")
        default:
            preconditionFailure("expected openDirect")
        }

        switch DiscoverPickupGameClusterSelection.resolveTap(clusterRows: [early, late], stillValid: { _ in nil }) {
        case .none:
            break
        default:
            preconditionFailure("all stale → none")
        }

        precondition(DiscoverPickupGameClusterSelection.goingCountCaption(0) == nil)
        precondition(DiscoverPickupGameClusterSelection.goingCountCaption(1) == "1 Going")
        precondition(DiscoverPickupGameClusterSelection.goingCountCaption(4) == "4 Going")
        precondition(
            DiscoverPickupGameClusterSelection.accessibilityLabel(forCount: 2)
                == "2 pickup games at this location."
        )

        print("[DiscoverPickupGameClusterSelectionSelfTests] PASS")
    }

    private static func stub(id: UUID, title: String, start: String) -> PickupGameRow {
        PickupGameRow(
            id: id,
            creator_user_id: UUID(),
            creator_email: nil,
            title: title,
            sport: "soccer",
            description: nil,
            game_format: "pickup",
            competition_level: nil,
            skill_level: "casual",
            game_start_at: start,
            end_time: nil,
            address: nil,
            city: nil,
            state: nil,
            latitude: 30.0,
            longitude: -90.0,
            is_visible: true,
            players_needed: 4,
            play_environment: "either",
            participant_preference: "mixed",
            age_min: nil,
            age_max: nil,
            is_free: true,
            entry_fee_amount: nil,
            max_players: nil,
            status: "active",
            approved_join_count: 2,
            cleanup_delay_hours: 12,
            remove_after_at: nil,
            created_at: nil,
            updated_at: nil,
            poll_create_permission: nil
        )
    }
}
#endif
