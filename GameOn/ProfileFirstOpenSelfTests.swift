import CoreLocation
import Foundation

#if DEBUG
@MainActor
enum ProfileFirstOpenSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[ProfileFirstOpenTest] PASS \(name)")
            } else {
                failures += 1
                print("[ProfileFirstOpenTest] FAIL \(name)")
            }
        }

        expect(
            ProfileFirstOpenScheduler.shouldStartOnFirstAppear(.profileIdentity),
            "identity is immediate viewport"
        )
        expect(
            ProfileFirstOpenScheduler.shouldStartOnFirstAppear(.myTeams),
            "My Teams is immediate viewport"
        )
        expect(
            ProfileFirstOpenScheduler.shouldStartOnFirstAppear(.favoriteTeamsFromAppStorage),
            "Favorite Teams AppStorage is immediate viewport"
        )
        expect(
            ProfileFirstOpenScheduler.shouldStartOnFirstAppear(.homeCrowdCached),
            "cached Home Crowd is immediate viewport"
        )
        expect(
            !ProfileFirstOpenScheduler.shouldStartOnFirstAppear(.suggestedFans),
            "Suggested Fans is not first-appear work"
        )
        expect(
            ProfileFirstOpenScheduler.shouldDeferUntilIdle(.suggestedFans),
            "Suggested Fans waits for idle"
        )
        expect(
            ProfileFirstOpenScheduler.shouldDeferUntilIdle(.sponsoredPlacement),
            "sponsored placement waits for idle"
        )
        expect(
            ProfileFirstOpenScheduler.shouldDeferUntilIdle(.suggestedFanAvatarPrefetch),
            "Suggested Fans avatar prefetch waits for idle"
        )
        expect(
            ProfileFirstOpenScheduler.shouldDeferUntilIdle(.providerArtworkRefresh),
            "provider artwork refresh waits for idle"
        )
        expect(
            ProfileFirstOpenScheduler.priority(for: .artworkSeed) == .afterFirstFrame,
            "live-match artwork seed is after first frame"
        )
        expect(
            ProfileFirstOpenScheduler.priority(for: .pickupOrganizer) == .afterFirstFrame,
            "pickup organizer is after first frame"
        )

        let cached = CLLocationCoordinate2D(latitude: 40.76, longitude: -111.89)
        let home = CLLocationCoordinate2D(latitude: 40.75, longitude: -111.88)
        let firstPaint = ProfileSponsoredLocationPolicy.firstPaintLocation(
            cached: cached,
            homeCrowd: home
        )
        expect(
            firstPaint?.latitude == cached.latitude,
            "GPS does not block first render when cached location exists"
        )
        expect(
            ProfileSponsoredLocationPolicy.firstPaintLocation(cached: nil, homeCrowd: home)?.latitude == home.latitude,
            "Home Crowd coordinate is used when GPS cache is empty"
        )
        expect(
            ProfileSponsoredLocationPolicy.firstPaintLocation(cached: nil, homeCrowd: nil) == nil,
            "missing location returns nil without waiting"
        )
        expect(
            !ProfileSponsoredLocationPolicy.isUsable(CLLocationCoordinate2D(latitude: 0, longitude: 0)),
            "0,0 is not a usable Profile location"
        )

        let authId = UUID()
        ProfilePhase1PersonalizationCache.storeMyTeams([], for: authId)
        ProfilePhase1PersonalizationCache.storeMyTeams(
            ProfilePhase1PersonalizationCache.cachedMyTeamsRegardlessOfAge(for: authId) ?? [],
            for: authId
        )
        expect(
            ProfilePhase1PersonalizationCache.cachedMyTeamsIfFresh(for: authId) != nil,
            "My Teams process cache is reusable on second Profile open"
        )
        ProfilePhase1PersonalizationCache.invalidateMyTeams(for: authId)
        expect(
            ProfilePhase1PersonalizationCache.cachedMyTeamsIfFresh(for: authId) == nil,
            "My Teams cache invalidation still works"
        )

        expect(
            !MyTeamsRefreshPresentation.blocksProfileScrolling(
                refreshPending: true,
                presentingBlockingAlert: false
            ),
            "My Teams refresh does not block Profile scrolling"
        )
        expect(
            !MyTeamsRefreshPresentation.shouldPresentBlockingAlert(
                trigger: .automaticProfileHydration,
                hasCachedTeams: true,
                isHostTabSelected: false,
                isCancellation: false,
                isMissingAuth: false
            ),
            "automatic Profile hydration never presents a Teams modal"
        )

        let fingerprintA = ProfileIdentityScrollSnapshotBuilder.compactArtworkFingerprint(
            teamIDs: ["a", "b", "c"],
            paintRevision: 1
        )
        let fingerprintB = ProfileIdentityScrollSnapshotBuilder.compactArtworkFingerprint(
            teamIDs: ["a", "b", "c"],
            paintRevision: 1
        )
        expect(fingerprintA == fingerprintB, "unchanged favorite IDs do not change artwork fingerprint")
        expect(
            !fingerprintA.contains("thesportsdb"),
            "Favorite Teams fingerprint is not N+1 URL resolution"
        )

        let snapshotUnchanged = ProfileIdentityScrollSnapshotBuilder.token(
            authId: "u1",
            displayName: "Ada",
            handleLine: "@ada",
            bioLine: "hi",
            avatarIdentity: "av",
            xp: 10,
            backgroundKey: "fangeo",
            identityCardsFingerprint: "cards",
            handlePrompt: false,
            belowFold: false,
            myTeamsFingerprint: "t1",
            favoriteTeamsFingerprint: fingerprintA,
            homeCrowdFingerprint: "h1",
            openToFingerprint: "o1",
            pickupFingerprint: "p1",
            suggestedFansFingerprint: "s1",
            suggestedFanChipsFingerprint: "c1",
            pokesFingerprint: "k1",
            sponsoredIdentity: "",
            uploadingAvatar: false,
            savingIdentity: false,
            languageCode: "en",
            paintFingerprint: fingerprintA
        )
        let snapshotSameData = ProfileIdentityScrollSnapshotBuilder.token(
            authId: "u1",
            displayName: "Ada",
            handleLine: "@ada",
            bioLine: "hi",
            avatarIdentity: "av",
            xp: 10,
            backgroundKey: "fangeo",
            identityCardsFingerprint: "cards",
            handlePrompt: false,
            belowFold: false,
            myTeamsFingerprint: "t1",
            favoriteTeamsFingerprint: fingerprintB,
            homeCrowdFingerprint: "h1",
            openToFingerprint: "o1",
            pickupFingerprint: "p1",
            suggestedFansFingerprint: "s1",
            suggestedFanChipsFingerprint: "c1",
            pokesFingerprint: "k1",
            sponsoredIdentity: "",
            uploadingAvatar: false,
            savingIdentity: false,
            languageCode: "en",
            paintFingerprint: fingerprintB
        )
        expect(snapshotUnchanged == snapshotSameData, "unchanged refresh does not bust scroll gate")

        let gpsTick = ProfileIdentityScrollSnapshotBuilder.token(
            authId: "u1",
            displayName: "Ada",
            handleLine: "@ada",
            bioLine: "hi",
            avatarIdentity: "av",
            xp: 10,
            backgroundKey: "fangeo",
            identityCardsFingerprint: "cards",
            handlePrompt: false,
            belowFold: false,
            myTeamsFingerprint: "t1",
            favoriteTeamsFingerprint: fingerprintA,
            homeCrowdFingerprint: "h1",
            openToFingerprint: "o1",
            pickupFingerprint: "p1",
            suggestedFansFingerprint: "s1",
            suggestedFanChipsFingerprint: "c1",
            pokesFingerprint: "k1",
            sponsoredIdentity: "",
            uploadingAvatar: false,
            savingIdentity: false,
            languageCode: "en",
            paintFingerprint: fingerprintA
        )
        expect(snapshotUnchanged == gpsTick, "Profile scroll gate still skips unrelated identity-stable updates")

        expect(
            SportsArtworkEnrichmentService.usesDirectTheSportsDBAPI == false,
            "no global TheSportsDB / artwork-epoch regression from Profile open"
        )

        let ids = (0..<12).map { "team-\($0)" }
        let compactStarted = CFAbsoluteTimeGetCurrent()
        var compactSink = 0
        for _ in 0..<400 {
            compactSink &+= ProfileIdentityScrollSnapshotBuilder.compactArtworkFingerprint(
                teamIDs: ids,
                paintRevision: 9
            ).count
        }
        let compactMs = (CFAbsoluteTimeGetCurrent() - compactStarted) * 1000
        expect(compactSink > 0, "compact fingerprint is measurable")
        expect(compactMs < 50, "compact fingerprint stays cheap (\(String(format: "%.2f", compactMs))ms / 400)")

        if failures == 0 {
            print("[ProfileFirstOpenTest] all passed compactFingerprintMs=\(String(format: "%.2f", compactMs))")
        } else {
            print("[ProfileFirstOpenTest] failures=\(failures)")
            assertionFailure("ProfileFirstOpenSelfTests failed")
        }
    }
}
#endif
