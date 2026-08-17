import Foundation

extension MapViewModel {
    @MainActor
    func enqueueProGameNotificationDeepLink(matchID: String) {
        let trimmed = matchID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingProGameNotificationDeepLink = ProGameNotificationDeepLinkRequest(
            id: UUID(),
            matchID: trimmed
        )
        requestScheduleHubSurface(.pro)
        requestedMainTabRaw = MainTabView.AppTab.calendar.rawValue
        // Prefer Schedule → Pro highlight path when we can resolve timing.
        if let match = resolveLiveMatchForProGameNotificationDeepLink(matchID: trimmed) {
            pendingScheduleProGameNav = ScheduleProGameNavIntent(
                matchId: match.id,
                stableKey: SavedProGame.stableKey(for: match),
                startTime: match.startTime
            )
        } else if let saved = savedProGames.first(where: { saved in
            SavedProGame.normalizedHydrationToken(saved.id) == SavedProGame.normalizedHydrationToken(trimmed)
                || SavedProGame.normalizedHydrationToken(saved.stableKey) == SavedProGame.normalizedHydrationToken(trimmed)
        }) {
            pendingScheduleProGameNav = ScheduleProGameNavIntent(
                matchId: saved.id,
                stableKey: saved.stableKey,
                startTime: saved.startTime
            )
        }
    }

    @MainActor
    func clearPendingProGameNotificationDeepLink() {
        pendingProGameNotificationDeepLink = nil
    }

    /// Resolves a live match row for a pro game reminder notification `match_id`.
    func resolveLiveMatchForProGameNotificationDeepLink(matchID: String) -> LiveMatch? {
        let normalized = SavedProGame.normalizedHydrationToken(matchID)
        guard !normalized.isEmpty else { return nil }

        if let direct = liveMatches.first(where: { match in
            let matchToken = SavedProGame.normalizedHydrationToken(match.id)
            let stableToken = SavedProGame.normalizedHydrationToken(SavedProGame.stableKey(for: match))
            return matchToken == normalized || stableToken == normalized
        }) {
            return direct
        }

        guard let saved = savedProGames.first(where: { saved in
            SavedProGame.normalizedHydrationToken(saved.id) == normalized
                || SavedProGame.normalizedHydrationToken(saved.stableKey) == normalized
        }) else {
            return nil
        }

        return liveMatchForSavedProGameDeepLink(saved)
    }

    private func liveMatchForSavedProGameDeepLink(_ saved: SavedProGame) -> LiveMatch? {
        liveMatches.first(where: { SavedProGame.directlyMatchesSavedProGame($0, saved) })
    }

    /// Opens professional game detail from a chat share card.
    @MainActor
    func presentSharedProGameDetail(payload: ProGameSharePayload) {
        if let match = resolveLiveMatchForSharedProGame(payload: payload) {
            pendingSharedProGameDetailMatch = match
#if DEBUG
            print("[ProGameShareDebug] presentDetail gameId=\(match.id) source=resolved")
#endif
            return
        }

        let languageCode = L10n.normalizedLanguageCode(
            UserDefaults.standard.string(forKey: L10n.appLanguageKey) ?? L10n.defaultLanguageCode
        )
        showSocialActionToast(
            L10n.t("share_pro_game_unavailable", languageCode: languageCode),
            isError: true
        )
#if DEBUG
        print("[ProGameShareDebug] presentDetailUnavailable gameId=\(payload.gameId)")
#endif
    }

    @MainActor
    func clearSharedProGameDetailPresentation() {
        pendingSharedProGameDetailMatch = nil
    }

    /// Prefer live/saved hydration; fall back to payload snapshot for offline/unavailable feeds.
    func resolveLiveMatchForSharedProGame(payload: ProGameSharePayload) -> LiveMatch? {
        let candidates = [
            payload.gameId,
            payload.stableKey
        ]
        .map { SavedProGame.normalizedHydrationToken($0) }
        .filter { !$0.isEmpty }

        for token in candidates {
            if let match = resolveLiveMatchForProGameNotificationDeepLink(matchID: token) {
                return match
            }
        }

        if let saved = savedProGames.first(where: { saved in
            let idToken = SavedProGame.normalizedHydrationToken(saved.id)
            let keyToken = SavedProGame.normalizedHydrationToken(saved.stableKey)
            return candidates.contains(idToken) || candidates.contains(keyToken)
        }) {
            if let live = liveMatchForSavedProGameDeepLink(saved) {
                return live
            }
            if let reconstructed = saved.reconstructedLiveMatchForVenueImport() {
                return reconstructed
            }
        }

        return ProGameShareMessage.reconstructedLiveMatch(from: payload)
    }
}
