import Foundation
import Supabase

/// Server DTO for `list_my_fan_notification_inbox`.
struct FanNotificationInboxServerRow: Decodable, Equatable, Sendable, Identifiable {
    let id: UUID
    let notification_type: String
    let title: String
    let body: String
    let kind_raw: String
    let destination_raw: String
    let source_type: String?
    let source_id: String?
    let team_id: UUID?
    let event_id: UUID?
    let actor_user_id: UUID?
    let payload: [String: AnyCodableJSON]?
    let deduplication_key: String
    let created_at: Date
    let read_at: Date?
    let cleared_at: Date?

    var stableKey: String {
        FanGeoActionCenterActionKey.sanitize(deduplication_key)
    }
}

/// Minimal JSON value box for flexible inbox payload maps.
enum AnyCodableJSON: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case object([String: AnyCodableJSON])
    case array([AnyCodableJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .number(Double(i))
        } else if let d = try? container.decode(Double.self) {
            self = .number(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let o = try? container.decode([String: AnyCodableJSON].self) {
            self = .object(o)
        } else if let a = try? container.decode([AnyCodableJSON].self) {
            self = .array(a)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let s):
            return s
        case .number(let n):
            if n.rounded() == n {
                return String(Int(n))
            }
            return String(n)
        default:
            return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .string(let raw):
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "t", "yes": return true
            case "false", "0", "f", "no": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .number(let n):
            guard n.rounded() == n else { return nil }
            return Int(n)
        case .string(let raw):
            return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    var stringArray: [String]? {
        switch self {
        case .array(let items):
            return items.compactMap(\.stringValue)
        case .string(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            if trimmed.hasPrefix("["),
               let data = trimmed.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                return decoded
            }
            return trimmed
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        default:
            return nil
        }
    }
}

enum FanGeoNotificationInboxService {
    private static var client: SupabaseClient { supabase }

    struct ListParams: Encodable {
        let p_limit: Int
        let p_before_created_at: Date?
        let p_before_id: UUID?
    }

    struct KeysParams: Encodable {
        let p_deduplication_keys: [String]
    }

    static func fetchPage(
        limit: Int = 50,
        beforeCreatedAt: Date? = nil,
        beforeId: UUID? = nil
    ) async throws -> [FanNotificationInboxServerRow] {
        try await client
            .rpc(
                "list_my_fan_notification_inbox",
                params: ListParams(
                    p_limit: limit,
                    p_before_created_at: beforeCreatedAt,
                    p_before_id: beforeId
                )
            )
            .execute()
            .value
    }

    static func markRead(deduplicationKeys: [String]) async throws {
        let keys = FanGeoActionCenterActionKey.sanitizedUnique(deduplicationKeys)
        guard !keys.isEmpty else { return }
        try await client
            .rpc("mark_my_fan_notification_inbox_read", params: KeysParams(p_deduplication_keys: keys))
            .execute()
    }

    static func clear(deduplicationKeys: [String]) async throws {
        let keys = FanGeoActionCenterActionKey.sanitizedUnique(deduplicationKeys)
        guard !keys.isEmpty else { return }
        try await client
            .rpc("clear_my_fan_notification_inbox", params: KeysParams(p_deduplication_keys: keys))
            .execute()
    }

    static func clearAll() async throws {
        try await client.rpc("clear_all_my_fan_notification_inbox").execute()
    }
}

extension FanGeoNotificationInboxEntry {
    static func from(serverRow: FanNotificationInboxServerRow) -> FanGeoNotificationInboxEntry {
        let pickupId = serverRow.event_id
            ?? uuidFromPayload(serverRow.payload, key: "pickup_game_id")
        let teamId = serverRow.team_id
            ?? uuidFromPayload(serverRow.payload, key: "team_id")
        let title = serverRow.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = serverRow.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = FanGeoActionCenterTeamNotificationPresentation.inboxFields(from: serverRow)
        let isJoinDecision = FanGeoActionCenterTeamNotificationPresentation.isJoinRequestDecision(
            serverRow.notification_type
        )
        let isSecurity = FanGeoSecuritySessionReplacement.isSecurityEvent(
            notificationType: serverRow.notification_type,
            sourceType: serverRow.source_type
        )
        let recoveredIdentity = FanGeoTeamEventNoticeBuilder.parseTeamIdentityLine(title)
        let resolvedTeamName = isSecurity
            ? nil
            : (fields.teamName
                ?? stringFromPayload(serverRow.payload, key: "team_name")
                ?? recoveredIdentity?.teamName)
        let isTeamNotification = !isSecurity && !isJoinDecision && (teamId != nil || resolvedTeamName != nil)
        let announcementBody = fields.announcementBody?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let subtitleArgs: [String]
        let subtitleKey: String
        if isTeamNotification, !announcementBody.isEmpty, announcementBody != title {
            subtitleKey = "action_center_notification_title_passthrough_format"
            subtitleArgs = [announcementBody]
        } else if body.isEmpty || body == title {
            subtitleKey = "action_center_notification_subtitle_default"
            subtitleArgs = []
        } else {
            subtitleKey = "action_center_notification_title_passthrough_format"
            subtitleArgs = [body]
        }
        return FanGeoNotificationInboxEntry(
            id: FanGeoActionCenterActionKey.sanitize(serverRow.deduplication_key),
            kindRaw: isSecurity
                ? FanGeoSecuritySessionReplacement.kindRaw
                : serverRow.kind_raw,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: [title],
            subtitleKey: subtitleKey,
            subtitleFormatArgs: subtitleArgs,
            destinationRaw: isSecurity
                ? FanGeoSecuritySessionReplacement.destinationRaw
                : serverRow.destination_raw,
            timestamp: serverRow.created_at,
            count: 1,
            personName: fields.personName,
            personUsername: nil,
            personAvatarURL: fields.personAvatarURL,
            teamName: resolvedTeamName,
            eventTitle: isJoinDecision
                ? (stringFromPayload(serverRow.payload, key: "title")
                    ?? fields.eventTitle
                    ?? body)
                : (isTeamNotification
                    ? (fields.eventTitle
                        ?? recoveredIdentity?.detail
                        ?? title)
                    : title),
            eventTypeLabel: isSecurity
                ? FanGeoSecuritySessionReplacement.sanitizedDeviceFamily(
                    stringFromPayload(serverRow.payload, key: "new_device_type")
                )
                : (isTeamNotification
                    ? (fields.gameFormat ?? recoveredIdentity?.detail)
                    : nil),
            locationLabel: fields.locationLabel
                ?? stringFromPayload(serverRow.payload, key: "after_location"),
            eventStartAt: isTeamNotification ? fields.eventStartAt : nil,
            pickupGameId: isSecurity ? nil : pickupId,
            teamId: isSecurity ? nil : teamId,
            invitationId: nil,
            friendshipId: nil,
            requesterUserId: serverRow.actor_user_id,
            pokeId: nil,
            sportLabel: fields.sportLabel,
            matchupLabel: stringFromPayload(serverRow.payload, key: "matchup"),
            opponentName: fields.opponentName
                ?? stringFromPayload(serverRow.payload, key: "after_opponent"),
            changeDetails: isTeamNotification
                ? fields.changeDetails.map {
                    FanGeoNotificationInboxEntry.FanGeoActionChangeDetailRecord(
                        labelKey: $0.labelKey,
                        oldValue: $0.oldValue,
                        newValue: $0.newValue
                    )
                }
                : [],
            moreChangesCount: 0,
            isRead: serverRow.read_at != nil,
            createdAt: serverRow.created_at,
            updatedAt: serverRow.read_at ?? serverRow.created_at,
            notificationType: {
                let raw = (fields.notificationType ?? serverRow.notification_type)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return raw.isEmpty ? nil : raw
            }(),
            roleToken: fields.roleToken,
            managedPlayerId: fields.managedPlayerId,
            isManagedPlayer: fields.isManagedPlayer,
            personAvatarThumbnailURL: fields.personAvatarThumbnailURL,
            proGameMatchId: stringFromPayload(serverRow.payload, key: "match_id")
                ?? serverRow.source_id,
            proGameSnapshot: FanGeoProGameInboxSnapshot.from(
                payload: serverRow.payload,
                notificationType: serverRow.notification_type,
                sourceType: serverRow.source_type,
                sourceID: serverRow.source_id
            ),
            scoreLine: fields.scoreLine
                ?? stringFromPayload(serverRow.payload, key: "score_line")
                ?? (FanGeoActionCenterTeamNotificationPresentation.isTeamEventScoreNotification(
                    serverRow.notification_type
                ) ? body : nil),
            scorerAttributionKind: fields.scorerAttributionKind
                ?? stringFromPayload(serverRow.payload, key: "scorer_attribution_kind")
        )
    }

    private static func stringFromPayload(
        _ payload: [String: AnyCodableJSON]?,
        key: String
    ) -> String? {
        guard let raw = payload?[key]?.stringValue else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func uuidFromPayload(
        _ payload: [String: AnyCodableJSON]?,
        key: String
    ) -> UUID? {
        guard let raw = stringFromPayload(payload, key: key) else { return nil }
        return UUID(uuidString: raw)
    }
}
