import Foundation
import SwiftUI

/// Polished copy + chrome for Team schedule/announcement notifications.
/// Layout stays on ``FanGeoActionCenterCard``; this only chooses wording and accent.
enum FanGeoActionCenterTeamNotificationPresentation {
    enum Variant: Equatable, Sendable {
        case created
        case timeChanged
        case dateChanged
        case locationChanged
        case opponentChanged
        case rescheduled
        case cancelled
        case announcement
        case updated
    }

    /// Team-branded Notifications (not Action Needed, not standalone Pickup).
    static func usesTeamChrome(for item: FanGeoActionItem) -> Bool {
        if FanGeoSecuritySessionReplacement.isSecurityItem(item) {
            return false
        }
        if FanGeoProGameInboxPresentation.isProGame(item) {
            return false
        }
        if isJoinRequestDecision(item.context.notificationType ?? "") {
            return false
        }
        switch item.kind {
        case .scheduleChange, .eventCancellation:
            break
        default:
            return false
        }
        if item.context.teamId != nil { return true }
        let name = item.context.teamName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return true }
        // Historical / live-upserted rows often omit team_id + team_name but keep
        // "IMC Team · Practice changed" in the stored title.
        return FanGeoTeamEventNoticeBuilder.inferredTeamName(for: item) != nil
    }

    static func variant(for item: FanGeoActionItem) -> Variant? {
        guard usesTeamChrome(for: item) else { return nil }
        if item.kind == .eventCancellation { return .cancelled }

        let type = (item.context.notificationType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let format = (item.context.eventTypeLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Membership / role / admin rows are not schedule events.
        if isMembershipLifecycle(type) {
            return nil
        }
        if type.contains("announcement") || format == GameType.announcement.rawValue {
            return .announcement
        }
        if type.contains("cancel") { return .cancelled }
        if type.contains("created") || type.contains("scheduled") {
            return .created
        }

        let kinds = item.context.changeDetails.map(\.labelKey)
        let hasTime = kinds.contains("action_center_change_time")
            || kinds.contains("action_center_change_end_time")
        let hasDate = kinds.contains("action_center_change_date")
        let hasLocation = kinds.contains("action_center_change_location")
        let hasOpponent = kinds.contains("action_center_change_opponent")
        let hasTitle = kinds.contains("action_center_change_title")
        let hasEventType = kinds.contains("action_center_change_event_type")
        let hasStatus = kinds.contains("action_center_change_status")
        let hasVisibility = kinds.contains("action_center_change_visibility")
        let fieldCount = [hasTime, hasDate, hasLocation, hasOpponent, hasTitle, hasEventType, hasStatus, hasVisibility]
            .filter(\.self).count
        if fieldCount > 1 {
            return .updated
        }
        if hasDate { return .dateChanged }
        if hasTime { return .timeChanged }
        if hasLocation { return .locationChanged }
        if hasOpponent { return .opponentChanged }

        if type.contains("time_and_location") || type.contains("reschedul") {
            return .updated
        }
        if type.contains("location") { return .locationChanged }
        if type.contains("opponent") { return .opponentChanged }
        if type.contains("time") { return .timeChanged }
        if item.context.changeDetails.isEmpty, item.context.eventStartAt != nil {
            if item.titleKey == "action_center_event_changed_format" {
                return .updated
            }
            let headline = (
                item.titleFormatArgs.first
                    ?? item.context.eventTitle
                    ?? ""
            ).lowercased()
            if headline.contains("changed") || headline.contains("updated") {
                return .updated
            }
            if type.contains("change") { return .updated }
            return .created
        }
        return .updated
    }

    static func badgeKey(for item: FanGeoActionItem) -> String {
        if isMembershipLifecycle(item.context.notificationType ?? "") {
            return "action_center_badge_team_update"
        }
        if usesTeamChrome(for: item), variant(for: item) == .announcement {
            return "action_center_badge_team_update"
        }
        if usesTeamChrome(for: item) {
            if item.kind == .eventCancellation || variant(for: item) == .cancelled {
                return "action_center_badge_event_cancelled"
            }
            if variant(for: item) == .created {
                return "action_center_badge_event_created"
            }
            return "action_center_badge_event_updated"
        }
        return item.kind.categoryBadgeKey
    }

    /// Membership / announcements: `TEAM · JT`. Team events: NEW PRACTICE / PRACTICE UPDATED / PRACTICE CANCELLED.
    static func headerBadgeText(for item: FanGeoActionItem, languageCode: String) -> String {
        if FanGeoSecuritySessionReplacement.isSecurityItem(item) {
            return FanGeoSecuritySessionNotificationPresentation.headerBadgeText(languageCode: languageCode)
        }
        if let proBadge = FanGeoProGameInboxPresentation.headerBadgeText(
            for: item,
            languageCode: languageCode
        ) {
            return proBadge
        }
        if isMembershipLifecycle(item.context.notificationType ?? "") {
            return membershipHeaderBadge(for: item, languageCode: languageCode)
        }
        if usesTeamChrome(for: item), let variant = variant(for: item) {
            if variant == .announcement {
                return eventTypeBadge(
                    noun: L10n.t("pickup_game_format_announcement", languageCode: languageCode),
                    variant: .created,
                    languageCode: languageCode
                )
            }
            return eventTypeBadge(
                noun: eventNoun(for: item, languageCode: languageCode),
                variant: variant,
                languageCode: languageCode
            )
        }
        return L10n.t(badgeKey(for: item), languageCode: languageCode)
    }

    private static func membershipHeaderBadge(for item: FanGeoActionItem, languageCode: String) -> String {
        let base = L10n.t(badgeKey(for: item), languageCode: languageCode)
        let team = item.context.teamName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !team.isEmpty else { return base }
        return String(
            format: L10n.t("action_center_team_header_format", languageCode: languageCode),
            locale: Locale(identifier: L10n.normalizedLanguageCode(languageCode)),
            base,
            team
        )
    }

    static func eventTypeBadge(
        noun: String,
        variant: Variant,
        languageCode: String
    ) -> String {
        let locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        let badgeNoun = badgeEventNoun(noun, languageCode: languageCode)
        let key: String
        switch variant {
        case .created, .announcement:
            key = "action_center_badge_new_event_format"
        case .cancelled:
            key = "action_center_badge_event_type_cancelled_format"
        default:
            key = "action_center_badge_event_type_updated_format"
        }
        return String(format: L10n.t(key, languageCode: languageCode), locale: locale, badgeNoun)
    }

    static func eventTypeTitle(
        noun: String,
        variant: Variant,
        languageCode: String
    ) -> String {
        let locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        let key: String
        switch variant {
        case .created, .announcement:
            key = "action_center_title_new_event_format"
        case .cancelled:
            key = "action_center_title_event_cancelled_format"
        default:
            key = "action_center_title_event_updated_format"
        }
        return String(format: L10n.t(key, languageCode: languageCode), locale: locale, noun)
    }

    private static func badgeEventNoun(_ noun: String, languageCode: String) -> String {
        let trimmed = noun.trimmingCharacters(in: .whitespacesAndNewlines)
        let lang = L10n.normalizedLanguageCode(languageCode)
        if lang.hasPrefix("zh") { return trimmed }
        return trimmed.uppercased(with: Locale(identifier: lang))
    }

    /// Team inbox cards keep only the unread blue dot — no second status/time dot.
    /// Unread cards never stack a second accent/status dot on any notification type.
    static func showsTimestampStatusDot(for item: FanGeoActionItem, isUnread: Bool = false) -> Bool {
        if isUnread { return false }
        if usesTeamChrome(for: item) { return false }
        let type = (item.context.notificationType ?? "").lowercased()
        if item.kind == .scheduleChange || item.kind == .eventCancellation,
           type.contains("team_event") || type.contains("team_game") || type.contains("team_announcement") {
            return false
        }
        return true
    }

    static func ctaKey(for item: FanGeoActionItem) -> String? {
        guard isMembershipLifecycle(item.context.notificationType ?? "") else { return nil }
        return "action_center_cta_view_teams"
    }

    static func title(for item: FanGeoActionItem, languageCode: String) -> String? {
        if isJoinRequestDecision(item.context.notificationType ?? "") {
            return L10n.t("action_center_join_decision_title", languageCode: languageCode)
        }
        if let membership = membershipTitle(for: item, languageCode: languageCode) {
            return membership
        }
        let type = item.context.notificationType ?? ""
        if isTeamEventScoreNotification(type) {
            if isTeamEventScored(type) {
                let parsed = FanTeamScorerAttributionMode.parse(item.context.scorerAttributionKind)
                let mode = parsed.promptsForScorer
                    ? parsed
                    : FanTeamScoreAttribution.mode(forSport: item.context.sportLabel ?? "")
                return FanTeamScoreAttributionPresentation.notificationTitle(
                    mode: mode,
                    scorerName: item.context.personName,
                    teamName: item.context.teamName ?? "",
                    languageCode: languageCode
                )
            }
            return FanTeamScoreAttributionPresentation.finalTitle(languageCode: languageCode)
        }
        guard let variant = variant(for: item) else { return nil }
        if variant == .announcement {
            return eventTypeTitle(
                noun: L10n.t("pickup_game_format_announcement", languageCode: languageCode),
                variant: .created,
                languageCode: languageCode
            )
        }
        return FanGeoTeamEventNoticeBuilder.headline(for: item, languageCode: languageCode)
    }

    /// One-line “what changed” under the title. Nil when nothing extra should show.
    static func summaryLine(for item: FanGeoActionItem, languageCode: String) -> String? {
        if FanGeoSecuritySessionReplacement.isSecurityItem(item) {
            return FanGeoSecuritySessionNotificationPresentation.body(languageCode: languageCode)
        }
        if let join = joinDecisionSummary(for: item, languageCode: languageCode) {
            return join
        }
        if let membership = membershipSummary(for: item, languageCode: languageCode) {
            return membership
        }
        guard let variant = variant(for: item) else { return nil }
        let locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        switch variant {
        case .announcement:
            let quote = announcementQuote(for: item)
            guard !quote.isEmpty else { return nil }
            return String(
                format: L10n.t("action_center_team_notif_quote_format", languageCode: languageCode),
                locale: locale,
                quote
            )
        case .timeChanged, .dateChanged, .locationChanged, .opponentChanged,
             .rescheduled, .created, .updated, .cancelled:
            // FanGeoTeamEventNotice owns the body. Do not emit a combined
            // date/time subtitle that duplicates notice rows.
            return nil
        }
    }

    static func eventNoun(for item: FanGeoActionItem, languageCode: String) -> String {
        if let format = GameType.parse(item.context.eventTypeLabel) {
            return format.scheduleFormSummaryLabel(languageCode: languageCode)
        }
        let title = item.context.eventTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let inferred = GameType.parse(title) {
            return inferred.scheduleFormSummaryLabel(languageCode: languageCode)
        }
        let lowered = title.lowercased()
        for format in GameType.allCases {
            let label = format.scheduleFormSummaryLabel(languageCode: languageCode)
            if lowered == label.lowercased() { return label }
        }
        return L10n.t("action_center_team_notif_event_noun", languageCode: languageCode)
    }

    static func cardAccent(for item: FanGeoActionItem) -> Color {
        if FanGeoProGameInboxPresentation.isProGame(item) {
            return FGColor.intentWatch
        }
        guard usesTeamChrome(for: item) else { return item.kind.accentColor }
        if item.kind == .eventCancellation || variant(for: item) == .cancelled {
            return Color.red
        }
        if isMembershipLifecycle(item.context.notificationType ?? "")
            || variant(for: item) == .announcement {
            if let teamId = item.context.teamId,
               let hex = FanTeamIdentityRealtimeCoordinator.shared.colorHex(forTeamId: teamId),
               let color = Color(fanTeamHex: hex) {
                return color
            }
            return FGColor.intentTeams
        }
        return item.kind.accentColor
    }

    // MARK: - Inbox hydration (no extra network)

    static func inboxFields(from serverRow: FanNotificationInboxServerRow) -> InboxFields {
        let payload = Self.resolvedPayload(serverRow.payload)
        let notificationType = serverRow.notification_type
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let gameFormat = string(payload, "game_format")
            ?? string(payload, "event_type")
        let teamName = string(payload, "team_name")
        let sportLabel = string(payload, "sport")
            ?? string(payload, "sport_label")
        let roleToken = string(payload, "role")
        let eventTitle = string(payload, "title")
            ?? string(payload, "after_title")
        let afterStartRaw = string(payload, "after_start")
        let beforeStartRaw = string(payload, "before_start")
        let afterEndRaw = string(payload, "after_end") ?? string(payload, "after_end_time")
        let beforeEndRaw = string(payload, "before_end") ?? string(payload, "before_end_time")
        let afterLocation = string(payload, "after_location")
        let beforeLocation = string(payload, "before_location")
        let afterOpponent = string(payload, "after_opponent")
        let beforeOpponent = string(payload, "before_opponent")
        let afterStatus = string(payload, "after_status")
        let beforeStatus = string(payload, "before_status")
        let beforeTitle = string(payload, "before_title")
        let afterTitle = string(payload, "after_title") ?? eventTitle
        let beforeEventType = string(payload, "before_game_format")
            ?? string(payload, "before_event_type")
        let afterEventType = string(payload, "after_game_format")
            ?? string(payload, "after_event_type")
            ?? gameFormat
        let beforeVisibility = string(payload, "before_visibility")
            ?? boolToken(payload, "before_is_visible")
        let afterVisibility = string(payload, "after_visibility")
            ?? boolToken(payload, "after_is_visible")
        let announcement = bool(payload, "is_team_announcement") == true
            || (notificationType ?? "").lowercased().contains("announcement")
            || (gameFormat?.lowercased() == GameType.announcement.rawValue)
        let kinds = stringArray(payload, "change_kinds")

        let details = FanGeoTeamEventChangeProjection.details(
            beforeStartRaw: beforeStartRaw,
            afterStartRaw: afterStartRaw,
            beforeEndRaw: beforeEndRaw,
            afterEndRaw: afterEndRaw,
            beforeLocation: beforeLocation,
            afterLocation: afterLocation,
            beforeOpponent: beforeOpponent,
            afterOpponent: afterOpponent,
            beforeStatus: beforeStatus,
            afterStatus: afterStatus,
            beforeTitle: beforeTitle,
            afterTitle: afterTitle,
            beforeEventType: beforeEventType,
            afterEventType: afterEventType,
            beforeVisibility: beforeVisibility,
            afterVisibility: afterVisibility,
            changeKinds: kinds
        )

        let affected = FanGeoTeamEventAffectedPlayerResolver.fromPayload(payload)
        let body = serverRow.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return InboxFields(
            notificationType: notificationType,
            gameFormat: gameFormat,
            teamName: teamName,
            eventTitle: eventTitle,
            locationLabel: afterLocation,
            eventStartAt: FanGeoTeamEventNoticeBuilder.parseInstant(afterStartRaw),
            changeDetails: details,
            announcementBody: announcement ? (body.isEmpty ? eventTitle : body) : nil,
            sportLabel: sportLabel,
            roleToken: roleToken,
            opponentName: afterOpponent ?? beforeOpponent,
            personName: affected?.displayName,
            personAvatarURL: affected?.avatarURL,
            personAvatarThumbnailURL: affected?.avatarThumbnailURL,
            managedPlayerId: affected?.managedPlayerId,
            isManagedPlayer: affected?.isManagedPlayer ?? false,
            scoreLine: string(payload, "score_line"),
            scorerAttributionKind: string(payload, "scorer_attribution_kind")
        )
    }

    struct InboxFields: Equatable, Sendable {
        var notificationType: String?
        var gameFormat: String?
        var teamName: String?
        var eventTitle: String?
        var locationLabel: String?
        var eventStartAt: Date?
        var changeDetails: [FanGeoActionChangeDetail]
        var announcementBody: String?
        var sportLabel: String?
        var roleToken: String?
        var opponentName: String? = nil
        var personName: String? = nil
        var personAvatarURL: String? = nil
        var personAvatarThumbnailURL: String? = nil
        var managedPlayerId: UUID? = nil
        var isManagedPlayer: Bool = false
        var scoreLine: String? = nil
        var scorerAttributionKind: String? = nil
    }

    // MARK: - Private

    static func isJoinRequestDecision(_ rawType: String) -> Bool {
        let type = rawType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return type == "join_request_approved" || type == "join_request_rejected"
    }

    static func isTeamEventScoreNotification(_ rawType: String) -> Bool {
        let type = rawType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return type == "team_event_scored" || type == "team_event_final"
    }

    static func isTeamEventScored(_ rawType: String) -> Bool {
        rawType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "team_event_scored"
    }

    private static func joinDecisionSummary(
        for item: FanGeoActionItem,
        languageCode: String
    ) -> String? {
        let type = (item.context.notificationType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isJoinRequestDecision(type) else { return nil }
        let event = item.context.eventTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? item.context.matchupLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        let name = event.isEmpty ? L10n.t("Pickup", languageCode: languageCode) : event
        let locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        let key = type == "join_request_approved"
            ? "action_center_join_decision_approved_format"
            : "action_center_join_decision_declined_format"
        return String(format: L10n.t(key, languageCode: languageCode), locale: locale, name)
    }

    static func isMembershipLifecycle(_ rawType: String) -> Bool {
        let type = rawType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if type.isEmpty { return false }
        return type.contains("removed_from_team")
            || type.contains("team_role")
            || type.contains("team_admin")
            || type.contains("player_number")
            || type.contains("preferred_position")
            || type.contains("removed_from_event")
            || type.contains("added_back_to_event")
            || type.contains("left_team")
    }

    private static func membershipTitle(for item: FanGeoActionItem, languageCode: String) -> String? {
        let type = (item.context.notificationType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isMembershipLifecycle(type) else { return nil }
        if type.contains("removed_from_team") {
            return L10n.t("action_center_team_notif_removed_title", languageCode: languageCode)
        }
        if type.contains("team_admin") {
            return L10n.t("action_center_team_notif_admin_title", languageCode: languageCode)
        }
        if type.contains("team_role") {
            return L10n.t("action_center_team_notif_role_title", languageCode: languageCode)
        }
        return nil
    }

    private static func membershipSummary(for item: FanGeoActionItem, languageCode: String) -> String? {
        let type = (item.context.notificationType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isMembershipLifecycle(type) else { return nil }
        let team = item.context.teamName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        if type.contains("removed_from_team") {
            let name = team.isEmpty ? L10n.t("Team", languageCode: languageCode) : team
            return String(
                format: L10n.t("action_center_team_notif_removed_body_format", languageCode: languageCode),
                locale: locale,
                name
            )
        }
        if type.contains("team_admin_granted") {
            let name = team.isEmpty ? L10n.t("Team", languageCode: languageCode) : team
            return String(
                format: L10n.t("action_center_team_notif_admin_granted_body_format", languageCode: languageCode),
                locale: locale,
                name
            )
        }
        if type.contains("team_admin_removed") {
            let name = team.isEmpty ? L10n.t("Team", languageCode: languageCode) : team
            return String(
                format: L10n.t("action_center_team_notif_admin_removed_body_format", languageCode: languageCode),
                locale: locale,
                name
            )
        }
        if type.contains("team_role") {
            let name = team.isEmpty ? L10n.t("Team", languageCode: languageCode) : team
            let role = FanTeamMemberRole.parse(item.context.roleToken)
            if role == .member {
                return String(
                    format: L10n.t("action_center_team_notif_role_member_body_format", languageCode: languageCode),
                    locale: locale,
                    name,
                    L10n.t(FanTeamMemberRole.member.localizedKey, languageCode: languageCode)
                )
            }
            return String(
                format: L10n.t("action_center_team_notif_role_body_format", languageCode: languageCode),
                locale: locale,
                L10n.t(role.localizedKey, languageCode: languageCode),
                name
            )
        }
        let fallback = item.subtitle(languageCode: languageCode)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? nil : fallback
    }

    private static func announcementQuote(for item: FanGeoActionItem) -> String {
        if let body = item.subtitleFormatArgs.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           !body.isEmpty {
            return body
        }
        let title = item.context.eventTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title
    }

    private static func compactDayLabel(_ date: Date, languageCode: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return formatter.string(from: date)
    }

    /// Historical Inbox rows nest before/after keys or use camelCase.
    static func resolvedPayload(
        _ payload: [String: AnyCodableJSON]?
    ) -> [String: AnyCodableJSON]? {
        guard var map = payload else { return nil }
        for nestedKey in ["payload", "data", "changes", "change"] {
            if case .object(let nested)? = map[nestedKey] {
                for (key, value) in nested where map[key] == nil {
                    map[key] = value
                }
            }
        }
        let aliases: [(String, String)] = [
            ("beforeStart", "before_start"),
            ("afterStart", "after_start"),
            ("beforeEnd", "before_end"),
            ("afterEnd", "after_end"),
            ("beforeEndTime", "before_end"),
            ("afterEndTime", "after_end"),
            ("old_start", "before_start"),
            ("new_start", "after_start"),
            ("beforeLocation", "before_location"),
            ("afterLocation", "after_location"),
            ("old_location", "before_location"),
            ("new_location", "after_location"),
            ("beforeOpponent", "before_opponent"),
            ("afterOpponent", "after_opponent"),
            ("beforeStatus", "before_status"),
            ("afterStatus", "after_status"),
            ("teamName", "team_name"),
            ("gameFormat", "game_format"),
            ("eventType", "event_type"),
            ("changeKinds", "change_kinds"),
            ("managedPlayerId", "managed_player_id"),
            ("targetManagedPlayerId", "target_managed_player_id"),
            ("managedPlayerName", "managed_player_name"),
            ("isManagedPlayer", "is_managed_player"),
            ("membershipId", "membership_id"),
            ("participantId", "participant_id"),
            ("playerId", "player_id"),
            ("playerName", "player_name"),
        ]
        for (from, to) in aliases where map[to] == nil {
            if let value = map[from] {
                map[to] = value
            }
        }
        return map
    }

    private static func string(_ payload: [String: AnyCodableJSON]?, _ key: String) -> String? {
        guard let raw = payload?[key]?.stringValue else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func bool(_ payload: [String: AnyCodableJSON]?, _ key: String) -> Bool? {
        payload?[key]?.boolValue
    }

    private static func boolToken(_ payload: [String: AnyCodableJSON]?, _ key: String) -> String? {
        if let raw = string(payload, key) { return raw }
        guard let value = bool(payload, key) else { return nil }
        return value ? "true" : "false"
    }

    private static func stringArray(_ payload: [String: AnyCodableJSON]?, _ key: String) -> [String] {
        payload?[key]?.stringArray ?? []
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
