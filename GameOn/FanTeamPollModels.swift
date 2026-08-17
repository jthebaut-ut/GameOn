import Foundation

// MARK: - Team poll create permission

/// Who may create polls in Team Chat (stored on `fan_teams.poll_create_permission`).
enum FanTeamPollCreatePermission: String, CaseIterable, Identifiable, Sendable {
    case managementOnly = "management_only"
    case anyone = "anyone"

    var id: String { rawValue }

    static func resolved(_ raw: String?) -> FanTeamPollCreatePermission {
        let token = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return FanTeamPollCreatePermission(rawValue: token) ?? .managementOnly
    }

    func title(languageCode: String?) -> String {
        switch self {
        case .managementOnly:
            return L10n.t("team_poll_permission_management_only", languageCode: languageCode)
        case .anyone:
            return L10n.t("team_poll_permission_anyone", languageCode: languageCode)
        }
    }
}

/// Client-side create gate; server enforces via `create_fan_team_poll`.
enum FanTeamPollAccess {
    static func canCreate(
        canManageTeam: Bool,
        permission: FanTeamPollCreatePermission,
        isActiveTeamChatMember: Bool
    ) -> Bool {
        guard isActiveTeamChatMember else { return false }
        if canManageTeam { return true }
        switch permission {
        case .managementOnly:
            return false
        case .anyone:
            return true
        }
    }

    static func canModerate(canManageTeam: Bool) -> Bool {
        canManageTeam
    }
}

struct FanTeamPollAccessSnapshot: Equatable, Sendable {
    let teamId: UUID
    let conversationId: UUID
    let permission: FanTeamPollCreatePermission
    let viewerCanManage: Bool
    let viewerCanCreate: Bool

    init(
        teamId: UUID,
        conversationId: UUID,
        permission: FanTeamPollCreatePermission,
        viewerCanManage: Bool,
        viewerCanCreate: Bool
    ) {
        self.teamId = teamId
        self.conversationId = conversationId
        self.permission = permission
        self.viewerCanManage = viewerCanManage
        self.viewerCanCreate = viewerCanCreate
    }

    enum CodingKeys: String, CodingKey {
        case teamId = "team_id"
        case conversationId = "conversation_id"
        case pollCreatePermission = "poll_create_permission"
        case viewerCanManage = "viewer_can_manage"
        case viewerCanCreate = "viewer_can_create"
    }
}

extension FanTeamPollAccessSnapshot: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        teamId = try c.decode(UUID.self, forKey: .teamId)
        conversationId = try c.decode(UUID.self, forKey: .conversationId)
        permission = FanTeamPollCreatePermission.resolved(
            try c.decodeIfPresent(String.self, forKey: .pollCreatePermission)
        )
        viewerCanManage = try c.decodeIfPresent(Bool.self, forKey: .viewerCanManage) ?? false
        viewerCanCreate = try c.decodeIfPresent(Bool.self, forKey: .viewerCanCreate) ?? false
    }
}

enum TeamChatPollDebug {
    static func log(_ event: String, detail: String? = nil) {
#if DEBUG
        if let detail, !detail.isEmpty {
            print("[TeamChatPoll] \(event) \(detail)")
        } else {
            print("[TeamChatPoll] \(event)")
        }
#endif
    }
}
