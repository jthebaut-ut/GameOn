import Foundation

/// Localized copy helpers for enriched Action Center cards.
enum FanGeoActionCenterCopy {
    static func contextLines(for item: FanGeoActionItem, languageCode: String) -> [String] {
        let locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        var lines: [String] = []
        let ctx = item.context

        switch item.kind {
        case .joinApproval:
            if let title = ctx.eventTitle?.nilIfEmpty {
                lines.append(title)
            }
            if let matchup = ctx.matchupLabel?.nilIfEmpty,
               matchup.caseInsensitiveCompare(ctx.eventTitle ?? "") != .orderedSame {
                lines.append(matchup)
            }
            if let type = ctx.eventTypeLabel?.nilIfEmpty,
               type.caseInsensitiveCompare(ctx.eventTitle ?? "") != .orderedSame {
                lines.append(type)
            }
            if let team = ctx.teamName?.nilIfEmpty {
                lines.append(team)
            }
            if let when = formattedEventWhen(ctx.eventStartAt, languageCode: languageCode) {
                lines.append(when)
            }
            if let location = ctx.locationLabel?.nilIfEmpty {
                lines.append(location)
            }
            if let capacity = ctx.capacityLabel?.nilIfEmpty {
                lines.append(capacity)
            }

        case .pendingPickupRating:
            if let type = ctx.eventTypeLabel?.nilIfEmpty {
                lines.append(type)
            } else if let title = ctx.eventTitle?.nilIfEmpty {
                lines.append(title)
            }
            if let when = formattedEventWhen(ctx.eventStartAt, languageCode: languageCode) {
                lines.append(when)
            }
            if let matchup = ctx.matchupLabel?.nilIfEmpty {
                lines.append(matchup)
            } else if ctx.eventTypeLabel != nil, let title = ctx.eventTitle?.nilIfEmpty {
                lines.append(title)
            }
            if let organizer = ctx.personName?.nilIfEmpty {
                lines.append(
                    String(
                        format: L10n.t("pickup_rating_prompt_subtitle_format", languageCode: languageCode),
                        locale: locale,
                        organizer
                    )
                )
            }

        case .scheduleChange, .eventCancellation:
            if FanGeoActionCenterTeamNotificationPresentation.usesTeamChrome(for: item) {
                if let notice = FanGeoTeamEventNoticeBuilder.make(for: item, languageCode: languageCode) {
                    lines.append(contentsOf: notice.allRows.map {
                        $0.spokenLine(languageCode: languageCode)
                    })
                } else if let summary = FanGeoActionCenterTeamNotificationPresentation.summaryLine(
                    for: item,
                    languageCode: languageCode
                ) {
                    lines.append(summary)
                }
                break
            }
            if let when = formattedEventWhen(ctx.eventStartAt, languageCode: languageCode) {
                lines.append(when)
            }
            for detail in ctx.changeDetails.prefix(3) {
                lines.append(formatChangeDetail(detail, languageCode: languageCode, locale: locale))
            }
            if ctx.moreChangesCount > 0 {
                lines.append(
                    String(
                        format: L10n.t("action_center_more_changes_format", languageCode: languageCode),
                        locale: locale,
                        Int64(ctx.moreChangesCount)
                    )
                )
            }
            if item.kind == .eventCancellation, let location = ctx.locationLabel?.nilIfEmpty {
                lines.append(location)
            } else if item.kind == .scheduleChange,
                      !ctx.changeDetails.contains(where: { $0.labelKey == "action_center_change_location" }),
                      let location = ctx.locationLabel?.nilIfEmpty {
                lines.append(location)
            }

        case .pickupInvitation:
            if let team = ctx.teamName, let type = ctx.eventTypeLabel {
                lines.append("\(team) · \(type)")
            } else if let type = ctx.eventTypeLabel {
                lines.append(type)
            }
            if let when = formattedEventWhen(ctx.eventStartAt, languageCode: languageCode) {
                lines.append(when)
            }
            if let location = ctx.locationLabel?.nilIfEmpty {
                lines.append(location)
            }
            if let inviter = ctx.personName?.nilIfEmpty {
                lines.append(
                    String(
                        format: L10n.t("action_center_invited_by_format", languageCode: languageCode),
                        locale: locale,
                        inviter
                    )
                )
            }

        case .teamInvitation:
            var meta: [String] = []
            if let sport = ctx.sportLabel?.nilIfEmpty {
                meta.append(sport)
            }
            meta.append(L10n.t("action_center_private_team", languageCode: languageCode))
            if !meta.isEmpty {
                lines.append(meta.joined(separator: " · "))
            }
            if let inviter = ctx.personName?.nilIfEmpty {
                lines.append(
                    String(
                        format: L10n.t("action_center_invited_by_format", languageCode: languageCode),
                        locale: locale,
                        inviter
                    )
                )
            }

        case .friendRequest:
            if let username = ctx.personUsername?.nilIfEmpty {
                lines.append(username.hasPrefix("@") ? username : "@\(username)")
            } else {
                lines.append(item.subtitle(languageCode: languageCode))
            }

        case .poke:
            if let relative = ctx.relativeTimestamp {
                lines.append(relative.formatted(.relative(presentation: .named).locale(locale)))
            } else {
                lines.append(item.subtitle(languageCode: languageCode))
            }

        case .businessClaim:
            lines.append(item.subtitle(languageCode: languageCode))

        case .securitySession:
            lines.append(FanGeoSecuritySessionNotificationPresentation.body(languageCode: languageCode))
            if let device = FanGeoSecuritySessionNotificationPresentation.deviceLine(
                for: item,
                languageCode: languageCode
            ) {
                lines.append(device)
            }
            if let when = FanGeoSecuritySessionNotificationPresentation.timestampLine(
                for: item,
                languageCode: languageCode
            ) {
                lines.append(when)
            }
        }

        return lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func formatChangeDetail(
        _ detail: FanGeoActionChangeDetail,
        languageCode: String,
        locale: Locale
    ) -> String {
        let label = L10n.t(detail.labelKey, languageCode: languageCode)
        let oldValue = detail.oldValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let newValue = detail.newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !oldValue.isEmpty, !newValue.isEmpty {
            let arrow = String(
                format: L10n.t("action_center_value_arrow_format", languageCode: languageCode),
                locale: locale,
                oldValue,
                newValue
            )
            return "\(label): \(arrow)"
        }
        if !newValue.isEmpty {
            return "\(label): \(newValue)"
        }
        return label
    }

    static func formattedEventWhen(_ date: Date?, languageCode: String) -> String? {
        guard let date else { return nil }
        let locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        let datePart = date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
        let timePart = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
        return "\(datePart) \(L10n.t("action_center_at", languageCode: languageCode)) \(timePart)"
    }

    /// Compact relative / calendar label for card headers (e.g. "2m ago", "Today").
    static func relativeTimestampLabel(for item: FanGeoActionItem, languageCode: String, now: Date = Date()) -> String? {
        let locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        let date = item.timestamp
            ?? item.context.relativeTimestamp
            ?? item.context.eventStartAt
        guard let date else { return nil }
        let interval = now.timeIntervalSince(date)
        if interval >= 0, interval < 60 {
            return L10n.t("action_center_time_just_now", languageCode: languageCode)
        }
        if interval >= 0, interval < 3600 {
            let mins = max(1, Int(interval / 60))
            return String(
                format: L10n.t("action_center_time_minutes_ago_format", languageCode: languageCode),
                locale: locale,
                Int64(mins)
            )
        }
        if Calendar.current.isDateInToday(date) {
            return L10n.t("action_center_time_today", languageCode: languageCode)
        }
        if Calendar.current.isDateInYesterday(date) {
            return L10n.t("action_center_time_yesterday", languageCode: languageCode)
        }
        if interval >= 0, interval < 86_400 * 7 {
            return date.formatted(.relative(presentation: .named).locale(locale))
        }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
    }

    /// Icon + label rows for the rich context block (presentation only).
    static func metadataRows(for item: FanGeoActionItem, languageCode: String) -> [FanGeoActionCenterMetadataRow] {
        let ctx = item.context
        var rows: [FanGeoActionCenterMetadataRow] = []

        switch item.kind {
        case .joinApproval:
            // Event title is the card subtitle so it is immediately visible.
            if let matchup = ctx.matchupLabel?.nilIfEmpty,
               matchup.caseInsensitiveCompare(ctx.eventTitle ?? "") != .orderedSame {
                rows.append(.init(systemImage: "arrow.left.arrow.right", text: matchup))
            }
            if let type = ctx.eventTypeLabel?.nilIfEmpty,
               type.caseInsensitiveCompare(ctx.eventTitle ?? "") != .orderedSame {
                rows.append(.init(systemImage: "flag.fill", text: type))
            }
            if let team = ctx.teamName?.nilIfEmpty {
                rows.append(.init(systemImage: "person.3.fill", text: team))
            }
            if let when = formattedEventWhen(ctx.eventStartAt, languageCode: languageCode) {
                rows.append(.init(systemImage: "calendar", text: when))
            }
            if let location = ctx.locationLabel?.nilIfEmpty {
                rows.append(.init(systemImage: "mappin.and.ellipse", text: location))
            }
            if let capacity = ctx.capacityLabel?.nilIfEmpty {
                rows.append(.init(systemImage: "person.3.fill", text: capacity))
            }

        case .pickupInvitation:
            if let team = ctx.teamName?.nilIfEmpty, let type = ctx.eventTypeLabel?.nilIfEmpty {
                rows.append(.init(systemImage: "person.3.fill", text: "\(team) · \(type)"))
            } else if let team = ctx.teamName?.nilIfEmpty {
                rows.append(.init(systemImage: "person.3.fill", text: team))
            } else if let title = ctx.eventTitle?.nilIfEmpty {
                rows.append(.init(systemImage: "sportscourt.fill", text: title))
            }
            if let type = ctx.eventTypeLabel?.nilIfEmpty, ctx.teamName == nil {
                rows.append(.init(systemImage: "flag.fill", text: type))
            }
            if let when = formattedEventWhen(ctx.eventStartAt, languageCode: languageCode) {
                rows.append(.init(systemImage: "calendar", text: when))
            }
            if let location = ctx.locationLabel?.nilIfEmpty {
                rows.append(.init(systemImage: "mappin.and.ellipse", text: location))
            }

        case .pendingPickupRating:
            if let type = ctx.eventTypeLabel?.nilIfEmpty {
                rows.append(.init(systemImage: "flag.fill", text: type))
            }
            if let title = ctx.eventTitle?.nilIfEmpty {
                rows.append(.init(systemImage: "sportscourt.fill", text: title))
            }
            if let when = formattedEventWhen(ctx.eventStartAt, languageCode: languageCode) {
                rows.append(.init(systemImage: "calendar", text: when))
            }
            if let matchup = ctx.matchupLabel?.nilIfEmpty {
                rows.append(.init(systemImage: "arrow.left.arrow.right", text: matchup))
            }
            if let organizer = ctx.personName?.nilIfEmpty {
                rows.append(.init(systemImage: "person.fill", text: organizer))
            }

        case .scheduleChange, .eventCancellation:
            if FanGeoActionCenterTeamNotificationPresentation.usesTeamChrome(for: item) {
                break
            }
            if let title = ctx.eventTitle?.nilIfEmpty {
                let rendered = item.title(languageCode: languageCode)
                if !rendered.localizedCaseInsensitiveContains(title),
                   FanGeoTeamEventNoticeBuilder.meaningfulCustomTitle(
                    title,
                    teamName: ctx.teamName,
                    format: GameType.parse(ctx.eventTypeLabel),
                    languageCode: languageCode
                   ) != nil {
                    rows.append(.init(systemImage: "sportscourt.fill", text: title))
                }
            }
            if let type = ctx.eventTypeLabel?.nilIfEmpty {
                let rendered = item.title(languageCode: languageCode)
                let noun = FanGeoActionCenterTeamNotificationPresentation.eventNoun(
                    for: item,
                    languageCode: languageCode
                )
                if !rendered.localizedCaseInsensitiveContains(noun),
                   type.caseInsensitiveCompare(ctx.eventTitle ?? "") != .orderedSame {
                    rows.append(.init(systemImage: "flag.fill", text: type))
                }
            }
            if let when = formattedEventWhen(ctx.eventStartAt, languageCode: languageCode) {
                rows.append(.init(systemImage: "calendar", text: when))
            }
            if let location = ctx.locationLabel?.nilIfEmpty {
                let collapsed = FanTeamScheduleLocationPresentation.collapsedLine(location)
                rows.append(.init(systemImage: "mappin.and.ellipse", text: collapsed.isEmpty ? location : collapsed))
            }

        case .teamInvitation:
            if let team = ctx.teamName?.nilIfEmpty {
                rows.append(.init(systemImage: "person.3.fill", text: team))
            }
            if let sport = ctx.sportLabel?.nilIfEmpty {
                rows.append(.init(systemImage: "sportscourt.fill", text: sport))
            }
            rows.append(
                .init(
                    systemImage: "lock.fill",
                    text: L10n.t("action_center_private_team", languageCode: languageCode)
                )
            )
            if let inviter = ctx.personName?.nilIfEmpty {
                rows.append(.init(systemImage: "person.fill", text: inviter))
            }

        case .friendRequest:
            if let username = ctx.personUsername?.nilIfEmpty {
                let handle = username.hasPrefix("@") ? username : "@\(username)"
                rows.append(.init(systemImage: "at", text: handle))
            }

        case .poke:
            if let relative = ctx.relativeTimestamp {
                let locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
                rows.append(
                    .init(
                        systemImage: "clock",
                        text: relative.formatted(.relative(presentation: .named).locale(locale))
                    )
                )
            }

        case .businessClaim:
            rows.append(
                .init(
                    systemImage: "building.2.fill",
                    text: item.subtitle(languageCode: languageCode)
                )
            )

        case .securitySession:
            if let device = FanGeoSecuritySessionNotificationPresentation.deviceLine(
                for: item,
                languageCode: languageCode
            ) {
                rows.append(.init(systemImage: "iphone", text: device))
            }
            if let when = FanGeoSecuritySessionNotificationPresentation.timestampLine(
                for: item,
                languageCode: languageCode
            ) {
                rows.append(.init(systemImage: "clock", text: when))
            }
        }

        // Deduplicate identical text rows while preserving order.
        var seen = Set<String>()
        return rows.filter { row in
            let key = row.text.lowercased()
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    static func changeLabelKey(for kind: PickupGameMeaningfulChangeKind) -> String {
        switch kind {
        case .start: return "action_center_change_time"
        case .end: return "action_center_change_end_time"
        case .location: return "action_center_change_location"
        case .opponent: return "pickup_edit_change_opponent"
        case .status: return "action_center_change_cancelled"
        case .title: return "action_center_change_title"
        case .sport: return "action_center_change_event_type"
        case .capacity: return "action_center_change_capacity"
        case .welcome: return "pickup_edit_change_welcome"
        case .skill: return "pickup_edit_change_skill"
        case .environment: return "pickup_edit_change_environment"
        case .cost: return "pickup_edit_change_cost"
        case .visibility: return "pickup_edit_change_visibility"
        }
    }

    static func formattedStartRaw(_ raw: String?, languageCode: String) -> String {
        guard let raw, let date = PickupGameModels.parseSupabaseTimestamptz(raw) else {
            return raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct FanGeoActionCenterMetadataRow: Hashable, Sendable {
    var systemImage: String
    var text: String
}
