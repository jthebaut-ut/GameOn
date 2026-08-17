import Foundation

/// Source discriminator for Going → Play cards. Pickup and Team stay distinct
/// models; this is the UI/projection layer only.
enum GoingPlaySource: String, Equatable, Sendable {
    case pickup
    case team
}

/// Visible Going → Play filter. Not a three-page Playing/Hosting/Invites layout.
enum GoingPlayFilter: String, CaseIterable, Hashable, Sendable {
    case all
    case hosting
    case invites
    case pickups
    case teamEvents

    var titleKey: String {
        switch self {
        case .all: return "going_play_filter_all"
        case .hosting: return "going_play_filter_hosting"
        case .invites: return "going_play_filter_invites"
        case .pickups: return "going_play_filter_pickups"
        case .teamEvents: return "going_play_filter_team_events"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "figure.run"
        case .hosting: return "person.3.fill"
        case .invites: return "envelope.fill"
        case .pickups: return "figure.run"
        case .teamEvents: return "shield.fill"
        }
    }
}

/// Canonical participation chip on a Going → Play card. Values map to existing
/// join/RSVP tokens — never invented solely for UI.
enum GoingPlayParticipationState: String, Equatable, Sendable {
    case approved
    case going
    case pending
    case invited
    case declined
    case full
    case completed
    case started

    func titleKey() -> String {
        switch self {
        case .approved: return "pickup_host_participant_status_approved"
        case .going: return "Going"
        case .pending: return "pickup_join_status_pending"
        case .invited: return "going_play_status_invited"
        case .declined: return "pickup_join_status_rejected"
        case .full: return "pickup_status_full"
        case .completed: return "Completed"
        case .started: return "Started"
        }
    }
}

/// One row in the Going → Play unified feed.
struct GoingPlayFeedItem: Identifiable, Equatable {
    /// Stable list id. Pickup playing uses the join-request id; everything else
    /// uses `pickupGameId`.
    let id: UUID
    let pickupGameId: UUID
    let source: GoingPlaySource
    let title: String
    let sport: String
    let sportSubtype: String?
    let eventType: GameType
    let eventTypeLabel: String
    let participation: GoingPlayParticipationState?
    let isFull: Bool
    let startAt: Date
    let dateTimeLine: String
    let locationLine: String
    let teamIdentity: PickupDiscoverTeamIdentity?
    let organizerUserId: UUID?
    let organizerName: String?
    let viaManagedPlayerNames: [String]
    let pickupCard: PickupGameJoinRequestCardDisplay?
    let hostedRowId: UUID?
    let inviteId: UUID?

    func withPresentation(dateTimeLine: String? = nil, locationLine: String? = nil) -> GoingPlayFeedItem {
        with(
            participation: participation,
            dateTimeLine: dateTimeLine ?? self.dateTimeLine,
            locationLine: locationLine ?? self.locationLine
        )
    }

    func withParticipation(_ participation: GoingPlayParticipationState?) -> GoingPlayFeedItem {
        with(participation: participation, dateTimeLine: dateTimeLine, locationLine: locationLine)
    }

    private func with(
        participation: GoingPlayParticipationState?,
        dateTimeLine: String,
        locationLine: String
    ) -> GoingPlayFeedItem {
        GoingPlayFeedItem(
            id: id,
            pickupGameId: pickupGameId,
            source: source,
            title: title,
            sport: sport,
            sportSubtype: sportSubtype,
            eventType: eventType,
            eventTypeLabel: eventTypeLabel,
            participation: participation,
            isFull: isFull,
            startAt: startAt,
            dateTimeLine: dateTimeLine,
            locationLine: locationLine,
            teamIdentity: teamIdentity,
            organizerUserId: organizerUserId,
            organizerName: organizerName,
            viaManagedPlayerNames: viaManagedPlayerNames,
            pickupCard: pickupCard,
            hostedRowId: hostedRowId,
            inviteId: inviteId
        )
    }
}

/// Guardian-sourced Team event that is not already represented by a pickup join card.
struct GoingPlayTeamParticipation: Identifiable, Equatable, Sendable {
    var id: UUID { pickupGameId }
    let pickupGameId: UUID
    let teamId: UUID
    let teamName: String
    let teamSport: String
    let sportSubtype: String?
    let colorHex: String?
    let logoURL: String?
    let logoThumbnailURL: String?
    let eventType: GameType
    let customTitle: String?
    let opponentName: String?
    let startsAt: Date
    let endsAt: Date?
    let locationLine: String
    let createdBy: UUID
    let viaManagedPlayerNames: [String]
    let isCreator: Bool

    var identity: PickupDiscoverTeamIdentity {
        PickupDiscoverTeamIdentity(
            pickupGameId: pickupGameId,
            teamId: teamId,
            teamName: teamName,
            teamSport: teamSport,
            colorHex: colorHex,
            logoURL: logoURL,
            logoThumbnailURL: logoThumbnailURL,
            displayRefreshToken: nil
        )
    }
}

/// Unified Going → Play projection. Counts MUST be derived from the same arrays
/// that render Playing / Hosting / Invites.
enum GoingPlayProjection {
    // MARK: - Playable vs excluded Team content

    /// Going → Play is for sporting participation. Meetings and announcements stay
    /// on Team Schedule / Inbox / Action Needed.
    static func isPlayableTeamEvent(_ format: GameType) -> Bool {
        switch format {
        case .practice, .scrimmage, .league_game, .tournament_game, .match, .tryout, .clinic, .pickup, .other:
            return true
        case .team_meeting, .announcement:
            return false
        }
    }

    static func isPlayableTeamEvent(_ type: FanTeamGameType) -> Bool {
        isPlayableTeamEvent(GameType(rawValue: type.rawValue) ?? .other)
    }

    static func isExcludedFromPlay(_ format: GameType) -> Bool {
        !isPlayableTeamEvent(format)
    }

    // MARK: - Source

    static func source(
        identity: PickupDiscoverTeamIdentity?,
        format: GameType? = nil
    ) -> GoingPlaySource {
        _ = format
        return identity != nil ? .team : .pickup
    }

    // MARK: - Titles

    /// Canonical Team event identity: custom title → matchup → catalog title → type fallback.
    /// Never returns a UUID.
    static func teamEventTitle(
        customTitle: String?,
        teamName: String,
        opponentName: String?,
        format: GameType,
        sport: String,
        languageCode: String
    ) -> String {
        FanGeoTeamEventNoticeBuilder.gameLabel(
            teamName: teamName,
            customTitle: customTitle,
            gameFormat: format.rawValue,
            opponent: opponentName,
            matchupLabel: FanTeamScheduleMatchup.matchupLine(
                homeTeamName: teamName,
                opponentName: opponentName,
                languageCode: languageCode
            ),
            languageCode: languageCode
        )
    }

    static func eventTypeLabel(
        format: GameType,
        sport: String,
        languageCode: String
    ) -> String {
        FanTeamEventTypeCatalog.displayTitle(for: format, sport: sport, languageCode: languageCode)
    }

    /// Footer subtitle: sport identity for practice; catalog type otherwise.
    static func teamFooterSubtitle(
        format: GameType,
        sport: String,
        sportSubtype: String?,
        languageCode: String
    ) -> String {
        if format == .practice {
            let identity = SportSubtypeCatalog.identityLine(
                sport: sport,
                subtype: sportSubtype,
                languageCode: languageCode
            )
            let trimmed = identity.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return eventTypeLabel(format: format, sport: sport, languageCode: languageCode)
    }

    static func participation(from pill: PickupFollowingJoinRequestPillKind) -> GoingPlayParticipationState? {
        switch pill {
        case .approved: return .approved
        case .pending: return .pending
        case .declined: return .declined
        case .cancelled, .withdrawing, .canceledByOrganizer: return nil
        }
    }

    static func teamPlayingParticipation(
        pill: PickupFollowingJoinRequestPillKind?
    ) -> GoingPlayParticipationState {
        switch pill {
        case .approved: return .approved
        case .pending: return .pending
        case .declined: return .declined
        case .none, .cancelled, .withdrawing, .canceledByOrganizer: return .going
        }
    }

    // MARK: - Playing

    /// Playing = pickup join cards (non-team) + playable Team join cards + managed-player
    /// Team Going items not already represented by a join card.
    ///
    /// Hosted games the viewer created stay on Hosting (existing Going precedent:
    /// organizers do not also occupy Playing via a self join request). Managed-player
    /// Going on a game the guardian created may still appear here with a Via chip.
    static func playingItems(
        pickupCards: [PickupGameJoinRequestCardDisplay],
        resolvedGame: (UUID) -> PickupGameRow?,
        teamIdentities: [UUID: PickupDiscoverTeamIdentity],
        teamParticipations: [GoingPlayTeamParticipation],
        hostedGameIds: Set<UUID>,
        languageCode: String,
        now: Date
    ) -> [GoingPlayFeedItem] {
        var items: [GoingPlayFeedItem] = []
        var seenPickupIds = Set<UUID>()

        for card in pickupCards {
            let game = resolvedGame(card.pickupGameId)
            let format = game?.gameFormat ?? .pickup
            let identity = teamIdentities[card.pickupGameId]
            let src = source(identity: identity, format: format)
            if src == .team, isExcludedFromPlay(format) {
                continue
            }
            seenPickupIds.insert(card.pickupGameId)
            let start = PickupGameModels.parseSupabaseTimestamptz(card.game_start_at) ?? .distantFuture
            let title: String = {
                if src == .team {
                    return teamEventTitle(
                        customTitle: game?.title ?? card.title,
                        teamName: identity?.teamName ?? card.title,
                        opponentName: game?.opponent_name,
                        format: format,
                        sport: game?.sport ?? card.sport,
                        languageCode: languageCode
                    )
                }
                return card.title
            }()
            let sport = game?.sport ?? card.sport
            items.append(
                GoingPlayFeedItem(
                    id: card.id,
                    pickupGameId: card.pickupGameId,
                    source: src,
                    title: title,
                    sport: sport,
                    sportSubtype: game?.sport_subtype,
                    eventType: format,
                    eventTypeLabel: eventTypeLabel(format: format, sport: sport, languageCode: languageCode),
                    participation: src == .team
                        ? teamPlayingParticipation(pill: card.pill)
                        : participation(from: card.pill),
                    isFull: game?.isPickupFullForDiscover ?? false,
                    startAt: start,
                    dateTimeLine: card.dateTimeLine,
                    locationLine: card.locationLine,
                    teamIdentity: identity,
                    organizerUserId: card.organizerUserId,
                    organizerName: card.organizerName,
                    viaManagedPlayerNames: [],
                    pickupCard: card,
                    hostedRowId: nil,
                    inviteId: nil
                )
            )
        }

        for part in teamParticipations {
            if seenPickupIds.contains(part.pickupGameId) { continue }
            if !isPlayableTeamEvent(part.eventType) { continue }
            if part.isCreator, hostedGameIds.contains(part.pickupGameId), part.viaManagedPlayerNames.isEmpty {
                continue
            }
            seenPickupIds.insert(part.pickupGameId)
            let sport = part.teamSport
            items.append(
                GoingPlayFeedItem(
                    id: part.pickupGameId,
                    pickupGameId: part.pickupGameId,
                    source: .team,
                    title: teamEventTitle(
                        customTitle: part.customTitle,
                        teamName: part.teamName,
                        opponentName: part.opponentName,
                        format: part.eventType,
                        sport: sport,
                        languageCode: languageCode
                    ),
                    sport: sport,
                    sportSubtype: part.sportSubtype,
                    eventType: part.eventType,
                    eventTypeLabel: eventTypeLabel(
                        format: part.eventType,
                        sport: sport,
                        languageCode: languageCode
                    ),
                    participation: .going,
                    isFull: false,
                    startAt: part.startsAt,
                    dateTimeLine: "",
                    locationLine: part.locationLine,
                    teamIdentity: part.identity,
                    organizerUserId: part.createdBy,
                    organizerName: nil,
                    viaManagedPlayerNames: part.viaManagedPlayerNames,
                    pickupCard: nil,
                    hostedRowId: nil,
                    inviteId: nil
                )
            )
        }

        return sortChronologically(items, now: now)
    }

    // MARK: - Hosting

    /// Hosting = games the current account created (`myPickupGamesForSettings`).
    /// Team Owner/Manager role alone does **not** put every Team event here.
    /// Team Meeting / Announcement are excluded from Play Hosting.
    static func hostingItems(
        hostedRows: [PickupGameRow],
        teamIdentities: [UUID: PickupDiscoverTeamIdentity],
        languageCode: String,
        now: Date
    ) -> [GoingPlayFeedItem] {
        var items: [GoingPlayFeedItem] = []
        var seen = Set<UUID>()
        for row in hostedRows {
            if !seen.insert(row.id).inserted { continue }
            let identity = teamIdentities[row.id]
            let src = source(identity: identity, format: row.gameFormat)
            if src == .team, isExcludedFromPlay(row.gameFormat) {
                continue
            }
            let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) ?? .distantFuture
            let title: String = {
                if src == .team {
                    return teamEventTitle(
                        customTitle: row.title,
                        teamName: identity?.teamName ?? row.title,
                        opponentName: row.opponent_name,
                        format: row.gameFormat,
                        sport: row.sport,
                        languageCode: languageCode
                    )
                }
                return row.title
            }()
            items.append(
                GoingPlayFeedItem(
                    id: row.id,
                    pickupGameId: row.id,
                    source: src,
                    title: title,
                    sport: row.sport,
                    sportSubtype: row.sport_subtype,
                    eventType: row.gameFormat,
                    eventTypeLabel: eventTypeLabel(
                        format: row.gameFormat,
                        sport: row.sport,
                        languageCode: languageCode
                    ),
                    participation: nil,
                    isFull: row.isPickupFullForDiscover,
                    startAt: start,
                    dateTimeLine: "",
                    locationLine: "",
                    teamIdentity: identity,
                    organizerUserId: row.creator_user_id,
                    organizerName: nil,
                    viaManagedPlayerNames: [],
                    pickupCard: nil,
                    hostedRowId: row.id,
                    inviteId: nil
                )
            )
        }
        return sortChronologically(items, now: now)
    }

    // MARK: - Invites

    /// Pickup invitations unchanged. Team-linked invite rows keep the same invite
    /// actions and only change source chrome. Unanswered Team RSVP is **not** an
    /// invite (Action Needed owns that contract).
    static func inviteItems(
        invites: [PickupGameInviteDisplay],
        teamIdentities: [UUID: PickupDiscoverTeamIdentity],
        languageCode: String,
        now: Date
    ) -> [GoingPlayFeedItem] {
        var items: [GoingPlayFeedItem] = []
        for invite in invites {
            let game = invite.game
            let identity = teamIdentities[game.id]
            let src = source(identity: identity, format: game.gameFormat)
            if src == .team, isExcludedFromPlay(game.gameFormat) {
                continue
            }
            let start = PickupGameModels.parseSupabaseTimestamptz(game.game_start_at) ?? .distantFuture
            let title: String = {
                if src == .team {
                    return teamEventTitle(
                        customTitle: game.title,
                        teamName: identity?.teamName ?? game.title,
                        opponentName: game.opponent_name,
                        format: game.gameFormat,
                        sport: game.sport,
                        languageCode: languageCode
                    )
                }
                return game.title
            }()
            items.append(
                GoingPlayFeedItem(
                    id: invite.id,
                    pickupGameId: game.id,
                    source: src,
                    title: title,
                    sport: game.sport,
                    sportSubtype: game.sport_subtype,
                    eventType: game.gameFormat,
                    eventTypeLabel: eventTypeLabel(
                        format: game.gameFormat,
                        sport: game.sport,
                        languageCode: languageCode
                    ),
                    participation: .invited,
                    isFull: game.isPickupFullForDiscover,
                    startAt: start,
                    dateTimeLine: "",
                    locationLine: "",
                    teamIdentity: identity,
                    organizerUserId: game.creator_user_id,
                    organizerName: nil,
                    viaManagedPlayerNames: [],
                    pickupCard: nil,
                    hostedRowId: nil,
                    inviteId: invite.id
                )
            )
        }
        return sortChronologically(items, now: now)
    }

    static func compactCountBadge(_ count: Int) -> String {
        count > 9 ? "9+" : "\(max(0, count))"
    }

    static func locationLine(for row: PickupGameRow) -> String {
        FanTeamScheduleLocationPresentation.displayLocation(
            venueName: nil,
            address: row.address,
            city: row.city,
            state: row.state
        )
    }

    /// One chronological feed. Playing wins over hosting over invites for the same
    /// `pickupGameId` so an event is never listed twice.
    static func unifiedItems(
        playing: [GoingPlayFeedItem],
        hosting: [GoingPlayFeedItem],
        invites: [GoingPlayFeedItem],
        now: Date
    ) -> [GoingPlayFeedItem] {
        var seen = Set<UUID>()
        var out: [GoingPlayFeedItem] = []
        for item in playing + hosting + invites {
            if seen.insert(item.pickupGameId).inserted {
                out.append(item)
            }
        }
        return sortChronologically(out, now: now)
    }

    static func filteredItems(
        unified: [GoingPlayFeedItem],
        hosting: [GoingPlayFeedItem],
        invites: [GoingPlayFeedItem],
        filter: GoingPlayFilter
    ) -> [GoingPlayFeedItem] {
        switch filter {
        case .all:
            return unified
        case .hosting:
            return hosting
        case .invites:
            return invites
        case .pickups:
            return unified.filter { $0.source == .pickup }
        case .teamEvents:
            return unified.filter { $0.source == .team }
        }
    }

    struct FilterCounts: Equatable {
        let all: Int
        let hosting: Int
        let invites: Int
        let pickups: Int
        let teamEvents: Int

        func count(for filter: GoingPlayFilter) -> Int {
            switch filter {
            case .all: return all
            case .hosting: return hosting
            case .invites: return invites
            case .pickups: return pickups
            case .teamEvents: return teamEvents
            }
        }
    }

    static func filterCounts(
        unified: [GoingPlayFeedItem],
        hosting: [GoingPlayFeedItem],
        invites: [GoingPlayFeedItem]
    ) -> FilterCounts {
        FilterCounts(
            all: unified.count,
            hosting: hosting.count,
            invites: invites.count,
            pickups: unified.filter { $0.source == .pickup }.count,
            teamEvents: unified.filter { $0.source == .team }.count
        )
    }

    static func emptyTitleKey(for filter: GoingPlayFilter) -> String {
        switch filter {
        case .all: return "going_play_empty_all"
        case .hosting: return "going_play_empty_hosting"
        case .invites: return "going_play_empty_invites"
        case .pickups: return "going_play_empty_pickups"
        case .teamEvents: return "going_play_empty_team_events"
        }
    }

    static func emptySupportingKey(for filter: GoingPlayFilter) -> String {
        switch filter {
        case .all: return "going_play_empty_all_supporting"
        case .hosting: return "going_play_empty_hosting_supporting"
        case .invites: return "going_play_empty_invites_supporting"
        case .pickups: return "going_play_empty_pickups_supporting"
        case .teamEvents: return "going_play_empty_team_events_supporting"
        }
    }

    static func sortChronologically(_ items: [GoingPlayFeedItem], now: Date) -> [GoingPlayFeedItem] {
        _ = now
        return items.sorted { a, b in
            if a.startAt != b.startAt { return a.startAt < b.startAt }
            return a.pickupGameId.uuidString < b.pickupGameId.uuidString
        }
    }

    static func isTeamGameVisibleInGoing(startsAt: Date, endsAt: Date?, now: Date) -> Bool {
        let end = endsAt ?? startsAt.addingTimeInterval(2 * 3600)
        if now < end { return true }
        return GoingTabCompletedGameVisibility.isVisibleInGoingTab(
            completedAt: end,
            isCompleted: true,
            now: now
        )
    }

    static func accessibilityLabel(
        item: GoingPlayFeedItem,
        dateTimeLine: String,
        languageCode: String
    ) -> String {
        var parts: [String] = []
        if item.source == .team {
            let spokenTitle = item.title
                .replacingOccurrences(of: " vs ", with: " versus ", options: .caseInsensitive)
            parts.append(spokenTitle)
            parts.append(L10n.t("going_play_a11y_team", languageCode: languageCode))
        } else {
            parts.append(item.title)
            parts.append(L10n.t("going_play_a11y_pickup", languageCode: languageCode))
        }
        if let participation = item.participation {
            parts.append(L10n.t(participation.titleKey(), languageCode: languageCode))
        }
        let when = dateTimeLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if !when.isEmpty { parts.append(when) }
        let whereLine = item.locationLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if !whereLine.isEmpty { parts.append(whereLine) }
        if let via = item.viaManagedPlayerNames.first, !via.isEmpty {
            parts.append(
                String(
                    format: L10n.t("fan_teams_relationship_via", languageCode: languageCode),
                    locale: Locale(identifier: L10n.normalizedLanguageCode(languageCode)),
                    via
                )
            )
        }
        return parts.joined(separator: ". ")
    }
}
