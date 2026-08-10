import Foundation
import Supabase

/// Lightweight shared Team-identity refresh for all active Team members.
///
/// Reuses `FanTeamIdentityChangeCenter` (same local path as Edit Team) so My Teams,
/// Team Detail, and Team Chat marks update without rebuilding Chat realtime / history.
///
/// Requires `public.fan_teams` in `supabase_realtime` (migration 20260934).
@MainActor
final class FanTeamIdentityRealtimeCoordinator {
    static let shared = FanTeamIdentityRealtimeCoordinator()

    private struct Snapshot: Equatable {
        var conversationId: UUID
        var name: String
        var sport: String
        var colorHex: String?
        var competitionLevel: PickupCompetitionLevel?
        var logoURL: String?
        var logoThumbnailURL: String?
    }

    private let service = FanTeamsService()
    private var channel: RealtimeChannelV2?
    private var listenTask: Task<Void, Never>?
    private var boundUserId: UUID?
    private var snapshotsByTeamId: [UUID: Snapshot] = [:]
    /// Last identity display refresh token per Team (logo/sport/color edits).
    private var displayRefreshTokensByTeamId: [UUID: UUID] = [:]
    private var foregroundRefreshTask: Task<Void, Never>?
    private var lastForegroundRefreshAt: Date?
    private var identityObserver: NSObjectProtocol?

    /// In-memory Team mark fields for Chat inbox / search / header (no network).
    struct MarkSnapshot: Equatable, Sendable {
        let teamId: UUID
        let conversationId: UUID
        let name: String
        let sport: String
        let memberCountHint: Int
        let competitionLevel: PickupCompetitionLevel?
        let colorHex: String?
        let logoURL: String?
        let logoThumbnailURL: String?
        let displayRefreshToken: UUID?
    }

    private static let foregroundMinInterval: TimeInterval = 8

    private init() {
        identityObserver = NotificationCenter.default.addObserver(
            forName: FanTeamIdentityChangeCenter.identityDidChangeNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let change = FanTeamIdentityChangeCenter.identityChange(from: note) else { return }
            Task { @MainActor [weak self] in
                self?.remember(change: change)
            }
        }
    }

    deinit {
        if let identityObserver {
            NotificationCenter.default.removeObserver(identityObserver)
        }
    }

    func startIfNeeded(userId: UUID) async {
        if boundUserId == userId, listenTask != nil, channel != nil {
            return
        }
        await stop()
        boundUserId = userId
#if DEBUG
        print("[FanTeamIdentityRealtime] starting user=\(userId.uuidString.lowercased())")
        print("[RealtimePublicationVerify] expected table=fan_teams publication=supabase_realtime migration=20260934")
#endif
        listenTask = Task { [weak self] in
            await self?.runListenerLoop(userId: userId)
        }
        await refreshAndPublishDiffs(reason: "start")
    }

    func stop() async {
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
        let task = listenTask
        listenTask = nil
        boundUserId = nil
        task?.cancel()
        await removeChannelOnly()
        if let task {
            _ = await task.result
        }
        let hadSnapshots = !snapshotsByTeamId.isEmpty
        snapshotsByTeamId.removeAll(keepingCapacity: false)
        displayRefreshTokensByTeamId.removeAll(keepingCapacity: false)
        if hadSnapshots {
            Self.postMembershipSnapshotsDidChange()
        }
#if DEBUG
        print("[FanTeamIdentityRealtime] stopped")
#endif
    }

    /// Resume / foreground: pull authoritative Team identity and publish only real diffs.
    func handleSceneBecameActive() {
        guard boundUserId != nil else { return }
        if let last = lastForegroundRefreshAt,
           Date().timeIntervalSince(last) < Self.foregroundMinInterval {
            return
        }
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await self.refreshAndPublishDiffs(reason: "foreground")
        }
    }

    /// Conversation ids for the viewer’s active Fan Teams (already loaded via `list_my_fan_teams`).
    var knownFanTeamConversationIds: Set<UUID> {
        Set(snapshotsByTeamId.values.map(\.conversationId))
    }

    /// Active Fan Team ids for the viewer (from `list_my_fan_teams` seed/diffs).
    var knownFanTeamIds: Set<UUID> {
        Set(snapshotsByTeamId.keys)
    }

    func teamId(forConversationId conversationId: UUID) -> UUID? {
        for (teamId, snap) in snapshotsByTeamId where snap.conversationId == conversationId {
            return teamId
        }
        return nil
    }

    /// Team accent hex for inbox / search tinting (nil → untinted white card).
    func colorHex(forConversationId conversationId: UUID) -> String? {
        for snap in snapshotsByTeamId.values where snap.conversationId == conversationId {
            return snap.colorHex
        }
        return nil
    }

    func colorHex(forTeamId teamId: UUID) -> String? {
        snapshotsByTeamId[teamId]?.colorHex
    }

    /// Authoritative Team mark for Chat surfaces. Prefer `teamId` when known.
    func markSnapshot(teamId: UUID?, conversationId: UUID?) -> MarkSnapshot? {
        let resolvedTeamId = teamId
            ?? conversationId.flatMap { self.teamId(forConversationId: $0) }
        guard let resolvedTeamId, let snap = snapshotsByTeamId[resolvedTeamId] else { return nil }
        return MarkSnapshot(
            teamId: resolvedTeamId,
            conversationId: snap.conversationId,
            name: snap.name,
            sport: snap.sport,
            memberCountHint: 0,
            competitionLevel: snap.competitionLevel,
            colorHex: snap.colorHex,
            logoURL: snap.logoURL,
            logoThumbnailURL: snap.logoThumbnailURL,
            displayRefreshToken: displayRefreshTokensByTeamId[resolvedTeamId]
        )
    }

    func fanTeamChatContext(forConversationId conversationId: UUID) -> FanTeamChatContext? {
        guard let mark = markSnapshot(teamId: nil, conversationId: conversationId) else { return nil }
        return FanTeamChatContext(
            conversationId: mark.conversationId,
            teamId: mark.teamId,
            teamName: mark.name,
            sport: mark.sport,
            memberCount: mark.memberCountHint,
            competitionLevel: mark.competitionLevel,
            logoURL: mark.logoURL,
            logoThumbnailURL: mark.logoThumbnailURL,
            colorHex: mark.colorHex
        )
    }

    func seed(from teams: [FanTeamSummary]) {
        for team in teams {
            snapshotsByTeamId[team.id] = Snapshot(
                conversationId: team.groupConversationId,
                name: team.name,
                sport: team.sport,
                colorHex: team.colorHex,
                competitionLevel: team.competitionLevel,
                logoURL: team.logoURL,
                logoThumbnailURL: team.logoThumbnailURL
            )
        }
        Self.postMembershipSnapshotsDidChange()
    }

    /// After `list_my_fan_teams`, publish identity diffs so open Detail/Chat update even if
    /// Realtime was offline while backgrounded.
    func publishDiffs(previous: [FanTeamSummary], next: [FanTeamSummary]) {
        // First seed: remember only — do not blast refresh tokens for every Team.
        if previous.isEmpty, snapshotsByTeamId.isEmpty {
            seed(from: next)
            return
        }
        let previousById = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let nextIds = Set(next.map(\.id))
        // Drop Teams the viewer is no longer a member of so Chat inbox Teams filter stays accurate.
        snapshotsByTeamId = snapshotsByTeamId.filter { nextIds.contains($0.key) }
        for team in next {
            let prev = previousById[team.id]
            let before = prev.map {
                Snapshot(
                    conversationId: $0.groupConversationId,
                    name: $0.name,
                    sport: $0.sport,
                    colorHex: $0.colorHex,
                    competitionLevel: $0.competitionLevel,
                    logoURL: $0.logoURL,
                    logoThumbnailURL: $0.logoThumbnailURL
                )
            } ?? snapshotsByTeamId[team.id]
            let after = Snapshot(
                conversationId: team.groupConversationId,
                name: team.name,
                sport: team.sport,
                colorHex: team.colorHex,
                competitionLevel: team.competitionLevel,
                logoURL: team.logoURL,
                logoThumbnailURL: team.logoThumbnailURL
            )
            snapshotsByTeamId[team.id] = after
            guard before != after else { continue }
            postChange(
                teamId: team.id,
                conversationId: after.conversationId,
                name: after.name,
                sport: after.sport,
                colorHex: after.colorHex,
                competitionLevel: after.competitionLevel,
                logoURL: after.logoURL,
                logoThumbnailURL: after.logoThumbnailURL,
                previousLogoURL: before?.logoURL,
                previousLogoThumbnailURL: before?.logoThumbnailURL
            )
        }
        // Membership / conversation linkage may change even when identity fields match.
        Self.postMembershipSnapshotsDidChange()
    }

    /// Posted when Team ↔ conversation membership snapshots change (Chat inbox Teams filter).
    static let membershipSnapshotsDidChangeNotification =
        Notification.Name("FanGeo.FanTeamMembershipSnapshotsDidChange")

    private static func postMembershipSnapshotsDidChange() {
        NotificationCenter.default.post(name: membershipSnapshotsDidChangeNotification, object: nil)
    }

    // MARK: - Private

    private func remember(change: FanTeamIdentityChange) {
        snapshotsByTeamId[change.teamId] = Snapshot(
            conversationId: change.conversationId,
            name: change.name,
            sport: change.sport,
            colorHex: change.colorHex,
            competitionLevel: change.competitionLevel,
            logoURL: change.logoURL,
            logoThumbnailURL: change.logoThumbnailURL
        )
        displayRefreshTokensByTeamId[change.teamId] = change.displayRefreshToken
    }

    private func refreshAndPublishDiffs(reason: String) async {
        guard boundUserId != nil else { return }
        do {
            let next = try await service.listMyTeams()
            if snapshotsByTeamId.isEmpty {
                seed(from: next)
            } else {
                let previous = snapshotsByTeamId.keys.compactMap { id -> FanTeamSummary? in
                    guard let snap = snapshotsByTeamId[id] else { return nil }
                    return FanTeamSummary(
                        id: id,
                        name: snap.name,
                        sport: snap.sport,
                        logoURL: snap.logoURL,
                        logoThumbnailURL: snap.logoThumbnailURL,
                        colorHex: snap.colorHex,
                        competitionLevel: snap.competitionLevel,
                        ownerUserId: UUID(),
                        groupConversationId: snap.conversationId,
                        myRole: .member,
                        memberCount: 0,
                        pendingInvitationCount: 0,
                        pushNotificationsMuted: false,
                        nextGameStartsAt: nil,
                        nextGameTitle: nil,
                        nextGameVenue: nil,
                        createdAt: nil
                    )
                }
                publishDiffs(previous: previous, next: next)
            }
            lastForegroundRefreshAt = Date()
#if DEBUG
            print("[FanTeamIdentityRealtime] refresh ok reason=\(reason) teams=\(next.count)")
#endif
        } catch {
#if DEBUG
            print("[FanTeamIdentityRealtime] refresh failed reason=\(reason) error=\(error.localizedDescription)")
#endif
        }
    }

    private func runListenerLoop(userId: UUID) async {
        defer {
            if boundUserId == userId {
                listenTask = nil
            }
        }

        let channel = supabase.channel(
            "fan-teams-identity-\(userId.uuidString.lowercased())"
        )
        self.channel = channel

        let updates = channel.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "fan_teams"
        )

        do {
            try await channel.subscribeWithError()
#if DEBUG
            print("[FanTeamIdentityRealtime] subscribed")
#endif
            for await action in updates {
                if Task.isCancelled { break }
                try Task.checkCancellation()
                handleUpdate(action)
            }
        } catch {
            if !(error is CancellationError) {
#if DEBUG
                print("[FanTeamIdentityRealtime] subscribe/stream error: \(error)")
#endif
            }
        }

        await removeChannelOnly()
    }

    private func handleUpdate(_ action: UpdateAction) {
        guard let teamId = Self.uuid(from: action.record["id"]) else { return }

        let name = Self.string(from: action.record["name"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sport = Self.string(from: action.record["sport"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty, let sport, !sport.isEmpty else { return }

        let colorHex = FanTeamColorPalette.normalized(Self.string(from: action.record["color_hex"]))
        let competitionLevel = PickupCompetitionLevel.parse(Self.string(from: action.record["competition_level"]))
        let logoURL = ImageDisplayURL.canonicalStorageURLString(Self.string(from: action.record["logo_url"])).nilIfEmpty
        let logoThumbnailURL = ImageDisplayURL.canonicalStorageURLString(
            Self.string(from: action.record["logo_thumbnail_url"])
        ).nilIfEmpty
        let conversationId = Self.uuid(from: action.record["group_conversation_id"])
            ?? snapshotsByTeamId[teamId]?.conversationId
        guard let conversationId else { return }

        let previous = snapshotsByTeamId[teamId]
        let next = Snapshot(
            conversationId: conversationId,
            name: name,
            sport: sport,
            colorHex: colorHex,
            competitionLevel: competitionLevel,
            logoURL: logoURL,
            logoThumbnailURL: logoThumbnailURL
        )
        guard previous != next else { return }

        // Prefer oldRecord logos when present; otherwise use last seeded snapshot.
        let previousLogo = ImageDisplayURL.canonicalStorageURLString(
            Self.string(from: action.oldRecord["logo_url"]) ?? previous?.logoURL
        ).nilIfEmpty
        let previousThumb = ImageDisplayURL.canonicalStorageURLString(
            Self.string(from: action.oldRecord["logo_thumbnail_url"]) ?? previous?.logoThumbnailURL
        ).nilIfEmpty

        snapshotsByTeamId[teamId] = next
        postChange(
            teamId: teamId,
            conversationId: conversationId,
            name: name,
            sport: sport,
            colorHex: colorHex,
            competitionLevel: competitionLevel,
            logoURL: logoURL,
            logoThumbnailURL: logoThumbnailURL,
            previousLogoURL: previousLogo,
            previousLogoThumbnailURL: previousThumb
        )
#if DEBUG
        print("[FanTeamIdentityRealtime] identity update team=\(teamId.uuidString.lowercased())")
#endif
    }

    private func postChange(
        teamId: UUID,
        conversationId: UUID,
        name: String,
        sport: String,
        colorHex: String?,
        competitionLevel: PickupCompetitionLevel?,
        logoURL: String?,
        logoThumbnailURL: String?,
        previousLogoURL: String?,
        previousLogoThumbnailURL: String?
    ) {
        let change = FanTeamIdentityChange(
            teamId: teamId,
            conversationId: conversationId,
            name: name,
            sport: sport,
            colorHex: colorHex,
            competitionLevel: competitionLevel,
            logoURL: logoURL,
            logoThumbnailURL: logoThumbnailURL,
            previousLogoURL: previousLogoURL,
            previousLogoThumbnailURL: previousLogoThumbnailURL
        )
        FanTeamIdentityChangeCenter.postIdentityChange(change)
    }

    private func removeChannelOnly() async {
        if let channel {
            await supabase.removeChannel(channel)
        }
        self.channel = nil
    }

    private static func uuid(from value: AnyJSON?) -> UUID? {
        guard let value else { return nil }
        if case .string(let s) = value {
            return UUID(uuidString: s)
        }
        return nil
    }

    private static func string(from value: AnyJSON?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let s):
            return s
        case .null:
            return nil
        default:
            return nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
