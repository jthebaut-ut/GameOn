import SwiftUI

// MARK: - Team Announcement detail (presentation only)
//
// Announcements are informational notices — not games/events.
// Host: `DiscoverPickupGameDetailSheet` when `gameFormat == .announcement`.

enum FanTeamAnnouncementDetailPresentation {
    /// Navigation title key for announcement-focused detail.
    static let navTitleKey = "team_announcement_detail_nav_title"

    static func sentAtDate(for game: PickupGameRow) -> Date? {
        if let raw = game.created_at,
           let created = PickupGameModels.parseSupabaseTimestamptz(raw) {
            return created
        }
        return PickupGameModels.parseSupabaseTimestamptz(game.game_start_at)
    }

    /// Example: `Tuesday, Aug 11, 2026 • 5:20 PM`
    static func sentAtText(for game: PickupGameRow, languageCode: String) -> String? {
        guard let date = sentAtDate(for: game) else { return nil }
        let locale = Locale(identifier: languageCode.replacingOccurrences(of: "-", with: "_"))
        let datePart = date.formatted(
            Date.FormatStyle()
                .weekday(.wide)
                .month(.abbreviated)
                .day()
                .year()
                .locale(locale)
        )
        let timePart = date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened)
                .locale(locale)
        )
        return "\(datePart) • \(timePart)"
    }

    static func senderDisplayName(
        creatorLabel: String?,
        memberDisplayName: String?,
        languageCode: String
    ) -> String {
        let fromLabel = (creatorLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !fromLabel.isEmpty { return fromLabel }
        let fromMember = (memberDisplayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !fromMember.isEmpty { return fromMember }
        return L10n.t("team_announcement_manager_fallback", languageCode: languageCode)
    }

    /// Compact header line: `From FanGeo (Owner)` — role omitted when unknown.
    static func fromLine(
        senderName: String,
        role: FanTeamMemberRole?,
        languageCode: String
    ) -> String {
        let name = senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let role else {
            return String(
                format: L10n.t("team_announcement_detail_from_name_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                name
            )
        }
        let roleTitle = L10n.t(role.localizedKey, languageCode: languageCode)
        return String(
            format: L10n.t("team_announcement_detail_from_name_role_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            name,
            roleTitle
        )
    }

    /// Audience line when known. Prefer member count; otherwise “Entire Team” for team-linked.
    static func audienceText(memberCount: Int?, isTeamLinked: Bool, languageCode: String) -> String? {
        if let memberCount, memberCount > 0 {
            return String(
                format: L10n.t(
                    "team_announcement_detail_sent_to_count_format",
                    languageCode: languageCode
                ),
                locale: Locale(identifier: languageCode),
                Int64(memberCount)
            )
        }
        guard isTeamLinked else { return nil }
        return L10n.t("team_announcement_detail_sent_to_entire_team", languageCode: languageCode)
    }

    /// Primary message body (description preferred; title as last resort).
    static func messageBody(for game: PickupGameRow) -> String? {
        let description = (game.description ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty { return description }
        let title = game.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// Optional subject line when title is distinct from the message body.
    static func subjectTitle(for game: PickupGameRow) -> String? {
        let title = game.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let body = (game.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty, title.caseInsensitiveCompare(body) == .orderedSame {
            return nil
        }
        let formatTitle = GameType.announcement.displayTitle(languageCode: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !formatTitle.isEmpty, title.caseInsensitiveCompare(formatTitle) == .orderedSame {
            return nil
        }
        return title
    }

    /// Announcements have no event-style “More Details” (organizer lives in the header).
    static func showsMoreDetailsSection(for format: GameType) -> Bool {
        format != .announcement
    }
}

// MARK: - Shared announcement card chrome (FanGeo glass cards)

private struct FanTeamAnnouncementCardChrome<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(FGSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                        .fill(
                            Color.black.opacity(colorScheme == .dark ? 0.22 : 0.03)
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                    .strokeBorder(
                        FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.4),
                        lineWidth: 1
                    )
            }
    }
}

// MARK: - Header

struct FanTeamAnnouncementDetailHeaderCard: View {
    let team: PickupGameTeamCreationContext?
    let fallbackSport: String
    let fromLine: String
    let sentAtText: String?
    let audienceText: String?
    let languageCode: String
    let accent: Color

    @Environment(\.colorScheme) private var colorScheme

    private var mainInk: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : FGColor.primaryText(colorScheme)
    }

    private var subInk: Color {
        colorScheme == .dark ? Color.white.opacity(0.72) : FGColor.secondaryText(colorScheme)
    }

    var body: some View {
        FanTeamAnnouncementCardChrome {
            VStack(alignment: .leading, spacing: FGSpacing.md) {
                HStack(alignment: .center, spacing: FGSpacing.md) {
                    if let team {
                        FanTeamMarkView(
                            sport: team.teamSport,
                            logoURL: team.logoURL,
                            logoThumbnailURL: team.logoThumbnailURL,
                            colorHex: team.colorHex,
                            size: 64,
                            preferDetailURL: false
                        )
                        .accessibilityHidden(true)
                    } else {
                        SportArtworkIconView(sport: fallbackSport, diameter: 64)
                            .accessibilityHidden(true)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        if let name = team?.teamName.trimmingCharacters(in: .whitespacesAndNewlines),
                           !name.isEmpty {
                            Text(name)
                                .font(FGTypography.metadata.weight(.semibold))
                                .foregroundStyle(accent)
                                .lineLimit(2)
                        }

                        Text(L10n.t("team_announcement_detail_hero_title", languageCode: languageCode))
                            .font(FGTypography.sectionTitle)
                            .foregroundStyle(mainInk)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(fromLine)
                        .font(FGTypography.metadata.weight(.semibold))
                        .foregroundStyle(mainInk)
                        .fixedSize(horizontal: false, vertical: true)

                    if let sentAtText, !sentAtText.isEmpty {
                        Text(sentAtText)
                            .font(FGTypography.caption.weight(.medium))
                            .foregroundStyle(subInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let audienceText, !audienceText.isEmpty {
                        Text(audienceText)
                            .font(FGTypography.caption.weight(.medium))
                            .foregroundStyle(subInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Message body (primary content)

struct FanTeamAnnouncementMessageCard: View {
    let subjectTitle: String?
    let message: String?
    let languageCode: String
    let accent: Color

    @Environment(\.colorScheme) private var colorScheme

    private var mainInk: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : FGColor.primaryText(colorScheme)
    }

    var body: some View {
        FanTeamAnnouncementCardChrome {
            VStack(alignment: .leading, spacing: FGSpacing.md) {
                HStack(spacing: 8) {
                    Image(systemName: "megaphone.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                    Text(L10n.t("team_announcement_detail_message_section", languageCode: languageCode))
                        .font(FGTypography.caption.weight(.bold))
                        .foregroundStyle(accent)
                        .textCase(.uppercase)
                }
                .accessibilityAddTraits(.isHeader)

                if let subjectTitle, !subjectTitle.isEmpty {
                    Text(subjectTitle)
                        .font(FGTypography.metadata.weight(.semibold))
                        .foregroundStyle(mainInk)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(mainInk)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else {
                    Text(L10n.t("pickup_detail_no_description", languageCode: languageCode))
                        .font(FGTypography.body)
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                }
            }
            .padding(.vertical, FGSpacing.sm)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [
            L10n.t("team_announcement_detail_message_section", languageCode: languageCode)
        ]
        if let subjectTitle, !subjectTitle.isEmpty {
            parts.append(subjectTitle)
        }
        if let message, !message.isEmpty {
            parts.append(message)
        }
        return parts.joined(separator: ". ")
    }
}
