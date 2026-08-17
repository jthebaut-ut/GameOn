import Foundation

// MARK: - Team-scoped Player Info subject

/// A Team Overview Player Info subject: one participant seat the viewer may represent.
///
/// Canonical identity is `membershipId` (`fan_team_members.membership_id`), matching
/// RSVP / lineup / attendance seat keys. Choosing a subject does not rewrite membership
/// or guardian relations — it persists the viewer's Overview preference for that Team.
struct FanTeamPlayerInfoSubject: Identifiable, Hashable, Sendable {
    var id: UUID { membershipId }
    /// `fan_team_members.membership_id` — selection key for this card.
    let membershipId: UUID
    /// Roster (or seat-projected) member fields for display.
    let member: FanTeamMember
    /// True when this seat is the authenticated viewer's own account membership.
    let isViewerAccountSeat: Bool

    var isManagedPlayer: Bool { member.isManagedPlayer }

    /// Future RSVP / lineup / attendance reuse without a second identity system.
    var rsvpSubject: FanTeamRSVPSubject { FanTeamRSVPSubject.from(member: member) }

    var participantIdentity: TeamParticipantIdentity? { member.participantIdentity }
}

// MARK: - Presentation (eligible subjects + selection)

extension FanTeamMyPlayerInfoPresentation {
    /// Team-scoped seats the viewer is authorized to view as Player Info subjects.
    ///
    /// Includes:
    /// - the viewer's own account seat when present on this Team
    /// - managed-player seats returned by `list_my_managed_players_on_team` for this Team
    ///
    /// Does **not** include managed players who are only on other Teams.
    static func eligibleSubjects(
        members: [FanTeamMember],
        currentUserId: UUID?,
        managedSeats: [FanTeamManagedPlayerSeat]
    ) -> [FanTeamPlayerInfoSubject] {
        var subjects: [FanTeamPlayerInfoSubject] = []
        var seenMembershipIds = Set<UUID>()

        if let selfMember = viewerMember(from: members, currentUserId: currentUserId),
           selfMember.isPlayer {
            subjects.append(
                FanTeamPlayerInfoSubject(
                    membershipId: selfMember.membershipId,
                    member: selfMember,
                    isViewerAccountSeat: true
                )
            )
            seenMembershipIds.insert(selfMember.membershipId)
        }

        let membersByMembershipId = Dictionary(
            members.map { ($0.membershipId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let membersByManagedPlayerId = Dictionary(
            members.compactMap { member -> (UUID, FanTeamMember)? in
                guard let managedId = member.managedPlayerId else { return nil }
                return (managedId, member)
            },
            uniquingKeysWith: { first, _ in first }
        )

        for seat in managedSeats {
            if seenMembershipIds.contains(seat.id) { continue }
            let rosterMember =
                membersByMembershipId[seat.id]
                ?? membersByManagedPlayerId[seat.managedPlayerId]
            let member = enrich(member: rosterMember, seat: seat)
            subjects.append(
                FanTeamPlayerInfoSubject(
                    membershipId: member.membershipId,
                    member: member,
                    isViewerAccountSeat: false
                )
            )
            seenMembershipIds.insert(member.membershipId)
        }

        return subjects
    }

    /// Hide the card when the viewer has no representable seat on this Team.
    static func shouldShow(subjects: [FanTeamPlayerInfoSubject]) -> Bool {
        !subjects.isEmpty
    }

    /// Overview section: players linked to this account for this Team.
    static let overviewSectionTitleKey = "team_overview_players_from_your_account"

    /// Helper under the Overview section title.
    static let overviewSectionHelperKey = "team_overview_players_from_your_account_helper"

    /// Account-self first, then managed players A→Z by display name.
    static func orderedForOverview(_ subjects: [FanTeamPlayerInfoSubject]) -> [FanTeamPlayerInfoSubject] {
        let selfSeats = subjects.filter(\.isViewerAccountSeat)
        let managed = subjects
            .filter { !$0.isViewerAccountSeat }
            .sorted {
                $0.member.displayName.localizedCaseInsensitiveCompare($1.member.displayName) == .orderedAscending
            }
        return selfSeats + managed
    }

    /// "Myself" / "Managed Player" — never invents leadership roles for managed seats.
    static func identityCaption(
        subject: FanTeamPlayerInfoSubject,
        languageCode: String
    ) -> String {
        L10n.t(selectorSubtitleKey(subject: subject), languageCode: languageCode)
    }

    /// `#12 · Center Back` — omits missing jersey and/or position (never "Not set").
    static func jerseyPositionLine(
        subject: FanTeamPlayerInfoSubject,
        sportToken: String?,
        languageCode: String
    ) -> String? {
        headerManagedSummary(
            playerNumber: subject.member.playerNumber,
            preferredPositionCode: subject.member.preferredPositionCode,
            sportToken: sportToken,
            languageCode: languageCode
        )
    }

    /// `Member since Aug 11, 2026` — omitted when `joined_at` is missing (never "Not set").
    static func memberSinceLine(
        subject: FanTeamPlayerInfoSubject,
        languageCode: String
    ) -> String? {
        guard let date = FanManagedPlayerPresentation.memberSinceMediumDate(
            subject.member.joinedAt,
            languageCode: languageCode
        ) else {
            return nil
        }
        return String(
            format: L10n.t("managed_players_member_since_format", languageCode: languageCode),
            locale: Locale(identifier: L10n.normalizedLanguageCode(languageCode)),
            date
        )
    }

    static func overviewRowAccessibilityLabel(
        subject: FanTeamPlayerInfoSubject,
        sportToken: String?,
        languageCode: String
    ) -> String {
        var parts: [String] = [
            subject.member.displayName,
            identityCaption(subject: subject, languageCode: languageCode)
        ]
        if let jerseyPosition = jerseyPositionLine(
            subject: subject,
            sportToken: sportToken,
            languageCode: languageCode
        ) {
            parts.append(jerseyPosition)
        }
        if let since = memberSinceLine(subject: subject, languageCode: languageCode) {
            parts.append(since)
        }
        return parts.joined(separator: ", ")
    }

    /// Title: "My Player Info" only for a single account-self subject; otherwise "Player Info".
    static func titleKey(subjects: [FanTeamPlayerInfoSubject]) -> String {
        if subjects.count == 1, subjects[0].isViewerAccountSeat {
            return "fan_teams_my_player_info"
        }
        return "managed_players_player_info"
    }

    static func showsChangeControl(subjects: [FanTeamPlayerInfoSubject]) -> Bool {
        subjects.count >= 2
    }

    /// Default / reconcile selection by `membership_id`.
    ///
    /// Order: previously selected valid → account self → first managed seat.
    static func resolveSelectedMembershipId(
        preferred: UUID?,
        subjects: [FanTeamPlayerInfoSubject]
    ) -> UUID? {
        guard !subjects.isEmpty else { return nil }
        if let preferred, subjects.contains(where: { $0.membershipId == preferred }) {
            return preferred
        }
        if let selfSeat = subjects.first(where: \.isViewerAccountSeat) {
            return selfSeat.membershipId
        }
        return subjects.first?.membershipId
    }

    static func subject(
        membershipId: UUID?,
        in subjects: [FanTeamPlayerInfoSubject]
    ) -> FanTeamPlayerInfoSubject? {
        guard let membershipId else { return nil }
        return subjects.first { $0.membershipId == membershipId }
    }

    /// Header secondary line under the display name.
    static func headerSecondarySummary(
        subject: FanTeamPlayerInfoSubject,
        sportToken: String?,
        languageCode: String,
        showsChangeControl: Bool
    ) -> String? {
        if subject.isViewerAccountSeat {
            // Multi-subject: "Myself". Single "My Player Info": keep @handle when present.
            if showsChangeControl {
                return L10n.t("team_player_selector_myself", languageCode: languageCode)
            }
            return FanTeamRosterRowPresentation.parentheticalHandle(username: subject.member.username)
        }
        return headerManagedSummary(
            playerNumber: subject.member.playerNumber,
            preferredPositionCode: subject.member.preferredPositionCode,
            sportToken: sportToken,
            languageCode: languageCode
        )
    }

    /// Selector / Change-sheet subtitle.
    static func selectorSubtitleKey(subject: FanTeamPlayerInfoSubject) -> String {
        subject.isViewerAccountSeat
            ? "team_player_selector_myself"
            : "team_invite_managed_caption"
    }

    /// Username is account-only; managed seats never expose social handles.
    static func showsUsername(subject: FanTeamPlayerInfoSubject) -> Bool {
        subject.isViewerAccountSeat && !subject.member.isManagedPlayer
    }

    /// Jersey · Position (long name) for managed-player header chips.
    static func headerManagedSummary(
        playerNumber: Int?,
        preferredPositionCode: String?,
        sportToken: String?,
        languageCode: String
    ) -> String? {
        let numberLabel: String? = {
            guard let playerNumber, FanTeamPlayerNumber.isValid(playerNumber) else { return nil }
            return FanTeamPlayerNumber.displayLabel(playerNumber)
        }()
        let positionLabel: String? = {
            let normalized = preferredPositionCode?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased() ?? ""
            guard !normalized.isEmpty else { return nil }
            if let catalog = FanTeamSportPositions.position(code: normalized, sportToken: sportToken) {
                return catalog.accessibilityLabel(languageCode: languageCode)
            }
            return normalized
        }()
        switch (numberLabel, positionLabel) {
        case let (number?, position?):
            return "\(number) · \(position)"
        case let (number?, nil):
            return number
        case let (nil, position?):
            return position
        case (nil, nil):
            return nil
        }
    }

    /// Merge roster row with Team-scoped managed seat (position may be missing on roster RPC).
    static func enrich(
        member: FanTeamMember?,
        seat: FanTeamManagedPlayerSeat
    ) -> FanTeamMember {
        if let member {
            let displayName = member.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return FanTeamMember(
                membershipId: member.membershipId,
                userId: nil,
                managedPlayerId: member.managedPlayerId ?? seat.managedPlayerId,
                role: member.role,
                joinedAt: member.joinedAt ?? seat.joinedAt,
                displayName: displayName.isEmpty ? seat.displayName : member.displayName,
                username: nil,
                avatarURL: member.avatarURL ?? seat.avatarURL,
                avatarThumbnailURL: member.avatarThumbnailURL ?? seat.avatarThumbnailURL,
                lastSeenAtRaw: nil,
                playerNumber: member.playerNumber ?? seat.playerNumber,
                preferredPositionCode: member.preferredPositionCode ?? seat.preferredPositionCode,
                genderRaw: nil
            )
        }
        return FanTeamMember(
            membershipId: seat.id,
            userId: nil,
            managedPlayerId: seat.managedPlayerId,
            role: .member,
            joinedAt: seat.joinedAt,
            displayName: seat.displayName,
            username: nil,
            avatarURL: seat.avatarURL,
            avatarThumbnailURL: seat.avatarThumbnailURL,
            lastSeenAtRaw: nil,
            playerNumber: seat.playerNumber,
            preferredPositionCode: seat.preferredPositionCode,
            genderRaw: nil
        )
    }
}
