import Foundation

/// Authoritative meaningful pickup-game field changes for Going activity, chat system
/// messages, and edit push notifications. Ignores audit/sync-only noise.
nonisolated enum PickupGameMeaningfulChangeKind: String, CaseIterable, Sendable {
    case title
    case sport
    case start
    case end
    case location
    case capacity
    case welcome
    case skill
    case environment
    case cost
    case status
    case visibility

    var localizationKey: String {
        switch self {
        case .title: return "pickup_edit_change_title"
        case .sport: return "pickup_edit_change_sport"
        case .start: return "pickup_edit_change_date"
        case .end: return "pickup_edit_change_time"
        case .location: return "pickup_edit_change_location"
        case .capacity: return "pickup_edit_change_capacity"
        case .welcome: return "pickup_edit_change_welcome"
        case .skill: return "pickup_edit_change_skill"
        case .environment: return "pickup_edit_change_environment"
        case .cost: return "pickup_edit_change_cost"
        case .status: return "pickup_edit_change_cancelled"
        case .visibility: return "pickup_edit_change_visibility"
        }
    }
}

nonisolated struct PickupGameMeaningfulChangeSet: Equatable, Sendable {
    let kinds: [PickupGameMeaningfulChangeKind]
    let beforeLocationLabel: String
    let afterLocationLabel: String
    let beforeStartRaw: String
    let afterStartRaw: String
    let beforePlayersNeeded: Int
    let afterPlayersNeeded: Int
    let title: String
    let isCancellation: Bool

    var isEmpty: Bool { kinds.isEmpty }

    /// Stable activity fingerprint fragment for the after-location label.
    var activityLocationKey: String {
        PickupGameMeaningfulChange.locationPlaceTextKey(
            address: afterLocationLabel,
            city: "",
            state: ""
        )
    }
}

nonisolated enum PickupGameMeaningfulChange {
    /// Coordinate rounding (~11m) — enough to ignore geocode jitter, catch real moves.
    static let coordinateDecimalPlaces = 4

    static func normalizedText(_ raw: String?) -> String {
        (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    static func roundedCoordinate(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        let factor = pow(10.0, Double(coordinateDecimalPlaces))
        let rounded = (value * factor).rounded() / factor
        return String(format: "%.*f", coordinateDecimalPlaces, rounded)
    }

    /// Place-text identity only (address/city/state). Postal may be embedded in `state`.
    static func locationPlaceTextKey(
        address: String?,
        city: String?,
        state: String?
    ) -> String {
        [
            normalizedText(address),
            normalizedText(city),
            normalizedText(state)
        ].joined(separator: "|")
    }

    static func locationIdentityKey(
        address: String?,
        city: String?,
        state: String?,
        latitude: Double?,
        longitude: Double?
    ) -> String {
        let place = locationPlaceTextKey(address: address, city: city, state: state)
        // When place text is present, ignore coordinate-only geocode jitter.
        if !place.replacingOccurrences(of: "|", with: "").isEmpty {
            return place
        }
        return [
            place,
            roundedCoordinate(latitude),
            roundedCoordinate(longitude)
        ].joined(separator: "|")
    }

    static func locationIdentityKey(for row: PickupGameRow) -> String {
        locationIdentityKey(
            address: row.address,
            city: row.city,
            state: row.state,
            latitude: row.latitude,
            longitude: row.longitude
        )
    }

    static func locationDisplayLabel(for row: PickupGameRow) -> String {
        let parts = [row.address, row.city, row.state]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: ", ") }
        let lat = roundedCoordinate(row.latitude)
        let lon = roundedCoordinate(row.longitude)
        if !lat.isEmpty, !lon.isEmpty { return "\(lat), \(lon)" }
        return ""
    }

    /// Diff two authoritative pickup rows. Empty when only audit/noise changed.
    static func diff(before: PickupGameRow, after: PickupGameRow) -> PickupGameMeaningfulChangeSet {
        var kinds: [PickupGameMeaningfulChangeKind] = []

        if normalizedText(before.title) != normalizedText(after.title) {
            kinds.append(.title)
        }
        if normalizedText(before.sport) != normalizedText(after.sport)
            || normalizedText(before.game_format) != normalizedText(after.game_format) {
            kinds.append(.sport)
        }
        if normalizedText(before.game_start_at) != normalizedText(after.game_start_at) {
            kinds.append(.start)
        }
        if normalizedText(before.end_time) != normalizedText(after.end_time) {
            kinds.append(.end)
        }
        if locationIdentityKey(for: before) != locationIdentityKey(for: after) {
            kinds.append(.location)
        }
        if PickupGameRow.clampPlayersNeeded(before.players_needed)
            != PickupGameRow.clampPlayersNeeded(after.players_needed)
            || (before.max_players ?? -1) != (after.max_players ?? -1) {
            kinds.append(.capacity)
        }
        if normalizedText(before.participant_preference) != normalizedText(after.participant_preference)
            || before.age_min != after.age_min
            || before.age_max != after.age_max {
            kinds.append(.welcome)
        }
        if normalizedText(before.skill_level) != normalizedText(after.skill_level) {
            kinds.append(.skill)
        }
        if normalizedText(before.play_environment) != normalizedText(after.play_environment) {
            kinds.append(.environment)
        }
        if before.is_free != after.is_free
            || abs((before.entry_fee_amount ?? 0) - (after.entry_fee_amount ?? 0)) > 0.009 {
            kinds.append(.cost)
        }

        let beforeStatus = normalizedText(before.status)
        let afterStatus = normalizedText(after.status)
        let isCancellation = beforeStatus != "removed" && afterStatus == "removed"
        if isCancellation || beforeStatus != afterStatus {
            kinds.append(.status)
        }
        if before.is_visible != after.is_visible {
            kinds.append(.visibility)
        }

        return PickupGameMeaningfulChangeSet(
            kinds: kinds,
            beforeLocationLabel: locationDisplayLabel(for: before),
            afterLocationLabel: locationDisplayLabel(for: after),
            beforeStartRaw: before.game_start_at,
            afterStartRaw: after.game_start_at,
            beforePlayersNeeded: PickupGameRow.clampPlayersNeeded(before.players_needed),
            afterPlayersNeeded: PickupGameRow.clampPlayersNeeded(after.players_needed),
            title: after.title.trimmingCharacters(in: .whitespacesAndNewlines),
            isCancellation: isCancellation
        )
    }

    /// Compact push body (single sentence).
    static func pushBody(for changes: PickupGameMeaningfulChangeSet, languageCode: String) -> String {
        let title = changes.title.isEmpty
            ? L10n.t("pickup_edit_fallback_title", languageCode: languageCode)
            : changes.title
        if changes.isCancellation {
            return String(
                format: L10n.t("pickup_edit_push_cancelled_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                title
            )
        }
        let kinds = Set(changes.kinds)
        if kinds == [.start] || kinds == [.start, .end] || kinds == [.end] {
            return String(
                format: L10n.t("pickup_edit_push_date_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                title,
                formattedStart(changes.afterStartRaw, languageCode: languageCode)
            )
        }
        if kinds == [.location] {
            let place = changes.afterLocationLabel.isEmpty
                ? L10n.t("pickup_edit_location_unknown", languageCode: languageCode)
                : changes.afterLocationLabel
            return String(
                format: L10n.t("pickup_edit_push_location_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                title,
                place
            )
        }
        if kinds.contains(.start), kinds.contains(.location) {
            return String(
                format: L10n.t("pickup_edit_push_date_location_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                title
            )
        }
        if kinds == [.capacity] {
            return String(
                format: L10n.t("pickup_edit_push_capacity_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                title,
                changes.beforePlayersNeeded,
                changes.afterPlayersNeeded
            )
        }
        return String(
            format: L10n.t("pickup_edit_push_generic_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            title
        )
    }

    /// Multi-line chat body (system message). First line is the headline.
    static func chatBodyLines(for changes: PickupGameMeaningfulChangeSet, languageCode: String) -> [String] {
        var lines: [String] = [
            L10n.t("pickup_edit_chat_headline", languageCode: languageCode)
        ]
        if changes.isCancellation {
            lines.append(L10n.t("pickup_edit_chat_cancelled", languageCode: languageCode))
            return lines
        }
        let kinds = Set(changes.kinds)
        if kinds.contains(.start) || kinds.contains(.end) {
            lines.append(
                String(
                    format: L10n.t("pickup_edit_chat_date_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    formattedStart(changes.beforeStartRaw, languageCode: languageCode),
                    formattedStart(changes.afterStartRaw, languageCode: languageCode)
                )
            )
        }
        if kinds.contains(.location) {
            let before = changes.beforeLocationLabel.isEmpty
                ? L10n.t("pickup_edit_location_unknown", languageCode: languageCode)
                : changes.beforeLocationLabel
            let after = changes.afterLocationLabel.isEmpty
                ? L10n.t("pickup_edit_location_unknown", languageCode: languageCode)
                : changes.afterLocationLabel
            lines.append(
                String(
                    format: L10n.t("pickup_edit_chat_location_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    before,
                    after
                )
            )
        }
        if kinds.contains(.capacity) {
            lines.append(
                String(
                    format: L10n.t("pickup_edit_chat_capacity_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    changes.beforePlayersNeeded,
                    changes.afterPlayersNeeded
                )
            )
        }
        let remaining = changes.kinds.filter {
            $0 != .start && $0 != .end && $0 != .location && $0 != .capacity && $0 != .status
        }
        for kind in remaining.prefix(3) {
            lines.append(L10n.t(kind.localizationKey, languageCode: languageCode))
        }
        if lines.count == 1 {
            lines.append(L10n.t("pickup_edit_chat_generic", languageCode: languageCode))
        }
        return lines
    }

    static func formattedStart(_ raw: String, languageCode: String) -> String {
        guard let date = PickupGameModels.parseSupabaseTimestamptz(raw) else {
            return raw
        }
        let locale = Locale(identifier: languageCode)
        let datePart = date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
        let timePart = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
        return "\(datePart) · \(timePart)"
    }

    /// Activity signature fragment covering user-visible schedule/location/roster fields.
    static func activitySignatureFragment(for game: PickupGameRow) -> String {
        [
            normalizedText(game.title),
            normalizedText(game.status),
            normalizedText(game.game_start_at),
            normalizedText(game.end_time),
            locationIdentityKey(for: game),
            "\(PickupGameRow.clampPlayersNeeded(game.players_needed))",
            "\(game.max_players ?? -1)",
            game.is_visible ? "1" : "0",
            normalizedText(game.sport),
            normalizedText(game.skill_level),
            normalizedText(game.play_environment),
            normalizedText(game.participant_preference),
            game.is_free ? "free" : String(format: "%.2f", game.entry_fee_amount ?? 0)
        ].joined(separator: "|")
    }
}
