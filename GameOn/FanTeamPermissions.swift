import Foundation

// MARK: - Team granted permissions (Owner-assignable)

/// Stable permission keys for Fan Team management.
/// Raw values match `fan_team_members.granted_permissions` JSON / SQL tokens.
enum FanTeamPermissionKey: String, Codable, Hashable, CaseIterable, Sendable {
    case createEvents = "create_events"
    case editEvents = "edit_events"
    case publishAnnouncements = "publish_announcements"
    case inviteMembers = "invite_members"
    case manageRoster = "manage_roster"
    case manageLineups = "manage_lineups"
    case manageManagedPlayers = "manage_managed_players"
    case editTeamInformation = "edit_team_information"
    case moderateTeamChat = "moderate_team_chat"

    var titleKey: String { "fan_team_permission_\(rawValue)_title" }
    var helpKey: String { "fan_team_permission_\(rawValue)_help" }
}

struct FanTeamPermissionSet: Hashable, Sendable {
    private(set) var keys: Set<FanTeamPermissionKey>

    static let empty = FanTeamPermissionSet(keys: [])
    static let all = FanTeamPermissionSet(keys: Set(FanTeamPermissionKey.allCases))
    /// Owner-assigned "Team Administrator" preset — every management key, never ownership.
    static let teamAdministrator = Self.all

    init(keys: Set<FanTeamPermissionKey> = []) {
        self.keys = keys
    }

    init(keys: [FanTeamPermissionKey]) {
        self.keys = Set(keys)
    }

    init(rawValues: [String]?) {
        let parsed = (rawValues ?? []).compactMap { FanTeamPermissionKey(rawValue: $0) }
        self.keys = Set(parsed)
    }

    var rawValues: [String] {
        FanTeamPermissionKey.allCases
            .filter { keys.contains($0) }
            .map(\.rawValue)
    }

    func contains(_ key: FanTeamPermissionKey) -> Bool {
        keys.contains(key)
    }

    mutating func set(_ key: FanTeamPermissionKey, enabled: Bool) {
        if enabled {
            keys.insert(key)
        } else {
            keys.remove(key)
        }
    }

    func toggling(_ key: FanTeamPermissionKey, enabled: Bool) -> FanTeamPermissionSet {
        var next = self
        next.set(key, enabled: enabled)
        return next
    }

    /// True when this set is the full Team Administrator preset (all management keys).
    var isTeamAdministratorPreset: Bool {
        keys == Set(FanTeamPermissionKey.allCases)
    }
}

/// Role defaults + Owner custom overrides.
enum FanTeamPermissionResolution: Hashable, Sendable {
    /// Effective permissions match the role default matrix (no Owner override).
    case roleDefaults
    /// Owner saved an explicit permission set for this seat.
    case custom(FanTeamPermissionSet)

    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }
}

enum FanTeamPermissions {
    /// Role titles are identity only. Owner always has every key; every other role
    /// defaults to no management. Management is the Team Administrator preset.
    static func roleDefaults(for role: FanTeamMemberRole) -> FanTeamPermissionSet {
        role == .owner ? .all : .empty
    }

    /// Whether the seat currently has the Team Administrator preset.
    /// Owner is always treated as administrator (toggle is hidden / not editable).
    static func isTeamAdministrator(
        role: FanTeamMemberRole,
        effective: FanTeamPermissionSet
    ) -> Bool {
        if role == .owner { return true }
        return effective.isTeamAdministratorPreset
    }

    /// Persistable granted set for the single Team Administrator switch.
    static func grantedSet(isTeamAdministrator: Bool) -> FanTeamPermissionSet {
        isTeamAdministrator ? .teamAdministrator : .empty
    }

    /// Effective permissions for a seat.
    /// Owner always has every permission (cannot be reduced).
    static func effective(
        role: FanTeamMemberRole,
        resolution: FanTeamPermissionResolution
    ) -> FanTeamPermissionSet {
        if role == .owner { return .all }
        switch resolution {
        case .roleDefaults:
            return roleDefaults(for: role)
        case .custom(let set):
            return set
        }
    }

    static func effective(
        role: FanTeamMemberRole,
        useCustom: Bool,
        granted: FanTeamPermissionSet
    ) -> FanTeamPermissionSet {
        effective(
            role: role,
            resolution: useCustom ? .custom(granted) : .roleDefaults
        )
    }

    /// Only the Team Owner may grant/revoke permissions (Managers cannot elevate).
    static func canEditPermissions(
        viewerRole: FanTeamMemberRole,
        targetRole: FanTeamMemberRole,
        targetIsManagedPlayer: Bool,
        viewerUserId: UUID?,
        targetUserId: UUID?
    ) -> Bool {
        guard viewerRole == .owner else { return false }
        guard targetRole != .owner else { return false }
        guard !targetIsManagedPlayer else { return false }
        // Never edit your own permission toggles (Owner always-all).
        if let viewerUserId, let targetUserId, viewerUserId == targetUserId {
            return false
        }
        return true
    }
}
