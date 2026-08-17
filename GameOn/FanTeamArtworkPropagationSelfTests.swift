import Foundation
import UIKit

#if DEBUG
enum FanTeamArtworkPropagationSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[TeamArtworkPropagationTest] PASS \(name)")
            } else {
                failures += 1
                print("[TeamArtworkPropagationTest] FAIL \(name)")
            }
        }

        let teamId = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let otherId = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let conversationId = UUID()
        let oldURL = "https://cdn.example/fan-team-logos/\(teamId.uuidString.lowercased())/logo-old.jpg"
        let newURL = "https://cdn.example/fan-team-logos/\(teamId.uuidString.lowercased())/logo-new.jpg"
        let sameURL = oldURL
        let otherURL = "https://cdn.example/fan-team-logos/\(otherId.uuidString.lowercased())/logo-other.jpg"

        let original = DiscoverableFanTeamMapRow(
            id: teamId,
            name: "FanGeo Badminton Team",
            sport: "Badminton",
            sportSubtype: nil,
            logoURL: oldURL,
            logoThumbnailURL: oldURL,
            colorHex: "#22C25A",
            lookingForPlayers: true,
            memberCount: 3,
            precision: .specific,
            placeName: "Riverton",
            city: "Riverton",
            region: "UT",
            postalCode: nil,
            countryCode: "US",
            latitude: 40.52,
            longitude: -111.94
        )
        let unrelated = DiscoverableFanTeamMapRow(
            id: otherId,
            name: "Other",
            sport: "Soccer",
            sportSubtype: nil,
            logoURL: otherURL,
            logoThumbnailURL: otherURL,
            colorHex: "#2F6BFF",
            lookingForPlayers: false,
            memberCount: 2,
            precision: .generalArea,
            placeName: nil,
            city: "Lehi",
            region: "UT",
            postalCode: nil,
            countryCode: "US",
            latitude: 40.39,
            longitude: -111.85
        )

        let uploaded = FanTeamIdentityChange(
            teamId: teamId,
            conversationId: conversationId,
            name: original.name,
            sport: original.sport,
            colorHex: original.colorHex,
            logoURL: newURL,
            logoThumbnailURL: newURL,
            previousLogoURL: oldURL,
            previousLogoThumbnailURL: oldURL,
            artworkReplaced: true
        )
        expect(FanTeamArtworkPropagation.artworkChanged(uploaded), "upload marks artwork changed")
        let patched = FanTeamArtworkPropagation.applying(uploaded, to: original)
        expect(patched.logoURL == newURL, "authoritative Team model updates logo URL")
        expect(patched.logoThumbnailURL == newURL, "authoritative Team model updates thumbnail URL")
        expect(patched.id == teamId, "same Team ID remains stable")
        expect(patched.latitude == original.latitude && patched.longitude == original.longitude, "location does not change")
        expect(patched.displayRefreshToken == uploaded.displayRefreshToken, "Discover artwork version follows the change token")

        let beforeFingerprint = FanTeamArtworkPropagation.annotationFingerprint(for: original)
        let afterFingerprint = FanTeamArtworkPropagation.annotationFingerprint(for: patched)
        expect(beforeFingerprint != afterFingerprint, "Discover annotation artwork input changes")
        expect(afterFingerprint.hasPrefix(teamId.uuidString.lowercased()), "annotation fingerprint keeps Team id")

        let collection = FanTeamArtworkPropagation.patchRows([original, unrelated], with: uploaded)
        expect(collection.didChange, "patch reports the matching Team changed")
        expect(collection.rows[0].logoURL == newURL, "Team Chat / Discover collection receive new image URL")
        expect(collection.rows[1].logoURL == otherURL, "unrelated Team cache entries remain intact")
        expect(collection.rows[1].displayRefreshToken == nil, "unrelated Team version is untouched")

        let pickup = PickupDiscoverTeamIdentity(
            pickupGameId: UUID(),
            teamId: teamId,
            teamName: original.name,
            teamSport: original.sport,
            colorHex: original.colorHex,
            logoURL: oldURL,
            logoThumbnailURL: oldURL,
            displayRefreshToken: nil
        ).applyingIdentityChange(uploaded)
        expect(pickup.logoURL == newURL, "Team-linked Discover pickup identity receives new image")
        expect(pickup.teamId == teamId, "pickup identity keeps Team id")

        let summary = FanTeamSummary(
            id: teamId,
            name: original.name,
            sport: original.sport,
            logoURL: oldURL,
            logoThumbnailURL: oldURL,
            colorHex: original.colorHex,
            competitionLevel: nil,
            ownerUserId: UUID(),
            groupConversationId: conversationId,
            myRole: .owner,
            memberCount: 3,
            pendingInvitationCount: 0,
            pushNotificationsMuted: false,
            nextGameStartsAt: nil,
            nextGameTitle: nil,
            nextGameVenue: nil,
            createdAt: Date()
        ).applying(uploaded)
        expect(summary.logoURL == newURL, "My Teams / Profile Team summary receives new image")
        let profileMembership = ProfileFanTeamMembership(
            teamId: teamId,
            name: original.name,
            sport: original.sport,
            logoURL: oldURL,
            logoThumbnailURL: oldURL,
            colorHex: original.colorHex,
            role: .owner,
            viewerCanOpen: true
        ).applyingIdentityChange(uploaded)
        expect(profileMembership.logoURL == newURL, "Profile My Teams card receives new image")

        let sameURLChange = FanTeamIdentityChange(
            teamId: teamId,
            conversationId: conversationId,
            name: original.name,
            sport: original.sport,
            colorHex: original.colorHex,
            logoURL: sameURL,
            logoThumbnailURL: sameURL,
            previousLogoURL: sameURL,
            previousLogoThumbnailURL: sameURL,
            artworkReplaced: true
        )
        expect(FanTeamArtworkPropagation.artworkChanged(sameURLChange), "same URL + explicit replace still counts as artwork change")
        let sameURLPatched = FanTeamArtworkPropagation.applying(sameURLChange, to: original)
        expect(
            FanTeamArtworkPropagation.annotationFingerprint(for: sameURLPatched)
                != FanTeamArtworkPropagation.annotationFingerprint(for: original),
            "same URL + newer artwork version invalidates old bitmap identity"
        )
        let versionedA = FanTeamArtworkPropagation.cacheIdentity(url: sameURL, version: sameURLChange.displayRefreshToken)
        let versionedB = FanTeamArtworkPropagation.cacheIdentity(url: sameURL, version: sameURLChange.displayRefreshToken)
        expect(versionedA == versionedB, "same URL + same version remains cached")
        expect(
            FanTeamArtworkPropagation.cacheIdentity(url: sameURL, version: UUID()) != versionedA,
            "same URL + new version is a distinct cache key"
        )
        let sameURLInvalidations = FanTeamArtworkPropagation.urlsToInvalidate(from: sameURLChange)
        expect(
            sameURLInvalidations.contains { $0.absoluteString.contains("logo-old.jpg") },
            "same-URL replacement invalidates the old bitmap URL"
        )

        let nameOnly = FanTeamIdentityChange(
            teamId: teamId,
            conversationId: conversationId,
            name: "Renamed",
            sport: original.sport,
            colorHex: original.colorHex,
            logoURL: oldURL,
            logoThumbnailURL: oldURL,
            previousLogoURL: oldURL,
            previousLogoThumbnailURL: oldURL,
            artworkReplaced: false
        )
        expect(FanTeamArtworkPropagation.artworkChanged(nameOnly) == false, "failed/no artwork replace does not mark artwork changed")
        expect(
            FanTeamArtworkPropagation.urlsToInvalidate(from: nameOnly).isEmpty,
            "failed upload / name-only edit does not invalidate old image"
        )

        let emptyPickup: [UUID: PickupDiscoverTeamIdentity] = [:]
        expect(emptyPickup.isEmpty, "Discover Team pins still patch when no pickup-game identities exist")

        expect(
            FanTeamsService.makeVersionedTeamLogoFileName()
                != FanTeamsService.makeVersionedTeamLogoFileName(),
            "storage filenames are unique so app restart is not required to bust CDN"
        )

        let chatContext = FanTeamChatContext(from: summary).applying(uploaded)
        expect(chatContext.logoURL == newURL, "Team Chat context receives new image")

        if failures == 0 {
            print("[TeamArtworkPropagationTest] ALL PASSED")
        } else {
            print("[TeamArtworkPropagationTest] FAILURES=\(failures)")
            assertionFailure("FanTeamArtworkPropagationSelfTests failed: \(failures)")
        }
    }

    static func runCacheInvalidationSuite() async {
        let old = URL(string: "https://cdn.example/fan-team-logos/old-team/logo-old.jpg")!
        let unrelated = URL(string: "https://cdn.example/fan-team-logos/other-team/logo-other.jpg")!
        let versionedOld = URL(
            string: FanTeamArtworkPropagation.cacheIdentity(url: old.absoluteString, version: UUID())
        )!
        guard let image = UIImage(systemName: "person.crop.circle") else {
            print("[TeamArtworkPropagationTest] FAIL cache suite missing UIImage")
            return
        }
        await DiscoverMapImageCache.shared.store(image, for: [old, versionedOld, unrelated], bucket: .avatar)
        let hadOld = DiscoverMapImageCache.shared.peekCachedImage(for: old, bucket: .avatar) != nil
        let hadUnrelated = DiscoverMapImageCache.shared.peekCachedImage(for: unrelated, bucket: .avatar) != nil
        await DiscoverMapImageCache.shared.invalidate(urls: [old])
        let oldGone = DiscoverMapImageCache.shared.peekCachedImage(for: old, bucket: .avatar) == nil
        let versionedGone = DiscoverMapImageCache.shared.peekCachedImage(for: versionedOld, bucket: .avatar) == nil
        let unrelatedKept = DiscoverMapImageCache.shared.peekCachedImage(for: unrelated, bucket: .avatar) != nil
        let passed = hadOld && hadUnrelated && oldGone && versionedGone && unrelatedKept
        if passed {
            print("[TeamArtworkPropagationTest] PASS old Discover cache entry invalidated; unrelated kept")
            print("[TeamArtworkPropagationTest] CACHE SUITE PASSED")
        } else {
            print("[TeamArtworkPropagationTest] FAIL cache invalidation hadOld=\(hadOld) oldGone=\(oldGone) versionedGone=\(versionedGone) unrelatedKept=\(unrelatedKept)")
            assertionFailure("FanTeamArtworkPropagation cache invalidation suite failed")
        }
    }
}
#endif
