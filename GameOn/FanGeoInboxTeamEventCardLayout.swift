import Foundation

/// Presentation-only Team-event card rows. Builder data (date/time rows) stays unchanged.
struct FanGeoInboxTeamEventDisplayRow: Equatable, Sendable {
    var kind: FanGeoTeamEventNoticeRow.Kind
    var labelKey: String
    var value: String
    var systemImage: String
    var showsPlayerAvatar: Bool
    var showsDividerBefore: Bool
    var isIdentity: Bool
}

enum FanGeoInboxTeamEventCardLayout {
    private static let identityKinds: Set<FanGeoTeamEventNoticeRow.Kind> = [
        .player, .team, .game, .title
    ]

    static func rows(
        from notice: FanGeoTeamEventNotice,
        languageCode: String
    ) -> [FanGeoInboxTeamEventDisplayRow] {
        var result: [FanGeoInboxTeamEventDisplayRow] = []

        let identitySource = notice.identityRows + notice.supportingRows.filter {
            identityKinds.contains($0.kind)
        }
        for row in identitySource {
            result.append(displayRow(from: row, languageCode: languageCode, divider: false))
        }

        for row in notice.changeRows {
            result.append(displayRow(from: row, languageCode: languageCode, divider: false))
        }

        var remaining = notice.supportingRows.filter { !identityKinds.contains($0.kind) }
        let dateRow = remaining.first { $0.kind == .date && !isArrowChange($0) }
        let timeRow = remaining.first { $0.kind == .time && !isArrowChange($0) }
        var whenParts: [String] = []
        var whenImage = "clock"
        if let dateRow {
            let value = dateRow.displayValue(languageCode: languageCode)
            if !value.isEmpty { whenParts.append(value) }
        }
        if let timeRow {
            let value = timeRow.displayValue(languageCode: languageCode)
            if !value.isEmpty { whenParts.append(value) }
            whenImage = timeRow.systemImage
        }
        remaining.removeAll { row in
            (row.kind == .date || row.kind == .time) && !isArrowChange(row)
        }

        var needsDivider = !identitySource.isEmpty
            && (!whenParts.isEmpty || remaining.contains { $0.kind == .location } || !remaining.isEmpty)

        if !whenParts.isEmpty {
            result.append(
                FanGeoInboxTeamEventDisplayRow(
                    kind: .time,
                    labelKey: "action_center_label_when",
                    value: whenParts.joined(separator: " · "),
                    systemImage: whenImage,
                    showsPlayerAvatar: false,
                    showsDividerBefore: needsDivider,
                    isIdentity: false
                )
            )
            needsDivider = false
        }

        for row in remaining {
            let labelKey = row.kind == .location && !isArrowChange(row)
                ? "action_center_label_where"
                : row.labelKey
            result.append(
                FanGeoInboxTeamEventDisplayRow(
                    kind: row.kind,
                    labelKey: labelKey,
                    value: row.displayValue(languageCode: languageCode),
                    systemImage: row.systemImage,
                    showsPlayerAvatar: row.kind == .player,
                    showsDividerBefore: needsDivider,
                    isIdentity: row.isIdentity
                )
            )
            needsDivider = false
        }

        return result.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func usesTeamLogoAsPrimaryArtwork(for item: FanGeoActionItem) -> Bool {
        let source = FanGeoActionCenterLeadingIdentity.source(for: item)
        return source != .personAvatar
            && (
                source == .teamMark
                    || FanGeoActionCenterLeadingIdentity.isTeamEventLeadingKind(item.kind)
                    || FanGeoActionCenterTeamNotificationPresentation.usesTeamChrome(for: item)
            )
    }

    static func keepsPlayerAvatarInBodyRow(_ notice: FanGeoTeamEventNotice) -> Bool {
        notice.allRows.contains { $0.kind == .player }
    }

    private static func isArrowChange(_ row: FanGeoTeamEventNoticeRow) -> Bool {
        let oldText = row.oldValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let newText = row.newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !oldText.isEmpty && !newText.isEmpty && oldText != newText
    }

    private static func displayRow(
        from row: FanGeoTeamEventNoticeRow,
        languageCode: String,
        divider: Bool
    ) -> FanGeoInboxTeamEventDisplayRow {
        FanGeoInboxTeamEventDisplayRow(
            kind: row.kind,
            labelKey: row.labelKey,
            value: row.displayValue(languageCode: languageCode),
            systemImage: row.systemImage,
            showsPlayerAvatar: row.kind == .player,
            showsDividerBefore: divider,
            isIdentity: row.isIdentity
        )
    }
}
