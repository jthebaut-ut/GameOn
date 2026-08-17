import Foundation

extension MapViewModel {
    @MainActor
    private static weak var actionCenterNotificationIngestHost: MapViewModel?

    @MainActor
    static func bindActionCenterNotificationIngestHost(_ host: MapViewModel) {
        actionCenterNotificationIngestHost = host
    }

    @MainActor
    static func sharedActionCenterUserIdForNotificationIngest() -> UUID? {
        actionCenterNotificationIngestHost?.currentUserAuthId
    }

    @MainActor
    static func noteSharedActionCenterNotificationInboxChangedFromPush() {
        actionCenterNotificationIngestHost?.noteActionCenterNotificationInboxChangedFromPush()
    }

    @MainActor
    func actionCenterScheduleActivityInputs(languageCode: String) -> [FanGeoActionScheduleActivityInput] {
        guard hasUnreadPickupActivity else { return [] }
        let unread = pickupFollowingUnreadActivityGameIds
        guard !unread.isEmpty else { return [] }

        var results: [FanGeoActionScheduleActivityInput] = []
        results.reserveCapacity(unread.count)

        for gameId in unread.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let game = pickupGamesFollowingTabCache[gameId]
                ?? myPickupGamesForSettings.first(where: { $0.id == gameId })
                ?? resolvedPickupGameRow(for: gameId)
            else {
                let card = myPickupGameJoinRequestCards.first(where: { $0.pickupGameId == gameId })
                let fallbackSignature = [
                    card?.title ?? "",
                    card?.game_start_at ?? "",
                    card?.pill == .canceledByOrganizer ? "cancelled" : "active"
                ].joined(separator: "|")
                results.append(
                    FanGeoActionScheduleActivityInput(
                        pickupGameId: gameId,
                        title: card?.title ?? L10n.t("Pickup", languageCode: languageCode),
                        teamName: pickupDiscoverTeamIdentityByGameId[gameId]?.teamName,
                        teamId: pickupDiscoverTeamIdentityByGameId[gameId]?.teamId,
                        eventTypeLabel: nil,
                        startAt: card.flatMap { PickupGameModels.parseSupabaseTimestamptz($0.game_start_at) },
                        locationLabel: card?.locationLine.nilIfEmpty,
                        isCancellation: card?.pill == .canceledByOrganizer,
                        changeDetails: [],
                        moreChangesCount: 0,
                        activityInstanceKey: FanGeoActionCenterActionKey.instanceKey(fromSignature: fallbackSignature)
                    )
                )
                continue
            }

            let team = pickupDiscoverTeamIdentityByGameId[gameId]
            let seen = hydratedPickupFollowingSeenActivitySignatures()[gameId]
            let diff = Self.actionCenterDiffFromSeenSignature(
                seenSignature: seen,
                currentGame: game,
                languageCode: languageCode
            )
            let title = game.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let currentSignature = PickupGameMeaningfulChange.activitySignatureFragment(for: game)
            results.append(
                FanGeoActionScheduleActivityInput(
                    pickupGameId: gameId,
                    title: title.isEmpty ? L10n.t("Pickup", languageCode: languageCode) : title,
                    teamName: team?.teamName,
                    teamId: team?.teamId,
                    eventTypeLabel: game.gameFormat.displayTitle(languageCode: languageCode),
                    startAt: PickupGameModels.parseSupabaseTimestamptz(game.game_start_at),
                    locationLabel: PickupGameMeaningfulChange.locationDisplayLabel(for: game).nilIfEmpty,
                    isCancellation: diff.isCancellation || game.isPickupGameSoftCancelled,
                    changeDetails: diff.details,
                    moreChangesCount: diff.moreCount,
                    activityInstanceKey: FanGeoActionCenterActionKey.instanceKey(fromSignature: currentSignature)
                )
            )
        }
        return results
    }

    @MainActor
    func actionCenterPickupInviteInputs(languageCode: String) -> [FanGeoActionPickupInviteInput] {
        incomingPickupGameInvites.map { invite in
            let team = pickupDiscoverTeamIdentityByGameId[invite.game.id]
            let inviter = invite.inviterProfile?.display_name?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return FanGeoActionPickupInviteInput(
                inviteId: invite.invite.id,
                pickupGameId: invite.game.id,
                gameTitle: invite.game.title,
                teamName: team?.teamName,
                eventTypeLabel: invite.game.gameFormat.displayTitle(languageCode: languageCode),
                startAt: PickupGameModels.parseSupabaseTimestamptz(invite.game.game_start_at),
                locationLabel: PickupGameMeaningfulChange.locationDisplayLabel(for: invite.game).nilIfEmpty,
                inviterName: inviter?.nilIfEmpty
            )
        }
    }

    @MainActor
    func actionCenterPokeInputs() -> [FanGeoActionPokeInput] {
        guard let authId = currentUserAuthId else { return [] }
        let items = ProfilePhase1PersonalizationCache.incomingPokesByAuthId[authId] ?? []
        let acknowledgedAt =
            UserDefaults.standard.object(forKey: pokesAcknowledgedAtStorageKey(for: authId)) as? Date
            ?? .distantPast
        return items.compactMap { item in
            guard !item.isDeleted else { return nil }
            guard let created = FanPropsRelativeTime.parse(item.createdAt), created > acknowledgedAt else {
                return nil
            }
            return FanGeoActionPokeInput(
                pokeId: item.id,
                pokerUserId: item.pokerUserId,
                displayName: item.pokerDisplayName,
                username: item.pokerUsername,
                avatarURL: item.pokerAvatarThumbnailURL ?? item.pokerAvatarURL,
                createdAt: created
            )
        }
    }

    /// Pending organizer ratings for Action Center — derived from existing Playing cards + rating caches (no network).
    @MainActor
    func actionCenterPendingRatingInputs(
        languageCode: String,
        now: Date = Date()
    ) -> [FanGeoActionPendingRatingInput] {
        guard canFanUsePickupGamesUI, currentUserAuthId != nil else { return [] }

        var results: [FanGeoActionPendingRatingInput] = []
        results.reserveCapacity(myPickupGameJoinRequestCards.count)

        for card in myPickupGameJoinRequestCards {
            guard card.pill == .approved else { continue }
            guard let game = pickupGamesFollowingTabCache[card.pickupGameId]
                ?? myPickupGamesForSettings.first(where: { $0.id == card.pickupGameId })
                ?? resolvedPickupGameRow(for: card.pickupGameId)
            else {
                continue
            }
            let joinStatus = pickupJoinRequestLatestByPickupGameIdForFan[card.pickupGameId]?.status
                ?? "approved"
            guard pickupCreatorRatingEligibility(
                game: game,
                joinStatus: joinStatus,
                now: now
            ).eligible else {
                continue
            }

            let team = pickupDiscoverTeamIdentityByGameId[card.pickupGameId]
            let teamName = team?.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchup = FanTeamScheduleMatchup.matchupLine(
                homeTeamName: teamName ?? "",
                opponentName: game.opponent_name,
                languageCode: languageCode
            )
            let organizerFromCache = pickupCreatorDisplayLabel(for: card.organizerUserId)
            let organizerRaw = (organizerFromCache ?? card.organizerName)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = game.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let avatarThumb = pickupOrganizerAvatarThumbnailForDetail(userId: card.organizerUserId)
            let avatarFull = pickupOrganizerAvatarFullForDetail(userId: card.organizerUserId)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            results.append(
                FanGeoActionPendingRatingInput(
                    pickupGameId: card.pickupGameId,
                    organizerUserId: card.organizerUserId,
                    organizerName: organizerRaw.isEmpty
                        ? L10n.t("pickup_rating_organizer_fallback", languageCode: languageCode)
                        : organizerRaw,
                    organizerAvatarURL: avatarThumb ?? (avatarFull.isEmpty ? nil : avatarFull),
                    gameTitle: title.isEmpty
                        ? L10n.t("Pickup", languageCode: languageCode)
                        : title,
                    teamName: (teamName?.isEmpty == false) ? teamName : nil,
                    eventTypeLabel: game.gameFormat.displayTitle(languageCode: languageCode),
                    matchupLabel: matchup,
                    startAt: PickupGameModels.parseSupabaseTimestamptz(game.game_start_at)
                )
            )
        }

        results.sort {
            let lhs = $0.startAt?.timeIntervalSince1970 ?? 0
            let rhs = $1.startAt?.timeIntervalSince1970 ?? 0
            if lhs != rhs { return lhs > rhs }
            return $0.pickupGameId.uuidString < $1.pickupGameId.uuidString
        }
        return results
    }

    /// Compare persisted activity signature against the current game row (no network).
    static func actionCenterDiffFromSeenSignature(
        seenSignature: String?,
        currentGame: PickupGameRow,
        languageCode: String
    ) -> (details: [FanGeoActionChangeDetail], moreCount: Int, isCancellation: Bool) {
        let currentMeaningful = PickupGameMeaningfulChange.activitySignatureFragment(for: currentGame)
        guard let seenSignature, !seenSignature.isEmpty else {
            return ([], 0, currentGame.isPickupGameSoftCancelled)
        }
        let parts = seenSignature.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        // Signature: join|approved|spots|meaningful(13 fields)
        guard parts.count >= 16 else {
            return ([], 0, currentGame.isPickupGameSoftCancelled)
        }
        let oldMeaningful = parts.suffix(from: 3).joined(separator: "|")
        let oldFields = oldMeaningful.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let newFields = currentMeaningful.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard oldFields.count >= 13, newFields.count >= 13 else {
            return ([], 0, currentGame.isPickupGameSoftCancelled)
        }

        var changed: [PickupGameMeaningfulChangeKind] = []
        func note(_ kind: PickupGameMeaningfulChangeKind, oldIdx: Int, newIdx: Int) {
            if oldFields[oldIdx] != newFields[newIdx], !changed.contains(kind) {
                changed.append(kind)
            }
        }
        note(.title, oldIdx: 0, newIdx: 0)
        note(.status, oldIdx: 1, newIdx: 1)
        note(.start, oldIdx: 2, newIdx: 2)
        note(.end, oldIdx: 3, newIdx: 3)
        note(.location, oldIdx: 4, newIdx: 4)
        if oldFields[5] != newFields[5] || oldFields[6] != newFields[6], !changed.contains(.capacity) {
            changed.append(.capacity)
        }
        note(.visibility, oldIdx: 7, newIdx: 7)
        note(.sport, oldIdx: 8, newIdx: 8)
        note(.skill, oldIdx: 9, newIdx: 9)
        note(.environment, oldIdx: 10, newIdx: 10)
        note(.welcome, oldIdx: 11, newIdx: 11)
        note(.cost, oldIdx: 12, newIdx: 12)

        let isCancellation = oldFields[1] != "removed" && newFields[1] == "removed"
        if isCancellation {
            return ([], 0, true)
        }

        let priority: [PickupGameMeaningfulChangeKind] = [
            .start, .end, .location, .title, .sport, .capacity, .status, .skill, .environment, .welcome, .cost, .visibility
        ]
        let ordered = priority.filter { changed.contains($0) }
        let primary = Array(ordered.prefix(3))
        let more = max(0, ordered.count - primary.count)

        var details: [FanGeoActionChangeDetail] = []
        for kind in primary {
            switch kind {
            case .start:
                details.append(
                    FanGeoActionChangeDetail(
                        labelKey: FanGeoActionCenterCopy.changeLabelKey(for: .start),
                        oldValue: FanGeoActionCenterCopy.formattedStartRaw(oldFields[2], languageCode: languageCode),
                        newValue: FanGeoActionCenterCopy.formattedStartRaw(newFields[2], languageCode: languageCode)
                    )
                )
            case .end:
                details.append(
                    FanGeoActionChangeDetail(
                        labelKey: FanGeoActionCenterCopy.changeLabelKey(for: .end),
                        oldValue: FanGeoActionCenterCopy.formattedStartRaw(oldFields[3], languageCode: languageCode),
                        newValue: FanGeoActionCenterCopy.formattedStartRaw(newFields[3], languageCode: languageCode)
                    )
                )
            case .location:
                details.append(
                    FanGeoActionChangeDetail(
                        labelKey: FanGeoActionCenterCopy.changeLabelKey(for: .location),
                        oldValue: nil,
                        newValue: PickupGameMeaningfulChange.locationDisplayLabel(for: currentGame).nilIfEmpty
                    )
                )
            default:
                details.append(
                    FanGeoActionChangeDetail(
                        labelKey: FanGeoActionCenterCopy.changeLabelKey(for: kind),
                        oldValue: nil,
                        newValue: nil
                    )
                )
            }
        }
        return (details, more, false)
    }

    // MARK: - Action Center dismissals

    /// Pending-request X / snooze lasts this TTL (persisted locally across launches).
    static let actionCenterPendingSnoozeTTL: TimeInterval = FanGeoActionCenterLocalVisibility.pendingSnoozeTTL

    func clearActionCenterDismissalsFromMemory() {
        actionCenterDismissedKeys = []
        actionCenterPendingSnoozedAt = [:]
        actionCenterClearAllHiddenKeys = []
        actionCenterLastKnownPendingKeys = []
        actionCenterNotificationInboxEpoch &+= 1
    }

    func activeActionCenterPendingSnoozeKeys(now: Date = Date()) -> Set<String> {
        FanGeoActionCenterLocalVisibility.pendingSnoozeKeysForProjection(
            inMemory: actionCenterPendingSnoozedAt,
            userId: currentUserAuthId,
            now: now
        )
    }

    func hydrateActionCenterDismissalsForCurrentUser() {
        guard let userId = currentUserAuthId else {
            clearActionCenterDismissalsFromMemory()
            return
        }
        actionCenterPendingSnoozedAt = FanGeoActionCenterLocalVisibility.loadPendingSnooze(userId: userId)
        let local = FanGeoActionCenterLocalVisibility.loadPermanentDismissedKeys(userId: userId)
        actionCenterDismissedKeys = local
        actionCenterClearAllHiddenKeys = FanGeoActionCenterLocalVisibility.loadClearAllHiddenKeys(userId: userId)
        actionCenterLastKnownPendingKeys = FanGeoActionCenterLocalVisibility.loadLastKnownPendingKeys(userId: userId)
        FanGeoActionCenterLocalVisibility.rememberUserId(userId)
        FanGeoActionCenterLocalVisibility.savePermanentDismissedKeys(local, userId: userId)
        actionCenterNotificationInboxEpoch &+= 1
        ActionCenterDismissDebug.log(
            "hydrateLocal userID=\(userId.uuidString.lowercased()) dismissalCount=\(local.count)"
        )
        Task { await refreshActionCenterDismissalsFromServer(userId: userId) }
        Task { await refreshNotificationInboxFromServer() }
    }

    /// Fetches durable Supabase inbox and reconciles into the local cache.
    @MainActor
    func refreshNotificationInboxFromServer() async {
        guard currentUserAuthId != nil else { return }
        FanGeoInboxOpenPerf.reconcileStarted()
        FanGeoInboxOpenPerf.noteAsyncTaskStarted()
        defer { FanGeoInboxOpenPerf.noteAsyncTaskFinished() }
        do {
            let rows = try await FanGeoNotificationInboxService.fetchPage(limit: 100)
            guard let userId = currentUserAuthId else { return }
            let before = FanGeoNotificationInboxStore.visibleEntries(userId: userId)
            let after = FanGeoNotificationInboxStore.reconcileFromServer(
                rows: rows,
                userId: userId,
                pageLimit: 100
            )
            let didChange = !FanGeoNotificationInboxStore.presentationEquals(before, after)
            FanGeoInboxOpenPerf.reconcileCompleted(didChange: didChange)
            if didChange {
                actionCenterNotificationInboxEpoch &+= 1
                FanGeoInboxOpenPerf.inboxPublished(name: "reconcile")
            }
        } catch {
#if DEBUG
            print("[FanNotificationInbox] refreshFailed \(error.localizedDescription)")
#endif
            FanGeoInboxOpenPerf.reconcileCompleted(didChange: false)
        }
    }

    /// Builds Action Center snapshot and syncs live notification candidates into the inbox.
    @MainActor
    func makeActionCenterSnapshot(
        languageCode: String,
        teamInvitations: [FanGeoActionTeamInviteInput],
        teamInvitationCount: Int,
        friendRequests: [FanGeoActionFriendRequestInput],
        friendRequestCount: Int,
        chatUnreadCount: Int,
        showsBusinessClaim: Bool
    ) -> FanGeoActionCenterProjection.Snapshot {
        let userId = FanGeoActionCenterLocalVisibility.resolvedUserId(currentUserAuthId)
        let seenPendingKeys = FanGeoActionCenterActionKey.sanitizedUnique(
            teamInvitations.map { FanGeoActionCenterActionKey.teamInvite($0.invitationId) }
                + friendRequests.map { FanGeoActionCenterActionKey.friendRequest($0.friendshipId) }
                + pendingPickupJoinApprovalSummaries.map { FanGeoActionCenterActionKey.joinApproval($0.requestId) }
                + incomingPickupGameInvites.map { FanGeoActionCenterActionKey.pickupInvite($0.invite.id) }
        )
        if let userId {
            let merged = FanGeoActionCenterLocalVisibility.mergingLastKnownPendingKeys(
                seenPendingKeys,
                into: actionCenterLastKnownPendingKeys
            )
            if merged != actionCenterLastKnownPendingKeys {
                actionCenterLastKnownPendingKeys = merged
                FanGeoActionCenterLocalVisibility.saveLastKnownPendingKeys(merged, userId: userId)
            }
        }
        let resolvedDismissed = FanGeoActionCenterLocalVisibility.dismissedKeysForProjection(
            inMemory: actionCenterDismissedKeys,
            userId: userId
        )
        let resolvedSnooze = FanGeoActionCenterLocalVisibility.pendingSnoozeKeysForProjection(
            inMemory: actionCenterPendingSnoozedAt,
            userId: userId
        )
        let resolvedClearAllHidden = FanGeoActionCenterLocalVisibility.clearAllHiddenKeysForProjection(
            inMemory: actionCenterClearAllHiddenKeys,
            userId: userId
        )
        let resolvedLastKnownPending = FanGeoActionCenterLocalVisibility.lastKnownPendingKeysForProjection(
            inMemory: actionCenterLastKnownPendingKeys,
            userId: userId
        )
        let cacheKey = FanGeoActionCenterSnapshotCacheKey(
            epoch: actionCenterNotificationInboxEpoch,
            languageCode: languageCode,
            teamInvitationIds: teamInvitations.map(\.invitationId),
            friendRequestIds: friendRequests.map(\.friendshipId),
            pickupInviteIds: incomingPickupGameInvites.map(\.invite.id),
            joinApprovalIds: pendingPickupJoinApprovalSummaries.map(\.requestId),
            pendingRatingGameIds: myPickupGameJoinRequestCards
                .filter { $0.pill == .approved }
                .map(\.pickupGameId),
            scheduleUnreadIds: pickupFollowingUnreadActivityGameIds.sorted {
                $0.uuidString < $1.uuidString
            },
            pokeCount: unseenPokesCount,
            unseenPokesCount: unseenPokesCount,
            showsBusinessClaim: showsBusinessClaim,
            chatUnreadCount: chatUnreadCount,
            dismissedCount: resolvedDismissed.count,
            snoozeCount: resolvedSnooze.count,
            clearAllHiddenCount: resolvedClearAllHidden.count,
            isSignedIn: isAuthenticatedForSocialFeatures
        )
        if let cached = actionCenterSnapshotCache,
           actionCenterSnapshotCacheKey == cacheKey {
            FanGeoInboxOpenPerf.duplicatePublishSkipped(name: "actionCenterSnapshot")
            return cached
        }

        let snapshot = FanGeoInboxOpenPerf.measureMainActor("makeActionCenterSnapshot") {
            let persistedEntries = userId.map { FanGeoNotificationInboxStore.visibleEntries(userId: $0) } ?? []
            let clearedKeys = userId.map { FanGeoNotificationInboxStore.loadClearedKeys(userId: $0) } ?? []
            let persistedItems = persistedEntries.compactMap { entry -> FanGeoActionItem? in
                guard let item = entry.asActionItem() else { return nil }
                return FanGeoTeamEventAffectedPlayerResolver.applyingAccountOwner(
                    to: item,
                    displayName: currentUserDisplayName,
                    avatarURL: currentUserAvatarURL,
                    avatarThumbnailURL: currentUserAvatarThumbnailURL
                )
            }
            let unreadIds = Set(persistedEntries.filter { !$0.isRead }.map(\.id))

            let draft = FanGeoActionCenterProjection.snapshot(
                from: FanGeoActionCenterProjection.Inputs(
                    teamInvitations: teamInvitations,
                    teamInvitationCount: teamInvitationCount,
                    pickupInvites: actionCenterPickupInviteInputs(languageCode: languageCode),
                    friendRequests: friendRequests,
                    friendRequestCount: friendRequestCount,
                    joinApprovals: pendingPickupJoinApprovalSummaries,
                    pendingJoinApprovalCount: pendingPickupGameJoinRequestCount,
                    pendingRatings: actionCenterPendingRatingInputs(languageCode: languageCode),
                    scheduleActivities: actionCenterScheduleActivityInputs(languageCode: languageCode),
                    scheduleActivityCount: pickupActivityCount,
                    hasUnreadScheduleActivity: hasUnreadPickupActivity,
                    pokes: actionCenterPokeInputs(),
                    unseenPokesCount: unseenPokesCount,
                    hasUnseenPokes: canReceiveProfilePokes && hasUnseenPokes,
                    showsBusinessClaim: showsBusinessClaim,
                    chatUnreadCount: chatUnreadCount,
                    isSignedInForSocial: isAuthenticatedForSocialFeatures,
                    dismissedActionKeys: resolvedDismissed,
                    sessionSnoozedPendingKeys: resolvedSnooze,
                    clearAllHiddenActionKeys: resolvedClearAllHidden,
                    lastKnownPendingActionKeys: resolvedLastKnownPending,
                    persistedNotifications: persistedItems,
                    unreadNotificationIds: unreadIds,
                    clearedNotificationKeys: clearedKeys
                )
            )
            scheduleInboxLiveCandidateSync(
                userId: userId,
                candidates: draft.liveNotificationCandidates
            )
            return draft
        }
        actionCenterSnapshotCacheKey = cacheKey
        actionCenterSnapshotCache = snapshot
        return snapshot
    }

    @MainActor
    private func scheduleInboxLiveCandidateSync(
        userId: UUID?,
        candidates: [FanGeoActionItem]
    ) {
        guard let userId, !candidates.isEmpty else { return }
        let fingerprint = candidates
            .map {
                "\($0.id)|\(Int($0.timestamp?.timeIntervalSince1970 ?? 0))|\($0.titleFormatArgs.first ?? "")"
            }
            .joined(separator: ",")
        guard fingerprint != lastInboxLiveCandidateFingerprint else { return }
        lastInboxLiveCandidateFingerprint = fingerprint
        Task { @MainActor in
            await Task.yield()
            let before = FanGeoNotificationInboxStore.visibleEntries(userId: userId)
            _ = FanGeoNotificationInboxStore.upsert(items: candidates, userId: userId)
            let after = FanGeoNotificationInboxStore.visibleEntries(userId: userId)
            if !FanGeoNotificationInboxStore.presentationEquals(before, after) {
                actionCenterNotificationInboxEpoch &+= 1
                FanGeoInboxOpenPerf.inboxPublished(name: "liveCandidates")
            } else {
                FanGeoInboxOpenPerf.duplicatePublishSkipped(name: "liveCandidates")
            }
        }
    }

    func markActionCenterNotificationRead(_ item: FanGeoActionItem) {
        guard item.kind.listSection == .notifications,
              let userId = currentUserAuthId else { return }
        _ = FanGeoNotificationInboxStore.markRead(ids: [item.id], userId: userId)
        actionCenterNotificationInboxEpoch &+= 1
        let key = item.id
        Task {
            try? await FanGeoNotificationInboxService.markRead(deduplicationKeys: [key])
        }
    }

    func clearActionCenterNotification(_ item: FanGeoActionItem) {
        guard item.kind.listSection == .notifications,
              let userId = currentUserAuthId else { return }
        _ = FanGeoNotificationInboxStore.clear(ids: [item.id], userId: userId)
        actionCenterNotificationInboxEpoch &+= 1
        ActionCenterDismissDebug.log("notificationCleared actionKey=\(item.id)")
        let key = item.id
        Task {
            try? await FanGeoNotificationInboxService.clear(deduplicationKeys: [key])
        }
    }

    func clearAllActionCenterNotifications() {
        guard let userId = currentUserAuthId else { return }
        _ = FanGeoNotificationInboxStore.clearAll(userId: userId)
        actionCenterNotificationInboxEpoch &+= 1
        ActionCenterDismissDebug.log("notificationClearAll")
        Task {
            try? await FanGeoNotificationInboxService.clearAll()
        }
    }

    func noteActionCenterNotificationInboxChangedFromPush() {
        actionCenterNotificationInboxEpoch &+= 1
    }

    func dismissActionCenterItems(_ items: [FanGeoActionItem]) {
        let actionItems = items.filter { $0.kind.listSection == .actionNeeded }
        let permanentItems = actionItems.filter { $0.kind.dismissalPersistence == .permanent }
        let pendingItems = actionItems.filter { $0.kind.dismissalPersistence == .sessionSnooze }
        snoozePendingActionCenterItems(pendingItems)
        let keys = FanGeoActionCenterActionKey.sanitizedUnique(permanentItems.map(\.id))
        guard !keys.isEmpty else {
            if !pendingItems.isEmpty {
                ActionCenterDismissDebug.log(
                    "dismissSucceeded persistence=sessionSnooze " +
                    "actionKey=\(pendingItems.first?.id ?? "") count=\(pendingItems.count)"
                )
            }
            return
        }
        applyActionCenterDismissalMutation(adding: keys, removing: [])
        ActionCenterDismissDebug.log(
            "dismissSucceeded persistence=permanent actionKey=\(keys.first ?? "") count=\(keys.count) " +
            "dismissalCount=\(actionCenterDismissedKeys.count)"
        )
        persistActionCenterDismissalsToServer(upsert: keys, delete: [])
    }

    func undismissActionCenterItems(_ items: [FanGeoActionItem]) {
        let actionItems = items.filter { $0.kind.listSection == .actionNeeded }
        let permanentItems = actionItems.filter { $0.kind.dismissalPersistence == .permanent }
        let pendingItems = actionItems.filter { $0.kind.dismissalPersistence == .sessionSnooze }
        unsnoozePendingActionCenterItems(pendingItems)
        let keys = FanGeoActionCenterActionKey.sanitizedUnique(permanentItems.map(\.id))
        guard !keys.isEmpty else { return }
        applyActionCenterDismissalMutation(adding: [], removing: keys)
        ActionCenterDismissDebug.log("undoTapped count=\(keys.count) actionKey=\(keys.first ?? "")")
        persistActionCenterDismissalsToServer(upsert: [], delete: keys)
    }

    func clearAllInboxContent(visibleActionNeeded: [FanGeoActionItem]) {
        clearAllActionCenterNotifications()
        let actionItems = visibleActionNeeded.filter { $0.kind.listSection == .actionNeeded }
        let permanentItems = actionItems.filter { $0.kind.dismissalPersistence == .permanent }
        let pendingItems = actionItems.filter { $0.kind.dismissalPersistence == .sessionSnooze }
        let permanentKeys = FanGeoActionCenterActionKey.sanitizedUnique(permanentItems.map(\.id))
        if !permanentKeys.isEmpty {
            applyActionCenterDismissalMutation(adding: permanentKeys, removing: [])
            persistActionCenterDismissalsToServer(upsert: permanentKeys, delete: [])
        }
        let pendingIds = pendingItems.map(\.id)
        let mergedKnown = FanGeoActionCenterLocalVisibility.mergingLastKnownPendingKeys(
            pendingIds,
            into: actionCenterLastKnownPendingKeys
        )
        actionCenterLastKnownPendingKeys = mergedKnown
        let nextHidden = FanGeoActionCenterLocalVisibility.applyingClearAllHidden(
            visibleIds: pendingIds,
            lastKnownPendingKeys: mergedKnown,
            to: actionCenterClearAllHiddenKeys
        )
        actionCenterClearAllHiddenKeys = nextHidden
        if let userId = currentUserAuthId ?? FanGeoActionCenterLocalVisibility.lastKnownUserId() {
            FanGeoActionCenterLocalVisibility.saveLastKnownPendingKeys(mergedKnown, userId: userId)
            FanGeoActionCenterLocalVisibility.saveClearAllHiddenKeys(nextHidden, userId: userId)
            FanGeoActionCenterLocalVisibility.rememberUserId(userId)
        }
        actionCenterNotificationInboxEpoch &+= 1
        ActionCenterDismissDebug.log(
            "inboxClearAll notifications=all actionNeeded=\(actionItems.count) " +
            "hiddenPending=\(nextHidden.count)"
        )
    }

    func clearAllDismissibleActionCenterItems(_ items: [FanGeoActionItem]) {
        clearAllInboxContent(visibleActionNeeded: items)
    }

    private func snoozePendingActionCenterItems(_ items: [FanGeoActionItem]) {
        let keys = FanGeoActionCenterActionKey.sanitizedUnique(items.map(\.id))
        guard !keys.isEmpty else { return }
        let now = Date()
        let next = FanGeoActionCenterLocalVisibility.applyingPendingSnooze(
            keys: keys,
            to: actionCenterPendingSnoozedAt,
            now: now
        )
        actionCenterPendingSnoozedAt = next
        if let userId = currentUserAuthId {
            FanGeoActionCenterLocalVisibility.savePendingSnooze(next, userId: userId, now: now)
        }
    }

    private func unsnoozePendingActionCenterItems(_ items: [FanGeoActionItem]) {
        let keys = FanGeoActionCenterActionKey.sanitizedUnique(items.map(\.id))
        guard !keys.isEmpty else { return }
        let next = FanGeoActionCenterLocalVisibility.removingPendingSnooze(
            keys: keys,
            from: actionCenterPendingSnoozedAt
        )
        actionCenterPendingSnoozedAt = next
        if let userId = currentUserAuthId {
            FanGeoActionCenterLocalVisibility.savePendingSnooze(next, userId: userId)
        }
    }

    private func applyActionCenterDismissalMutation(adding: [String], removing: [String]) {
        let addingPermanent = adding.filter { !FanGeoActionCenterActionKey.isPendingRequestKey($0) }
        let removingKeys = removing
        var next = actionCenterDismissedKeys
        for key in addingPermanent { next.insert(key) }
        for key in removingKeys { next.remove(key) }
        actionCenterDismissedKeys = next
        if let userId = currentUserAuthId {
            FanGeoActionCenterLocalVisibility.savePermanentDismissedKeys(next, userId: userId)
        }
    }

    private func persistActionCenterDismissalsToServer(upsert: [String], delete: [String]) {
        guard let userId = currentUserAuthId else { return }
        let upsertPermanent = upsert.filter { !FanGeoActionCenterActionKey.isPendingRequestKey($0) }
        Task {
            do {
                if !upsertPermanent.isEmpty {
                    try await FanGeoActionCenterDismissalService.upsert(
                        userId: userId,
                        actionKeys: upsertPermanent
                    )
                }
                if !delete.isEmpty {
                    try await FanGeoActionCenterDismissalService.delete(userId: userId, actionKeys: delete)
                }
            } catch {
                ActionCenterDismissDebug.log(
                    "dismissFailed reason=\(error.localizedDescription)"
                )
            }
        }
    }

    private func refreshActionCenterDismissalsFromServer(userId: UUID) async {
        do {
            let remote = try await FanGeoActionCenterDismissalService.fetchKeys(userId: userId)
            await MainActor.run {
                guard currentUserAuthId == userId else { return }
                let remotePermanent = FanGeoActionCenterActionKey.retainingPermanentKeys(in: remote)
                let strayPending = remote.subtracting(remotePermanent)
                let merged = FanGeoActionCenterActionKey.retainingPermanentKeys(
                    in: actionCenterDismissedKeys.union(remotePermanent)
                )
                let previous = actionCenterDismissedKeys
                actionCenterDismissedKeys = merged
                FanGeoActionCenterLocalVisibility.savePermanentDismissedKeys(merged, userId: userId)
                if merged != previous {
                    actionCenterNotificationInboxEpoch &+= 1
                }
                ActionCenterDismissDebug.log(
                    "hydrateRemote dismissalCount=\(merged.count)"
                )
                let localOnly = merged.subtracting(remotePermanent)
                if !localOnly.isEmpty {
                    persistActionCenterDismissalsToServer(upsert: Array(localOnly), delete: [])
                }
                if !strayPending.isEmpty {
                    persistActionCenterDismissalsToServer(upsert: [], delete: Array(strayPending))
                }
            }
        } catch {
            ActionCenterDismissDebug.log(
                "hydrateRemoteFailed reason=\(error.localizedDescription)"
            )
        }
    }

    /// Pure Going Action Needed projection. No longer shown on Going — FanGeo Inbox is authoritative.
    func goingActionSummary(languageCode: String, now: Date = Date()) -> GoingActionSummary {
        GoingActionCenter.summary(
            from: goingActionInputs(languageCode: languageCode, now: now),
            languageCode: languageCode,
            now: now
        )
    }

    /// Going tab badge: Going plans only. Inbox owns invitations, join requests, ratings, and schedule actions.
    func goingContentBadgeCount() -> Int {
        0
    }

    func goingActionInputs(languageCode: String, now: Date = Date()) -> GoingActionCenter.Inputs {
        GoingActionCenter.Inputs(
            pickupInvites: actionCenterPickupInviteInputs(languageCode: languageCode),
            joinApprovals: pendingPickupJoinApprovalSummaries,
            pendingJoinApprovalCount: pendingPickupGameJoinRequestCount,
            pendingRatings: actionCenterPendingRatingInputs(languageCode: languageCode, now: now),
            scheduleActivities: actionCenterScheduleActivityInputs(languageCode: languageCode),
            startsSoon: goingActionStartsSoonInputs(now: now),
            isSignedIn: isAuthenticatedForSocialFeatures
        )
    }

    func goingActionStartsSoonInputs(now: Date) -> [GoingActionStartsSoonInput] {
        var results: [GoingActionStartsSoonInput] = []
        var seen = Set<UUID>()

        func append(id: UUID, title: String, startAt: Date, surface: GoingActionStartsSoonInput.Surface) {
            guard !seen.contains(id) else { return }
            guard GoingActionCenter.isStartsSoon(startAt, now: now) else { return }
            seen.insert(id)
            results.append(
                GoingActionStartsSoonInput(
                    id: id,
                    title: title,
                    startAt: startAt,
                    surface: surface
                )
            )
        }

        for item in followingTabGoingItems where item.isServerGoing {
            guard !VenueGameExpiration.isWatchingCompleted(row: item.venueEvent, now: now) else { continue }
            guard let start = VenueGameExpiration.scheduledStartDate(for: item.venueEvent) else { continue }
            let eventTitle = item.venueEvent.event_title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = eventTitle.isEmpty ? item.bar.name : eventTitle
            append(id: item.id, title: title, startAt: start, surface: .watch)
        }

        guard canFanUsePickupGamesUI else { return results }

        for card in myPickupGameJoinRequestCards where card.pill == .approved {
            guard let start = PickupGameModels.parseSupabaseTimestamptz(card.game_start_at) else { continue }
            append(id: card.pickupGameId, title: card.title, startAt: start, surface: .pickup)
        }

        for game in myPickupGamesForSettings where !game.isPickupGameSoftCancelled {
            guard let start = PickupGameModels.parseSupabaseTimestamptz(game.game_start_at) else { continue }
            append(id: game.id, title: game.title, startAt: start, surface: .pickup)
        }

        return results
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
