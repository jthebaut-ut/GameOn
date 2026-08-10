import Foundation

/// Presentation-only context so Team Chat can show Team branding without changing group realtime/backend.
struct FanTeamChatContext: Equatable, Sendable {
    let conversationId: UUID
    let teamId: UUID
    let teamName: String
    let sport: String
    let memberCount: Int
    let competitionLevel: PickupCompetitionLevel?
    let logoURL: String?
    let logoThumbnailURL: String?
    let colorHex: String?

    init(from summary: FanTeamSummary) {
        conversationId = summary.groupConversationId
        teamId = summary.id
        teamName = summary.name
        sport = summary.sport
        memberCount = summary.memberCount
        competitionLevel = summary.competitionLevel
        logoURL = summary.logoURL
        logoThumbnailURL = summary.logoThumbnailURL
        colorHex = summary.colorHex
    }

    init(
        conversationId: UUID,
        teamId: UUID,
        teamName: String,
        sport: String,
        memberCount: Int,
        competitionLevel: PickupCompetitionLevel? = nil,
        logoURL: String?,
        logoThumbnailURL: String?,
        colorHex: String?
    ) {
        self.conversationId = conversationId
        self.teamId = teamId
        self.teamName = teamName
        self.sport = sport
        self.memberCount = memberCount
        self.competitionLevel = competitionLevel
        self.logoURL = logoURL
        self.logoThumbnailURL = logoThumbnailURL
        self.colorHex = colorHex
    }

    func headerSubtitle(languageCode: String) -> String {
        FanTeamMetaLine.compose(
            competitionLevel: competitionLevel,
            sport: sport,
            memberCount: memberCount,
            languageCode: languageCode
        )
    }

    func applying(_ change: FanTeamIdentityChange) -> FanTeamChatContext {
        FanTeamChatContext(
            conversationId: conversationId,
            teamId: teamId,
            teamName: change.name,
            sport: change.sport,
            memberCount: memberCount,
            competitionLevel: change.competitionLevel,
            logoURL: change.logoURL,
            logoThumbnailURL: change.logoThumbnailURL,
            colorHex: change.colorHex
        )
    }
}
