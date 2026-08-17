import Foundation
import SwiftUI

#if DEBUG
enum TeamEventPlayerDetailSelfTests {
    static func runAll() {
        navigationTitleKeys()
        announcementDetailPresentation()
        pastEventDetection()
        interactiveRSVPGates()
        bottomSocialActionRowGates()
        presentationModeLocksBeforeHydration()
        pickupDetailKeepsStandaloneIdentity()
        print("[TeamEventPlayerDetailSelfTests] ALL PASSED")
    }

    private static func pickupDetailKeepsStandaloneIdentity() {
        precondition(PickupGameDetailPresentation.accent == FGColor.intentPlay)
        precondition(
            TeamEventPlayerDetailPresentation.showsBottomSocialActionRow(isTeamLinked: false),
            "standalone Pickup keeps Invite/Chat/Share"
        )
        precondition(
            !TeamEventPlayerDetailPresentation.showsBottomSocialActionRow(isTeamLinked: true),
            "Team Event Details stay without bottom social row"
        )
    }

    private static func presentationModeLocksBeforeHydration() {
        let teamId = UUID()
        let gameId = UUID()
        let team = PickupGameTeamCreationContext(
            teamId: teamId,
            teamName: "Atlas FC",
            teamSport: "soccer"
        )
        let teamToken = PickupDetailNavigationToken.teamEvent(gameId: gameId, team: team)
        precondition(teamToken.presentationMode == .teamEvent)
        precondition(teamToken.seededTeamContext?.teamId == teamId)
        precondition(
            FanTeamEventPresentation.detailNavigationTitleKey(
                isTeamLinked: teamToken.presentationMode == .teamEvent
            ) == "team_event_detail_nav_title"
        )
        precondition(
            !TeamEventPlayerDetailPresentation.showsBottomSocialActionRow(
                isTeamLinked: teamToken.presentationMode == .teamEvent
            )
        )

        let standalone = PickupDetailNavigationToken.standalone(gameId)
        precondition(standalone.presentationMode == .standalonePickup)
        precondition(standalone.seededTeamContext == nil)
        precondition(
            FanTeamEventPresentation.detailNavigationTitleKey(
                isTeamLinked: standalone.presentationMode == .teamEvent
            ) == "share_pickup_card_badge"
        )
        precondition(
            TeamEventPlayerDetailPresentation.showsBottomSocialActionRow(
                isTeamLinked: standalone.presentationMode == .teamEvent
            )
        )
    }

    private static func navigationTitleKeys() {
        let teamKey = FanTeamEventPresentation.detailNavigationTitleKey(isTeamLinked: true)
        let pickupKey = FanTeamEventPresentation.detailNavigationTitleKey(isTeamLinked: false)
        precondition(teamKey == "team_event_detail_nav_title")
        precondition(pickupKey == "share_pickup_card_badge")
        let announcementKey = FanTeamEventPresentation.detailNavigationTitleKey(
            isTeamLinked: true,
            format: .announcement
        )
        precondition(announcementKey == FanTeamAnnouncementDetailPresentation.navTitleKey)
        let eventTitle = L10n.t(teamKey, languageCode: "en")
        let pickupTitle = L10n.t(pickupKey, languageCode: "en")
        let announcementTitle = L10n.t(announcementKey, languageCode: "en")
        precondition(eventTitle == "Event Details", "team nav=\(eventTitle)")
        precondition(pickupTitle == "Pickup game", "pickup nav=\(pickupTitle)")
        precondition(announcementTitle == "Team Announcement", "announcement nav=\(announcementTitle)")
        for key in [
            "team_event_notes_title",
            "team_event_more_details",
            "team_event_more_details_subtitle",
            "team_event_change_your_response",
            "team_event_youre_going",
            "team_event_youre_maybe",
            "team_event_you_cant_go",
            "team_event_status_started",
            "team_event_whos_going_empty",
            "team_announcement_detail_hero_title",
            "team_announcement_detail_message_section",
            "team_announcement_detail_from_name_role_format",
            "team_announcement_detail_sent_to_entire_team",
            "team_announcement_detail_sent_to_count_format",
        ] {
            precondition(L10n.t(key, languageCode: "en") != key, "missing \(key)")
        }
    }

    private static func announcementDetailPresentation() {
        let created = "2026-08-11T23:20:00.000Z"
        let game = sampleAnnouncement(
            title: "Practice moved indoors",
            description: "This is a test.",
            createdAt: created,
            startAt: "2026-08-11T23:20:00.000Z"
        )
        precondition(
            FanTeamAnnouncementDetailPresentation.messageBody(for: game) == "This is a test."
        )
        precondition(
            FanTeamAnnouncementDetailPresentation.subjectTitle(for: game) == "Practice moved indoors"
        )
        precondition(
            !FanTeamAnnouncementDetailPresentation.showsMoreDetailsSection(for: .announcement)
        )
        precondition(
            FanTeamAnnouncementDetailPresentation.showsMoreDetailsSection(for: .practice)
        )

        let fromWithRole = FanTeamAnnouncementDetailPresentation.fromLine(
            senderName: "FanGeo",
            role: .owner,
            languageCode: "en"
        )
        precondition(fromWithRole == "From FanGeo (Owner)", "from=\(fromWithRole)")

        let entire = FanTeamAnnouncementDetailPresentation.audienceText(
            memberCount: 0,
            isTeamLinked: true,
            languageCode: "en"
        )
        precondition(entire == "Sent to Entire Team", "audience=\(String(describing: entire))")

        let counted = FanTeamAnnouncementDetailPresentation.audienceText(
            memberCount: 18,
            isTeamLinked: true,
            languageCode: "en"
        )
        precondition(counted == "Sent to 18 Team Members", "audience=\(String(describing: counted))")

        let omitted = FanTeamAnnouncementDetailPresentation.audienceText(
            memberCount: nil,
            isTeamLinked: false,
            languageCode: "en"
        )
        precondition(omitted == nil)

        let sent = FanTeamAnnouncementDetailPresentation.sentAtText(for: game, languageCode: "en")
        precondition(sent != nil && sent!.contains("2026"), "sentAt=\(String(describing: sent))")
        precondition(sent!.contains("•"), "sentAt missing bullet: \(String(describing: sent))")
    }

    private static func pastEventDetection() {
        let pastStart = "2020-01-01T18:00:00.000Z"
        let pastEnd = "2020-01-01T20:00:00.000Z"
        let futureStart = "2099-01-01T18:00:00.000Z"
        let futureEnd = "2099-01-01T20:00:00.000Z"
        let past = sampleGame(start: pastStart, end: pastEnd)
        let future = sampleGame(start: futureStart, end: futureEnd)
        precondition(TeamEventPlayerDetailPresentation.isPastEvent(past))
        precondition(!TeamEventPlayerDetailPresentation.isPastEvent(future))
    }

    private static func interactiveRSVPGates() {
        let future = sampleGame(
            start: "2099-08-12T21:03:00.000Z",
            end: "2099-08-12T23:03:00.000Z"
        )
        precondition(
            TeamEventPlayerDetailPresentation.showsInteractiveRSVP(
                game: future,
                isCancelled: false,
                isExcluded: false
            )
        )
        precondition(
            !TeamEventPlayerDetailPresentation.showsInteractiveRSVP(
                game: future,
                isCancelled: true,
                isExcluded: false
            )
        )
        precondition(
            !TeamEventPlayerDetailPresentation.showsInteractiveRSVP(
                game: future,
                isCancelled: false,
                isExcluded: true
            )
        )
    }

    private static func bottomSocialActionRowGates() {
        precondition(
            !TeamEventPlayerDetailPresentation.showsBottomSocialActionRow(isTeamLinked: true),
            "Team Event Detail must not show bottom Invite/Chat CTAs"
        )
        precondition(
            TeamEventPlayerDetailPresentation.showsBottomSocialActionRow(isTeamLinked: false),
            "Standalone Pickup keeps bottom social actions"
        )
    }

    private static func sampleAnnouncement(
        title: String,
        description: String,
        createdAt: String,
        startAt: String
    ) -> PickupGameRow {
        PickupGameRow(
            id: UUID(),
            creator_user_id: UUID(),
            creator_email: nil,
            title: title,
            sport: "soccer",
            description: description,
            game_format: "announcement",
            competition_level: nil,
            skill_level: "casual",
            game_start_at: startAt,
            end_time: nil,
            address: nil,
            city: nil,
            state: nil,
            latitude: 0,
            longitude: 0,
            is_visible: false,
            players_needed: 1,
            play_environment: "outdoor",
            participant_preference: "anyone",
            age_min: nil,
            age_max: nil,
            is_free: true,
            entry_fee_amount: nil,
            max_players: nil,
            status: "active",
            approved_join_count: 0,
            cleanup_delay_hours: 12,
            remove_after_at: nil,
            created_at: createdAt,
            updated_at: createdAt,
            poll_create_permission: nil
        )
    }

    private static func sampleGame(start: String, end: String) -> PickupGameRow {
        PickupGameRow(
            id: UUID(),
            creator_user_id: UUID(),
            creator_email: nil,
            title: "JT",
            sport: "soccer",
            description: "Bring water",
            game_format: "league_game",
            competition_level: nil,
            skill_level: "casual",
            game_start_at: start,
            end_time: end,
            address: "Draper",
            city: "Draper",
            state: "UT 84020",
            latitude: 40.52,
            longitude: -111.86,
            is_visible: false,
            players_needed: 11,
            play_environment: "outdoor",
            participant_preference: "anyone",
            age_min: nil,
            age_max: nil,
            is_free: true,
            entry_fee_amount: nil,
            max_players: 18,
            status: "active",
            approved_join_count: 2,
            cleanup_delay_hours: 12,
            remove_after_at: nil,
            created_at: start,
            updated_at: start,
            poll_create_permission: nil
        )
    }
}
#endif
