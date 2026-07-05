import Foundation

extension MapViewModel {
    private enum UserWarmCacheTarget: String {
        case favoriteTeams
        case savedProGames
        case favoriteTeamProGames
        case pickupJoinGames
        case hostedPickupGames
        case venueGoingRows
        case notificationPreferences
    }

    private static let userWarmCacheCoalesceInterval: TimeInterval = 90
    private static let userWarmCacheTabIntentSkipInterval: TimeInterval = 15

    func runUserPreferencesWarmCacheIfNeeded(forceRefresh: Bool = false) async {
        if let inFlight = userPreferencesWarmCacheTask {
            await inFlight.value
            if !forceRefresh { return }
        }

        if !forceRefresh,
           let userId = currentUserAuthId,
           lastUserPreferencesWarmCacheUserId == userId,
           let lastUserPreferencesWarmCacheAt,
           Date().timeIntervalSince(lastUserPreferencesWarmCacheAt) < Self.userWarmCacheCoalesceInterval {
            return
        }

        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.runUserPreferencesWarmCacheNow(forceRefresh: forceRefresh)
        }
        userPreferencesWarmCacheTask = task
        await task.value
        userPreferencesWarmCacheTask = nil
    }

    @MainActor
    private func runUserPreferencesWarmCacheNow(forceRefresh: Bool) async {
        print("[UserWarmCache] started")
        let startedAt = Date()

        guard isAuthenticatedForSocialFeatures, !isAdminLoggedIn else {
            logUserWarmCacheFinished(
                startedAt: startedAt,
                savedProGames: savedProGames.count,
                favoriteTeams: 0,
                pickup: 0,
                venues: 0
            )
            return
        }

        if !forceRefresh, shouldSkipUserWarmCacheDueToRecentTabIntent() {
            logUserWarmCacheFinished(
                startedAt: startedAt,
                savedProGames: savedProGames.count,
                favoriteTeams: currentFavoriteTeamIDs.count,
                pickup: myPickupGameJoinRequestCards.count + myPickupGamesForSettings.count,
                venues: followingTabGoingItems.count
            )
            return
        }

        await warmUserFavoriteTeamsIfNeeded(forceRefresh: forceRefresh)
        await Task.yield()

        await warmUserSavedProGamesIfNeeded(forceRefresh: forceRefresh)
        await Task.yield()

        await warmUserFavoriteTeamProGamesFromCachedLiveMatchesIfNeeded()
        await Task.yield()

        await warmUserPickupJoinGamesIfNeeded(forceRefresh: forceRefresh)
        await Task.yield()

        await warmUserHostedPickupGamesIfNeeded(forceRefresh: forceRefresh)
        await Task.yield()

        await warmUserVenueGoingRowsIfNeeded(forceRefresh: forceRefresh)
        await Task.yield()

        await warmUserNotificationPreferencesIfNeeded(forceRefresh: forceRefresh)

        lastUserPreferencesWarmCacheAt = Date()
        lastUserPreferencesWarmCacheUserId = currentUserAuthId

        logUserWarmCacheFinished(
            startedAt: startedAt,
            savedProGames: savedProGames.count,
            favoriteTeams: currentFavoriteTeamIDs.count,
            pickup: myPickupGameJoinRequestCards.count + myPickupGamesForSettings.count,
            venues: followingTabGoingItems.count
        )
    }

    private var currentFavoriteTeamIDs: [String] {
        FavoriteTeamsStore.decodeIDs(
            from: UserDefaults.standard.string(forKey: FavoriteTeamsStore.appStorageKey) ?? ""
        )
    }

    private func shouldSkipUserWarmCacheDueToRecentTabIntent() -> Bool {
        isTabIntentPreloadInFlight("following")
            || didCompleteTabIntentPreloadRecently("following", within: Self.userWarmCacheTabIntentSkipInterval)
            || isTabIntentPreloadInFlight("calendar")
            || didCompleteTabIntentPreloadRecently("calendar", within: Self.userWarmCacheTabIntentSkipInterval)
    }

    private func logUserWarmCacheSkipped(_ target: UserWarmCacheTarget, reason: String) {
        print("[UserWarmCache] skipped reason=\(reason) target=\(target.rawValue)")
    }

    private func logUserWarmCacheFinished(
        startedAt: Date,
        savedProGames: Int,
        favoriteTeams: Int,
        pickup: Int,
        venues: Int
    ) {
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        print(
            "[UserWarmCache] finished durationMs=\(durationMs) savedProGames=\(savedProGames) favoriteTeams=\(favoriteTeams) pickup=\(pickup) venues=\(venues)"
        )
    }

    private func shouldSkipUserWarmCacheTarget(_ target: UserWarmCacheTarget) -> String? {
        if isTabIntentPreloadInFlight("following")
            || didCompleteTabIntentPreloadRecently("following", within: Self.userWarmCacheTabIntentSkipInterval) {
            return "recentlyRefreshed"
        }

        switch target {
        case .favoriteTeams:
            if let lastFavoriteTeamsLoadAt,
               Date().timeIntervalSince(lastFavoriteTeamsLoadAt) < 180 {
                return "recentlyRefreshed"
            }
            if let lastLightweightStartupPrefetchAt,
               Date().timeIntervalSince(lastLightweightStartupPrefetchAt) < 120 {
                return "recentlyRefreshed"
            }
        case .savedProGames:
            if let lastSavedProGamesFetchAt,
               Date().timeIntervalSince(lastSavedProGamesFetchAt) < 45 {
                return "recentlyRefreshed"
            }
        case .favoriteTeamProGames:
            if let lastFavoriteTeamProGamesRefreshAt,
               Date().timeIntervalSince(lastFavoriteTeamProGamesRefreshAt) < 45 {
                return "recentlyRefreshed"
            }
            if !favoriteTeamProGames.isEmpty {
                return "recentlyRefreshed"
            }
        case .pickupJoinGames:
            if let uid = currentUserAuthId,
               lastSuccessfulFollowingJoinRequestsRefreshUserId == uid,
               let lastSuccessfulFollowingJoinRequestsRefreshAt,
               Date().timeIntervalSince(lastSuccessfulFollowingJoinRequestsRefreshAt) < 45 {
                return "recentlyRefreshed"
            }
        case .hostedPickupGames:
            if let lastMyPickupGamesLightweightLoadAt,
               Date().timeIntervalSince(lastMyPickupGamesLightweightLoadAt) < 45 {
                return "recentlyRefreshed"
            }
        case .venueGoingRows:
            if let lastFollowingTabGlobalRefreshAt,
               Date().timeIntervalSince(lastFollowingTabGlobalRefreshAt) < 60 {
                return "recentlyRefreshed"
            }
            if let lastFollowingTodayPlansLoadAt,
               Date().timeIntervalSince(lastFollowingTodayPlansLoadAt) < 45 {
                return "recentlyRefreshed"
            }
        case .notificationPreferences:
            if let lastProGameNotificationPreferencesLoadAt,
               Date().timeIntervalSince(lastProGameNotificationPreferencesLoadAt) < 120 {
                return "recentlyRefreshed"
            }
        }
        return nil
    }

    private func warmUserFavoriteTeamsIfNeeded(forceRefresh: Bool) async {
        if !forceRefresh, let reason = shouldSkipUserWarmCacheTarget(.favoriteTeams) {
            logUserWarmCacheSkipped(.favoriteTeams, reason: reason)
            return
        }
        await loadFavoriteTeamsFromSupabase(forceRefresh: false)
    }

    private func warmUserSavedProGamesIfNeeded(forceRefresh: Bool) async {
        if !forceRefresh, let reason = shouldSkipUserWarmCacheTarget(.savedProGames) {
            logUserWarmCacheSkipped(.savedProGames, reason: reason)
            return
        }
        await fetchSavedProGames(forceRefresh: false, reason: "userWarmCache")
    }

    @MainActor
    private func warmUserFavoriteTeamProGamesFromCachedLiveMatchesIfNeeded() async {
        if let reason = shouldSkipUserWarmCacheTarget(.favoriteTeamProGames) {
            logUserWarmCacheSkipped(.favoriteTeamProGames, reason: reason)
            return
        }
        guard UserDefaults.standard.bool(forKey: ProGamesFavoriteTeamAutoFollowPreference.enabledKey) else {
            return
        }
        let teams = FavoriteTeamsStore.resolvedTeams(
            from: UserDefaults.standard.string(forKey: FavoriteTeamsStore.appStorageKey) ?? ""
        )
        guard !teams.isEmpty, !liveMatches.isEmpty else { return }
        guard favoriteTeamProGames.isEmpty else { return }

        favoriteTeamProGames = Self.favoriteTeamProGames(from: liveMatches, favoriteTeams: teams)
    }

    private func warmUserPickupJoinGamesIfNeeded(forceRefresh: Bool) async {
        guard canFanUsePickupGamesUI else { return }
        if !forceRefresh, let reason = shouldSkipUserWarmCacheTarget(.pickupJoinGames) {
            logUserWarmCacheSkipped(.pickupJoinGames, reason: reason)
            return
        }
        await loadMyPickupGameJoinRequestsForFollowing(forceRefresh: false, reason: "userWarmCache")
    }

    private func warmUserHostedPickupGamesIfNeeded(forceRefresh: Bool) async {
        guard canFanUsePickupGamesUI else { return }
        if !forceRefresh, let reason = shouldSkipUserWarmCacheTarget(.hostedPickupGames) {
            logUserWarmCacheSkipped(.hostedPickupGames, reason: reason)
            return
        }
        await loadMyPickupGamesForSettings(forceRefresh: false, reason: "userWarmCache")
    }

    private func warmUserVenueGoingRowsIfNeeded(forceRefresh: Bool) async {
        guard canUseFollowingTab else { return }
        if !forceRefresh, let reason = shouldSkipUserWarmCacheTarget(.venueGoingRows) {
            logUserWarmCacheSkipped(.venueGoingRows, reason: reason)
            return
        }
        await refreshFollowingTodayVenueEventPlansLightweight(forceRefresh: false)
        if shouldSkipFollowingTabGlobalRefresh() {
            return
        }
        await refreshFollowingTabDataGloballyUnlessFresh()
    }

    private func warmUserNotificationPreferencesIfNeeded(forceRefresh: Bool) async {
        if !forceRefresh, let reason = shouldSkipUserWarmCacheTarget(.notificationPreferences) {
            logUserWarmCacheSkipped(.notificationPreferences, reason: reason)
            return
        }
        await loadProGameNotificationPreferencesFromBackend(reason: "userWarmCache")
    }
}
