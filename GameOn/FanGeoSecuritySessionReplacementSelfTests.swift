import Foundation
import UserNotifications

#if DEBUG
enum FanGeoSecuritySessionReplacementSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[SecuritySessionReplacedTest] PASS \(name)")
            } else {
                failures += 1
                print("[SecuritySessionReplacedTest] FAIL \(name)")
            }
        }

        let iphone = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let ipad = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        expect(
            FanGeoSecuritySessionReplacement.decision(
                oldSessionId: "old-iphone",
                newSessionId: "new-ipad",
                oldInstallationId: iphone,
                newInstallationId: ipad
            ) == .notify,
            "iPhone signed in then iPad signs in notifies old iPhone"
        )
        expect(
            FanGeoSecuritySessionReplacement.decision(
                oldSessionId: "old-iphone",
                newSessionId: "new-ipad",
                oldInstallationId: iphone,
                newInstallationId: ipad
            ) != .sameDevice,
            "new iPad is not treated as the replaced device"
        )
        expect(
            FanGeoSecuritySessionReplacement.decision(
                oldSessionId: nil,
                newSessionId: "first",
                oldInstallationId: nil,
                newInstallationId: iphone
            ) == .noPreviousSession,
            "first claim does not notify"
        )
        expect(
            FanGeoSecuritySessionReplacement.decision(
                oldSessionId: "a",
                newSessionId: "b",
                oldInstallationId: iphone,
                newInstallationId: iphone
            ) == .sameDevice,
            "same physical device re-auth does not false-warn"
        )
        expect(
            FanGeoSecuritySessionReplacement.decision(
                oldSessionId: "a",
                newSessionId: "b",
                oldInstallationId: iphone,
                newInstallationId: nil
            ) == .missingNewInstallation,
            "missing new installation does not guess recipients"
        )

        let rotatedSameInstall = FanGeoSecuritySessionReplacement.decision(
            oldSessionId: "session-1",
            newSessionId: "session-2",
            oldInstallationId: iphone,
            newInstallationId: iphone
        )
        expect(rotatedSameInstall == .sameDevice, "APNs token rotation on same install does not notify")

        let fanItem = FanGeoActionItem(
            id: FanGeoSecuritySessionReplacement.dedupeKey(
                oldInstallationId: iphone,
                oldSessionId: "old",
                newSessionId: "new"
            ),
            kind: .securitySession,
            titleKey: "security_session_replaced_title",
            subtitleKey: "security_session_replaced_body",
            destination: .accountSecurity,
            timestamp: Date(),
            context: FanGeoActionContext(
                eventTypeLabel: "iPad",
                notificationType: FanGeoSecuritySessionReplacement.notificationType
            )
        )
        expect(fanItem.kind.listSection == .notifications, "security row lives in Inbox Notifications")
        expect(fanItem.destination == .accountSecurity, "tap does not route to Discover/Team/Chat/Schedule")
        expect(
            FanGeoActionCenterTeamNotificationPresentation.usesTeamChrome(for: fanItem) == false,
            "security row is not a Team event card"
        )
        expect(
            FanGeoProGameInboxPresentation.isProGame(fanItem) == false,
            "security row is not a pro-game card"
        )
        expect(
            fanItem.title(languageCode: "en") == "New sign-in detected",
            "fan security title"
        )
        expect(
            fanItem.subtitle(languageCode: "en").contains("another device"),
            "fan security body"
        )
        expect(
            FanGeoSecuritySessionNotificationPresentation.deviceLine(for: fanItem, languageCode: "en")
                == "Signed in on iPad",
            "optional iPad device line"
        )

        let businessItem = FanGeoActionItem(
            id: "security_session_replaced:biz",
            kind: .securitySession,
            titleKey: "security_session_replaced_title",
            subtitleKey: "security_session_replaced_body",
            destination: .accountSecurity,
            context: FanGeoActionContext(
                eventTypeLabel: "iPhone",
                notificationType: FanGeoSecuritySessionReplacement.notificationType
            )
        )
        expect(businessItem.destination == .accountSecurity, "business path uses the same security destination")
        expect(
            FanGeoActionCenterTeamNotificationPresentation.headerBadgeText(
                for: businessItem,
                languageCode: "en"
            ) == "SECURITY",
            "business security badge"
        )

        let missingDevice = FanGeoActionItem(
            id: "security_session_replaced:no-device",
            kind: .securitySession,
            titleKey: "security_session_replaced_title",
            subtitleKey: "security_session_replaced_body",
            destination: .accountSecurity,
            context: FanGeoActionContext(notificationType: FanGeoSecuritySessionReplacement.notificationType)
        )
        expect(
            FanGeoSecuritySessionNotificationPresentation.deviceLine(for: missingDevice, languageCode: "en") == nil,
            "missing old APNs / device family does not invent device copy"
        )

        let dedupeA = FanGeoSecuritySessionReplacement.dedupeKey(
            oldInstallationId: iphone,
            oldSessionId: "old",
            newSessionId: "new"
        )
        let dedupeB = FanGeoSecuritySessionReplacement.dedupeKey(
            oldInstallationId: iphone,
            oldSessionId: "old",
            newSessionId: "new"
        )
        expect(dedupeA == dedupeB, "retry uses a stable dedupe key")
        expect(dedupeA.hasPrefix("security_session_replaced:"), "dedupe key namespace")

        let concurrentFirst = FanGeoSecuritySessionReplacement.dedupeKey(
            oldInstallationId: iphone,
            oldSessionId: "s0",
            newSessionId: "s1"
        )
        let concurrentSecond = FanGeoSecuritySessionReplacement.dedupeKey(
            oldInstallationId: ipad,
            oldSessionId: "s1",
            newSessionId: "s2"
        )
        expect(concurrentFirst != concurrentSecond, "two concurrent new logins stay deterministic and distinct")

        let dirty: [AnyHashable: Any] = [
            "source": FanGeoSecuritySessionReplacement.source,
            "security_event": "new_sign_in",
            "new_device_type": "iPad",
            "event_id": UUID().uuidString,
            "access_token": "secret-access",
            "refresh_token": "secret-refresh",
            "ip_address": "203.0.113.10",
            "user_agent": "FanGeo/1.0",
            "session_token": "jwt"
        ]
        let safe = FanGeoSecuritySessionReplacement.sanitizedCustomData(dirty)
        expect(safe["source"] == FanGeoSecuritySessionReplacement.source, "payload keeps source")
        expect(safe["new_device_type"] == "iPad", "payload keeps coarse device family")
        expect(safe["access_token"] == nil, "payload drops access token")
        expect(safe["refresh_token"] == nil, "payload drops refresh token")
        expect(safe["ip_address"] == nil, "payload drops IP")
        expect(safe["user_agent"] == nil, "payload drops user agent")
        expect(safe["session_token"] == nil, "payload drops session token")

        let userInfo: [AnyHashable: Any] = [
            "source": FanGeoSecuritySessionReplacement.source,
            "notification_type": FanGeoSecuritySessionReplacement.notificationType,
            "new_device_type": "iPad",
            "deduplication_key": dedupeA,
            "aps": [
                "alert": [
                    "title": "New sign-in detected",
                    "body": "Your FanGeo account was signed in on another device. This device has been signed out."
                ]
            ]
        ]
        let ingested = FanGeoNotificationInboxIngest.makeItem(
            userInfo: userInfo,
            content: nil
        )
        if let ingested {
            expect(ingested.kind == .securitySession, "APNs ingest maps to security kind")
            expect(ingested.destination == .accountSecurity, "APNs ingest tap is account security")
            expect(
                FanGeoActionCenterTeamNotificationPresentation.usesTeamChrome(for: ingested) == false,
                "ingested security row is not Team chrome"
            )
        } else {
            expect(false, "APNs ingest creates a security inbox item")
        }

        let serverRow = FanNotificationInboxServerRow(
            id: UUID(),
            notification_type: FanGeoSecuritySessionReplacement.notificationType,
            title: "New sign-in detected",
            body: "Your FanGeo account was signed in on another device. This device has been signed out.",
            kind_raw: "securitySession",
            destination_raw: "accountSecurity",
            source_type: FanGeoSecuritySessionReplacement.source,
            source_id: nil,
            team_id: nil,
            event_id: UUID(),
            actor_user_id: nil,
            payload: [
                "security_event": .string("new_sign_in"),
                "new_device_type": .string("iPad")
            ],
            deduplication_key: dedupeA,
            created_at: Date(),
            read_at: nil,
            cleared_at: nil
        )
        let entry = FanGeoNotificationInboxEntry.from(serverRow: serverRow)
        if let item = entry.asActionItem() {
            expect(item.kind == .securitySession, "Inbox security row hydrates")
            expect(item.destination == .accountSecurity, "Inbox security tap destination")
            expect(item.context.eventTypeLabel == "iPad", "Inbox keeps optional device family")
            expect(
                FanGeoProGameInboxPresentation.isProGame(item) == false,
                "Inbox security row does not become a pro-game card"
            )
        } else {
            expect(false, "Inbox security row maps to an action item")
        }

        expect(
            FanGeoActionKind.securitySession.dismissalPersistence == .notificationInbox,
            "logout/account-switch does not use Action Needed dismissals for security rows"
        )
        expect(
            FanGeoActionDestination.accountSecurity != .scheduleActivity
                && FanGeoActionDestination.accountSecurity != .teamsHome
                && FanGeoActionDestination.accountSecurity != .chatUnread,
            "security tap is not unrelated content"
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(
                kind: .securitySession,
                teamId: nil,
                personAvatarURL: "https://example.test/avatar.jpg",
                isPendingRating: false,
                personName: "FanGeo"
            ) == .kindGlyph,
            "security card uses the lock glyph, not a person or Team mark"
        )

        let scoreItem = FanGeoActionItem(
            id: "pro_game:score:control",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["Chicago Cubs scored"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                notificationType: "pro_game_score",
                proGameMatchId: "mlb-control",
                proGameSnapshot: FanGeoProGameInboxSnapshot(
                    kind: .score,
                    matchID: "mlb-control",
                    homeTeam: "Chicago Cubs",
                    awayTeam: "St. Louis Cardinals",
                    homeScore: 3,
                    awayScore: 0,
                    scoringTeam: "Chicago Cubs",
                    league: "MLB",
                    sport: "Baseball",
                    matchStatus: "LIVE",
                    clock: nil,
                    homeBadgeURL: nil,
                    awayBadgeURL: nil,
                    homeProviderId: nil,
                    awayProviderId: nil
                )
            )
        )
        expect(
            FanGeoProGameInboxPresentation.isProGame(scoreItem),
            "pro-game cards remain on the rich scoreboard path"
        )
        expect(
            FanGeoSecuritySessionReplacement.isSecurityItem(scoreItem) == false,
            "pro-game cards are not classified as security events"
        )

        if failures == 0 {
            print("[SecuritySessionReplacedTest] ALL PASSED")
        } else {
            print("[SecuritySessionReplacedTest] FAILURES=\(failures)")
            assertionFailure("FanGeoSecuritySessionReplacementSelfTests failed: \(failures)")
        }
    }
}
#endif
