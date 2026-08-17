import Foundation

/// A guardian-managed Team participant (typically a child) backed by
/// `public.fan_managed_players`.
///
/// Managed players are **Teams-only**. They have no account, no profile, no
/// friendships, no chat identity and never appear in Discover or DMs. Every
/// action on one is performed by an authorized guardian.
struct FanManagedPlayer: Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    var firstName: String
    var lastName: String
    var displayName: String
    var avatarURL: String?
    var avatarThumbnailURL: String?
    /// Year only — never a full date of birth (age banding is the only product need).
    var birthYear: Int?
    var guardianRole: FanManagedPlayerGuardianRole
    /// Active Team memberships this player currently holds.
    var teamCount: Int
    let createdAt: Date?

    init(
        id: UUID,
        firstName: String,
        lastName: String = "",
        displayName: String,
        avatarURL: String? = nil,
        avatarThumbnailURL: String? = nil,
        birthYear: Int? = nil,
        guardianRole: FanManagedPlayerGuardianRole = .guardian,
        teamCount: Int = 0,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.firstName = firstName
        self.lastName = lastName
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.avatarThumbnailURL = avatarThumbnailURL
        self.birthYear = birthYear
        self.guardianRole = guardianRole
        self.teamCount = teamCount
        self.createdAt = createdAt
    }

    var fullName: String {
        [firstName, lastName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Initials for the placeholder avatar (managed players usually have no photo).
    var initials: String {
        let source = fullName.isEmpty ? displayName : fullName
        let parts = source
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
        return parts.joined().uppercased()
    }
}

enum FanManagedPlayerGuardianRole: String, Sendable, CaseIterable {
    case guardian
    case primaryGuardian = "primary_guardian"

    static func parse(_ raw: String?) -> FanManagedPlayerGuardianRole {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "primary_guardian": return .primaryGuardian
        default: return .guardian
        }
    }
}

/// One Team a managed player belongs to (guardian-facing detail screen).
struct FanManagedPlayerTeamMembership: Identifiable, Equatable, Hashable, Sendable {
    /// `fan_team_members.membership_id` — the stable roster seat.
    let id: UUID
    let teamId: UUID
    let teamName: String
    let sport: String
    let logoURL: String?
    let logoThumbnailURL: String?
    let colorHex: String?
    let playerNumber: Int?
    let preferredPositionCode: String?
    let joinedAt: Date?
}

/// A managed player holding an active seat on one specific Team.
struct FanTeamManagedPlayerSeat: Identifiable, Equatable, Hashable, Sendable {
    /// `fan_team_members.membership_id`.
    let id: UUID
    let managedPlayerId: UUID
    let displayName: String
    let avatarURL: String?
    let avatarThumbnailURL: String?
    let playerNumber: Int?
    let preferredPositionCode: String?
    let joinedAt: Date?
}

// MARK: - Participant identity

/// Who a Team roster seat represents.
///
/// The database enforces the same exclusive-or (`fan_team_members` CHECK): a seat
/// is either an authenticated account **or** a managed player, never both and
/// never neither. Mirroring it in the type system keeps UI branches honest.
enum TeamParticipantIdentity: Equatable, Hashable, Sendable {
    case account(userId: UUID)
    case managedPlayer(managedPlayerId: UUID)

    /// `nil` when the payload violates the XOR contract (defensive: old/partial rows).
    static func resolve(userId: UUID?, managedPlayerId: UUID?) -> TeamParticipantIdentity? {
        switch (userId, managedPlayerId) {
        case let (.some(userId), .none):
            return .account(userId: userId)
        case let (.none, .some(managedPlayerId)):
            return .managedPlayer(managedPlayerId: managedPlayerId)
        default:
            return nil
        }
    }

    var accountUserId: UUID? {
        if case let .account(userId) = self { return userId }
        return nil
    }

    var managedPlayerId: UUID? {
        if case let .managedPlayer(id) = self { return id }
        return nil
    }

    var isManagedPlayer: Bool { managedPlayerId != nil }

    /// Social affordances (DM, profile, friend request, presence) require an account.
    var supportsSocialActions: Bool { accountUserId != nil }
}

// MARK: - Validation

enum FanManagedPlayerValidation {
    static let maxFirstNameLength = 40
    static let maxLastNameLength = 40
    static let maxDisplayNameLength = 60
    /// Matches the `fan_managed_players_birth_year_ck` lower bound.
    static let minBirthYear = 1900
    /// Preferred wheel span for managed players (youth / young-adult Team seats).
    /// Inclusive: `currentYear - preferredPickerSpanYears` … `currentYear`.
    static let preferredPickerSpanYears = 25

    static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isValidFirstName(_ raw: String) -> Bool {
        let value = normalized(raw)
        return !value.isEmpty && value.count <= maxFirstNameLength
    }

    static func isValidLastName(_ raw: String) -> Bool {
        normalized(raw).count <= maxLastNameLength
    }

    static func currentGregorianYear(now: Date = Date()) -> Int {
        Calendar(identifier: .gregorian).component(.year, from: now)
    }

    static func isValidBirthYear(_ year: Int?, now: Date = Date()) -> Bool {
        guard let year else { return true }
        let currentYear = currentGregorianYear(now: now)
        return year >= minBirthYear && year <= currentYear
    }

    /// Descending year list for the birth-year wheel.
    /// Preferred: `currentYear` … `currentYear - 25`. If an existing stored year is
    /// outside that window but still schema-valid, it is included so Edit stays honest.
    static func pickerYears(now: Date = Date(), including existing: Int? = nil) -> [Int] {
        let currentYear = currentGregorianYear(now: now)
        let lower = max(minBirthYear, currentYear - preferredPickerSpanYears)
        var years = Array((lower...currentYear).reversed())
        if let existing,
           isValidBirthYear(existing, now: now),
           !years.contains(existing) {
            years.append(existing)
            years.sort(by: >)
        }
        return years
    }

    /// Server applies the same fallback; doing it client-side keeps the preview honest.
    static func resolvedDisplayName(
        firstName: String,
        lastName: String,
        preferred: String
    ) -> String {
        let preferred = normalized(preferred)
        if !preferred.isEmpty {
            return String(preferred.prefix(maxDisplayNameLength))
        }
        let combined = [normalized(firstName), normalized(lastName)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(combined.prefix(maxDisplayNameLength))
    }

    static func canSubmit(firstName: String, lastName: String, birthYear: Int?) -> Bool {
        isValidFirstName(firstName)
            && isValidLastName(lastName)
            && isValidBirthYear(birthYear)
    }
}

/// Distinguishes allowlist rejection ("rate limit rejected") from true over-limit
/// (`rate_limit_exceeded`). Used for diagnostics / self-tests only.
enum FanManagedPlayerRateLimitDiagnostics {
    static func isAllowlistRejectionMessage(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("rate limit rejected")
            && !lowered.contains("rate_limit_exceeded")
    }
}

// MARK: - Presentation

enum FanManagedPlayerPresentation {
    /// "Born 2015" — never a full date, so the caption cannot leak a child's birthday.
    static func birthYearCaption(_ birthYear: Int?, languageCode: String) -> String? {
        guard let birthYear, birthYear >= FanManagedPlayerValidation.minBirthYear else { return nil }
        return String(
            format: L10n.t("managed_players_birth_year_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            String(birthYear)
        )
    }

    /// Approximate age from birth year only (no day/month). Omitted when year is missing/invalid.
    static func ageCaption(
        birthYear: Int?,
        languageCode: String,
        now: Date = Date()
    ) -> String? {
        guard let birthYear, FanManagedPlayerValidation.isValidBirthYear(birthYear, now: now) else {
            return nil
        }
        let age = FanManagedPlayerValidation.currentGregorianYear(now: now) - birthYear
        guard age >= 0 else { return nil }
        return String(
            format: L10n.t("managed_players_age_format", languageCode: languageCode),
            locale: Locale(identifier: L10n.normalizedLanguageCode(languageCode)),
            Int64(age)
        )
    }

    static func teamCountCaption(_ count: Int, languageCode: String) -> String {
        if count == 1 {
            return L10n.t("managed_players_team_count_one", languageCode: languageCode)
        }
        return String(
            format: L10n.t("managed_players_team_count_other", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            Int64(count)
        )
    }

    /// Managed-player seats are DB-constrained to `role = 'member'`
    /// (`fan_team_members` CHECK in 20260960). Display that real role — never invent leadership.
    static var managedPlayerTeamRole: FanTeamMemberRole { .member }

    /// Fan Teams are invitation-only; matches ``FanTeamPrivacyPresentation``.
    static var showsPrivateTeamBadge: Bool { true }

    /// Medium date for membership cards ("Aug 11, 2026"). Nil when join date missing — never "Not set".
    static func memberSinceMediumDate(_ joinedAt: Date?, languageCode: String) -> String? {
        guard let joinedAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let value = formatter.string(from: joinedAt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func jerseyLabel(_ playerNumber: Int?) -> String? {
        guard let playerNumber, FanTeamPlayerNumber.isValid(playerNumber) else { return nil }
        return FanTeamPlayerNumber.displayLabel(playerNumber)
    }

    static func positionLabel(
        preferredPositionCode: String?,
        sportToken: String?,
        languageCode: String
    ) -> String? {
        let normalized = preferredPositionCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        guard !normalized.isEmpty else { return nil }
        if let catalog = FanTeamSportPositions.position(code: normalized, sportToken: sportToken) {
            return catalog.accessibilityLabel(languageCode: languageCode)
        }
        return normalized
    }

    /// Player detail Teams row second line (legacy compact subtitle).
    ///
    /// Includes jersey, position, and `Member since <MMM yyyy>` when present.
    /// Missing jersey / position / join date are omitted — never `"Not set"`.
    /// Join date is `fan_team_members.joined_at` (`FanManagedPlayerTeamMembership.joinedAt`).
    static func teamMembershipSubtitle(
        playerNumber: Int?,
        preferredPositionCode: String?,
        sportToken: String?,
        languageCode: String,
        joinedAt: Date? = nil
    ) -> String? {
        var parts: [String] = []
        if let jersey = jerseyLabel(playerNumber) {
            parts.append(jersey)
        }
        if let position = positionLabel(
            preferredPositionCode: preferredPositionCode,
            sportToken: sportToken,
            languageCode: languageCode
        ) {
            parts.append(position)
        }
        if let joinedAt {
            let monthYear = FanTeamRosterJoinedCaption.monthYear(
                from: joinedAt,
                languageCode: languageCode
            )
            if !monthYear.isEmpty {
                parts.append(
                    String(
                        format: L10n.t("managed_players_member_since_format", languageCode: languageCode),
                        locale: Locale(identifier: L10n.normalizedLanguageCode(languageCode)),
                        monthYear
                    )
                )
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    static func teamMembershipSubtitle(
        membership: FanManagedPlayerTeamMembership,
        languageCode: String
    ) -> String? {
        teamMembershipSubtitle(
            playerNumber: membership.playerNumber,
            preferredPositionCode: membership.preferredPositionCode,
            sportToken: membership.sport,
            languageCode: languageCode,
            joinedAt: membership.joinedAt
        )
    }

    /// Team Overview shows the legacy "My Players" card only when managed seats exist
    /// **and** they are not already listed under "My Players on This Team".
    /// Prefer hiding this card once the Overview list renders those seats.
    static func showsTeamPlayersCard(seats: [FanTeamManagedPlayerSeat]) -> Bool {
        !seats.isEmpty
    }

    /// Owner/Manager CTA when managed players exist globally but are not all on this Team.
    static func showsAddManagedPlayersToTeamCTA(
        canManageTeam: Bool,
        globalManagedPlayerCount: Int,
        seatsOnThisTeam: Int
    ) -> Bool {
        guard canManageTeam, globalManagedPlayerCount > 0 else { return false }
        return seatsOnThisTeam < globalManagedPlayerCount
    }
}
