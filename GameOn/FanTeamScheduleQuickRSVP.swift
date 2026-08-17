import Foundation

// MARK: - RSVP subject (future-ready for parent-managed players)

/// Identity whose attendance a Schedule quick-RSVP strip represents.
///
/// The subject is a roster seat (`membershipId`), which may be either the
/// authenticated viewer or a guardian-managed player on the same Team.
///
/// Authorization stays server-side: `set_fan_team_game_rsvp_for_membership`
/// verifies that the caller either owns the seat or is an active guardian of the
/// managed player, so the presentation layer never decides who may write.
///
/// `nonisolated`: pure value model (UUIDs / strings only). Module default actor
/// isolation is MainActor; this type must stay usable from nonisolated helpers
/// such as ``from(member:)``.
nonisolated struct FanTeamRSVPSubject: Identifiable, Hashable, Sendable {
    var id: UUID { membershipId ?? userId ?? managedPlayerId ?? Self.unidentifiedId }
    /// `fan_team_members.membership_id` — the write key for RSVP.
    ///
    /// Nil where the caller only knows the viewer (e.g. a pickup detail screen
    /// with no Team roster loaded). Those callers keep the unchanged self-RSVP
    /// write path; a managed subject always carries a seat id.
    let membershipId: UUID?
    /// Authenticated subject; nil for a managed player.
    let userId: UUID?
    /// Managed subject; nil for an authenticated member.
    let managedPlayerId: UUID?
    let displayName: String
    let username: String?
    let avatarURL: String?
    let avatarThumbnailURL: String?

    /// Sentinel so `Identifiable` stays total for a subject with no identity at
    /// all — a state the initializers below make unreachable in practice.
    private static let unidentifiedId = UUID(uuidString: "00000000-0000-4000-8000-000000000000")!

    init(
        membershipId: UUID?,
        userId: UUID?,
        managedPlayerId: UUID? = nil,
        displayName: String,
        username: String? = nil,
        avatarURL: String? = nil,
        avatarThumbnailURL: String? = nil
    ) {
        self.membershipId = membershipId
        self.userId = userId
        self.managedPlayerId = managedPlayerId
        self.displayName = displayName
        self.username = username
        self.avatarURL = avatarURL
        self.avatarThumbnailURL = avatarThumbnailURL
    }

    var isManagedPlayer: Bool { managedPlayerId != nil }

    /// Roster attendance is keyed by account `user_id` for adults and by
    /// `managed_player_id` (carried in roster `user_id`) for managed seats.
    var rosterAttendanceUserId: UUID? { userId ?? managedPlayerId }

    /// Name used in “Will %@ be there?” / confirmation copy (never “you”, never UUID/email).
    var promptDisplayName: String {
        Self.resolvePromptDisplayName(
            displayName: displayName,
            username: username
        )
    }

    static func resolvePromptDisplayName(
        displayName: String?,
        username: String?,
        languageCode: String = L10n.defaultLanguageCode
    ) -> String {
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        // Keep this path free of MainActor presentation helpers (FanTeamRosterRowPresentation /
        // FanGeoHandleRules) so the nonisolated value model stays Swift 6-safe.
        var handle = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        while handle.hasPrefix("@") {
            handle.removeFirst()
        }
        handle = handle.lowercased()
        if !handle.isEmpty { return handle }
        return L10n.t("fan_team_schedule_rsvp_player_fallback", languageCode: languageCode)
    }

    /// Pure member → subject conversion (no UI / MainActor dependency).
    /// Works for authenticated members and guardian-managed players alike.
    static func from(member: FanTeamMember) -> FanTeamRSVPSubject {
        FanTeamRSVPSubject(
            membershipId: member.membershipId,
            userId: member.userId,
            managedPlayerId: member.managedPlayerId,
            displayName: member.displayName,
            username: member.username,
            avatarURL: member.avatarURL,
            avatarThumbnailURL: member.avatarThumbnailURL
        )
    }

    /// Current authenticated Team member as RSVP subject (nil for outsiders).
    /// MainActor: resolves via roster presentation helpers that stay UI-adjacent.
    @MainActor
    static func currentViewer(
        from members: [FanTeamMember],
        currentUserId: UUID?
    ) -> FanTeamRSVPSubject? {
        FanTeamMyPlayerInfoPresentation.viewerMember(from: members, currentUserId: currentUserId)
            .map { Self.from(member: $0) }
    }
}

// MARK: - Eligibility / gates

enum FanTeamScheduleQuickRSVPEligibility {
    static func isCancelled(_ game: FanTeamGame) -> Bool {
        let status = game.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return status == "cancelled" || status == "canceled" || status == "removed"
    }

    /// Upcoming + active lifecycle only. Past / cancelled / announcements never show quick RSVP.
    static func showsQuickRSVPControls(game: FanTeamGame, now: Date = Date()) -> Bool {
        guard game.gameType != .announcement else { return false }
        guard FanTeamGamesTimeline.isUpcoming(game, now: now) else { return false }
        guard !isCancelled(game) else { return false }
        return true
    }

    /// Staff exclusion for this Team event (`fan_team_event_exclusions` via roster `excluded`).
    static func isExcludedFromEvent(
        subjectUserId: UUID?,
        gameId: UUID,
        roster: PickupGameRosterPayload?
    ) -> Bool {
        guard let subjectUserId else { return false }
        guard let roster, roster.pickup_game_id == gameId else { return false }
        return roster.excludedMembers.contains(where: { $0.user_id == subjectUserId })
    }
}

// MARK: - Status mapping (reuse attendance / RSVP tokens)

enum FanTeamScheduleQuickRSVPState: Hashable, Sendable {
    case noResponse
    case going
    case maybe
    case cantGo

    var writeStatus: FanTeamGameRSVPStatus? {
        switch self {
        case .noResponse: return nil
        case .going: return .going
        case .maybe: return .maybe
        case .cantGo: return .cant_go
        }
    }

    static func from(rsvp: FanTeamGameRSVPStatus?) -> FanTeamScheduleQuickRSVPState {
        switch rsvp {
        case .going: return .going
        case .maybe: return .maybe
        case .cant_go: return .cantGo
        case .none: return .noResponse
        }
    }

    static func from(attendance: PickupDetailAttendanceCategory?) -> FanTeamScheduleQuickRSVPState {
        switch attendance {
        case .going: return .going
        case .maybe: return .maybe
        case .cantGo: return .cantGo
        case .noResponse, .none: return .noResponse
        }
    }

    /// Prefer a definitive event-scoped self RSVP (`.status`), then this event's
    /// roster attendance. `.unanswered` must NOT suppress roster evidence — a sticky
    /// NULL from `get_fan_team_game_rsvp` previously short-circuited to No Response
    /// even when the same event's roster already had Going / Maybe / Can't Go.
    ///
    /// Never invent Going from organizer role alone (roster presentation already
    /// gates Team organizer synthesis).
    static func resolve(
        subjectUserId: UUID?,
        roster: PickupGameRosterPayload?,
        explicitSelfRSVP: FanTeamCachedSelfRSVP?,
        fallbackRSVP: FanTeamGameRSVPStatus?
    ) -> FanTeamScheduleQuickRSVPState {
        if case .status(let status) = explicitSelfRSVP {
            return from(rsvp: status)
        }
        if let subjectUserId, let roster {
            let row = PickupTeamAttendancePresentation.rows(from: roster)
                .first { $0.id == subjectUserId }
            if let row {
                return from(attendance: row.category)
            }
        }
        if case .unanswered = explicitSelfRSVP {
            return .noResponse
        }
        return from(rsvp: fallbackRSVP)
    }

    /// Backward-compatible overload used by older call sites / tests.
    static func resolve(
        subjectUserId: UUID?,
        roster: PickupGameRosterPayload?,
        fallbackRSVP: FanTeamGameRSVPStatus?
    ) -> FanTeamScheduleQuickRSVPState {
        resolve(
            subjectUserId: subjectUserId,
            roster: roster,
            explicitSelfRSVP: nil,
            fallbackRSVP: fallbackRSVP
        )
    }
}

// MARK: - User-facing error mapping

enum FanTeamRSVPErrorMapping {
    /// Maps backend tokens (e.g. pickup_request_decision_forbidden) to localized copy.
    /// Raw messages remain in DEBUG logs only.
    static func userFacingMessage(for error: Error, languageCode: String) -> String {
        let raw = error.localizedDescription
#if DEBUG
        print("[TeamRSVPDebug] mapping_user_facing raw=\(raw)")
#endif
        let lowered = raw.lowercased()
        if lowered.contains("pickup_request_decision_forbidden")
            || lowered.contains("pickup_request_cancel_forbidden")
            || lowered.contains("pickup_request_status_forbidden")
            || lowered.contains("not a participant for this team game")
            || lowered.contains("invalid rsvp status")
            || lowered.contains("game not found")
            || lowered.contains("not authenticated") {
            return L10n.t("fan_team_rsvp_update_failed_message", languageCode: languageCode)
        }
        // Prefer generic attendance copy over leaking opaque backend tokens.
        if lowered.contains("forbidden") || lowered.contains("42501") || lowered.contains("check_violation") {
            return L10n.t("fan_team_rsvp_update_failed_message", languageCode: languageCode)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return L10n.t("fan_team_rsvp_update_failed_message", languageCode: languageCode)
        }
        // Still avoid bare machine tokens as the only message.
        if trimmed.contains("_") && !trimmed.contains(" ") {
            return L10n.t("fan_team_rsvp_update_failed_message", languageCode: languageCode)
        }
        return trimmed
    }
}

// MARK: - Copy

enum FanTeamScheduleQuickRSVPCopy {
    static func prompt(subjectName: String, languageCode: String) -> String {
        String(
            format: L10n.t("fan_team_schedule_rsvp_will_be_there_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            subjectName
        )
    }

    static func confirmed(state: FanTeamScheduleQuickRSVPState, subjectName: String, languageCode: String) -> String {
        let key: String
        switch state {
        case .going:
            key = "fan_team_schedule_rsvp_is_going_format"
        case .maybe:
            key = "fan_team_schedule_rsvp_may_be_going_format"
        case .cantGo:
            key = "fan_team_schedule_rsvp_cant_go_format"
        case .noResponse:
            return prompt(subjectName: subjectName, languageCode: languageCode)
        }
        return String(
            format: L10n.t(key, languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            subjectName
        )
    }

    static func markGoingA11y(subjectName: String, languageCode: String) -> String {
        String(
            format: L10n.t("fan_team_schedule_rsvp_mark_going_a11y_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            subjectName
        )
    }

    static func markCantGoA11y(subjectName: String, languageCode: String) -> String {
        String(
            format: L10n.t("fan_team_schedule_rsvp_mark_cant_go_a11y_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            subjectName
        )
    }

    static func changeA11y(subjectName: String, languageCode: String) -> String {
        String(
            format: L10n.t("fan_team_schedule_rsvp_change_a11y_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            subjectName
        )
    }

    /// Menu labels — aggregate wording (not “I’m Going”).
    static func menuTitle(for status: FanTeamGameRSVPStatus, languageCode: String) -> String {
        switch status {
        case .going:
            return L10n.t("Going", languageCode: languageCode)
        case .maybe:
            return L10n.t("Maybe", languageCode: languageCode)
        case .cant_go:
            return L10n.t("fan_team_rsvp_cant_go", languageCode: languageCode)
        }
    }
}

// MARK: - Location (Team Schedule / event cards)

/// Canonical human-readable location line for Team Schedule (and similar) cards.
///
/// Root cause of duplicates: cards previously joined `venueName · address · city · state`
/// blindly. Pickup forms often store the same place in both `venue_name`/`address`, and
/// `city` + `state` (state may already include ZIP). Fields can also already contain
/// ` · `-joined concatenations. This helper flattens, normalizes, dedupes, and rebuilds.
enum FanTeamScheduleLocationPresentation {
    /// Alias preferred by newer call sites / docs.
    static func displayLocation(
        venueName: String?,
        address: String?,
        city: String?,
        state: String?
    ) -> String {
        line(venueName: venueName, address: address, city: city, state: state)
    }

    /// Collapses a preformatted location string that repeats the same locality,
    /// e.g. `Draper, UT 84020, Draper, UT 84020`.
    static func collapsedLine(_ raw: String?) -> String {
        guard let trimmed = normalize(raw) else { return "" }
        for sep in [", ", " · "] {
            let parts = trimmed
                .components(separatedBy: sep)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard parts.count >= 2, parts.count.isMultiple(of: 2) else { continue }
            let half = parts.count / 2
            let left = Array(parts[..<half])
            let right = Array(parts[half...])
            let same = zip(left, right).allSatisfy { lhs, rhs in
                normalized(lhs) == normalized(rhs)
            }
            if same {
                return left.joined(separator: sep)
            }
        }
        return line(venueName: trimmed, address: nil, city: nil, state: nil)
    }

    static func line(
        venueName: String?,
        address: String?,
        city: String?,
        state: String?
    ) -> String {
        let atoms = uniqueAtoms(from: [venueName, address, city, state])
        guard !atoms.isEmpty else { return "" }

        // Call via closure (not `.map(firstSegment)`): with module MainActor default
        // isolation, passing an isolated method as a function value warns.
        var cityOut = normalize(city).map { firstSegment($0) }
        let stateBits = PickupGameAppleCalendarLocation.splitRegionAndPostal(normalize(state))
        var region = stateBits.region
        var postal = stateBits.postalCode
        if PickupGameAppleCalendarLocation.tokensEqual(cityOut, region) {
            region = nil
        }

        var street: String?
        var place: String?

        for atom in atoms {
            if isCoveredByLocality(atom, city: cityOut, region: region, postal: postal) {
                continue
            }
            if let parsed = parseCombinedLocality(atom) {
                if cityOut == nil { cityOut = parsed.city }
                if region == nil { region = parsed.region }
                if postal == nil { postal = parsed.postal }
                if PickupGameAppleCalendarLocation.tokensEqual(cityOut, region) {
                    region = nil
                }
                continue
            }
            if looksLikeStreet(atom) {
                if street == nil || atom.count > (street?.count ?? 0) {
                    street = atom
                }
                continue
            }
            // Non-street leftover → venue / place name (skip if it only repeats city).
            if PickupGameAppleCalendarLocation.tokensEqual(atom, cityOut) { continue }
            if place == nil {
                place = atom
            } else if atom.count > place!.count, !normalized(place!).contains(normalized(atom)) {
                // Prefer longer distinctive place label when not a subset.
                place = atom
            }
        }

        // If address/venue still embeds locality after classification, strip it.
        if let s = street {
            street = stripEmbeddedLocality(s, city: cityOut, region: region, postal: postal)
        }
        if let p = place {
            place = stripEmbeddedLocality(p, city: cityOut, region: region, postal: postal)
            if place?.isEmpty == true { place = nil }
            if PickupGameAppleCalendarLocation.tokensEqual(place, street) {
                place = nil
            }
        }

        var parts: [String] = []
        if let place, !(place.isEmpty) {
            parts.append(place)
        }
        if let street, !(street.isEmpty) {
            parts.append(street)
        }
        if let locality = PickupGameAppleCalendarLocation.localityLine(
            city: cityOut,
            region: region,
            postalCode: postal
        ) {
            // Avoid "Draper, UT 84020 · Draper, UT 84020" when place/street already is that line.
            if !parts.contains(where: { normalized($0) == normalized(locality) }) {
                parts.append(locality)
            }
        }

        // Final pass: drop any part fully contained in a longer sibling.
        return collapseContained(parts).joined(separator: " · ")
    }

    // MARK: - Internals

    private static func uniqueAtoms(from fields: [String?]) -> [String] {
        var out: [String] = []
        for field in fields {
            guard let field = normalize(field) else { continue }
            for piece in field.components(separatedBy: " · ") {
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let norm = normalized(trimmed)
                if let idx = out.firstIndex(where: { normalized($0) == norm }) {
                    // Prefer longer spelling of the same atom.
                    if trimmed.count > out[idx].count {
                        out[idx] = trimmed
                    }
                    continue
                }
                // Replace shorter atom that is a strict subset of this one (token containment).
                if let idx = out.firstIndex(where: { normalized(trimmed).contains(normalized($0)) && normalized(trimmed) != normalized($0) }) {
                    out[idx] = trimmed
                    continue
                }
                if out.contains(where: { normalized($0).contains(norm) && normalized($0) != norm }) {
                    continue
                }
                out.append(trimmed)
            }
        }
        return out
    }

    private static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Pure string helper; `nonisolated` so it remains usable as a value transform
    /// under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
    nonisolated private static func firstSegment(_ raw: String) -> String {
        raw.components(separatedBy: " · ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? raw
    }

    private static func normalized(_ raw: String) -> String {
        raw
            .lowercased()
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func looksLikeStreet(_ raw: String) -> Bool {
        // Locality lines often include a ZIP digit ("Sandy, UT 84070") — those are not streets.
        if parseCombinedLocality(raw) != nil { return false }
        let regionPostal = PickupGameAppleCalendarLocation.splitRegionAndPostal(raw)
        if regionPostal.postalCode != nil {
            let region = regionPostal.region?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Bare "UT 84070" / "84070".
            if region.isEmpty || region.count <= 3 { return false }
        }
        // Prefer lines that begin with a street number.
        return raw.range(of: #"^\s*\d"#, options: .regularExpression) != nil
    }

    /// "Draper, UT 84020" / "Sandy, UT" / "Paris, Île-de-France".
    private static func parseCombinedLocality(
        _ raw: String
    ) -> (city: String?, region: String?, postal: String?)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(",") else { return nil }
        let chunks = trimmed
            .split(separator: ",", maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard chunks.count == 2 else { return nil }
        let city = chunks[0]
        let rest = PickupGameAppleCalendarLocation.splitRegionAndPostal(chunks[1])
        // Require region or postal so bare "Name, Nickname" place titles aren't treated as locality.
        guard rest.region != nil || rest.postalCode != nil else { return nil }
        return (city, rest.region, rest.postalCode)
    }

    private static func isCoveredByLocality(
        _ atom: String,
        city: String?,
        region: String?,
        postal: String?
    ) -> Bool {
        let norm = normalized(atom)
        if let city, normalized(city) == norm { return true }
        if let region, normalized(region) == norm { return true }
        if let postal, normalized(postal) == norm { return true }
        if let region, let postal {
            if normalized("\(region) \(postal)") == norm { return true }
        }
        if let locality = PickupGameAppleCalendarLocation.localityLine(
            city: city,
            region: region,
            postalCode: postal
        ), normalized(locality) == norm {
            return true
        }
        return false
    }

    private static func stripEmbeddedLocality(
        _ line: String,
        city: String?,
        region: String?,
        postal: String?
    ) -> String {
        var result = line
        let candidates = [
            PickupGameAppleCalendarLocation.localityLine(city: city, region: region, postalCode: postal),
            city,
            region,
            postal,
            region.flatMap { r in postal.map { "\(r) \($0)" } }
        ].compactMap { $0 }
        for component in candidates {
            result = PickupGameAppleCalendarLocation.stripTrailingComponent(result, matching: component)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collapseContained(_ parts: [String]) -> [String] {
        var result: [String] = []
        for part in parts {
            let norm = normalized(part)
            guard !norm.isEmpty else { continue }
            if result.contains(where: { normalized($0) == norm }) { continue }
            if let idx = result.firstIndex(where: {
                let existing = normalized($0)
                return existing.contains(norm) || norm.contains(existing)
            }) {
                if part.count > result[idx].count {
                    result[idx] = part
                }
                continue
            }
            result.append(part)
        }
        return result
    }
}

/// Doc alias — same canonical Team event location formatter.
typealias FanTeamEventLocationPresentation = FanTeamScheduleLocationPresentation
