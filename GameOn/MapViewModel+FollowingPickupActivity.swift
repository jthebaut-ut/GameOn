import Foundation
import Supabase

private let pickupFollowingSeenActivitySignaturesKeyPrefix = "gameon.following.pickupSeenActivitySignatures."

// MARK: - Following → Games to Play (activity, refresh cadence, requester realtime)

extension MapViewModel {

    func resetPickupFollowingActivityStateForCacheClear() {
        hasUnreadPickupActivity = false
        pickupActivityCount = 0
        lastJoinStatusRefreshAt = nil
        lastSuccessfulFollowingJoinRequestsRefreshAt = nil
        lastSuccessfulFollowingJoinRequestsRefreshUserId = nil
        lastKnownJoinStatus = [:]
        pickupFollowingUnreadActivityGameIds = []
        pickupFollowingCardRefreshSpinGameId = nil
        pickupFollowingActivityPrimed = false
        pickupFollowingSeenActivitySignatureByGameId.removeAll()
        Task { await stopFollowingPickupRealtime() }
    }

    /// Call when user opens **Play → Playing** and authoritative join cards are present (or load finished).
    /// Persists per-game acknowledgements so reviewed activity does not return after relaunch.
    func acknowledgePickupFollowingGamesToPlayActivity() {
        guard currentUserAuthId != nil else { return }
        // Nothing presented yet — never false-ack unread activity against an empty/error list.
        guard !myPickupGameJoinRequestCards.isEmpty else { return }
        guard pickupFollowingActivityPrimed else { return }

        var nextSeen = hydratedPickupFollowingSeenActivitySignatures()
        var acknowledged: Set<UUID> = []
        var seenGame: Set<UUID> = []
        for c in myPickupGameJoinRequestCards {
            guard !seenGame.contains(c.pickupGameId) else { continue }
            seenGame.insert(c.pickupGameId)
            guard let g = pickupGamesFollowingTabCache[c.pickupGameId] else { continue }
            let join = lastKnownJoinStatus[c.pickupGameId] ?? Self.joinStatusTokenFromPill(c.pill)
            let sig = Self.pickupFollowingActivitySignature(
                game: g,
                joinStatus: join,
                spotsSummary: c.spotsRemainingSummary
            )
            nextSeen[c.pickupGameId] = sig
            acknowledged.insert(c.pickupGameId)
        }
        guard !acknowledged.isEmpty else { return }

        // Persist before mutating published unread so overlapping refreshes observe the new acks.
        persistPickupFollowingSeenActivitySignatures(nextSeen)
        pickupFollowingSeenActivitySignatureByGameId = nextSeen

        let loadedIds = Set(myPickupGameJoinRequestCards.map(\.pickupGameId))
        // Drop orphans that can no longer be reviewed; keep only still-loaded unread.
        pickupFollowingUnreadActivityGameIds.formIntersection(loadedIds)
        pickupFollowingUnreadActivityGameIds.subtract(acknowledged)
        pickupActivityCount = pickupFollowingUnreadActivityGameIds.count
        hasUnreadPickupActivity = pickupActivityCount > 0
#if DEBUG
        print("[PickupFollowingActivity] acknowledged gamesToPlay acked=\(acknowledged.count) unread=\(pickupActivityCount)")
#endif
    }

    /// Acknowledge a single pickup game after the user opens its details (or equivalent review).
    func acknowledgePickupFollowingActivity(for pickupGameId: UUID) {
        guard currentUserAuthId != nil else { return }
        guard let g = pickupGamesFollowingTabCache[pickupGameId]
                ?? resolvedPickupGameRow(for: pickupGameId) else { return }
        let card = myPickupGameJoinRequestCards.first(where: { $0.pickupGameId == pickupGameId })
        let join = lastKnownJoinStatus[pickupGameId]
            ?? card.map { Self.joinStatusTokenFromPill($0.pill) }
            ?? "unknown"
        let sig = Self.pickupFollowingActivitySignature(
            game: g,
            joinStatus: join,
            spotsSummary: card?.spotsRemainingSummary
        )
        var nextSeen = hydratedPickupFollowingSeenActivitySignatures()
        // Always acknowledge the latest loaded row signature for this game.
        nextSeen[pickupGameId] = sig
        persistPickupFollowingSeenActivitySignatures(nextSeen)
        pickupFollowingSeenActivitySignatureByGameId = nextSeen
        pickupFollowingUnreadActivityGameIds.remove(pickupGameId)
        pickupActivityCount = pickupFollowingUnreadActivityGameIds.count
        hasUnreadPickupActivity = pickupActivityCount > 0
    }

    func pickupFollowingCaptureActivityBaseline() -> [UUID: String] {
        var map: [UUID: String] = [:]
        var seenGame: Set<UUID> = []
        for c in myPickupGameJoinRequestCards {
            guard !seenGame.contains(c.pickupGameId) else { continue }
            seenGame.insert(c.pickupGameId)
            guard let g = pickupGamesFollowingTabCache[c.pickupGameId] else { continue }
            let join = lastKnownJoinStatus[c.pickupGameId] ?? Self.joinStatusTokenFromPill(c.pill)
            map[c.pickupGameId] = Self.pickupFollowingActivitySignature(
                game: g,
                joinStatus: join,
                spotsSummary: c.spotsRemainingSummary
            )
        }
        return map
    }

    func pickupFollowingApplyActivityAfterJoinListLoad(
        baseline: [UUID: String],
        wasPrimed: Bool,
        cards: [PickupGameJoinRequestCardDisplay],
        gameById: [UUID: PickupGameRow],
        statusByGameId: [UUID: String]
    ) {
        lastKnownJoinStatus = statusByGameId
        lastJoinStatusRefreshAt = Date()

        var firstCardByGame: [UUID: PickupGameJoinRequestCardDisplay] = [:]
        for c in cards {
            if firstCardByGame[c.pickupGameId] != nil { continue }
            firstCardByGame[c.pickupGameId] = c
        }

        var seen = hydratedPickupFollowingSeenActivitySignatures()

        if !wasPrimed {
            pickupFollowingActivityPrimed = true
            var unread: Set<UUID> = []
            for (gid, c) in firstCardByGame {
                guard let g = gameById[gid] else { continue }
                let join = statusByGameId[gid] ?? Self.joinStatusTokenFromPill(c.pill)
                let currentSig = Self.pickupFollowingActivitySignature(
                    game: g,
                    joinStatus: join,
                    spotsSummary: c.spotsRemainingSummary
                )
                if let prev = seen[gid] {
                    if prev != currentSig {
                        unread.insert(gid)
                    }
                } else {
                    // First observation of this game: seed as seen (no historical unread).
                    seen[gid] = currentSig
                }
            }
            persistPickupFollowingSeenActivitySignatures(seen)
            pickupFollowingSeenActivitySignatureByGameId = seen
            pickupFollowingUnreadActivityGameIds = unread
            pickupActivityCount = unread.count
            hasUnreadPickupActivity = pickupActivityCount > 0
#if DEBUG
            print("[PickupFollowingActivity] first_load seedGames=\(seen.count) unread=\(pickupActivityCount)")
#endif
            return
        }

        var changed: Set<UUID> = []
        for (gid, c) in firstCardByGame {
            guard let g = gameById[gid] else { continue }
            let join = statusByGameId[gid] ?? Self.joinStatusTokenFromPill(c.pill)
            let sig = Self.pickupFollowingActivitySignature(game: g, joinStatus: join, spotsSummary: c.spotsRemainingSummary)
            if let old = baseline[gid] {
                if old != sig { changed.insert(gid) }
            } else {
                changed.insert(gid)
            }
        }
        for gid in baseline.keys where firstCardByGame[gid] == nil {
            changed.insert(gid)
        }

        var unread = pickupFollowingUnreadActivityGameIds
        for gid in changed {
            guard let c = firstCardByGame[gid], let g = gameById[gid] else {
                // Game dropped from the list — do not keep a sticky unread orphan.
                unread.remove(gid)
                continue
            }
            let join = statusByGameId[gid] ?? Self.joinStatusTokenFromPill(c.pill)
            let currentSig = Self.pickupFollowingActivitySignature(game: g, joinStatus: join, spotsSummary: c.spotsRemainingSummary)
            let acknowledged = seen[gid]
            if acknowledged != currentSig {
                unread.insert(gid)
            } else {
                unread.remove(gid)
            }
        }

        // Reconcile loaded cards that did not appear in `changed` (e.g. ack raced a refresh).
        for (gid, c) in firstCardByGame where !changed.contains(gid) {
            guard let g = gameById[gid] else { continue }
            let join = statusByGameId[gid] ?? Self.joinStatusTokenFromPill(c.pill)
            let currentSig = Self.pickupFollowingActivitySignature(game: g, joinStatus: join, spotsSummary: c.spotsRemainingSummary)
            if seen[gid] == currentSig {
                unread.remove(gid)
            }
        }

        pickupFollowingSeenActivitySignatureByGameId = seen
        pickupFollowingUnreadActivityGameIds = unread
        pickupActivityCount = unread.count
        hasUnreadPickupActivity = pickupActivityCount > 0
#if DEBUG
        print("[PickupFollowingActivity] changed=\(changed.count) unread=\(pickupActivityCount)")
#endif
    }

    /// Pull-to-refresh on Following scroll or timer / foreground.
    func performPickupFollowingJoinListRefresh(isUserPull: Bool) async {
#if DEBUG
        print("[PickupJoinRefresh] trigger=\(isUserPull ? "pull" : "auto_or_foreground")")
#endif
        await loadMyPickupGameJoinRequestsForFollowing(
            forceRefresh: isUserPull,
            reason: isUserPull ? "pullToRefresh" : "autoOrForeground"
        )
    }

    /// Per-card refresh (Games to Play row).
    func refreshPickupFollowingJoinCard(pickupGameId: UUID) async {
#if DEBUG
        print("[PickupJoinRefresh] manual card gameId=\(pickupGameId.uuidString.lowercased())")
#endif
        if let game = pickupGamesFollowingTabCache[pickupGameId],
           let card = myPickupGameJoinRequestCards.first(where: { $0.pickupGameId == pickupGameId }) {
            let join = lastKnownJoinStatus[pickupGameId] ?? Self.joinStatusTokenFromPill(card.pill)
            var nextSeen = hydratedPickupFollowingSeenActivitySignatures()
            nextSeen[pickupGameId] = Self.pickupFollowingActivitySignature(
                game: game,
                joinStatus: join,
                spotsSummary: card.spotsRemainingSummary
            )
            persistPickupFollowingSeenActivitySignatures(nextSeen)
            pickupFollowingSeenActivitySignatureByGameId = nextSeen
        }
        pickupFollowingUnreadActivityGameIds.remove(pickupGameId)
        pickupFollowingCardRefreshSpinGameId = pickupGameId
        await loadMyPickupGameJoinRequestsForFollowing(
            forceRefresh: true,
            reason: "manualCardRefresh"
        )
        pickupFollowingCardRefreshSpinGameId = nil
        pickupActivityCount = pickupFollowingUnreadActivityGameIds.count
        hasUnreadPickupActivity = pickupActivityCount > 0
    }

    func stopFollowingPickupRealtime() async {
        pickupFollowingRealtimeDebounceTask?.cancel()
        pickupFollowingRealtimeDebounceTask = nil

        let task = pickupFollowingRealtimeTask
        let channel = pickupFollowingRealtimeChannel
        pickupFollowingRealtimeTask = nil
        pickupFollowingRealtimeChannel = nil

        task?.cancel()
        if let channel {
            await supabase.removeChannel(channel)
        }
        if let task {
            _ = await task.result
        }
    }

    func scheduleFollowingPickupRealtimeDebouncedReload() {
        pickupFollowingRealtimeDebounceTask?.cancel()
        pickupFollowingRealtimeDebounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
#if DEBUG
            print("[PickupRealtimeUpdate] debounced_reload")
#endif
            await self.loadMyPickupGameJoinRequestsForFollowing(
                forceRefresh: true,
                reason: "pickupRealtimeUpdate"
            )
        }
    }

    func syncFollowingPickupRealtimeSubscriptionIfNeeded(gameIds: [UUID]) async {
        guard !shouldSuppressAuthenticatedRefreshForSafeLogout else { return }
        let unique = Array(Set(gameIds))
        guard canFanUsePickupGamesUI, let uid = currentUserAuthId, !unique.isEmpty else {
            await stopFollowingPickupRealtime()
            return
        }
        let capped = Array(unique.prefix(120)).sorted { $0.uuidString < $1.uuidString }

        await stopFollowingPickupRealtime()

        pickupFollowingRealtimeTask = Task { [weak self] in
            guard let self else { return }
            await self.runFollowingPickupRealtimeLoop(userId: uid, gameIds: capped)
        }
    }

    private func runFollowingPickupRealtimeLoop(userId: UUID, gameIds: [UUID]) async {
        guard !Task.isCancelled, !gameIds.isEmpty else { return }

        let channel = supabase.channel("pickup-following-requester-\(userId.uuidString.lowercased())")
        pickupFollowingRealtimeChannel = channel

        let requesterFilter = RealtimePostgresFilter.eq("requester_user_id", value: userId.uuidString.lowercased())
        let requestStream = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "pickup_game_requests",
            filter: requesterFilter
        )

        let gameFilter = RealtimePostgresFilter.in("id", values: gameIds)
        let gameStream = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "pickup_games",
            filter: gameFilter
        )

        do {
            #if DEBUG
            print("[RealtimePublicationVerify] expected table=pickup_games publication=supabase_realtime migration=20260731_0030")
            #endif
            try await channel.subscribeWithError()
        } catch {
            if pickupFollowingRealtimeChannel === channel {
                pickupFollowingRealtimeChannel = nil
            }
#if DEBUG
            print("[PickupRealtimeUpdate] subscribe_failed error=\(String(describing: error))")
#endif
            return
        }

#if DEBUG
        print("[PickupRealtimeUpdate] subscribed games=\(gameIds.count)")
#endif

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { return }
                for await _ in requestStream {
                    if Task.isCancelled { break }
#if DEBUG
                    print("[PickupRealtimeUpdate] event=requests")
#endif
                    await MainActor.run { self.scheduleFollowingPickupRealtimeDebouncedReload() }
                }
            }
            group.addTask { [weak self] in
                guard let self else { return }
                for await _ in gameStream {
                    if Task.isCancelled { break }
#if DEBUG
                    print("[PickupRealtimeUpdate] event=pickup_games")
#endif
                    await MainActor.run { self.scheduleFollowingPickupRealtimeDebouncedReload() }
                }
            }
        }

        if pickupFollowingRealtimeChannel === channel {
            await supabase.removeChannel(channel)
            pickupFollowingRealtimeChannel = nil
        }
    }

    // MARK: - Persisted acknowledgement

    func hydratedPickupFollowingSeenActivitySignatures() -> [UUID: String] {
        if !pickupFollowingSeenActivitySignatureByGameId.isEmpty {
            return pickupFollowingSeenActivitySignatureByGameId
        }
        guard let uid = currentUserAuthId else { return [:] }
        let persisted = Self.readPickupFollowingSeenActivitySignatures(userId: uid)
        if !persisted.isEmpty {
            pickupFollowingSeenActivitySignatureByGameId = persisted
        }
        return persisted
    }

    private func persistPickupFollowingSeenActivitySignatures(_ map: [UUID: String]) {
        guard let uid = currentUserAuthId else { return }
        Self.writePickupFollowingSeenActivitySignatures(userId: uid, signatures: map)
    }

    private static func readPickupFollowingSeenActivitySignatures(userId: UUID) -> [UUID: String] {
        let key = pickupFollowingSeenActivitySignaturesKeyPrefix + userId.uuidString.lowercased()
        guard let data = UserDefaults.standard.data(forKey: key),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        var out: [UUID: String] = [:]
        out.reserveCapacity(raw.count)
        for (idRaw, sig) in raw {
            guard let id = UUID(uuidString: idRaw), !sig.isEmpty else { continue }
            out[id] = sig
        }
        return out
    }

    private static func writePickupFollowingSeenActivitySignatures(userId: UUID, signatures: [UUID: String]) {
        let key = pickupFollowingSeenActivitySignaturesKeyPrefix + userId.uuidString.lowercased()
        let capped = signatures
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .prefix(240)
        var raw: [String: String] = [:]
        raw.reserveCapacity(capped.count)
        for (id, sig) in capped {
            guard !sig.isEmpty else { continue }
            raw[id.uuidString.lowercased()] = sig
        }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: - Signatures

    static func joinStatusTokenFromPill(_ pill: PickupFollowingJoinRequestPillKind) -> String {
        switch pill {
        case .pending: return "pending"
        case .approved: return "approved"
        case .declined: return "rejected"
        case .cancelled: return "cancelled"
        case .withdrawing: return "withdrawing"
        case .canceledByOrganizer: return "canceled_by_organizer"
        }
    }

    static func pickupFollowingActivitySignature(
        game: PickupGameRow,
        joinStatus: String,
        spotsSummary: String?
    ) -> String {
        let spotsKey = spotsSummary ?? ""
        let appr = game.approved_join_count ?? -1
        // Meaningful fragment includes location identity so place-only edits mark new activity.
        let meaningful = PickupGameMeaningfulChange.activitySignatureFragment(for: game)
        return "\(joinStatus)|\(appr)|\(spotsKey)|\(meaningful)"
    }
}
