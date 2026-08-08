import Foundation

// MARK: - Access

/// Who may create polls in a pickup-game chat (stored on `pickup_games.poll_create_permission`).
enum PickupPollCreatePermission: String, CaseIterable, Identifiable, Sendable {
    case organizerOnly = "organizer_only"
    case approvedPlayers = "approved_players"

    var id: String { rawValue }

    static func resolved(_ raw: String?) -> PickupPollCreatePermission {
        let token = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return PickupPollCreatePermission(rawValue: token) ?? .organizerOnly
    }

    func title(languageCode: String?) -> String {
        switch self {
        case .organizerOnly:
            return L10n.t("pickup_poll_permission_organizer_only", languageCode: languageCode)
        case .approvedPlayers:
            return L10n.t("pickup_poll_permission_approved_players", languageCode: languageCode)
        }
    }
}

/// Organizer gate for pickup poll moderation; create uses ``PickupPollCreatePermission``.
enum PickupGamePollAccess {
    static func canCreate(
        isOrganizer: Bool,
        permission: PickupPollCreatePermission,
        isApprovedParticipant: Bool
    ) -> Bool {
        if isOrganizer { return true }
        switch permission {
        case .organizerOnly:
            return false
        case .approvedPlayers:
            return isApprovedParticipant
        }
    }

    static func canModerate(isOrganizer: Bool) -> Bool {
        isOrganizer
    }
}

// MARK: - Validation

enum PickupGamePollValidation {
    nonisolated static let questionMaxLength = 120
    nonisolated static let optionMaxLength = 40
    static let optionMinCount = 2
    static let optionMaxCount = 8

    enum Issue: Equatable, Sendable {
        case emptyQuestion
        case questionTooLong
        case tooFewOptions
        case tooManyOptions
        case emptyOption(index: Int)
        case optionTooLong(index: Int)
        case duplicateOptions
        case moderationRejected
    }

    nonisolated static func normalizeQuestion(_ raw: String) -> String {
        String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(questionMaxLength))
    }

    nonisolated static func normalizeOption(_ raw: String) -> String {
        String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(optionMaxLength))
    }

    static func validate(question: String, options: [String]) -> Issue? {
        let q = normalizeQuestion(question)
        if q.isEmpty { return .emptyQuestion }
        if question.trimmingCharacters(in: .whitespacesAndNewlines).count > questionMaxLength {
            return .questionTooLong
        }

        let normalized = options.map(normalizeOption)
        if normalized.count < optionMinCount { return .tooFewOptions }
        if normalized.count > optionMaxCount { return .tooManyOptions }

        for (idx, opt) in normalized.enumerated() {
            if opt.isEmpty { return .emptyOption(index: idx) }
            if options[idx].trimmingCharacters(in: .whitespacesAndNewlines).count > optionMaxLength {
                return .optionTooLong(index: idx)
            }
        }

        var seen = Set<String>()
        for opt in normalized {
            let key = opt.lowercased()
            if seen.contains(key) { return .duplicateOptions }
            seen.insert(key)
        }

        if ModerationService.containsProfanity(q) {
            return .moderationRejected
        }
        for opt in normalized where ModerationService.containsProfanity(opt) {
            return .moderationRejected
        }

        return nil
    }

    static func userMessage(for issue: Issue, languageCode: String? = nil) -> String {
        switch issue {
        case .emptyQuestion:
            return L10n.t("pickup_poll_error_empty_question", languageCode: languageCode)
        case .questionTooLong:
            return L10n.t("pickup_poll_error_question_too_long", languageCode: languageCode)
        case .tooFewOptions:
            return L10n.t("pickup_poll_error_too_few_options", languageCode: languageCode)
        case .tooManyOptions:
            return L10n.t("pickup_poll_error_too_many_options", languageCode: languageCode)
        case .emptyOption:
            return L10n.t("pickup_poll_error_empty_option", languageCode: languageCode)
        case .optionTooLong:
            return L10n.t("pickup_poll_error_option_too_long", languageCode: languageCode)
        case .duplicateOptions:
            return L10n.t("pickup_poll_error_duplicate_options", languageCode: languageCode)
        case .moderationRejected:
            return L10n.t("pickup_poll_error_moderation", languageCode: languageCode)
        }
    }
}

// MARK: - Snapshot models

struct PickupGamePollOptionSnapshot: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let text: String
    let sortOrder: Int
    let voteCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case sortOrder = "sort_order"
        case voteCount = "vote_count"
    }
}

struct PickupGamePollVoterRow: Codable, Equatable, Sendable {
    let optionId: UUID
    let voterUserId: UUID

    enum CodingKeys: String, CodingKey {
        case optionId = "option_id"
        case voterUserId = "voter_user_id"
    }
}

struct PickupGamePollSnapshot: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let pickupGameId: UUID
    let conversationId: UUID
    let messageId: UUID?
    let createdBy: UUID
    let question: String
    let allowMultiple: Bool
    let isAnonymous: Bool
    let autoCloseAtGameStart: Bool
    let closesAt: String?
    let status: String
    let closedAt: String?
    let pinnedAt: String?
    let deletedAt: String?
    let createdAt: String
    let updatedAt: String
    let totalVoters: Int
    let options: [PickupGamePollOptionSnapshot]
    let myOptionIds: [UUID]
    let voters: [PickupGamePollVoterRow]
    let viewerIsOrganizer: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case pickupGameId = "pickup_game_id"
        case conversationId = "conversation_id"
        case messageId = "message_id"
        case createdBy = "created_by"
        case question
        case allowMultiple = "allow_multiple"
        case isAnonymous = "is_anonymous"
        case autoCloseAtGameStart = "auto_close_at_game_start"
        case closesAt = "closes_at"
        case status
        case closedAt = "closed_at"
        case pinnedAt = "pinned_at"
        case deletedAt = "deleted_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case totalVoters = "total_voters"
        case options
        case myOptionIds = "my_option_ids"
        case voters
        case viewerIsOrganizer = "viewer_is_organizer"
    }

    var isSoftDeleted: Bool { deletedAt != nil }

    var isClosed: Bool {
        let s = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s == "closed" || s == "archived" { return true }
        if let closes = closesAtDate, closes <= Date() { return true }
        return false
    }

    var isArchived: Bool {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "archived"
            || deletedAt != nil
    }

    var isPinned: Bool { pinnedAt != nil }

    var closesAtDate: Date? {
        guard let raw = closesAt else { return nil }
        return ISO8601DateFormatter.pickupPoll.date(from: raw)
            ?? ISO8601DateFormatter().date(from: raw)
    }

    var mySelectedOptionIds: Set<UUID> { Set(myOptionIds) }

    func voteCount(for optionId: UUID) -> Int {
        options.first(where: { $0.id == optionId })?.voteCount ?? 0
    }

    func progress(for optionId: UUID) -> Double {
        let total = max(1, options.map(\.voteCount).reduce(0, +))
        return Double(voteCount(for: optionId)) / Double(total)
    }
}

// MARK: - Structured message

nonisolated struct PickupGamePollPayload: Codable, Equatable, Sendable {
    let v: Int
    let pollId: UUID
    let question: String
    let allowMultiple: Bool
    let isAnonymous: Bool
    let autoCloseAtGameStart: Bool
    let closesAt: String?
    let createdByName: String?

    enum CodingKeys: String, CodingKey {
        case v
        case pollId = "poll_id"
        case question
        case allowMultiple = "allow_multiple"
        case isAnonymous = "is_anonymous"
        case autoCloseAtGameStart = "auto_close_at_game_start"
        case closesAt = "closes_at"
        case createdByName = "created_by_name"
    }

    init(
        pollId: UUID,
        question: String,
        allowMultiple: Bool,
        isAnonymous: Bool,
        autoCloseAtGameStart: Bool,
        closesAt: Date?,
        createdByName: String?
    ) {
        self.v = 1
        self.pollId = pollId
        self.question = PickupGamePollValidation.normalizeQuestion(question)
        self.allowMultiple = allowMultiple
        self.isAnonymous = isAnonymous
        self.autoCloseAtGameStart = autoCloseAtGameStart
        self.closesAt = closesAt.map { ISO8601DateFormatter.pickupPoll.string(from: $0) }
        let name = createdByName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.createdByName = name.isEmpty ? nil : name
    }
}

enum PickupGamePollMessage {
    nonisolated static let sentinel = "__FG_POLL_V1__"

    static func encodeBody(payload: PickupGamePollPayload) -> String {
        let preview = previewLine(for: payload)
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return preview
        }
        return "\(preview)\n\(sentinel)\(json)"
    }

    /// Pure sentinel + JSON decode — no MainActor state.
    nonisolated static func decode(from body: String) -> PickupGamePollPayload? {
        guard let range = body.range(of: sentinel) else { return nil }
        let jsonPart = body[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonPart.data(using: .utf8),
              let payload = try? JSONDecoder().decode(PickupGamePollPayload.self, from: data),
              payload.v == 1,
              !payload.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return payload
    }

    static func inboxPreview(from body: String, languageCode: String? = nil) -> String? {
        guard decode(from: body) != nil || body.contains(sentinel) else { return nil }
        return L10n.t("pickup_poll_inbox_preview", languageCode: languageCode)
    }

    static func previewLine(for payload: PickupGamePollPayload, languageCode: String? = nil) -> String {
        let q = payload.question.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            return String(
                format: L10n.t("pickup_poll_preview_format", languageCode: languageCode),
                locale: Locale(identifier: L10n.normalizedLanguageCode(languageCode)),
                q
            )
        }
        return L10n.t("pickup_poll_inbox_preview", languageCode: languageCode)
    }
}

extension ISO8601DateFormatter {
    nonisolated static let pickupPoll: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - Local hide

enum PickupGamePollLocalHide {
    private static let prefix = "fangeo.pickupPoll.hidden."

    static func key(userId: UUID, pollId: UUID) -> String {
        "\(prefix)\(userId.uuidString.lowercased()).\(pollId.uuidString.lowercased())"
    }

    static func isHidden(userId: UUID?, pollId: UUID) -> Bool {
        guard let userId else { return false }
        return UserDefaults.standard.bool(forKey: key(userId: userId, pollId: pollId))
    }

    static func hide(userId: UUID?, pollId: UUID) {
        guard let userId else { return }
        UserDefaults.standard.set(true, forKey: key(userId: userId, pollId: pollId))
    }
}
