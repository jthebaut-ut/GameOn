import Foundation
import UserNotifications
import os

/// Persistent Action Center → Notifications inbox.
///
/// Local UserDefaults is a **cache**. Canonical rows live in Supabase
/// (`fan_notification_inbox`), created server-side independently of APNs.
struct FanGeoNotificationInboxEntry: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kindRaw: String
    var titleKey: String
    var titleFormatArgs: [String]
    var subtitleKey: String
    var subtitleFormatArgs: [String]
    var destinationRaw: String
    var timestamp: Date?
    var count: Int
    var personName: String?
    var personUsername: String?
    var personAvatarURL: String?
    var teamName: String?
    var eventTitle: String?
    var eventTypeLabel: String?
    var locationLabel: String?
    var eventStartAt: Date?
    var pickupGameId: UUID?
    var teamId: UUID?
    var invitationId: UUID?
    var friendshipId: UUID?
    var requesterUserId: UUID?
    var pokeId: UUID?
    var sportLabel: String?
    var matchupLabel: String?
    var opponentName: String? = nil
    var changeDetails: [FanGeoActionChangeDetailRecord]
    var moreChangesCount: Int
    var isRead: Bool
    var createdAt: Date
    var updatedAt: Date
    var notificationType: String? = nil
    var roleToken: String? = nil
    var managedPlayerId: UUID? = nil
    /// Optional so older local-cache rows without this key still decode.
    var isManagedPlayer: Bool? = nil
    var personAvatarThumbnailURL: String? = nil
    var proGameMatchId: String? = nil
    var proGameSnapshot: FanGeoProGameInboxSnapshot? = nil
    var scoreLine: String? = nil
    var scorerAttributionKind: String? = nil

    struct FanGeoActionChangeDetailRecord: Codable, Equatable, Sendable {
        var labelKey: String
        var oldValue: String?
        var newValue: String?
    }

    func asActionItem() -> FanGeoActionItem? {
        guard let kind = FanGeoActionKind(rawValue: kindRaw),
              kind.listSection == .notifications,
              let destination = FanGeoActionDestination(rawValue: destinationRaw)
        else { return nil }
        return FanGeoActionItem(
            id: id,
            kind: kind,
            titleKey: titleKey,
            titleFormatArgs: titleFormatArgs,
            subtitleKey: subtitleKey,
            subtitleFormatArgs: subtitleFormatArgs,
            destination: destination,
            timestamp: timestamp ?? createdAt,
            count: max(1, count),
            context: FanGeoActionContext(
                personName: personName,
                personUsername: personUsername,
                personAvatarURL: personAvatarURL,
                teamName: teamName,
                eventTitle: eventTitle,
                eventTypeLabel: eventTypeLabel,
                locationLabel: locationLabel,
                eventStartAt: eventStartAt,
                relativeTimestamp: timestamp ?? createdAt,
                changeDetails: changeDetails.map {
                    FanGeoActionChangeDetail(
                        labelKey: $0.labelKey,
                        oldValue: $0.oldValue,
                        newValue: $0.newValue
                    )
                },
                moreChangesCount: moreChangesCount,
                pickupGameId: pickupGameId,
                teamId: teamId,
                invitationId: invitationId,
                friendshipId: friendshipId,
                requesterUserId: requesterUserId,
                pokeId: pokeId,
                sportLabel: sportLabel,
                matchupLabel: matchupLabel,
                opponentName: opponentName,
                notificationType: notificationType,
                roleToken: roleToken,
                managedPlayerId: managedPlayerId,
                isManagedPlayer: isManagedPlayer ?? false,
                personAvatarThumbnailURL: personAvatarThumbnailURL,
                proGameMatchId: proGameMatchId ?? proGameSnapshot?.matchID,
                proGameSnapshot: proGameSnapshot,
                scoreLine: scoreLine,
                scorerAttributionKind: scorerAttributionKind
            )
        )
    }

    static func from(item: FanGeoActionItem, existing: FanGeoNotificationInboxEntry?) -> FanGeoNotificationInboxEntry {
        let now = Date()
        let next = FanGeoNotificationInboxEntry(
            id: item.id,
            kindRaw: item.kind.rawValue,
            titleKey: item.titleKey,
            titleFormatArgs: item.titleFormatArgs,
            subtitleKey: item.subtitleKey,
            subtitleFormatArgs: item.subtitleFormatArgs,
            destinationRaw: item.destination.rawValue,
            timestamp: item.timestamp,
            count: item.count,
            personName: keep(item.context.personName, existing?.personName),
            personUsername: keep(item.context.personUsername, existing?.personUsername),
            personAvatarURL: keep(item.context.personAvatarURL, existing?.personAvatarURL),
            teamName: keep(item.context.teamName, existing?.teamName),
            eventTitle: keep(item.context.eventTitle, existing?.eventTitle),
            eventTypeLabel: keep(item.context.eventTypeLabel, existing?.eventTypeLabel),
            locationLabel: keep(item.context.locationLabel, existing?.locationLabel),
            eventStartAt: item.context.eventStartAt ?? existing?.eventStartAt,
            pickupGameId: item.context.pickupGameId ?? existing?.pickupGameId,
            teamId: item.context.teamId ?? existing?.teamId,
            invitationId: item.context.invitationId ?? existing?.invitationId,
            friendshipId: item.context.friendshipId ?? existing?.friendshipId,
            requesterUserId: item.context.requesterUserId ?? existing?.requesterUserId,
            pokeId: item.context.pokeId ?? existing?.pokeId,
            sportLabel: keep(item.context.sportLabel, existing?.sportLabel),
            matchupLabel: keep(item.context.matchupLabel, existing?.matchupLabel),
            opponentName: keep(item.context.opponentName, existing?.opponentName),
            changeDetails: item.context.changeDetails.isEmpty
                ? (existing?.changeDetails ?? [])
                : item.context.changeDetails.map {
                    FanGeoActionChangeDetailRecord(
                        labelKey: $0.labelKey,
                        oldValue: $0.oldValue,
                        newValue: $0.newValue
                    )
                },
            moreChangesCount: item.context.changeDetails.isEmpty
                ? (existing?.moreChangesCount ?? 0)
                : item.context.moreChangesCount,
            isRead: existing?.isRead ?? false,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            notificationType: keep(item.context.notificationType, existing?.notificationType),
            roleToken: keep(item.context.roleToken, existing?.roleToken),
            managedPlayerId: item.context.managedPlayerId ?? existing?.managedPlayerId,
            isManagedPlayer: item.context.isManagedPlayer || (existing?.isManagedPlayer ?? false),
            personAvatarThumbnailURL: keep(
                item.context.personAvatarThumbnailURL,
                existing?.personAvatarThumbnailURL
            ),
            proGameMatchId: keep(
                item.context.proGameMatchId ?? item.context.proGameSnapshot?.matchID,
                existing?.proGameMatchId
            ),
            proGameSnapshot: item.context.proGameSnapshot ?? existing?.proGameSnapshot,
            scoreLine: keep(item.context.scoreLine, existing?.scoreLine),
            scorerAttributionKind: keep(item.context.scorerAttributionKind, existing?.scorerAttributionKind)
        )
        if let existing, existing.isPresentationEqual(to: next) {
            return existing
        }
        return next
    }

    /// UI-visible identity. Ignores `updatedAt` so identical refreshes do not republish.
    func isPresentationEqual(to other: FanGeoNotificationInboxEntry) -> Bool {
        var lhs = self
        var rhs = other
        let stamp = Date(timeIntervalSince1970: 0)
        lhs.updatedAt = stamp
        rhs.updatedAt = stamp
        return lhs == rhs
    }

    private static func keep(_ incoming: String?, _ existing: String?) -> String? {
        let next = incoming?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !next.isEmpty { return next }
        let prior = existing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return prior.isEmpty ? nil : prior
    }
}

/// Per-user notification history cache for Action Center.
/// Authority is Supabase; local storage is for instant paint + offline.
enum FanGeoNotificationInboxStore {
    private static let defaults = UserDefaults.standard

    private static let entriesMemory = OSAllocatedUnfairLock<[UUID: [FanGeoNotificationInboxEntry]]>(initialState: [:])
    private static let clearedMemory = OSAllocatedUnfairLock<[UUID: Set<String>]>(initialState: [:])

#if DEBUG
    static private(set) var lastSaveSkippedAsDuplicate = false
    static private(set) var lastReconcileDidChange = true

    static func resetPerformanceFlagsForTests() {
        lastSaveSkippedAsDuplicate = false
        lastReconcileDidChange = true
    }
#endif

    private static func storageKey(userId: UUID) -> String {
        "fangeo.actionCenter.notificationInbox.v2.\(userId.uuidString.lowercased())"
    }

    private static func clearedKey(userId: UUID) -> String {
        "fangeo.actionCenter.notificationCleared.v2.\(userId.uuidString.lowercased())"
    }

    static func loadEntries(userId: UUID) -> [FanGeoNotificationInboxEntry] {
        if let cached = entriesMemory.withLock({ $0[userId] }) {
            return cached
        }
        if let data = defaults.data(forKey: storageKey(userId: userId)),
           let decoded = try? JSONDecoder().decode([FanGeoNotificationInboxEntry].self, from: data) {
            entriesMemory.withLock { $0[userId] = decoded }
            return decoded
        }
        // One-time migrate from v1 local-only cache if present.
        let legacyKey = "fangeo.actionCenter.notificationInbox.v1.\(userId.uuidString.lowercased())"
        guard let legacy = defaults.data(forKey: legacyKey),
              let decoded = try? JSONDecoder().decode([FanGeoNotificationInboxEntry].self, from: legacy)
        else { return [] }
        save(entries: decoded, userId: userId)
        return decoded
    }

    static func loadClearedKeys(userId: UUID) -> Set<String> {
        if let cached = clearedMemory.withLock({ $0[userId] }) {
            return cached
        }
        let raw = defaults.stringArray(forKey: clearedKey(userId: userId))
            ?? defaults.stringArray(
                forKey: "fangeo.actionCenter.notificationCleared.v1.\(userId.uuidString.lowercased())"
            )
            ?? []
        let keys = Set(FanGeoActionCenterActionKey.sanitizedUnique(raw))
        clearedMemory.withLock { $0[userId] = keys }
        return keys
    }

    static func save(entries: [FanGeoNotificationInboxEntry], userId: UUID) {
        let trimmed = Array(entries.sorted { lhs, rhs in
            let l = (lhs.timestamp ?? lhs.createdAt).timeIntervalSince1970
            let r = (rhs.timestamp ?? rhs.createdAt).timeIntervalSince1970
            if l != r { return l > r }
            return lhs.id < rhs.id
        }.prefix(300))
        let previous = entriesMemory.withLock { $0[userId] }
        if let previous, presentationEquals(previous, Array(trimmed)) {
#if DEBUG
            lastSaveSkippedAsDuplicate = true
            FanGeoInboxOpenPerf.duplicatePublishSkipped(name: "inboxSave")
#endif
            return
        }
#if DEBUG
        lastSaveSkippedAsDuplicate = false
#endif
        entriesMemory.withLock { $0[userId] = Array(trimmed) }
        if let data = try? JSONEncoder().encode(Array(trimmed)) {
            defaults.set(data, forKey: storageKey(userId: userId))
        }
    }

    static func saveClearedKeys(_ keys: Set<String>, userId: UUID) {
        let previous = clearedMemory.withLock { $0[userId] }
        if previous == keys {
            return
        }
        clearedMemory.withLock { $0[userId] = keys }
        defaults.set(Array(keys).sorted(), forKey: clearedKey(userId: userId))
    }

    /// In-flight APNs rows may arrive before the next list RPC. Older local-only
    /// rows that the server no longer returns were cleared server-side (membership
    /// loss) and must not ghost back via cache or live upsert.
    private static let localOnlyIngestGrace: TimeInterval = 120

    /// Replaces cache with server page and merges recent local-only (APNs) rows not yet cleared.
    /// Server `cleared_at` is authoritative. Local cache is not the source of truth.
    @discardableResult
    static func reconcileFromServer(
        rows: [FanNotificationInboxServerRow],
        userId: UUID,
        pageLimit: Int = 50
    ) -> [FanGeoNotificationInboxEntry] {
        let serverEntries = rows.map { FanGeoNotificationInboxEntry.from(serverRow: $0) }
        var byId = dictionaryByEntryId(serverEntries)
        var cleared = loadClearedKeys(userId: userId)
        let previousCleared = cleared
        let local = loadEntries(userId: userId)
        let previousVisible = visibleEntries(from: local, cleared: previousCleared)
        let now = Date()
        let pageLooksComplete = rows.count < max(pageLimit, 1)
        let oldestServerCreatedAt = serverEntries.map(\.createdAt).min()
        let removedTeamIds = Set(
            serverEntries.compactMap { entry -> UUID? in
                guard (entry.notificationType ?? "").lowercased() == "removed_from_team" else {
                    return nil
                }
                return entry.teamId
            }
        )
        for entry in local {
            let key = FanGeoActionCenterActionKey.sanitize(entry.id)
            guard !cleared.contains(key) else { continue }
            if let server = byId[key] {
                // Prefer server read state; keep richer local change details if server empty.
                var merged = server
                if merged.teamId == nil {
                    merged.teamId = entry.teamId
                }
                if (merged.teamName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty,
                   let localTeam = entry.teamName?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !localTeam.isEmpty {
                    merged.teamName = localTeam
                }
                if (merged.sportLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty,
                   let localSport = entry.sportLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !localSport.isEmpty {
                    merged.sportLabel = localSport
                }
                if merged.changeDetails.isEmpty, !entry.changeDetails.isEmpty {
                    merged.changeDetails = entry.changeDetails
                    merged.moreChangesCount = entry.moreChangesCount
                }
                if merged.proGameSnapshot == nil,
                   let localSnapshot = entry.proGameSnapshot,
                   localSnapshot.isRenderable {
                    merged.proGameSnapshot = localSnapshot
                    if merged.proGameMatchId == nil {
                        merged.proGameMatchId = localSnapshot.matchID
                    }
                }
                byId[key] = merged
                continue
            }
            let notificationType = (entry.notificationType ?? "").lowercased()
            let isRemovedFromTeamRow = notificationType == "removed_from_team"
            // Standalone Pickup (no team_id) is out of scope for membership-loss clear.
            if entry.teamId == nil {
                byId[key] = entry
                continue
            }
            if isRemovedFromTeamRow {
                byId[key] = entry
                continue
            }
            let lostTeamAccess = entry.teamId.map { removedTeamIds.contains($0) } == true
            if lostTeamAccess {
                cleared.insert(key)
                continue
            }
            let keepAsInFlightAPNs = now.timeIntervalSince(entry.createdAt) <= localOnlyIngestGrace
            if keepAsInFlightAPNs {
                byId[key] = entry
                continue
            }
            let olderThanPage = oldestServerCreatedAt.map { entry.createdAt < $0 } == true
            if pageLooksComplete || !olderThanPage {
                // Server would have returned this Team row if it were still visible.
                cleared.insert(key)
            } else {
                byId[key] = entry
            }
        }
        saveClearedKeys(cleared, userId: userId)
        let next = Array(byId.values)
        let nextVisible = visibleEntries(from: next, cleared: cleared)
        if presentationEquals(nextVisible, previousVisible), cleared == previousCleared {
#if DEBUG
            lastReconcileDidChange = false
            FanGeoInboxOpenPerf.duplicatePublishSkipped(name: "reconcileVisible")
#endif
            return nextVisible
        }
#if DEBUG
        lastReconcileDidChange = true
#endif
        save(entries: next, userId: userId)
        return nextVisible
    }

    /// Upsert live / push notification candidates. Cleared keys are skipped until a new id appears.
    @discardableResult
    static func upsert(
        items: [FanGeoActionItem],
        userId: UUID
    ) -> [FanGeoNotificationInboxEntry] {
        let cleared = loadClearedKeys(userId: userId)
        var byId = dictionaryByEntryId(loadEntries(userId: userId))
        for item in items where item.kind.listSection == .notifications {
            let key = FanGeoActionCenterActionKey.sanitize(item.id)
            guard !key.isEmpty, !cleared.contains(key) else { continue }
            byId[key] = FanGeoNotificationInboxEntry.from(item: item, existing: byId[key])
        }
        let next = Array(byId.values)
        save(entries: next, userId: userId)
        return visibleEntries(from: next, cleared: cleared)
    }

    static func presentationEquals(
        _ lhs: [FanGeoNotificationInboxEntry],
        _ rhs: [FanGeoNotificationInboxEntry]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { $0.isPresentationEqual(to: $1) }
    }

    /// One row per `id`. Duplicate ids keep the newer `(timestamp ?? createdAt)`.
    /// Equal timestamps keep the last processed row (stable for a given input order).
    private static func dictionaryByEntryId(
        _ entries: [FanGeoNotificationInboxEntry]
    ) -> [String: FanGeoNotificationInboxEntry] {
        var byId: [String: FanGeoNotificationInboxEntry] = [:]
        byId.reserveCapacity(entries.count)
        for entry in entries {
            if let existing = byId[entry.id] {
                byId[entry.id] = preferredDuplicate(existing: existing, incoming: entry)
            } else {
                byId[entry.id] = entry
            }
        }
        return byId
    }

    private static func preferredDuplicate(
        existing: FanGeoNotificationInboxEntry,
        incoming: FanGeoNotificationInboxEntry
    ) -> FanGeoNotificationInboxEntry {
        let existingStamp = (existing.timestamp ?? existing.createdAt).timeIntervalSince1970
        let incomingStamp = (incoming.timestamp ?? incoming.createdAt).timeIntervalSince1970
        if incomingStamp != existingStamp {
            return incomingStamp > existingStamp ? incoming : existing
        }
        return incoming
    }

    static func visibleEntries(userId: UUID) -> [FanGeoNotificationInboxEntry] {
        visibleEntries(from: loadEntries(userId: userId), cleared: loadClearedKeys(userId: userId))
    }

    private static func visibleEntries(
        from entries: [FanGeoNotificationInboxEntry],
        cleared: Set<String>
    ) -> [FanGeoNotificationInboxEntry] {
        entries
            .filter { !cleared.contains(FanGeoActionCenterActionKey.sanitize($0.id)) }
            .sorted { lhs, rhs in
                let l = (lhs.timestamp ?? lhs.createdAt).timeIntervalSince1970
                let r = (rhs.timestamp ?? rhs.createdAt).timeIntervalSince1970
                if l != r { return l > r }
                return lhs.id < rhs.id
            }
    }

    @discardableResult
    static func markRead(ids: [String], userId: UUID) -> [FanGeoNotificationInboxEntry] {
        let keys = Set(FanGeoActionCenterActionKey.sanitizedUnique(ids))
        guard !keys.isEmpty else { return visibleEntries(userId: userId) }
        var entries = loadEntries(userId: userId)
        let now = Date()
        for i in entries.indices where keys.contains(FanGeoActionCenterActionKey.sanitize(entries[i].id)) {
            entries[i].isRead = true
            entries[i].updatedAt = now
        }
        save(entries: entries, userId: userId)
        return visibleEntries(from: entries, cleared: loadClearedKeys(userId: userId))
    }

    @discardableResult
    static func clear(ids: [String], userId: UUID) -> [FanGeoNotificationInboxEntry] {
        let keys = FanGeoActionCenterActionKey.sanitizedUnique(ids)
        guard !keys.isEmpty else { return visibleEntries(userId: userId) }
        var cleared = loadClearedKeys(userId: userId)
        for key in keys { cleared.insert(key) }
        saveClearedKeys(cleared, userId: userId)
        var entries = loadEntries(userId: userId)
        entries.removeAll { cleared.contains(FanGeoActionCenterActionKey.sanitize($0.id)) }
        save(entries: entries, userId: userId)
        return visibleEntries(from: entries, cleared: cleared)
    }

    @discardableResult
    static func clearAll(userId: UUID) -> [FanGeoNotificationInboxEntry] {
        let entries = loadEntries(userId: userId)
        var cleared = loadClearedKeys(userId: userId)
        for entry in entries {
            cleared.insert(FanGeoActionCenterActionKey.sanitize(entry.id))
        }
        saveClearedKeys(cleared, userId: userId)
        save(entries: [], userId: userId)
        return []
    }

    static func clearMemory(userId: UUID?) {
        guard let userId else { return }
        defaults.removeObject(forKey: storageKey(userId: userId))
        defaults.removeObject(forKey: clearedKey(userId: userId))
        defaults.removeObject(
            forKey: "fangeo.actionCenter.notificationInbox.v1.\(userId.uuidString.lowercased())"
        )
        defaults.removeObject(
            forKey: "fangeo.actionCenter.notificationCleared.v1.\(userId.uuidString.lowercased())"
        )
        entriesMemory.withLock { state in
            _ = state.removeValue(forKey: userId)
        }
        clearedMemory.withLock { state in
            _ = state.removeValue(forKey: userId)
        }
    }
}

/// Ingest APNs / local notification payloads into the Action Center notification inbox.
enum FanGeoNotificationInboxIngest {
    /// Types that belong in Action Needed (never mirrored as Notifications).
    private static let actionNeededSources: Set<String> = [
        "team_invitation",
        "fan_team_invitation",
        "friend_request",
        "pickup_game_invite",
        "pickup_creator_rating",
        "join_request"
    ]

    static func ingestIfNeeded(
        userInfo: [AnyHashable: Any],
        content: UNNotificationContent?,
        userId: UUID?
    ) {
        guard let userId else { return }
        guard let item = makeItem(userInfo: userInfo, content: content) else { return }
        _ = FanGeoNotificationInboxStore.upsert(items: [item], userId: userId)
        Task { @MainActor in
            MapViewModel.noteSharedActionCenterNotificationInboxChangedFromPush()
        }
        NotificationCenter.default.post(name: .fanGeoNotificationInboxDidChange, object: nil)
    }

    static func makeItem(
        userInfo: [AnyHashable: Any],
        content: UNNotificationContent?
    ) -> FanGeoActionItem? {
        let source = stringValue(userInfo["source"])?.lowercased() ?? ""
        let type = stringValue(userInfo["type"])?.lowercased()
            ?? stringValue(userInfo["notification_type"])?.lowercased()
            ?? stringValue(userInfo["kind"])?.lowercased()
            ?? ""
        if actionNeededSources.contains(source) || actionNeededSources.contains(type) {
            return nil
        }
        // Chat / DM stay in Chat unread — not Action Center Notifications.
        if source.contains("chat") || source.contains("direct_message") || type.contains("direct_message") {
            return nil
        }

        let title = content?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = content?.body.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let alertTitle = apsAlertTitle(userInfo) ?? title
        let alertBody = apsAlertBody(userInfo) ?? body
        let displayTitle = alertTitle.isEmpty ? (alertBody.isEmpty ? nil : alertBody) : alertTitle
        guard let displayTitle, !displayTitle.isEmpty else { return nil }

        let (kind, destination, stableId) = classify(
            source: source,
            type: type,
            userInfo: userInfo
        )
        guard kind.listSection == .notifications else { return nil }

        let pickupId = uuidValue(userInfo["pickup_game_id"])
        let teamId = uuidValue(userInfo["team_id"])
        let notificationType = stringValue(userInfo["notification_type"]) ?? type
        var payload: [String: AnyCodableJSON] = [:]
        for key in [
            "game_format", "event_type", "team_name", "title",
            "before_start", "after_start", "before_end", "after_end",
            "before_location", "after_location", "matchup",
            "before_opponent", "after_opponent", "before_status", "after_status",
            "before_title", "after_title", "before_game_format", "after_game_format",
            "before_visibility", "after_visibility",
            "score_line", "score_title", "scorer_display_name", "scorer_attribution_kind",
            "scorer_membership_id", "sport",
            "scoring_team", "league", "sport", "match_status", "clock", "minute",
            "home_badge_url", "away_badge_url", "home_provider_id", "away_provider_id"
        ] {
            if let value = stringValue(userInfo[key]) {
                payload[key] = .string(value)
            }
        }
        if stringValue(userInfo["is_team_announcement"])?.lowercased() == "true" {
            payload["is_team_announcement"] = .bool(true)
        }
        let proGameSnapshot = FanGeoProGameInboxSnapshot.from(
            userInfo: userInfo,
            notificationType: notificationType
        )
        let fields = FanGeoActionCenterTeamNotificationPresentation.inboxFields(
            from: FanNotificationInboxServerRow(
                id: UUID(),
                notification_type: notificationType,
                title: displayTitle,
                body: alertBody,
                kind_raw: kind.rawValue,
                destination_raw: destination.rawValue,
                source_type: source.isEmpty ? nil : source,
                source_id: nil,
                team_id: teamId,
                event_id: pickupId,
                actor_user_id: nil,
                payload: payload.isEmpty ? nil : payload,
                deduplication_key: stableId,
                created_at: Date(),
                read_at: nil,
                cleared_at: nil
            )
        )
        let isTeamNotification = kind != .securitySession && (teamId != nil || fields.teamName != nil)
        let securityDevice = FanGeoSecuritySessionReplacement.sanitizedDeviceFamily(
            stringValue(userInfo["new_device_type"])
        )
        return FanGeoActionItem(
            id: stableId,
            kind: kind,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: [displayTitle],
            subtitleKey: alertBody.isEmpty || alertBody == displayTitle
                ? "action_center_notification_subtitle_default"
                : "action_center_notification_title_passthrough_format",
            subtitleFormatArgs: alertBody.isEmpty || alertBody == displayTitle ? [] : [alertBody],
            destination: destination,
            timestamp: Date(),
            count: 1,
            context: FanGeoActionContext(
                personName: fields.personName,
                personAvatarURL: fields.personAvatarURL,
                teamName: isTeamNotification ? (fields.teamName ?? stringValue(userInfo["team_name"])) : nil,
                eventTitle: isTeamNotification ? (fields.eventTitle ?? displayTitle) : displayTitle,
                eventTypeLabel: kind == .securitySession
                    ? securityDevice
                    : (isTeamNotification ? fields.gameFormat : nil),
                locationLabel: fields.locationLabel ?? stringValue(userInfo["after_location"]),
                eventStartAt: isTeamNotification ? fields.eventStartAt : nil,
                changeDetails: isTeamNotification ? fields.changeDetails : [],
                pickupGameId: pickupId,
                teamId: teamId,
                requesterUserId: uuidValue(userInfo["sender_id"]) ?? uuidValue(userInfo["poker_id"]),
                pokeId: uuidValue(userInfo["poke_id"]) ?? uuidValue(userInfo["event_id"]),
                sportLabel: fields.sportLabel ?? stringValue(userInfo["sport"]),
                matchupLabel: stringValue(userInfo["matchup"]),
                opponentName: fields.opponentName ?? stringValue(userInfo["after_opponent"]),
                notificationType: isTeamNotification ? fields.notificationType ?? notificationType : notificationType,
                roleToken: fields.roleToken ?? stringValue(userInfo["role"]),
                managedPlayerId: fields.managedPlayerId,
                isManagedPlayer: fields.isManagedPlayer,
                personAvatarThumbnailURL: fields.personAvatarThumbnailURL,
                proGameMatchId: proGameSnapshot?.matchID ?? stringValue(userInfo["match_id"]),
                proGameSnapshot: proGameSnapshot,
                scoreLine: fields.scoreLine ?? stringValue(userInfo["score_line"]),
                scorerAttributionKind: fields.scorerAttributionKind
                    ?? stringValue(userInfo["scorer_attribution_kind"])
            )
        )
    }

    /// Prefer server `deduplication_key` / `inbox_dedupe_key` so APNs ingest merges with SQL rows.
    private static func classify(
        source: String,
        type: String,
        userInfo: [AnyHashable: Any]
    ) -> (FanGeoActionKind, FanGeoActionDestination, String) {
        if FanGeoSecuritySessionNotificationDeepLinkPayload.isSecuritySessionNotification(userInfo)
            || source == FanGeoSecuritySessionReplacement.source
            || type == FanGeoSecuritySessionReplacement.notificationType {
            let key = FanGeoActionCenterActionKey.sanitize(
                stringValue(userInfo["deduplication_key"])
                    ?? stringValue(userInfo["inbox_dedupe_key"])
                    ?? stringValue(userInfo["event_id"])
                    ?? "security_session_replaced"
            )
            return (.securitySession, .accountSecurity, key)
        }
        if let explicit = stringValue(userInfo["deduplication_key"])
            ?? stringValue(userInfo["inbox_dedupe_key"]) {
            let key = FanGeoActionCenterActionKey.sanitize(explicit)
            if key.hasPrefix("security_session_replaced:") {
                return (.securitySession, .accountSecurity, key)
            }
            if key.hasPrefix("pickup_cancel:") {
                return (.eventCancellation, .scheduleActivity, key)
            }
            if key.hasPrefix("poke:") {
                return (.poke, .accountPokes, key)
            }
            return (.scheduleChange, .scheduleActivity, key)
        }
        if PickupGameChangeNotificationDeepLinkPayload.isPickupGameChangeNotification(userInfo)
            || source.contains("pickup")
            || type.contains("team_game")
            || type.contains("team_announcement")
            || type.contains("schedule") {
            let gameId = uuidValue(userInfo["pickup_game_id"]) ?? UUID()
            let instance = stringValue(userInfo["pickup_update_event_id"])
                ?? stringValue(userInfo["event_id"])
                ?? type
            let isCancel = type.contains("cancel") || stringValue(userInfo["change_class"]) == "cancelled"
            if isCancel {
                return (
                    .eventCancellation,
                    .scheduleActivity,
                    FanGeoActionCenterActionKey.pickupCancel(gameId: gameId, instanceKey: instance)
                )
            }
            return (
                .scheduleChange,
                .scheduleActivity,
                FanGeoActionCenterActionKey.pickupUpdate(gameId: gameId, instanceKey: instance)
            )
        }
        if source == "member_change"
            || type.contains("removed_from_team")
            || type.contains("team_role")
            || type.contains("team_admin")
            || type.contains("player_number")
            || type.contains("preferred_position")
            || type.contains("removed_from_event")
            || type.contains("added_back_to_event") {
            let eventId = stringValue(userInfo["event_id"]) ?? UUID().uuidString
            let uid = stringValue(userInfo["recipient_user_id"])
                ?? stringValue(userInfo["target_user_id"])
            let teamId = stringValue(userInfo["team_id"])
            let kind = (stringValue(userInfo["kind"]) ?? type).lowercased()
            let key: String
            if let teamId, let uid {
                switch kind {
                case "removed_from_team":
                    key = "team_removed:\(teamId.lowercased()):\(uid.lowercased()):\(eventId.lowercased())"
                case "team_role_changed":
                    key = "team_role_changed:\(teamId.lowercased()):\(uid.lowercased()):\(eventId.lowercased())"
                case "team_admin_granted":
                    key = "team_admin_granted:\(teamId.lowercased()):\(uid.lowercased()):\(eventId.lowercased())"
                case "team_admin_removed":
                    key = "team_admin_removed:\(teamId.lowercased()):\(uid.lowercased()):\(eventId.lowercased())"
                default:
                    key = "team_member_change:\(eventId.lowercased()):\(uid.lowercased())"
                }
            } else {
                key = uid.map { "team_member_change:\(eventId):\($0)" }
                    ?? "team_member_change:\(eventId)"
            }
            return (
                .scheduleChange,
                .teamsHome,
                FanGeoActionCenterActionKey.sanitize(key)
            )
        }
        if source.contains("poke") || type.contains("poke") {
            let pokeId = uuidValue(userInfo["poke_id"]) ?? uuidValue(userInfo["event_id"]) ?? UUID()
            return (.poke, .accountPokes, FanGeoActionCenterActionKey.poke(pokeId))
        }
        let fallback = stringValue(userInfo["event_id"])
            ?? stringValue(userInfo["pickup_game_id"])
            ?? UUID().uuidString
        if source == ProGameNotificationDeepLinkPayload.sourceValue
            || type.hasPrefix("pro_game_") {
            let matchID = stringValue(userInfo["match_id"]) ?? fallback
            let snapshot = FanGeoProGameInboxSnapshot.from(
                userInfo: userInfo,
                notificationType: type.isEmpty ? stringValue(userInfo["notification_type"]) : type
            )
            return (
                .scheduleChange,
                .scheduleActivity,
                snapshot?.dedupeKey
                    ?? FanGeoActionCenterActionKey.sanitize("pro_game:\(type):\(matchID)")
            )
        }
        return (
            .scheduleChange,
            .scheduleActivity,
            FanGeoActionCenterActionKey.sanitize("push_notification:\(source):\(type):\(fallback)")
        )
    }

    private static func stringValue(_ raw: Any?) -> String? {
        if let s = raw as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return nil
    }

    private static func uuidValue(_ raw: Any?) -> UUID? {
        guard let s = stringValue(raw) else { return nil }
        return UUID(uuidString: s)
    }

    private static func apsAlertTitle(_ userInfo: [AnyHashable: Any]) -> String? {
        guard let aps = userInfo["aps"] as? [AnyHashable: Any] else { return nil }
        if let alert = aps["alert"] as? String { return alert }
        if let alert = aps["alert"] as? [AnyHashable: Any] {
            return stringValue(alert["title"])
        }
        return nil
    }

    private static func apsAlertBody(_ userInfo: [AnyHashable: Any]) -> String? {
        guard let aps = userInfo["aps"] as? [AnyHashable: Any] else { return nil }
        if let alert = aps["alert"] as? String { return alert }
        if let alert = aps["alert"] as? [AnyHashable: Any] {
            return stringValue(alert["body"])
        }
        return nil
    }
}

extension Notification.Name {
    static let fanGeoNotificationInboxDidChange = Notification.Name("fanGeoNotificationInboxDidChange")
}
