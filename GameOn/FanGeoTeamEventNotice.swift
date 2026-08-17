import Foundation

/// One labeled identity/change row on a Team event Inbox card.
struct FanGeoTeamEventNoticeRow: Equatable, Hashable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case team
        case game
        case date
        case time
        case location
        case opponent
        case status
        case quote
        case title
        case eventType
        case visibility
        case player
    }

    var kind: Kind
    var labelKey: String
    var value: String
    var oldValue: String? = nil
    var newValue: String? = nil
    var systemImage: String

    var isIdentity: Bool {
        kind == .team || kind == .game || kind == .player
    }

    func displayValue(languageCode: String) -> String {
        let locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        let oldText = oldValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let newText = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !oldText.isEmpty, !newText.isEmpty, oldText != newText {
            return String(
                format: L10n.t("action_center_value_arrow_format", languageCode: languageCode),
                locale: locale,
                oldText,
                newText
            )
        }
        if !newText.isEmpty { return newText }
        if !oldText.isEmpty { return oldText }
        return value
    }

    func spokenLine(languageCode: String) -> String {
        let locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        let label = FanGeoTeamEventNoticeBuilder.spokenFieldLabel(
            labelKey,
            languageCode: languageCode
        )
        let oldText = oldValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let newText = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !oldText.isEmpty, !newText.isEmpty, oldText != newText {
            return String(
                format: L10n.t(
                    "action_center_team_event_a11y_changed_format",
                    languageCode: languageCode
                ),
                locale: locale,
                label,
                oldText,
                newText
            )
        }
        return String(
            format: L10n.t("action_center_team_event_a11y_labeled_format", languageCode: languageCode),
            locale: locale,
            label,
            displayValue(languageCode: languageCode)
        )
    }
}

/// Canonical Team EVENT Inbox projection (not membership, not Action Needed).
struct FanGeoTeamEventNotice: Equatable, Sendable {
    var title: String
    var identityRows: [FanGeoTeamEventNoticeRow]
    var changeRows: [FanGeoTeamEventNoticeRow]
    var supportingRows: [FanGeoTeamEventNoticeRow]
    var omitsGameRow: Bool

    var allRows: [FanGeoTeamEventNoticeRow] {
        identityRows + changeRows + supportingRows
    }

    func accessibilityLabel(languageCode: String) -> String {
        var parts: [String] = [title]
        for row in identityRows + supportingRows where row.kind == .player || row.kind == .team {
            if row.kind == .player, title.localizedCaseInsensitiveContains(row.value) {
                continue
            }
            parts.append(row.spokenLine(languageCode: languageCode))
        }
        for row in identityRows where row.kind == .game {
            parts.append(row.displayValue(languageCode: languageCode))
        }
        parts.append(contentsOf: changeRows.map { $0.spokenLine(languageCode: languageCode) })
        for row in supportingRows where row.kind != .player && row.kind != .team {
            parts.append(row.spokenLine(languageCode: languageCode))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ". ")
    }
}

/// Shared Team/event naming + labeled-row composition for Inbox cards.
enum FanGeoTeamEventNoticeBuilder {
    static func isScheduleEventNotice(for item: FanGeoActionItem) -> Bool {
        guard FanGeoActionCenterTeamNotificationPresentation.usesTeamChrome(for: item) else {
            return false
        }
        let type = item.context.notificationType ?? ""
        if FanGeoActionCenterTeamNotificationPresentation.isMembershipLifecycle(type) {
            return false
        }
        if FanGeoActionCenterTeamNotificationPresentation.isJoinRequestDecision(type) {
            return false
        }
        return true
    }

    static func make(for item: FanGeoActionItem, languageCode: String) -> FanGeoTeamEventNotice? {
        guard isScheduleEventNotice(for: item) else { return nil }
        let variant = FanGeoActionCenterTeamNotificationPresentation.variant(for: item) ?? .updated
        let title = FanGeoActionCenterTeamNotificationPresentation.title(
            for: item,
            languageCode: languageCode
        ) ?? item.title(languageCode: languageCode)

        let type = item.context.notificationType ?? ""
        if FanGeoActionCenterTeamNotificationPresentation.isTeamEventScoreNotification(type) {
            return makeScoreNotice(for: item, title: title, languageCode: languageCode)
        }

        if variant == .announcement {
            var supporting: [FanGeoTeamEventNoticeRow] = []
            supporting.append(
                contentsOf: identitySupportingRows(
                    for: item,
                    includeTeam: true,
                    includeCustomTitle: false,
                    languageCode: languageCode
                )
            )
            if let quote = announcementQuote(for: item) {
                supporting.append(
                    FanGeoTeamEventNoticeRow(
                        kind: .quote,
                        labelKey: "action_center_label_announcement",
                        value: quote,
                        systemImage: "megaphone.fill"
                    )
                )
            }
            return FanGeoTeamEventNotice(
                title: title,
                identityRows: [],
                changeRows: [],
                supportingRows: supporting,
                omitsGameRow: true
            )
        }

        let classified = classifyChanges(for: item, languageCode: languageCode)
        var changeRows: [FanGeoTeamEventNoticeRow]
        if variant == .cancelled {
            changeRows = classified.filter { $0.kind != .status }
        } else {
            changeRows = classified
        }
        if changeRows.isEmpty {
            changeRows = kindOnlyChangeRows(
                for: item,
                variant: variant,
                languageCode: languageCode
            )
        }
        let includeUnchangedContext = variant == .created
            || (changeRows.isEmpty && variant != .cancelled)
        let supportingContextRows = includeUnchangedContext
            ? supportingContext(
                for: item,
                languageCode: languageCode,
                excluding: Set(changeRows.map(\.kind))
            )
            : []
        let includeTeam = variant == .created || variant == .cancelled || changeRows.isEmpty
        let omitCustomTitle = changeRows.contains(where: { $0.kind == .title })
        let supporting = identitySupportingRows(
            for: item,
            includeTeam: includeTeam,
            includeCustomTitle: !omitCustomTitle,
            languageCode: languageCode
        ) + supportingContextRows
        let headline = headline(for: item, languageCode: languageCode)

        return FanGeoTeamEventNotice(
            title: headline ?? title,
            identityRows: [],
            changeRows: changeRows,
            supportingRows: supporting,
            omitsGameRow: true
        )
    }

    private static func makeScoreNotice(
        for item: FanGeoActionItem,
        title: String,
        languageCode: String
    ) -> FanGeoTeamEventNotice {
        var identity: [FanGeoTeamEventNoticeRow] = []
        if let player = FanGeoTeamEventAffectedPlayerResolver.fromContext(item.context) {
            let name = player.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                identity.append(
                    FanGeoTeamEventNoticeRow(
                        kind: .player,
                        labelKey: "team_score_scorer",
                        value: name,
                        systemImage: "person.crop.circle.fill"
                    )
                )
            }
        }
        var supporting: [FanGeoTeamEventNoticeRow] = []
        let line = (item.context.scoreLine ?? item.subtitle(languageCode: languageCode))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty, line.caseInsensitiveCompare(title) != .orderedSame {
            supporting.append(
                FanGeoTeamEventNoticeRow(
                    kind: .game,
                    labelKey: "team_score_line",
                    value: line,
                    systemImage: "sportscourt.fill"
                )
            )
        }
        return FanGeoTeamEventNotice(
            title: title,
            identityRows: identity,
            changeRows: [],
            supportingRows: supporting,
            omitsGameRow: true
        )
    }

    /// Card title: New Practice / Practice Updated / Practice Cancelled.
    /// Team name is a supporting row, not the title.
    static func headline(for item: FanGeoActionItem, languageCode: String) -> String? {
        let variant = FanGeoActionCenterTeamNotificationPresentation.variant(for: item) ?? .updated
        let format = GameType.parse(item.context.eventTypeLabel)
            ?? GameType.parse(inferredEventDetail(for: item))
        let noun = eventNoun(
            format: format,
            fallbackTitle: cleanedEventTitle(for: item) ?? inferredEventDetail(for: item),
            languageCode: languageCode
        )
        return FanGeoActionCenterTeamNotificationPresentation.eventTypeTitle(
            noun: noun,
            variant: variant,
            languageCode: languageCode
        )
    }

    /// Game/event identity for Going / schedule surfaces. Never a UUID.
    /// Inbox secondary rows should use ``secondaryGameIdentity`` instead.
    static func gameLabel(
        teamName: String?,
        customTitle: String?,
        gameFormat: String?,
        opponent: String?,
        matchupLabel: String?,
        languageCode: String
    ) -> String {
        let team = nonEmpty(teamName)
        let format = GameType.parse(gameFormat)
        if let custom = meaningfulCustomTitle(
            customTitle,
            teamName: team,
            format: format,
            languageCode: languageCode
        ) {
            return custom
        }
        if let matchup = nonEmpty(matchupLabel) {
            return matchup
        }
        if let built = FanTeamScheduleMatchup.matchupLine(
            homeTeamName: team ?? "",
            opponentName: opponent,
            languageCode: languageCode
        ) {
            return built
        }
        let noun = eventNoun(format: format, fallbackTitle: customTitle, languageCode: languageCode)
        if let team, !team.isEmpty {
            return String(
                format: L10n.t("action_center_team_event_identity_format", languageCode: languageCode),
                locale: Locale(identifier: L10n.normalizedLanguageCode(languageCode)),
                team,
                noun
            )
        }
        return noun
    }

    /// Inbox Game row: only custom titles and matchups. Generated
    /// `Team · Practice` / plain `Practice` fallbacks are omitted because the
    /// card title already carries Team + event type.
    static func secondaryGameIdentity(
        teamName: String?,
        customTitle: String?,
        gameFormat: String?,
        opponent: String?,
        matchupLabel: String?,
        languageCode: String
    ) -> String? {
        let format = GameType.parse(gameFormat)
        if let custom = meaningfulCustomTitle(
            customTitle,
            teamName: teamName,
            format: format,
            languageCode: languageCode
        ) {
            return custom
        }
        if let matchup = nonEmpty(matchupLabel) {
            return matchup
        }
        if let built = FanTeamScheduleMatchup.matchupLine(
            homeTeamName: nonEmpty(teamName) ?? "",
            opponentName: opponent,
            languageCode: languageCode
        ) {
            return built
        }
        return nil
    }

    static func eventNoun(
        format: GameType?,
        fallbackTitle: String?,
        languageCode: String
    ) -> String {
        if let format {
            return format.scheduleFormSummaryLabel(languageCode: languageCode)
        }
        if let inferred = GameType.parse(fallbackTitle) {
            return inferred.scheduleFormSummaryLabel(languageCode: languageCode)
        }
        return L10n.t("action_center_team_notif_event_noun", languageCode: languageCode)
    }

    static func meaningfulCustomTitle(
        _ raw: String?,
        teamName: String? = nil,
        format: GameType?,
        languageCode: String
    ) -> String? {
        guard let title = nonEmpty(raw) else { return nil }
        if looksLikeUUID(title) { return nil }
        if isRedundantGeneratedIdentity(
            title,
            teamName: teamName,
            format: format,
            languageCode: languageCode
        ) {
            return nil
        }
        return title
    }

    static func isRedundantGeneratedIdentity(
        _ raw: String,
        teamName: String?,
        format: GameType?,
        languageCode: String
    ) -> Bool {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return true }
        let noun = eventNoun(format: format, fallbackTitle: title, languageCode: languageCode)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if title.compare(noun, options: options) == .orderedSame {
            return true
        }
        if let format {
            let rawToken = format.rawValue.replacingOccurrences(of: "_", with: " ")
            if title.compare(rawToken, options: options) == .orderedSame {
                return true
            }
        }
        if let team = nonEmpty(teamName) {
            let generated = String(
                format: L10n.t("action_center_team_event_identity_format", languageCode: languageCode),
                locale: Locale(identifier: L10n.normalizedLanguageCode(languageCode)),
                team,
                noun
            )
            if title.compare(generated, options: options) == .orderedSame {
                return true
            }
            if title.compare(team, options: options) == .orderedSame {
                return true
            }
        }
        for candidate in composedNotificationTitles(
            teamName: teamName,
            noun: noun,
            languageCode: languageCode
        ) where title.compare(candidate, options: options) == .orderedSame {
            return true
        }
        let stripped = stripNotificationVerb(title)
        if stripped.compare(title, options: options) != .orderedSame {
            return isRedundantGeneratedIdentity(
                stripped,
                teamName: teamName,
                format: format,
                languageCode: languageCode
            )
        }
        if let parsed = parseTeamIdentityLine(title) {
            let parsedNoun = eventNoun(format: format, fallbackTitle: parsed.detail, languageCode: languageCode)
            if parsed.detail.compare(parsedNoun, options: options) == .orderedSame {
                return true
            }
            if parsed.detail.compare(noun, options: options) == .orderedSame {
                return true
            }
        }
        return false
    }

    static func inferredTeamName(for item: FanGeoActionItem) -> String? {
        if let name = nonEmpty(item.context.teamName) { return name }
        for raw in identitySourceStrings(for: item) {
            if let parsed = parseTeamIdentityLine(raw) {
                return parsed.teamName
            }
        }
        return nil
    }

    static func parseTeamIdentityLine(_ raw: String) -> (teamName: String, detail: String)? {
        let stripped = stripNotificationVerb(raw)
        let separator = stripped.range(of: " · ") ?? stripped.range(of: "·")
        guard let sep = separator else { return nil }
        let team = stripped[..<sep.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = stripped[sep.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !team.isEmpty, !detail.isEmpty else { return nil }
        return (team, detail)
    }

    private static func inferredEventDetail(for item: FanGeoActionItem) -> String? {
        if let label = nonEmpty(item.context.eventTypeLabel) { return label }
        for raw in identitySourceStrings(for: item) {
            if let parsed = parseTeamIdentityLine(raw) {
                return parsed.detail
            }
        }
        return nil
    }

    private static func cleanedEventTitle(for item: FanGeoActionItem) -> String? {
        if let parsed = parseTeamIdentityLine(item.context.eventTitle ?? "") {
            return parsed.detail
        }
        if let raw = nonEmpty(item.context.eventTitle) {
            let stripped = stripNotificationVerb(raw)
            return stripped.isEmpty ? nil : stripped
        }
        for raw in item.titleFormatArgs {
            if let parsed = parseTeamIdentityLine(raw) {
                return parsed.detail
            }
        }
        return nil
    }

    private static func identitySourceStrings(for item: FanGeoActionItem) -> [String] {
        var values: [String] = []
        values.append(contentsOf: item.titleFormatArgs)
        if let eventTitle = nonEmpty(item.context.eventTitle) {
            values.append(eventTitle)
        }
        return values
    }

    static func stripNotificationVerb(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixes = [
            " time changed",
            " location changed",
            " updated the time",
            " updated time & location",
            " updated an event",
            " changed",
            " updated",
            " cancelled",
            " canceled",
        ]
        let lowered = text.lowercased()
        for suffix in suffixes where lowered.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return text
    }

    /// Notification headlines such as `IMC Team · Practice changed` are not
    /// custom event names.
    private static func composedNotificationTitles(
        teamName: String?,
        noun: String,
        languageCode: String
    ) -> [String] {
        let locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        let phraseKeys = [
            "action_center_team_notif_created_format",
            "action_center_team_notif_changed_format",
            "action_center_team_notif_time_changed_format",
            "action_center_team_notif_updated_format",
            "action_center_team_notif_cancelled_format",
            "action_center_team_notif_moved_format",
            "action_center_team_notif_rescheduled_format"
        ]
        var titles: [String] = []
        for key in phraseKeys {
            let phrase = String(
                format: L10n.t(key, languageCode: languageCode),
                locale: locale,
                noun
            )
            titles.append(phrase)
            if let team = nonEmpty(teamName) {
                titles.append(
                    String(
                        format: L10n.t(
                            "action_center_team_event_identity_format",
                            languageCode: languageCode
                        ),
                        locale: locale,
                        team,
                        phrase
                    )
                )
            }
        }
        return titles
    }

    // MARK: - Rows

    private static func identitySupportingRows(
        for item: FanGeoActionItem,
        includeTeam: Bool,
        includeCustomTitle: Bool,
        languageCode: String
    ) -> [FanGeoTeamEventNoticeRow] {
        var rows: [FanGeoTeamEventNoticeRow] = []
        if let player = FanGeoTeamEventAffectedPlayerResolver.fromContext(item.context) {
            let name = player.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                rows.append(
                    FanGeoTeamEventNoticeRow(
                        kind: .player,
                        labelKey: "action_center_label_player",
                        value: name,
                        systemImage: "person.crop.circle.fill"
                    )
                )
            }
        }
        if includeCustomTitle,
           let custom = meaningfulCustomTitle(
                item.context.eventTitle,
                teamName: item.context.teamName,
                format: GameType.parse(item.context.eventTypeLabel),
                languageCode: languageCode
           ) {
            rows.append(
                FanGeoTeamEventNoticeRow(
                    kind: .title,
                    labelKey: "action_center_label_title",
                    value: custom,
                    systemImage: "textformat"
                )
            )
        }
        if includeTeam,
           let team = nonEmpty(item.context.teamName) ?? inferredTeamName(for: item) {
            rows.append(
                FanGeoTeamEventNoticeRow(
                    kind: .team,
                    labelKey: "action_center_label_team",
                    value: team,
                    systemImage: "person.3.fill"
                )
            )
        }
        return rows
    }

    private static func classifyChanges(
        for item: FanGeoActionItem,
        languageCode: String
    ) -> [FanGeoTeamEventNoticeRow] {
        var rows: [FanGeoTeamEventNoticeRow] = []
        let details = item.context.changeDetails
        if let date = details.first(where: { $0.labelKey == "action_center_change_date" }) {
            rows.append(
                formattedTemporalRow(
                    kind: .date,
                    labelKey: "action_center_label_date",
                    systemImage: "calendar",
                    detail: date,
                    languageCode: languageCode
                )
            )
        } else if let time = details.first(where: { $0.labelKey == "action_center_change_time" }) {
            // Legacy payloads sometimes stored a full start ISO under "time".
            // If the calendar day moved, surface Date as well.
            let oldDate = parseInstant(time.oldValue)
            let newDate = parseInstant(time.newValue)
            if let oldDate, let newDate, !Calendar.current.isDate(oldDate, inSameDayAs: newDate) {
                rows.append(
                    formattedTemporalRow(
                        kind: .date,
                        labelKey: "action_center_label_date",
                        systemImage: "calendar",
                        detail: time,
                        languageCode: languageCode
                    )
                )
            }
        }
        let startTime = details.first(where: { $0.labelKey == "action_center_change_time" })
        let endTime = details.first(where: { $0.labelKey == "action_center_change_end_time" })
        if startTime != nil || endTime != nil {
            rows.append(
                formattedTimeChangeRow(
                    startDetail: startTime,
                    endDetail: endTime,
                    fallbackStart: item.context.eventStartAt,
                    languageCode: languageCode
                )
            )
        }
        if let location = details.first(where: { $0.labelKey == "action_center_change_location" }) {
            let oldValue = collapsedLocation(location.oldValue)
            let newValue = collapsedLocation(location.newValue)
                ?? collapsedLocation(item.context.locationLabel)
            rows.append(
                FanGeoTeamEventNoticeRow(
                    kind: .location,
                    labelKey: "action_center_label_location",
                    value: newValue ?? oldValue ?? "",
                    oldValue: oldValue,
                    newValue: newValue,
                    systemImage: "mappin.and.ellipse"
                )
            )
        }
        if let opponent = details.first(where: { $0.labelKey == "action_center_change_opponent" }) {
            rows.append(
                FanGeoTeamEventNoticeRow(
                    kind: .opponent,
                    labelKey: "action_center_label_opponent",
                    value: nonEmpty(opponent.newValue) ?? nonEmpty(opponent.oldValue) ?? "",
                    oldValue: nonEmpty(opponent.oldValue),
                    newValue: nonEmpty(opponent.newValue),
                    systemImage: "shield.fill"
                )
            )
        }
        if let titleChange = details.first(where: { $0.labelKey == "action_center_change_title" }) {
            rows.append(
                FanGeoTeamEventNoticeRow(
                    kind: .title,
                    labelKey: "action_center_label_title",
                    value: nonEmpty(titleChange.newValue) ?? nonEmpty(titleChange.oldValue) ?? "",
                    oldValue: nonEmpty(titleChange.oldValue),
                    newValue: nonEmpty(titleChange.newValue),
                    systemImage: "pencil"
                )
            )
        }
        if let eventType = details.first(where: { $0.labelKey == "action_center_change_event_type" }) {
            let oldLabel = eventTypeLabel(raw: eventType.oldValue, languageCode: languageCode)
            let newLabel = eventTypeLabel(raw: eventType.newValue, languageCode: languageCode)
            rows.append(
                FanGeoTeamEventNoticeRow(
                    kind: .eventType,
                    labelKey: "action_center_label_event_type",
                    value: newLabel ?? oldLabel ?? "",
                    oldValue: oldLabel,
                    newValue: newLabel,
                    systemImage: "flag.fill"
                )
            )
        }
        if let status = details.first(where: { $0.labelKey == "action_center_change_status" }) {
            rows.append(
                FanGeoTeamEventNoticeRow(
                    kind: .status,
                    labelKey: "action_center_label_status",
                    value: statusLabel(
                        raw: nonEmpty(status.newValue) ?? nonEmpty(status.oldValue),
                        languageCode: languageCode
                    ),
                    oldValue: statusLabel(raw: status.oldValue, languageCode: languageCode),
                    newValue: statusLabel(raw: status.newValue, languageCode: languageCode),
                    systemImage: "xmark.circle.fill"
                )
            )
        }
        if let visibility = details.first(where: { $0.labelKey == "action_center_change_visibility" }) {
            rows.append(
                FanGeoTeamEventNoticeRow(
                    kind: .visibility,
                    labelKey: "action_center_label_visibility",
                    value: visibilityLabel(raw: visibility.newValue ?? visibility.oldValue, languageCode: languageCode),
                    oldValue: visibility.oldValue.map { visibilityLabel(raw: $0, languageCode: languageCode) },
                    newValue: visibility.newValue.map { visibilityLabel(raw: $0, languageCode: languageCode) },
                    systemImage: "eye.fill"
                )
            )
        }
        return rows.filter { !$0.displayValue(languageCode: languageCode).isEmpty }
    }

    private static func kindOnlyChangeRows(
        for item: FanGeoActionItem,
        variant: FanGeoActionCenterTeamNotificationPresentation.Variant,
        languageCode: String
    ) -> [FanGeoTeamEventNoticeRow] {
        switch variant {
        case .timeChanged, .dateChanged:
            guard let start = item.context.eventStartAt else { return [] }
            if variant == .dateChanged {
                return [
                    FanGeoTeamEventNoticeRow(
                        kind: .date,
                        labelKey: "action_center_change_date",
                        value: formatDate(start, languageCode: languageCode),
                        newValue: formatDate(start, languageCode: languageCode),
                        systemImage: "calendar"
                    )
                ]
            }
            return [
                FanGeoTeamEventNoticeRow(
                    kind: .time,
                    labelKey: "action_center_change_time",
                    value: formatTime(start, languageCode: languageCode),
                    newValue: formatTime(start, languageCode: languageCode),
                    systemImage: "clock"
                )
            ]
        case .locationChanged:
            guard let location = collapsedLocation(item.context.locationLabel) else { return [] }
            return [
                FanGeoTeamEventNoticeRow(
                    kind: .location,
                    labelKey: "action_center_change_location",
                    value: location,
                    newValue: location,
                    systemImage: "mappin.and.ellipse"
                )
            ]
        default:
            return []
        }
    }

    private static func supportingContext(
        for item: FanGeoActionItem,
        languageCode: String,
        excluding: Set<FanGeoTeamEventNoticeRow.Kind>
    ) -> [FanGeoTeamEventNoticeRow] {
        var rows: [FanGeoTeamEventNoticeRow] = []
        if let start = item.context.eventStartAt {
            if !excluding.contains(.date) {
                rows.append(
                    FanGeoTeamEventNoticeRow(
                        kind: .date,
                        labelKey: "action_center_label_date",
                        value: formatDate(start, languageCode: languageCode),
                        systemImage: "calendar"
                    )
                )
            }
            if !excluding.contains(.time) {
                rows.append(
                    FanGeoTeamEventNoticeRow(
                        kind: .time,
                        labelKey: "action_center_label_time",
                        value: formatTime(start, languageCode: languageCode),
                        systemImage: "clock"
                    )
                )
            }
        }
        if !excluding.contains(.location),
           let location = collapsedLocation(item.context.locationLabel) {
            rows.append(
                FanGeoTeamEventNoticeRow(
                    kind: .location,
                    labelKey: "action_center_label_location",
                    value: location,
                    systemImage: "mappin.and.ellipse"
                )
            )
        }
        return rows
    }

    private static func formattedTemporalRow(
        kind: FanGeoTeamEventNoticeRow.Kind,
        labelKey: String,
        systemImage: String,
        detail: FanGeoActionChangeDetail,
        languageCode: String
    ) -> FanGeoTeamEventNoticeRow {
        let oldDate = parseInstant(detail.oldValue)
        let newDate = parseInstant(detail.newValue)
        let oldText: String?
        let newText: String?
        if kind == .date {
            oldText = oldDate.map { formatDate($0, languageCode: languageCode) }
                ?? nonEmpty(detail.oldValue)
            newText = newDate.map { formatDate($0, languageCode: languageCode) }
                ?? nonEmpty(detail.newValue)
        } else {
            oldText = oldDate.map { formatTime($0, languageCode: languageCode) }
                ?? nonEmpty(detail.oldValue)
            newText = newDate.map { formatTime($0, languageCode: languageCode) }
                ?? nonEmpty(detail.newValue)
        }
        return FanGeoTeamEventNoticeRow(
            kind: kind,
            labelKey: labelKey,
            value: newText ?? oldText ?? "",
            oldValue: oldText,
            newValue: newText,
            systemImage: systemImage
        )
    }

    private static func formattedTimeChangeRow(
        startDetail: FanGeoActionChangeDetail?,
        endDetail: FanGeoActionChangeDetail?,
        fallbackStart: Date?,
        languageCode: String
    ) -> FanGeoTeamEventNoticeRow {
        let parsedOldStart = parseInstant(startDetail?.oldValue)
        let parsedNewStart = parseInstant(startDetail?.newValue)
        let oldStart = parsedOldStart ?? (endDetail != nil ? fallbackStart : nil)
        let newStart = parsedNewStart ?? (endDetail != nil ? fallbackStart : nil)
        let oldEnd = parseInstant(endDetail?.oldValue)
        let newEnd = parseInstant(endDetail?.newValue)
        let oldText: String?
        let newText: String?
        if endDetail != nil {
            oldText = formatTimeRange(start: oldStart, end: oldEnd, languageCode: languageCode)
                ?? nonEmpty(startDetail?.oldValue)
                ?? nonEmpty(endDetail?.oldValue)
            newText = formatTimeRange(start: newStart, end: newEnd, languageCode: languageCode)
                ?? nonEmpty(startDetail?.newValue)
                ?? nonEmpty(endDetail?.newValue)
        } else {
            oldText = oldStart.map { formatTime($0, languageCode: languageCode) }
                ?? nonEmpty(startDetail?.oldValue)
            newText = newStart.map { formatTime($0, languageCode: languageCode) }
                ?? nonEmpty(startDetail?.newValue)
        }
        return FanGeoTeamEventNoticeRow(
            kind: .time,
            labelKey: "action_center_label_time",
            value: newText ?? oldText ?? "",
            oldValue: oldText,
            newValue: newText,
            systemImage: "clock"
        )
    }

    private static func formatTimeRange(start: Date?, end: Date?, languageCode: String) -> String? {
        guard let start else {
            return end.map { formatTime($0, languageCode: languageCode) }
        }
        let startText = formatTime(start, languageCode: languageCode)
        guard let end else { return startText }
        let endText = formatTime(end, languageCode: languageCode)
        if startText == endText { return startText }
        return String(
            format: L10n.t("action_center_time_range_format", languageCode: languageCode),
            locale: Locale(identifier: L10n.normalizedLanguageCode(languageCode)),
            startText,
            endText
        )
    }

    private static func eventTypeLabel(raw: String?, languageCode: String) -> String? {
        guard let raw = nonEmpty(raw) else { return nil }
        if let format = GameType.parse(raw) {
            return format.scheduleFormSummaryLabel(languageCode: languageCode)
        }
        return raw
    }

    private static func visibilityLabel(raw: String?, languageCode: String) -> String {
        let token = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch token {
        case "true", "public", "visible", "1":
            return L10n.t("action_center_visibility_public", languageCode: languageCode)
        case "false", "private", "hidden", "0":
            return L10n.t("action_center_visibility_private", languageCode: languageCode)
        default:
            return raw?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? L10n.t("action_center_label_visibility", languageCode: languageCode)
        }
    }

    private static func resolvedOpponent(from item: FanGeoActionItem) -> String? {
        if let named = nonEmpty(item.context.opponentName) { return named }
        if let detail = item.context.changeDetails.first(
            where: { $0.labelKey == "action_center_change_opponent" }
        ) {
            return nonEmpty(detail.newValue) ?? nonEmpty(detail.oldValue)
        }
        return nil
    }

    private static func announcementQuote(for item: FanGeoActionItem) -> String? {
        if let body = nonEmpty(item.subtitleFormatArgs.first) { return body }
        return nonEmpty(item.context.eventTitle)
    }

    private static func statusLabel(raw: String?, languageCode: String) -> String {
        let token = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if token.isEmpty { return "" }
        if token == "removed" || token == "cancelled" || token == "canceled" {
            return L10n.t("action_center_status_cancelled", languageCode: languageCode)
        }
        if token == "scheduled" || token == "active" || token == "open" {
            return L10n.t("action_center_status_scheduled", languageCode: languageCode)
        }
        return raw ?? ""
    }

    static func spokenFieldLabel(_ key: String, languageCode: String) -> String {
        L10n.t(key, languageCode: languageCode)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":").union(.whitespaces))
    }

    private static func formatDate(_ date: Date, languageCode: String) -> String {
        let locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
    }

    private static func formatTime(_ date: Date, languageCode: String) -> String {
        let locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }

    static func parseInstant(_ raw: String?) -> Date? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return PickupGameModels.parseSupabaseTimestamptz(raw)
    }

    private static func collapsedLocation(_ raw: String?) -> String? {
        let collapsed = FanTeamScheduleLocationPresentation.collapsedLine(raw)
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func looksLikeUUID(_ raw: String) -> Bool {
        UUID(uuidString: raw) != nil
    }
}

/// Resolved affected player for a Team event Inbox card. Never invents a child.
struct FanGeoTeamEventAffectedPlayer: Equatable, Sendable {
    var displayName: String
    var avatarURL: String?
    var avatarThumbnailURL: String?
    var managedPlayerId: UUID?
    var isManagedPlayer: Bool
}

enum FanGeoTeamEventAffectedPlayerResolver {
    /// Payload-only resolution. Priority: managed_player_id → participant/player seat → nil.
    /// Account owner is applied later by the Action Center snapshot (no guessing).
    static func fromPayload(_ payload: [String: AnyCodableJSON]?) -> FanGeoTeamEventAffectedPlayer? {
        let managedId = uuid(payload, "managed_player_id")
            ?? uuid(payload, "target_managed_player_id")
        let seatId = uuid(payload, "membership_id")
            ?? uuid(payload, "target_membership_id")
            ?? uuid(payload, "participant_id")
            ?? uuid(payload, "player_id")
        let flaggedManaged = bool(payload, "is_managed_player") == true
        let name = firstString(payload, [
            "scorer_display_name",
            "scorer_display_name_snapshot",
            "managed_player_name",
            "player_display_name",
            "player_name",
            "participant_name"
        ])
        let avatar = firstString(payload, [
            "scorer_avatar_url_snapshot",
            "scorer_avatar_url",
            "managed_player_avatar_url",
            "player_avatar_url",
            "avatar_url"
        ])
        let thumb = firstString(payload, [
            "managed_player_avatar_thumbnail_url",
            "player_avatar_thumbnail_url",
            "avatar_thumbnail_url"
        ])

        if let managedId {
            return FanGeoTeamEventAffectedPlayer(
                displayName: name ?? "",
                avatarURL: avatar,
                avatarThumbnailURL: thumb,
                managedPlayerId: managedId,
                isManagedPlayer: true
            )
        }
        if flaggedManaged, name != nil || avatar != nil {
            return FanGeoTeamEventAffectedPlayer(
                displayName: name ?? "",
                avatarURL: avatar,
                avatarThumbnailURL: thumb,
                managedPlayerId: nil,
                isManagedPlayer: true
            )
        }
        if seatId != nil, name != nil || avatar != nil || flaggedManaged {
            return FanGeoTeamEventAffectedPlayer(
                displayName: name ?? "",
                avatarURL: avatar,
                avatarThumbnailURL: thumb,
                managedPlayerId: flaggedManaged ? seatId : nil,
                isManagedPlayer: flaggedManaged
            )
        }
        if firstString(payload, ["scorer_display_name", "scorer_display_name_snapshot"]) != nil {
            return FanGeoTeamEventAffectedPlayer(
                displayName: name ?? "",
                avatarURL: avatar,
                avatarThumbnailURL: thumb,
                managedPlayerId: uuid(payload, "scorer_managed_player_id"),
                isManagedPlayer: flaggedManaged || uuid(payload, "scorer_managed_player_id") != nil
            )
        }
        return nil
    }

    static func fromContext(_ context: FanGeoActionContext) -> FanGeoTeamEventAffectedPlayer? {
        let name = context.personName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let avatar = context.personAvatarURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let thumb = context.personAvatarThumbnailURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        if context.managedPlayerId != nil || context.isManagedPlayer || !name.isEmpty {
            return FanGeoTeamEventAffectedPlayer(
                displayName: name,
                avatarURL: (avatar?.isEmpty == false) ? avatar : nil,
                avatarThumbnailURL: (thumb?.isEmpty == false) ? thumb : nil,
                managedPlayerId: context.managedPlayerId,
                isManagedPlayer: context.isManagedPlayer || context.managedPlayerId != nil
            )
        }
        return nil
    }

    static func applyingAccountOwner(
        to item: FanGeoActionItem,
        displayName: String?,
        avatarURL: String?,
        avatarThumbnailURL: String?
    ) -> FanGeoActionItem {
        guard FanGeoTeamEventNoticeBuilder.isScheduleEventNotice(for: item) else { return item }
        if FanGeoTeamEventAffectedPlayerResolver.fromContext(item.context) != nil {
            return item
        }
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return item }
        var context = item.context
        context.personName = name
        context.personAvatarURL = avatarURL?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        context.personAvatarThumbnailURL = avatarThumbnailURL?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        context.isManagedPlayer = false
        context.managedPlayerId = nil
        return item.withContext(context)
    }

    private static func firstString(_ payload: [String: AnyCodableJSON]?, _ keys: [String]) -> String? {
        for key in keys {
            if let value = string(payload, key) { return value }
        }
        return nil
    }

    private static func string(_ payload: [String: AnyCodableJSON]?, _ key: String) -> String? {
        guard let raw = payload?[key]?.stringValue else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func bool(_ payload: [String: AnyCodableJSON]?, _ key: String) -> Bool? {
        payload?[key]?.boolValue
    }

    private static func uuid(_ payload: [String: AnyCodableJSON]?, _ key: String) -> UUID? {
        guard let raw = string(payload, key) else { return nil }
        return UUID(uuidString: raw)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Canonical Team-event field diffs from durable Inbox payload keys.
/// Does not reconstruct old values from live Team/event state.
enum FanGeoTeamEventChangeProjection {
    static func details(
        beforeStartRaw: String?,
        afterStartRaw: String?,
        beforeEndRaw: String?,
        afterEndRaw: String?,
        beforeLocation: String?,
        afterLocation: String?,
        beforeOpponent: String?,
        afterOpponent: String?,
        beforeStatus: String?,
        afterStatus: String?,
        beforeTitle: String?,
        afterTitle: String?,
        beforeEventType: String?,
        afterEventType: String?,
        beforeVisibility: String?,
        afterVisibility: String?,
        changeKinds: [String]
    ) -> [FanGeoActionChangeDetail] {
        var details: [FanGeoActionChangeDetail] = []
        let kinds = Set(changeKinds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })

        if let beforeStartRaw, let afterStartRaw, beforeStartRaw != afterStartRaw {
            let beforeDate = FanGeoTeamEventNoticeBuilder.parseInstant(beforeStartRaw)
            let afterDate = FanGeoTeamEventNoticeBuilder.parseInstant(afterStartRaw)
            let calendar = Calendar.current
            let sameDay: Bool = {
                guard let beforeDate, let afterDate else { return false }
                return calendar.isDate(beforeDate, inSameDayAs: afterDate)
            }()
            let sameClock: Bool = {
                guard let beforeDate, let afterDate else { return false }
                let oldParts = calendar.dateComponents([.hour, .minute], from: beforeDate)
                let newParts = calendar.dateComponents([.hour, .minute], from: afterDate)
                return oldParts.hour == newParts.hour && oldParts.minute == newParts.minute
            }()
            if !sameDay {
                details.append(
                    FanGeoActionChangeDetail(
                        labelKey: "action_center_change_date",
                        oldValue: beforeStartRaw,
                        newValue: afterStartRaw
                    )
                )
            }
            if !sameClock {
                details.append(
                    FanGeoActionChangeDetail(
                        labelKey: "action_center_change_time",
                        oldValue: beforeStartRaw,
                        newValue: afterStartRaw
                    )
                )
            }
        } else if (kinds.contains("start") || kinds.contains("time") || kinds.contains("date")),
                  let afterStartRaw {
            details.append(
                FanGeoActionChangeDetail(
                    labelKey: kinds.contains("date") && !kinds.contains("start") && !kinds.contains("time")
                        ? "action_center_change_date"
                        : "action_center_change_time",
                    oldValue: beforeStartRaw,
                    newValue: afterStartRaw
                )
            )
        }

        if let beforeEndRaw, let afterEndRaw, beforeEndRaw != afterEndRaw {
            details.append(
                FanGeoActionChangeDetail(
                    labelKey: "action_center_change_end_time",
                    oldValue: beforeEndRaw,
                    newValue: afterEndRaw
                )
            )
        }

        if let beforeLocation, let afterLocation, beforeLocation != afterLocation {
            details.append(
                FanGeoActionChangeDetail(
                    labelKey: "action_center_change_location",
                    oldValue: beforeLocation,
                    newValue: afterLocation
                )
            )
        } else if kinds.contains("location"), afterLocation != nil, beforeLocation == nil {
            details.append(
                FanGeoActionChangeDetail(
                    labelKey: "action_center_change_location",
                    oldValue: nil,
                    newValue: afterLocation
                )
            )
        }

        if kinds.contains("opponent")
            || ((beforeOpponent ?? "") != (afterOpponent ?? "")
                && (beforeOpponent != nil || afterOpponent != nil)) {
            if beforeOpponent != afterOpponent {
                details.append(
                    FanGeoActionChangeDetail(
                        labelKey: "action_center_change_opponent",
                        oldValue: beforeOpponent,
                        newValue: afterOpponent
                    )
                )
            }
        }

        if let beforeTitle, let afterTitle, beforeTitle != afterTitle {
            details.append(
                FanGeoActionChangeDetail(
                    labelKey: "action_center_change_title",
                    oldValue: beforeTitle,
                    newValue: afterTitle
                )
            )
        }

        if let beforeEventType, let afterEventType, beforeEventType != afterEventType {
            details.append(
                FanGeoActionChangeDetail(
                    labelKey: "action_center_change_event_type",
                    oldValue: beforeEventType,
                    newValue: afterEventType
                )
            )
        }

        let cancelled = (afterStatus?.lowercased() == "removed"
            || afterStatus?.lowercased() == "cancelled"
            || afterStatus?.lowercased() == "canceled")
            && (beforeStatus?.lowercased() != afterStatus?.lowercased())
        if cancelled || (beforeStatus != nil && afterStatus != nil && beforeStatus != afterStatus) {
            details.append(
                FanGeoActionChangeDetail(
                    labelKey: "action_center_change_status",
                    oldValue: beforeStatus,
                    newValue: afterStatus
                )
            )
        }

        if let beforeVisibility, let afterVisibility, beforeVisibility != afterVisibility {
            details.append(
                FanGeoActionChangeDetail(
                    labelKey: "action_center_change_visibility",
                    oldValue: beforeVisibility,
                    newValue: afterVisibility
                )
            )
        }

        return details
    }
}

#if DEBUG
enum FanGeoTeamEventInboxTrace {
    static func logRenderedCard(_ item: FanGeoActionItem, languageCode: String) {
        guard item.kind == .scheduleChange || item.kind == .eventCancellation else { return }
        guard !DirectChatInvestigation.quietConsole else { return }
        let notice = FanGeoTeamEventNoticeBuilder.make(for: item, languageCode: languageCode)
        let chrome = FanGeoActionCenterTeamNotificationPresentation.usesTeamChrome(for: item)
        print(
            "[TeamEventInboxTrace] id=\(item.id) kind=\(item.kind.rawValue) " +
            "type=\(item.context.notificationType ?? "nil") " +
            "teamId=\(item.context.teamId?.uuidString ?? "nil") " +
            "teamName=\(item.context.teamName ?? "nil") " +
            "inferredTeam=\(FanGeoTeamEventNoticeBuilder.inferredTeamName(for: item) ?? "nil") " +
            "titleKey=\(item.titleKey) title=\(item.title(languageCode: languageCode)) " +
            "chrome=\(chrome) notice=\(notice != nil) " +
            "changeDetails=\(item.context.changeDetails.map(\.labelKey)) " +
            "changeRows=\(notice?.changeRows.map(\.kind.rawValue) ?? []) " +
            "supporting=\(notice?.supportingRows.map(\.kind.rawValue) ?? []) " +
            "summary=\(FanGeoActionCenterTeamNotificationPresentation.summaryLine(for: item, languageCode: languageCode) ?? "nil")"
        )
    }
}
#endif

