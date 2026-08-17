import Foundation
import UserNotifications

#if DEBUG
enum FanGeoPushArtworkSelfTests {
    private static let sportsBadge =
        "https://www.thesportsdb.com/images/media/team/badge/xtwxyt1421429550.png"
    private static let sportsBadgeTiny =
        "https://www.thesportsdb.com/images/media/team/badge/xtwxyt1421429550.png/tiny"
    private static let awayBadge =
        "https://r2.thesportsdb.com/images/media/team/badge/awaybadge.png"
    private static let teamLogo =
        "https://abcdxyzcompany.supabase.co/storage/v1/object/public/fan-team-logos/imc.png"
    private static let userAvatar =
        "https://abcdxyzcompany.supabase.co/storage/v1/object/public/avatars/user.png"
    private static let png1x1 = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54,
        0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x01, 0x00, 0x05, 0xFE, 0xD4,
        0xEF, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82
    ])

    static func runAll() async {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[FanGeoPushArtworkTest] PASS \(name)")
            } else {
                failures += 1
                print("[FanGeoPushArtworkTest] FAIL \(name)")
            }
        }

        expect(
            FanGeoPushArtworkSelection.teamLogo(thumbnail: teamLogo, full: nil) == teamLogo,
            "Team artwork uses uploaded logo URL"
        )
        expect(
            FanGeoPushArtworkSelection.teamLogo(thumbnail: nil, full: nil) == nil,
            "Team with no uploaded logo has no artwork"
        )
        expect(
            FanGeoPushArtworkSelection.teamLogo(thumbnail: nil, full: teamLogo) == teamLogo,
            "Team artwork falls back to full uploaded logo"
        )

        let cubsScore = FanGeoPushArtworkSelection.proGameScore(
            scoringTeam: "Chicago Cubs",
            homeTeam: "St. Louis Cardinals",
            awayTeam: "Chicago Cubs",
            homeBadgeURL: awayBadge,
            awayBadgeURL: sportsBadge
        )
        expect(cubsScore == sportsBadgeTiny, "score update uses scoring-team badge")
        expect(
            FanGeoPushArtworkSelection.proGameScore(
                scoringTeam: nil,
                homeTeam: "St. Louis Cardinals",
                awayTeam: "Chicago Cubs",
                homeBadgeURL: awayBadge,
                awayBadgeURL: sportsBadge
            ) == nil,
            "score update without scoring-team identity has no team artwork"
        )
        expect(
            FanGeoPushArtworkSelection.proGameScore(
                scoringTeam: "Unknown Club",
                homeTeam: "St. Louis Cardinals",
                awayTeam: "Chicago Cubs",
                homeBadgeURL: awayBadge,
                awayBadgeURL: sportsBadge
            ) == nil,
            "unknown scoring team does not invent a badge"
        )

        expect(
            FanGeoPushArtworkSelection.proGameFinal(
                homeTeam: "St. Louis Cardinals",
                awayTeam: "Chicago Cubs",
                homeScore: 0,
                awayScore: 3,
                homeBadgeURL: awayBadge,
                awayBadgeURL: sportsBadge
            ) == sportsBadgeTiny,
            "final uses winner team badge"
        )
        expect(
            FanGeoPushArtworkSelection.proGameFinal(
                homeTeam: "St. Louis Cardinals",
                awayTeam: "Chicago Cubs",
                homeScore: 2,
                awayScore: 2,
                homeBadgeURL: awayBadge,
                awayBadgeURL: sportsBadge
            ) == nil,
            "draw does not privilege a team badge"
        )

        expect(
            FanGeoPushArtworkSelection.chatDirect(senderAvatarURL: userAvatar) == userAvatar,
            "DM uses sender avatar"
        )
        expect(
            FanGeoPushArtworkSelection.chatGroup(
                groupImageURL: nil,
                teamLogoURL: teamLogo,
                senderAvatarURL: userAvatar
            ) == teamLogo,
            "Team Chat uses Team logo over sender avatar"
        )
        expect(
            FanGeoPushArtworkSelection.chatGroup(
                groupImageURL: nil,
                teamLogoURL: nil,
                senderAvatarURL: userAvatar
            ) == userAvatar,
            "group without image falls back to sender avatar"
        )
        expect(
            FanGeoPushArtworkSelection.chatDirect(senderAvatarURL: nil) == nil,
            "missing avatar has no artwork"
        )

        expect(
            FanGeoPushArtwork.isTrustedArtworkURL("https://example.com/logo.png") == false,
            "untrusted host rejected"
        )
        expect(
            FanGeoPushArtwork.isTrustedArtworkURL("http://www.thesportsdb.com/badge.png") == false,
            "http URL rejected"
        )
        expect(
            FanGeoPushArtwork.isTrustedArtworkURL(
                "https://abcdxyzcompany.supabase.co/rest/v1/fan_teams"
            ) == false,
            "Supabase non-storage path rejected"
        )
        expect(FanGeoPushArtwork.isTrustedArtworkURL(sportsBadge) == true, "TheSportsDB host allowed")
        expect(FanGeoPushArtwork.isTrustedArtworkURL(teamLogo) == true, "Supabase storage host allowed")
        expect(
            FanGeoPushArtwork.trustedURL(from: sportsBadge)?.absoluteString == sportsBadgeTiny,
            "provider artwork compacted to tiny variant"
        )

        var payload: [AnyHashable: Any] = [
            "source": "pickup_game_change_notification",
            "pickup_game_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "team_id": "ffffffff-1111-4222-8333-444444444444",
            "notification_type": "created",
            "deduplication_key": "pickup_update:aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee:1",
        ]
        let beforeKeys = Set(payload.keys.compactMap { $0 as? String })
        FanGeoPushArtwork.merge(
            FanGeoPushArtwork.fields(url: teamLogo, kind: .team, entityID: "ffffffff-1111-4222-8333-444444444444"),
            into: &payload
        )
        expect(
            PickupGameChangeNotificationDeepLinkPayload.isPickupGameChangeNotification(payload),
            "deep-link source unchanged after artwork merge"
        )
        expect(
            (payload["pickup_game_id"] as? String) == "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "pickup_game_id unchanged"
        )
        expect(
            (payload["team_id"] as? String) == "ffffffff-1111-4222-8333-444444444444",
            "team_id unchanged"
        )
        expect(
            (payload["deduplication_key"] as? String)?.isEmpty == false,
            "dedupe key unchanged"
        )
        expect(
            beforeKeys.isSubset(of: Set(payload.keys.compactMap { $0 as? String })),
            "artwork merge only adds keys"
        )

        var invitation: [AnyHashable: Any] = [
            "source": "team_invitation",
            "type": "team_invitation",
            "invitation_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "team_id": "ffffffff-1111-4222-8333-444444444444",
            "invited_by_user_id": "99999999-aaaa-4bbb-8ccc-dddddddddddd",
            "event_id": "11111111-2222-4333-8444-555555555555",
        ]
        FanGeoPushArtwork.merge(
            FanGeoPushArtwork.fields(url: teamLogo, kind: .team, entityID: "ffffffff-1111-4222-8333-444444444444"),
            into: &invitation
        )
        expect(
            FanTeamInvitationNotificationDeepLinkPayload.isTeamInvitationNotification(invitation),
            "invitation deep-link unchanged"
        )

        var proPayload: [AnyHashable: Any] = [
            ProGameNotificationDeepLinkPayload.sourceKey: ProGameNotificationDeepLinkPayload.sourceValue,
            ProGameNotificationDeepLinkPayload.matchIDKey: "1336046",
            "notification_type": "pro_game_final",
        ]
        FanGeoPushArtwork.merge(
            FanGeoPushArtwork.fields(url: sportsBadge, kind: .proTeam),
            into: &proPayload
        )
        expect(
            ProGameNotificationDeepLinkPayload.matchID(from: proPayload) == "1336046",
            "pro-game deep-link match_id unchanged"
        )

        expect(
            !SportsArtworkEnrichmentService.usesDirectTheSportsDBAPI,
            "iOS does not call TheSportsDB directly"
        )

        let asyncResults = await runDownloadCases()
        for (ok, name) in asyncResults {
            expect(ok, name)
        }

        if failures == 0 {
            print("[FanGeoPushArtworkTest] ALL PASSED")
        } else {
            print("[FanGeoPushArtworkTest] FAILURES=\(failures)")
        }
    }

    private static func runDownloadCases() async -> [(Bool, String)] {
        var results: [(Bool, String)] = []
        func check(_ condition: Bool, _ name: String) {
            results.append((condition, name))
        }

        let missing = await FanGeoPushArtworkDownloader.download(urlString: nil)
        check(missing == nil, "missing artwork still delivers")

        let notFound = MockArtworkFetcher(data: Data(), status: 404, mime: "text/plain")
        let missingFile = await FanGeoPushArtworkDownloader.download(
            urlString: sportsBadge,
            fetcher: notFound
        )
        check(missingFile == nil, "404 image does not attach")

        var oversized = png1x1
        oversized.append(Data(count: FanGeoPushArtwork.maxBytes))
        let huge = MockArtworkFetcher(data: oversized, status: 200, mime: "image/png")
        let tooBig = await FanGeoPushArtworkDownloader.download(
            urlString: sportsBadge,
            fetcher: huge
        )
        check(tooBig == nil, "oversized image rejected")

        let html = MockArtworkFetcher(
            data: Data("<html>nope</html>".utf8),
            status: 200,
            mime: "text/html"
        )
        let badMime = await FanGeoPushArtworkDownloader.download(
            urlString: sportsBadge,
            fetcher: html
        )
        check(badMime == nil, "non-image MIME rejected")

        let hangTask = Task {
            await FanGeoPushArtworkDownloader.download(
                urlString: sportsBadge,
                fetcher: HangArtworkFetcher()
            )
        }
        hangTask.cancel()
        let timedOut = await hangTask.value
        check(timedOut == nil, "timeout/cancel delivers without artwork")

        let ok = MockArtworkFetcher(data: png1x1, status: 200, mime: "image/png")
        let file = await FanGeoPushArtworkDownloader.download(
            urlString: sportsBadge,
            fetcher: ok
        )
        check(file != nil, "trusted image downloads")
        if let file {
            try? FileManager.default.removeItem(at: file)
        }
        return results
    }
}

nonisolated private struct MockArtworkFetcher: FanGeoPushArtworkFetching {
    let data: Data
    let status: Int
    let mime: String

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://www.thesportsdb.com/")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": mime]
        )!
        return (data, response)
    }
}

nonisolated private struct HangArtworkFetcher: FanGeoPushArtworkFetching {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await Task.sleep(nanoseconds: 20_000_000_000)
        throw CancellationError()
    }
}
#endif
