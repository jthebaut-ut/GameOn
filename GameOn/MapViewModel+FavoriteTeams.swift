import Foundation

extension MapViewModel {
    /// Pulls favorite teams from Supabase into ``FavoriteTeamsStore`` AppStorage cache.
    func loadFavoriteTeamsFromSupabase(forceRefresh: Bool = false) async {
        if !forceRefresh, let inFlight = favoriteTeamsLoadTask {
#if DEBUG
            print("[StartupPrefetchDebug] favoriteTeams coalesced=true")
#endif
            await inFlight.value
            return
        }
        if !forceRefresh,
           let lastFavoriteTeamsLoadAt,
           Date().timeIntervalSince(lastFavoriteTeamsLoadAt) < 180 {
#if DEBUG
            print("[StartupPrefetchDebug] favoriteTeams cacheHit=true")
            print("[FavoriteTeamsHydration] skipped cacheHit authUserId=\(currentUserAuthId?.uuidString.lowercased() ?? "nil")")
#endif
            seedSportsArtworkFromFetchedLiveMatches()
            return
        }

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.loadFavoriteTeamsFromSupabaseNow()
        }
        favoriteTeamsLoadTask = task
        await task.value
        if favoriteTeamsLoadTask == task {
            favoriteTeamsLoadTask = nil
        }
    }

    private func loadFavoriteTeamsFromSupabaseNow() async {
        let uid = await MainActor.run(body: { currentUserAuthId })
        guard let uid else {
#if DEBUG
            print("[FavoriteTeamsHydration] load failed authUserId=nil reason=no_auth_user")
#endif
            return
        }

#if DEBUG
        print("[FavoriteTeamsHydration] loading started authUserId=\(uid.uuidString.lowercased())")
#endif

        let fetchResult = await FavoriteTeamsSyncService.fetchTeamSelectionResult(userId: uid)
        let remoteSelection: FavoriteTeamsSyncService.FavoriteTeamSelection
        switch fetchResult {
        case .success(let selection):
            remoteSelection = selection
        case .failure(let error):
#if DEBUG
            print(
                "[FavoriteTeamsHydration] load failed authUserId=\(uid.uuidString.lowercased()) error=\(error.localizedDescription)"
            )
#endif
            return
        }

        var remote = remoteSelection.teamIDs
        var resolvedSelection = remoteSelection
        let localRaw = UserDefaults.standard.string(forKey: FavoriteTeamsStore.appStorageKey) ?? ""
        let localPrimary = UserDefaults.standard.string(forKey: FavoriteTeamsStore.primaryTeamIDAppStorageKey)
        let local = FavoriteTeamsStore.decodeIDs(from: localRaw)
            .filter { FavoriteTeamCatalog.team(id: $0) != nil }

        if remote.isEmpty {
            if !local.isEmpty {
#if DEBUG
                print(
                    "[FavoriteTeamsSyncDebug] migrate_local_to_server userId=\(uid.uuidString.lowercased()) count=\(local.count)"
                )
#endif
                _ = await FavoriteTeamsSyncService.replaceTeamSelection(
                    userId: uid,
                    teamIDs: local,
                    primaryTeamID: FavoriteTeamsStore.normalizedPrimaryTeamID(localPrimary, within: local)
                )
                remote = local
                resolvedSelection = FavoriteTeamsSyncService.FavoriteTeamSelection(
                    teamIDs: local,
                    primaryTeamID: FavoriteTeamsStore.normalizedPrimaryTeamID(localPrimary, within: local)
                )
            }
        }

        let applied = FavoriteTeamsStore.mergedRemoteIDs(local: local, remote: remote)
        let primary = FavoriteTeamsStore.normalizedPrimaryTeamID(resolvedSelection.primaryTeamID, within: applied)
        let didApply = await MainActor.run { () -> Bool in
            guard currentUserAuthId == uid else {
#if DEBUG
                print(
                    "[FavoriteTeamsHydration] skipped due to auth mismatch fetchedAuthId=\(uid.uuidString.lowercased()) activeAuthId=\(currentUserAuthId?.uuidString.lowercased() ?? "nil")"
                )
#endif
                return false
            }
            let currentRaw = UserDefaults.standard.string(forKey: FavoriteTeamsStore.appStorageKey) ?? ""
            let currentIDs = FavoriteTeamsStore.decodeIDs(from: currentRaw)
            let currentPrimary = FavoriteTeamsStore.explicitPrimaryTeamID(localPrimary, within: currentIDs)
            lastFavoriteTeamsLoadAt = Date()
            if currentIDs == applied {
                if currentPrimary != primary {
                    FavoriteTeamsStore.writePrimaryTeamIDToAppStorage(primary)
                }
                return true
            }
            FavoriteTeamsStore.writeToAppStorage(applied)
            FavoriteTeamsStore.writePrimaryTeamIDToAppStorage(primary)
            favoriteTeamsHydrationGeneration &+= 1
            return true
        }

        if didApply {
            let teams = FavoriteTeamsStore.resolvedTeams(fromIDs: applied)
            seedSportsArtworkFromFetchedLiveMatches()
            Task {
                await SportsArtworkEnrichmentService.shared.enrich(favorites: teams)
            }
        }

#if DEBUG
        if didApply {
            print(
                "[FavoriteTeamsHydration] teams applied authUserId=\(uid.uuidString.lowercased()) count=\(applied.count) primary=\(primary ?? "nil")"
            )
            print("[FavoriteTeamsSyncDebug] applied_local_cache userId=\(uid.uuidString.lowercased()) count=\(applied.count)")
        }
#endif
    }

    /// Pushes catalog team IDs to Supabase (full replace). Local AppStorage should already be updated by the UI.
    @discardableResult
    func syncFavoriteTeamsToSupabase(teamIDs: [String], primaryTeamID: String? = nil) async -> Bool {
        guard let uid = await MainActor.run(body: { currentUserAuthId }) else {
#if DEBUG
            print("[FavoriteTeamsSyncDebug] sync_skipped reason=no_auth_user")
            print("[FavoriteTeamsHydration] load failed authUserId=nil reason=sync_no_auth_user")
#endif
            return false
        }

        return await FavoriteTeamsSyncService.replaceTeamSelection(
            userId: uid,
            teamIDs: teamIDs,
            primaryTeamID: primaryTeamID
        )
    }

    /// Profile / favorites reuse already-fetched sports rows. Does not call TheSportsDB
    /// and does not require the Live tab to have been opened.
    func seedSportsArtworkFromFetchedLiveMatches(refreshProviderCatalog: Bool = true) {
        SportsArtworkEnrichmentService.shared.ingestFromAlreadyFetchedLiveMatches(liveMatches)
        let ids = FavoriteTeamsStore.decodeIDs(
            from: UserDefaults.standard.string(forKey: FavoriteTeamsStore.appStorageKey) ?? ""
        )
        SportsFavoriteArtworkHydration.ingest(
            favorites: FavoriteTeamsStore.resolvedTeams(fromIDs: ids),
            from: liveMatches
        )
        guard refreshProviderCatalog else { return }
        Task {
            await SportsProviderArtworkService.shared.refreshIfStale()
        }
    }
}
