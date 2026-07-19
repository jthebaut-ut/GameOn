import Foundation

extension MapViewModel {
    /// Shared gate so wow moments never interrupt auth/error/venue-owner flows.
    @MainActor
    @discardableResult
    func presentWowMomentIfAllowed(
        _ moment: WowMoment,
        visibleDurationNanoseconds: UInt64? = nil
    ) -> Bool {
        guard isLoggedIn, !isVenueOwnerLoggedIn else { return false }
        guard !isAuthSessionRestoringForProfilePresentation else { return false }
        if let toast = socialActionToastText, socialActionToastIsError, !toast.isEmpty {
            return false
        }
        return wowMomentOverlay.present(
            moment,
            visibleDurationNanoseconds: visibleDurationNanoseconds
        )
    }

    @MainActor
    func presentFavoriteTeamWowMoment(team: FavoriteTeam, languageCode: String) {
        let language = L10n.normalizedLanguageCode(languageCode)
        let moment = WowMomentCopy.favoriteTeam(
            teamName: team.name,
            sport: team.sport,
            languageCode: language
        )
        guard isLoggedIn, !isVenueOwnerLoggedIn else { return }
        guard !isAuthSessionRestoringForProfilePresentation else { return }
        if let toast = socialActionToastText, socialActionToastIsError, !toast.isEmpty {
            return
        }
        // Coalesce rapid multi-adds; analytics only fire if/when the coalesced toast presents.
        wowMomentOverlay.presentFavoriteCoalesced(moment)
    }

    @MainActor
    func presentGoingWowMoment(
        totalGoingCount: Int,
        includesCurrentUser: Bool,
        venueEventID: UUID
    ) {
        let otherFans = WowMomentCopy.otherFans(
            fromTotal: totalGoingCount,
            includesCurrentUser: includesCurrentUser
        )
        let language = L10n.normalizedLanguageCode(
            UserDefaults.standard.string(forKey: L10n.appLanguageKey)
        )
        let moment = WowMomentCopy.going(
            otherFans: otherFans,
            languageCode: language,
            eventKey: venueEventID.uuidString.lowercased()
        )
        _ = presentWowMomentIfAllowed(
            moment,
            visibleDurationNanoseconds: WowMomentOverlayManager.goingVisibleDurationNanoseconds
        )
    }

    /// After Discover venue-event data settles; unique places with games on the local selected calendar day.
    @MainActor
    func considerMapActivityWowMoment(
        placeCount: Int,
        selectedSport: String,
        contentModeRaw: String,
        isLoading: Bool,
        languageCode: String,
        trigger: WowMomentOverlayManager.MapWowTrigger,
        expectedSnapshotGeneration: UInt64
    ) {
        guard !isLoading else { return }
        guard discoverMapContentMode == .venues else { return }
        guard Calendar.current.isDateInToday(selectedDate) else { return }
        // Stale debounce: only evaluate the generation that was settled when the timer started.
        guard expectedSnapshotGeneration == discoverMapRenderSnapshotGeneration else { return }

        let sport = selectedSport.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = L10n.normalizedLanguageCode(languageCode)

        let sportLabel: String? = {
            guard !sport.isEmpty, sport.caseInsensitiveCompare("All") != .orderedSame else { return nil }
            return sport
        }()

        guard placeCount > 0 else { return }

        let fingerprint = WowMomentCopy.mapMessageFingerprint(placeCount: placeCount, sportLabel: sportLabel)
        guard wowMomentOverlay.allowAndRecordMapPresentation(
            trigger: trigger,
            day: selectedDate,
            messageFingerprint: fingerprint
        ) else { return }

        let dedupe = "map:\(WowMomentOverlayManager.mapGeneralDayKey(day: selectedDate))|\(fingerprint)"
        guard let moment = WowMomentCopy.mapActivity(
            placeCount: placeCount,
            sportLabel: sportLabel,
            languageCode: language,
            dedupeKey: dedupe
        ) else { return }

        _ = presentWowMomentIfAllowed(moment)
        _ = contentModeRaw
    }
}
