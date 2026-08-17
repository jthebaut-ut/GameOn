import Foundation

// MARK: - My Teams home relationship filters

/// Compact chips under My Teams | Invites (session-local UI preference).
enum FanTeamHomeFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all
    case managing
    case joined

    var id: String { rawValue }

    var localizationKey: String {
        switch self {
        case .all: return "fan_teams_filter_all"
        case .managing: return "fan_teams_filter_managing"
        case .joined: return "fan_teams_filter_joined"
        }
    }

    /// Empty-state title for the selected My Teams relationship chip.
    var emptyTitleKey: String {
        switch self {
        case .all: return "fan_teams_empty_title"
        case .managing: return "fan_teams_empty_managing_title"
        case .joined: return "fan_teams_empty_joined_title"
        }
    }
}

/// Authoritative viewer ↔ Team relationship for home cards (presentation only).
enum FanTeamHomeRelationship: Equatable, Hashable, Sendable {
    case owner
    case manager
    /// Direct account seat that is not Owner/Manager (includes coach/captain seats).
    case member
    /// Visible only because one or more managed players belong to the Team.
    case viaManagedPlayers(names: [String])

    /// Managing chip: Owner or Manager only (`FanTeamMemberRole.canManageTeam`).
    var isManaging: Bool {
        switch self {
        case .owner, .manager: return true
        case .member, .viaManagedPlayers: return false
        }
    }

    var matchesFilter: (FanTeamHomeFilter) -> Bool {
        { filter in
            switch filter {
            case .all: return true
            case .managing: return isManaging
            case .joined: return !isManaging
            }
        }
    }

    /// Account holds a direct `fan_team_members` seat (not guardian-only access).
    var hasAccountSeat: Bool {
        switch self {
        case .owner, .manager, .member: return true
        case .viaManagedPlayers: return false
        }
    }
}

struct FanTeamHomeFilterCounts: Equatable, Sendable {
    var all: Int
    var managing: Int
    var joined: Int

    func count(for filter: FanTeamHomeFilter) -> Int {
        switch filter {
        case .all: return all
        case .managing: return managing
        case .joined: return joined
        }
    }

    static let zero = FanTeamHomeFilterCounts(all: 0, managing: 0, joined: 0)
}

/// One deduplicated Team row on the My Teams home list.
struct FanTeamHomeItem: Identifiable, Equatable, Hashable, Sendable {
    let team: FanTeamSummary
    let relationship: FanTeamHomeRelationship

    var id: UUID { team.id }

    /// Team Chat follows canonical Team ACCOUNT ACCESS, not Myself player
    /// participation or a direct `fan_team_members` seat.
    var showsTeamChat: Bool { team.canAccessTeamChat }
}

/// Pure classification + filter/search pipeline for Teams home.
enum FanTeamHomeCatalog {
    /// Builds the authoritative home list.
    ///
    /// - Account teams from `list_my_fan_teams` keep their existing order.
    /// - Guardian-only teams (managed-player access, no account seat) append after,
    ///   stable-sorted by name.
    /// - One card per Team: management / direct seat wins over via-managed presentation.
    static func build(
        accountTeams: [FanTeamSummary],
        guardianOnlyTeams: [FanTeamSummary],
        viaNamesByTeamId: [UUID: [String]]
    ) -> [FanTeamHomeItem] {
        // Post-20260972 RPC may return guardian-only rows inside `accountTeams`
        // (accessVia=.managedPlayer). Split so relationship badges stay correct.
        let rpcAccount = accountTeams.filter(\.hasAccountSeat)
        let rpcManaged = accountTeams.filter { !$0.hasAccountSeat }
        let accountIds = Set(rpcAccount.map(\.id))
        let rpcManagedIds = Set(rpcManaged.map(\.id))

        var items: [FanTeamHomeItem] = rpcAccount.map { team in
            let via = uniquePreservingOrder(
                viaNamesByTeamId[team.id] ?? team.viaManagedPlayerNames
            )
            return FanTeamHomeItem(
                team: team,
                relationship: relationship(
                    forAccountRole: team.myRole,
                    viaNames: via
                )
            )
        }

        var extras = rpcManaged
        for team in guardianOnlyTeams where !accountIds.contains(team.id) && !rpcManagedIds.contains(team.id) {
            extras.append(team)
        }
        extras.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        for team in extras {
            let names = uniquePreservingOrder(
                viaNamesByTeamId[team.id] ?? team.viaManagedPlayerNames
            )
            guard !names.isEmpty else { continue }
            items.append(
                FanTeamHomeItem(
                    team: team,
                    relationship: .viaManagedPlayers(names: names)
                )
            )
        }
        return items
    }

    /// Account seat classification. Via names never override Owner/Manager/Member badges.
    static func relationship(
        forAccountRole role: FanTeamMemberRole,
        viaNames: [String] = []
    ) -> FanTeamHomeRelationship {
        _ = viaNames
        if role.canManageTeam {
            return role == .owner ? .owner : .manager
        }
        return .member
    }

    static func counts(for items: [FanTeamHomeItem]) -> FanTeamHomeFilterCounts {
        var managing = 0
        var joined = 0
        for item in items {
            if item.relationship.isManaging {
                managing += 1
            } else {
                joined += 1
            }
        }
        return FanTeamHomeFilterCounts(
            all: items.count,
            managing: managing,
            joined: joined
        )
    }

    /// authoritative → filter → search (single derived pipeline).
    static func displayItems(
        from items: [FanTeamHomeItem],
        filter: FanTeamHomeFilter,
        searchText: String
    ) -> [FanTeamHomeItem] {
        let filtered = items.filter { $0.relationship.matchesFilter(filter) }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return filtered }
        return filtered.filter {
            $0.team.name.lowercased().contains(q)
                || $0.team.sport.lowercased().contains(q)
        }
    }

    /// Compact “Via Emma” / “Via Emma + Amelia”.
    static func viaDisplayNames(_ names: [String]) -> String {
        uniquePreservingOrder(names)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " + ")
    }

    static func uniquePreservingOrder(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(name)
        }
        return result
    }

    /// Prefer first name for compact “Via …” chips.
    static func compactManagedPlayerLabel(_ player: FanManagedPlayer) -> String {
        let first = player.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !first.isEmpty { return first }
        let display = player.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !display.isEmpty { return display }
        return player.fullName
    }

    /// Builds a home-card summary when the account has no seat but a managed player does.
    static func guardianOnlySummary(
        from membership: FanManagedPlayerTeamMembership,
        hydrated: FanTeamGuardianHomeHydration?,
        viaNames: [String] = []
    ) -> FanTeamSummary {
        FanTeamSummary(
            id: membership.teamId,
            name: hydrated?.name
                ?? membership.teamName.trimmingCharacters(in: .whitespacesAndNewlines),
            sport: (hydrated?.sport ?? membership.sport)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            logoURL: hydrated?.logoURL ?? membership.logoURL,
            logoThumbnailURL: hydrated?.logoThumbnailURL ?? membership.logoThumbnailURL,
            colorHex: hydrated?.colorHex ?? membership.colorHex,
            competitionLevel: hydrated?.competitionLevel,
            ownerUserId: hydrated?.ownerUserId ?? FanTeamGuardianHomeHydration.unknownOwnerSentinel,
            groupConversationId: hydrated?.groupConversationId
                ?? FanTeamGuardianHomeHydration.unknownConversationSentinel,
            // Not authoritative for badges — relationship is `.viaManagedPlayers`.
            myRole: .member,
            memberCount: max(0, hydrated?.memberCount ?? 0),
            pendingInvitationCount: 0,
            pushNotificationsMuted: false,
            nextGameStartsAt: hydrated?.nextGameStartsAt,
            nextGameTitle: hydrated?.nextGameTitle,
            nextGameVenue: hydrated?.nextGameVenue,
            createdAt: hydrated?.createdAt,
            memberAvatarPreviews: hydrated?.memberAvatarPreviews ?? [],
            accessVia: .managedPlayer,
            viaManagedPlayerNames: uniquePreservingOrder(viaNames)
        )
    }
}

/// Optional `fan_teams` hydration for guardian-only home cards.
struct FanTeamGuardianHomeHydration: Equatable, Sendable {
    /// Stable sentinels when RLS/hydration cannot supply ids (chat stays hidden via relationship).
    static let unknownOwnerSentinel = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let unknownConversationSentinel = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!

    var name: String
    var sport: String
    var logoURL: String?
    var logoThumbnailURL: String?
    var colorHex: String?
    var competitionLevel: PickupCompetitionLevel?
    var ownerUserId: UUID
    var groupConversationId: UUID
    var memberCount: Int
    var nextGameStartsAt: Date?
    var nextGameTitle: String?
    var nextGameVenue: String?
    var createdAt: Date?
    var memberAvatarPreviews: [FanTeamMemberAvatarPreview]
}

// MARK: - Presentation helpers

enum FanTeamHomeRelationshipPresentation {
    static func title(
        _ relationship: FanTeamHomeRelationship,
        languageCode: String
    ) -> String {
        switch relationship {
        case .owner:
            return L10n.t("fan_team_role_owner", languageCode: languageCode)
        case .manager:
            return L10n.t("fan_team_role_manager", languageCode: languageCode)
        case .member:
            return L10n.t("fan_team_role_member", languageCode: languageCode)
        case .viaManagedPlayers(let names):
            let joined = FanTeamHomeCatalog.viaDisplayNames(names)
            return String(
                format: L10n.t("fan_teams_relationship_via", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                joined
            )
        }
    }

    static func accessibilityLabel(
        _ relationship: FanTeamHomeRelationship,
        languageCode: String
    ) -> String {
        switch relationship {
        case .owner, .manager, .member:
            return String(
                format: L10n.t("fan_teams_relationship_a11y_role", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                title(relationship, languageCode: languageCode)
            )
        case .viaManagedPlayers(let names):
            return String(
                format: L10n.t("fan_teams_relationship_a11y_via", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                FanTeamHomeCatalog.viaDisplayNames(names)
            )
        }
    }

    static func showsCrownAccessory(_ relationship: FanTeamHomeRelationship) -> Bool {
        relationship == .owner
    }

    static func systemImage(_ relationship: FanTeamHomeRelationship) -> String? {
        switch relationship {
        case .owner: return FanTeamMemberRole.owner.badgeSystemImage
        case .manager: return FanTeamMemberRole.manager.badgeSystemImage
        case .member: return nil
        case .viaManagedPlayers: return "person.crop.circle"
        }
    }
}

#if DEBUG
enum FanTeamHomeFilteringSelfTests {
    static func runAll() {
        testOwnerManaging()
        testManagerManaging()
        testMemberJoined()
        testCaptainIsJoinedNotManaging()
        testManagedPlayerOnly()
        testRpcManagedPlayerAccessVia()
        testOwnerPlusManagedDedup()
        testManagerPlusManagedDedup()
        testMultipleManagedSameTeam()
        testSearchWithinFilter()
        testCounts()
        testChatVisibleForEveryHomeRelationship()
        testJoinedEmptyStatePresentation()
        print("[FanTeamHomeFilteringTest] ALL PASSED")
    }

    private static func summary(
        id: UUID = UUID(),
        name: String,
        role: FanTeamMemberRole,
        sport: String = "soccer",
        accessVia: FanTeamListAccessVia = .account,
        viaNames: [String] = []
    ) -> FanTeamSummary {
        FanTeamSummary(
            id: id,
            name: name,
            sport: sport,
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: nil,
            competitionLevel: nil,
            ownerUserId: UUID(),
            groupConversationId: UUID(),
            myRole: role,
            memberCount: 4,
            pendingInvitationCount: 0,
            pushNotificationsMuted: false,
            nextGameStartsAt: nil,
            nextGameTitle: nil,
            nextGameVenue: nil,
            createdAt: nil,
            accessVia: accessVia,
            viaManagedPlayerNames: viaNames
        )
    }

    private static func testOwnerManaging() {
        let jtId = UUID()
        let items = FanTeamHomeCatalog.build(
            accountTeams: [summary(id: jtId, name: "JT", role: .owner)],
            guardianOnlyTeams: [],
            viaNamesByTeamId: [:]
        )
        assert(items.count == 1)
        assert(items[0].relationship == .owner)
        assert(items[0].relationship.isManaging)
        let managing = FanTeamHomeCatalog.displayItems(from: items, filter: .managing, searchText: "")
        let joined = FanTeamHomeCatalog.displayItems(from: items, filter: .joined, searchText: "")
        assert(managing.map(\.team.name) == ["JT"])
        assert(joined.isEmpty)
    }

    private static func testManagerManaging() {
        let items = FanTeamHomeCatalog.build(
            accountTeams: [summary(name: "IMC Team", role: .manager)],
            guardianOnlyTeams: [],
            viaNamesByTeamId: [:]
        )
        assert(items[0].relationship == .manager)
        assert(FanTeamHomeCatalog.displayItems(from: items, filter: .managing, searchText: "").count == 1)
        assert(FanTeamHomeCatalog.displayItems(from: items, filter: .joined, searchText: "").isEmpty)
    }

    private static func testMemberJoined() {
        let items = FanTeamHomeCatalog.build(
            accountTeams: [summary(name: "Eagles", role: .member)],
            guardianOnlyTeams: [],
            viaNamesByTeamId: [:]
        )
        assert(items[0].relationship == .member)
        assert(FanTeamHomeCatalog.displayItems(from: items, filter: .managing, searchText: "").isEmpty)
        assert(FanTeamHomeCatalog.displayItems(from: items, filter: .joined, searchText: "").count == 1)
    }

    private static func testCaptainIsJoinedNotManaging() {
        let role = FanTeamMemberRole.captain
        assert(!role.canManageTeam)
        let items = FanTeamHomeCatalog.build(
            accountTeams: [summary(name: "Caps", role: .captain)],
            guardianOnlyTeams: [],
            viaNamesByTeamId: [:]
        )
        assert(items[0].relationship == .member)
        assert(!items[0].relationship.isManaging)
    }

    private static func testManagedPlayerOnly() {
        let warriorsId = UUID()
        let warriors = summary(id: warriorsId, name: "Warriors", role: .member)
        let items = FanTeamHomeCatalog.build(
            accountTeams: [],
            guardianOnlyTeams: [warriors],
            viaNamesByTeamId: [warriorsId: ["Emma"]]
        )
        assert(items.count == 1)
        assert(items[0].relationship == .viaManagedPlayers(names: ["Emma"]))
        assert(!items[0].relationship.hasAccountSeat)
        assert(items[0].showsTeamChat)
        assert(items[0].team.canAccessTeamChat)
        assert(FanTeamHomeCatalog.displayItems(from: items, filter: .managing, searchText: "").isEmpty)
        assert(FanTeamHomeCatalog.displayItems(from: items, filter: .joined, searchText: "").count == 1)
        assert(FanTeamHomeCatalog.displayItems(from: items, filter: .all, searchText: "").count == 1)
    }

    private static func testRpcManagedPlayerAccessVia() {
        let teamId = UUID()
        let team = summary(
            id: teamId,
            name: "Warriors",
            role: .member,
            accessVia: .managedPlayer,
            viaNames: ["Emma"]
        )
        assert(!team.hasAccountSeat)
        assert(!team.canLeaveTeam)
        assert(!team.canManage)
        assert(!team.canDeleteTeam)
        let items = FanTeamHomeCatalog.build(
            accountTeams: [team],
            guardianOnlyTeams: [],
            viaNamesByTeamId: [:]
        )
        assert(items.count == 1)
        assert(items[0].relationship == .viaManagedPlayers(names: ["Emma"]))
        assert(items[0].showsTeamChat)
        assert(items[0].team.canAccessTeamChat)
        assert(!items[0].team.hasAccountSeat)

        // Dedup: RPC managed row + overlay same id → one card.
        let items2 = FanTeamHomeCatalog.build(
            accountTeams: [team],
            guardianOnlyTeams: [summary(id: teamId, name: "Warriors", role: .member)],
            viaNamesByTeamId: [teamId: ["Emma"]]
        )
        assert(items2.count == 1)
    }

    private static func testOwnerPlusManagedDedup() {
        let teamId = UUID()
        let items = FanTeamHomeCatalog.build(
            accountTeams: [summary(id: teamId, name: "Shared", role: .owner)],
            guardianOnlyTeams: [summary(id: teamId, name: "Shared", role: .member)],
            viaNamesByTeamId: [teamId: ["Emma"]]
        )
        assert(items.count == 1)
        assert(items[0].relationship == .owner)
    }

    private static func testManagerPlusManagedDedup() {
        let teamId = UUID()
        let items = FanTeamHomeCatalog.build(
            accountTeams: [summary(id: teamId, name: "Shared", role: .manager)],
            guardianOnlyTeams: [summary(id: teamId, name: "Shared", role: .member)],
            viaNamesByTeamId: [teamId: ["Emma"]]
        )
        assert(items.count == 1)
        assert(items[0].relationship == .manager)
    }

    private static func testMultipleManagedSameTeam() {
        let teamId = UUID()
        let items = FanTeamHomeCatalog.build(
            accountTeams: [],
            guardianOnlyTeams: [summary(id: teamId, name: "Warriors", role: .member)],
            viaNamesByTeamId: [teamId: ["Emma", "Amelia", "Emma"]]
        )
        assert(items.count == 1)
        assert(items[0].relationship == .viaManagedPlayers(names: ["Emma", "Amelia"]))
        let title = FanTeamHomeRelationshipPresentation.title(
            items[0].relationship,
            languageCode: "en"
        )
        assert(title.contains("Emma"))
        assert(title.contains("Amelia"))
    }

    private static func testSearchWithinFilter() {
        let items = FanTeamHomeCatalog.build(
            accountTeams: [
                summary(name: "JT", role: .owner),
                summary(name: "Eagles", role: .member),
                summary(name: "JT Reserves", role: .member)
            ],
            guardianOnlyTeams: [],
            viaNamesByTeamId: [:]
        )
        let managingJT = FanTeamHomeCatalog.displayItems(
            from: items,
            filter: .managing,
            searchText: "JT"
        )
        assert(managingJT.map(\.team.name) == ["JT"])
        let joinedJT = FanTeamHomeCatalog.displayItems(
            from: items,
            filter: .joined,
            searchText: "JT"
        )
        assert(joinedJT.map(\.team.name) == ["JT Reserves"])
    }

    private static func testCounts() {
        let items = FanTeamHomeCatalog.build(
            accountTeams: [
                summary(name: "A", role: .owner),
                summary(name: "B", role: .manager),
                summary(name: "C", role: .member)
            ],
            guardianOnlyTeams: [summary(name: "D", role: .member)],
            viaNamesByTeamId: [
                UUID(): ["Emma"] // ignored — no matching guardian team id
            ]
        )
        // D omitted without via names for its id — rebuild properly:
        let dId = UUID()
        let items2 = FanTeamHomeCatalog.build(
            accountTeams: [
                summary(name: "A", role: .owner),
                summary(name: "B", role: .manager),
                summary(name: "C", role: .member)
            ],
            guardianOnlyTeams: [summary(id: dId, name: "D", role: .member)],
            viaNamesByTeamId: [dId: ["Emma"]]
        )
        let counts = FanTeamHomeCatalog.counts(for: items2)
        assert(counts.all == 4)
        assert(counts.managing == 2)
        assert(counts.joined == 2)
        _ = items
    }

    /// Chat stays on every home relationship, including guardian-only and
    /// Owner/Manager with no Myself player seat.
    private static func testChatVisibleForEveryHomeRelationship() {
        let owner = FanTeamHomeCatalog.build(
            accountTeams: [summary(name: "JT", role: .owner)],
            guardianOnlyTeams: [],
            viaNamesByTeamId: [:]
        )
        assert(owner[0].showsTeamChat)
        assert(owner[0].team.hasAccountSeat)

        let manager = FanTeamHomeCatalog.build(
            accountTeams: [summary(name: "IMC", role: .manager)],
            guardianOnlyTeams: [],
            viaNamesByTeamId: [:]
        )
        assert(manager[0].showsTeamChat)

        let member = FanTeamHomeCatalog.build(
            accountTeams: [summary(name: "Eagles", role: .member)],
            guardianOnlyTeams: [],
            viaNamesByTeamId: [:]
        )
        assert(member[0].showsTeamChat)

        let emmaId = UUID()
        let emmaOnly = FanTeamHomeCatalog.build(
            accountTeams: [],
            guardianOnlyTeams: [summary(id: emmaId, name: "Warriors", role: .member)],
            viaNamesByTeamId: [emmaId: ["Emma"]]
        )
        assert(emmaOnly[0].showsTeamChat)
        assert(!emmaOnly[0].relationship.hasAccountSeat)

        let twoKidsId = UUID()
        let twoKids = FanTeamHomeCatalog.build(
            accountTeams: [
                summary(
                    id: twoKidsId,
                    name: "Warriors",
                    role: .member,
                    accessVia: .managedPlayer,
                    viaNames: ["Emma", "Amelia"]
                )
            ],
            guardianOnlyTeams: [],
            viaNamesByTeamId: [:]
        )
        assert(twoKids[0].showsTeamChat)
        assert(twoKids[0].relationship == .viaManagedPlayers(names: ["Emma", "Amelia"]))
    }

    /// Screenshot fixture: All 3 / Managing 3 / Joined 0.
    private static func testJoinedEmptyStatePresentation() {
        let items = FanTeamHomeCatalog.build(
            accountTeams: [
                summary(name: "JT", role: .owner),
                summary(name: "IMC Team", role: .manager),
                summary(name: "ER basketball", role: .owner)
            ],
            guardianOnlyTeams: [],
            viaNamesByTeamId: [:]
        )
        let snapshot = items
        let counts = FanTeamHomeCatalog.counts(for: items)
        assert(counts.all == 3)
        assert(counts.managing == 3)
        assert(counts.joined == 0)

        let joined = FanTeamHomeCatalog.displayItems(from: items, filter: .joined, searchText: "")
        assert(joined.isEmpty, "Joined 0 shows no Team cards")

        let joinedTitle = L10n.t(FanTeamHomeFilter.joined.emptyTitleKey, languageCode: "en")
        assert(joinedTitle == "No joined teams yet")
        assert(joinedTitle != "fan_teams_empty_joined_title")
        assert(!joinedTitle.contains("fan_teams_empty_joined_title"))

        let all = FanTeamHomeCatalog.displayItems(from: items, filter: .all, searchText: "")
        assert(all.map(\.team.name) == ["JT", "IMC Team", "ER basketball"])

        let managing = FanTeamHomeCatalog.displayItems(from: items, filter: .managing, searchText: "")
        assert(managing.map(\.team.name) == ["JT", "IMC Team", "ER basketball"])

        assert(items == snapshot, "filter switching does not mutate membership data")
        assert(FanTeamHomeCatalog.counts(for: items) == counts)
    }
}
#endif
