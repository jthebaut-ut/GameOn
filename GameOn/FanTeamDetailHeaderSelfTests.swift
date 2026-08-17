import Foundation

enum FanTeamDetailHeaderSelfTests {
    static func runAll() {
        testMetaLineDetailNilSafe()
        testSafeMemberCount()
        testMarkIdentityStableAndShort()
        testInvalidLogoURLRejected()
        testMarkIdentityIgnoresQueryNoiseViaCanonical()
    }

    private static func testMetaLineDetailNilSafe() {
        let line = FanTeamDetailHeaderPresentation.metaLine(
            competitionLevel: nil,
            sport: "Soccer",
            memberCount: 4,
            pendingInvitationCount: 0,
            canManage: true,
            languageCode: "en"
        )
        precondition(!line.isEmpty, "meta line must compose from summary alone")
        precondition(!line.lowercased().contains("pending") || line.contains("4"))

        let withPending = FanTeamDetailHeaderPresentation.metaLine(
            competitionLevel: .youth,
            sport: "Soccer",
            memberCount: 4,
            pendingInvitationCount: 2,
            canManage: true,
            languageCode: "en"
        )
        precondition(withPending.contains("·"), "pending segment should append for managers")

        let memberNoPending = FanTeamDetailHeaderPresentation.metaLine(
            competitionLevel: nil,
            sport: "Soccer",
            memberCount: 1,
            pendingInvitationCount: 9,
            canManage: false,
            languageCode: "en"
        )
        // Non-managers must not surface pending invitation counts.
        precondition(memberNoPending == FanTeamMetaLine.compose(
            competitionLevel: nil,
            sport: "Soccer",
            memberCount: 1,
            languageCode: "en"
        ))
    }

    private static func testSafeMemberCount() {
        precondition(FanTeamDetailHeaderPresentation.safeMemberCount(-3) == 0)
        precondition(FanTeamDetailHeaderPresentation.safeMemberCount(0) == 0)
        precondition(FanTeamDetailHeaderPresentation.safeMemberCount(12) == 12)
    }

    private static func testMarkIdentityStableAndShort() {
        let a = FanTeamMarkIdentity.token(
            sport: "Soccer",
            logoURL: "https://example.com/logo.png?sig=aaaa",
            logoThumbnailURL: "https://example.com/logo-thumb.png?sig=bbbb",
            colorHex: "#112233",
            preferDetailURL: false,
            displayRefreshToken: nil
        )
        let b = FanTeamMarkIdentity.token(
            sport: "Soccer",
            logoURL: "https://example.com/logo.png?sig=zzzz",
            logoThumbnailURL: "https://example.com/logo-thumb.png?sig=yyyy",
            colorHex: "#112233",
            preferDetailURL: false,
            displayRefreshToken: nil
        )
        precondition(a == b, "canonical identity must ignore query noise")
        precondition(a.count < 40, "identity token must stay short for AttributeGraph")
        precondition(a.hasPrefix("ftm-"))
    }

    private static func testInvalidLogoURLRejected() {
        precondition(FanTeamMarkIdentity.safeURL(from: nil) == nil)
        precondition(FanTeamMarkIdentity.safeURL(from: "") == nil)
        precondition(FanTeamMarkIdentity.safeURL(from: "not a url") == nil)
        precondition(FanTeamMarkIdentity.safeURL(from: "https://cdn.example.com/t.png") != nil)
    }

    private static func testMarkIdentityIgnoresQueryNoiseViaCanonical() {
        let thumb = ImageDisplayURL.canonicalStorageURLString("https://cdn.example.com/a.png?x=1")
        precondition(!thumb.contains("?"), "canonical must strip query")
    }
}
