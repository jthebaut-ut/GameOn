import SwiftUI
import UIKit

// MARK: - Detail-nil-safe Team header leaves
//
// FanTeamDetailSheet must render these from lightweight `FanTeamSummary` alone.
// Do not read `detail`, roster, games, or announcement state here.

/// Stable identity token for ``FanTeamMarkView`` — avoids embedding full logo URL strings
/// into SwiftUI `.id(...)`, which previously thrashed AttributeGraph during sheet open.
enum FanTeamMarkIdentity {
    static func token(
        sport: String,
        logoURL: String?,
        logoThumbnailURL: String?,
        colorHex: String?,
        preferDetailURL: Bool,
        displayRefreshToken: UUID?,
        sportSubtype: String? = nil
    ) -> String {
        let thumb = ImageDisplayURL.canonicalStorageURLString(logoThumbnailURL)
        let full = ImageDisplayURL.canonicalStorageURLString(logoURL)
        var hasher = Hasher()
        hasher.combine(preferDetailURL)
        hasher.combine(displayRefreshToken)
        hasher.combine(thumb)
        hasher.combine(full)
        hasher.combine(sport)
        hasher.combine(colorHex ?? "")
        hasher.combine(sportSubtype ?? "")
        return "ftm-\(hasher.finalize())"
    }

    /// Rejects strings that Foundation cannot form into a URL (malformed logos must never crash).
    static func safeURL(from raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
#if DEBUG
            TeamDetailRenderBisect.mark("teamHeaderMarkInvalidURL")
#endif
            return nil
        }
        return url
    }
}

/// Header Team mark leaf — sport badge first; remote logo only via safe URL + list-first source.
struct FanTeamDetailHeaderMarkView: View {
    let sport: String
    let logoURL: String?
    let logoThumbnailURL: String?
    let colorHex: String?
    var size: CGFloat = 56
    var displayRefreshToken: UUID? = nil

    var body: some View {
        let _ = TeamDetailRenderBisect.mark("teamHeaderMark begin")
        // Prefer thumbnail / list source on first paint. Full-bleed detail URL can wait —
        // loading a heavy full logo during sheet presentation contributed to AttributeGraph churn.
        FanTeamMarkView(
            sport: sport,
            logoURL: logoURL,
            logoThumbnailURL: logoThumbnailURL,
            colorHex: colorHex,
            size: size,
            preferDetailURL: false,
            displayRefreshToken: displayRefreshToken
        )
        .accessibilityHidden(true)
        let _ = TeamDetailRenderBisect.mark(
            "teamHeaderMark end",
            details: "token=\(FanTeamMarkIdentity.token(sport: sport, logoURL: logoURL, logoThumbnailURL: logoThumbnailURL, colorHex: colorHex, preferDetailURL: false, displayRefreshToken: displayRefreshToken))"
        )
    }
}

/// Fallback static mark used by DEBUG `.noMark` bisect and as a hard-safe substitute.
struct FanTeamDetailHeaderStaticMarkView: View {
    let accent: Color
    var size: CGFloat = 56

    var body: some View {
        let _ = TeamDetailRenderBisect.mark("teamHeaderMarkStatic", details: "accent")
        let _ = accent
        FanGeoSportMark(sport: "", size: size)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Title + meta line only (no actions). Safe with `detail == nil`.
struct FanTeamDetailHeaderTitleBlock: View {
    let teamName: String
    let metaLine: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let _ = TeamDetailRenderBisect.mark("teamHeaderTitle begin")
        VStack(alignment: .leading, spacing: 5) {
            Text(teamName)
                .font(.title3.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            let _ = TeamDetailRenderBisect.mark("headerMetaLine", details: "begin")
            Text(metaLine)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            let _ = TeamDetailRenderBisect.mark("headerMetaLine", details: "completed")
        }
        let _ = TeamDetailRenderBisect.mark("teamHeaderTitle end")
    }
}

/// Privacy + role badges. Uses only summary role / privacy flags.
struct FanTeamDetailHeaderBadgesView: View {
    let showsPrivateBadge: Bool
    let privateBadgeTitle: String
    let role: FanTeamMemberRole
    let languageCode: String
    let accent: Color
    var showsRoleBadge: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let _ = TeamDetailRenderBisect.mark("teamHeaderBadgesCluster begin")
        HStack(spacing: 6) {
            if showsPrivateBadge {
                Text(privateBadgeTitle)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        accent.opacity(colorScheme == .dark ? 0.22 : 0.14),
                        in: Capsule()
                    )
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityAddTraits(.isStaticText)
            }
            if showsRoleBadge, role != .member {
                FanTeamRoleBadgeView(
                    role: role,
                    languageCode: languageCode,
                    showsTitle: true,
                    compact: true
                )
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityAddTraits(.isStaticText)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        let _ = TeamDetailRenderBisect.mark("teamHeaderBadgesCluster end")
    }
}

/// Compact trailing Quick Actions for the Team header card (Announce + Create Event).
///
/// Intentionally avoids `ViewThatFits`. Keep a single shallow render tree —
/// dual-branch measurement previously risked AttributeGraph storms on sheet open.
/// Intrinsic width only — omit entirely when both permissions are false (caller gates).
struct FanTeamDetailHeaderActionsView: View {
    let languageCode: String
    var showAnnounce: Bool
    var showCreateEvent: Bool
    let onAnnounce: () -> Void
    let onCreateEvent: () -> Void

    var body: some View {
        let _ = TeamDetailRenderBisect.mark("teamHeaderActionButtons begin")
        VStack(alignment: .trailing, spacing: 8) {
            if showAnnounce {
                FanTeamDetailHeaderChipButton(
                    title: L10n.t("fan_teams_header_announce", languageCode: languageCode),
                    systemImage: "megaphone.fill",
                    style: .outlinedAccent,
                    accent: FGColor.accentBlue,
                    compresses: true,
                    action: onAnnounce
                )
                .accessibilityHint(L10n.t("fan_teams_make_announcement_a11y_hint", languageCode: languageCode))
            }
            if showCreateEvent {
                FanTeamDetailHeaderChipButton(
                    title: L10n.t("fan_teams_header_create_event", languageCode: languageCode),
                    systemImage: "plus.circle.fill",
                    style: .outlinedAccent,
                    accent: FGColor.intentTeams,
                    compresses: true,
                    action: onCreateEvent
                )
                .accessibilityHint(L10n.t("fan_teams_schedule_event_a11y_hint", languageCode: languageCode))
            }
        }
        .background {
            let _ = TeamDetailRenderBisect.mark("teamHeaderActionButtons end")
            Color.clear
        }
    }
}

private enum FanTeamDetailHeaderChipStyle {
    case outlinedAccent
}

private struct FanTeamDetailHeaderChipButton: View {
    let title: String
    let systemImage: String
    let style: FanTeamDetailHeaderChipStyle
    let accent: Color
    var compresses: Bool = false
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(compresses ? 0.85 : 0.92)
                    .allowsTightening(true)
            } icon: {
                Image(systemName: systemImage)
                    .font(.caption.weight(.bold))
            }
            .labelStyle(.titleAndIcon)
            .foregroundStyle(accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minHeight: 32)
            .background {
                Capsule().fill(accent.opacity(colorScheme == .dark ? 0.22 : 0.12))
            }
            .overlay {
                Capsule().strokeBorder(accent.opacity(0.4), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// Pure helpers for detail-nil header meta (testable; no SwiftUI state).
enum FanTeamDetailHeaderPresentation {
    static func metaLine(
        competitionLevel: PickupCompetitionLevel?,
        sport: String,
        memberCount: Int,
        pendingInvitationCount: Int,
        canManage: Bool,
        languageCode: String
    ) -> String {
        let base = FanTeamMetaLine.compose(
            competitionLevel: competitionLevel,
            sport: sport,
            memberCount: max(0, memberCount),
            languageCode: languageCode
        )
        let pendingCount = max(0, pendingInvitationCount)
        guard canManage, pendingCount > 0 else { return base }
        let pending = TeamDetailLocalizedFormat.format(
            "fan_teams_pending_count_compact_format",
            languageCode: languageCode,
            int64Args: [Int64(pendingCount)]
        )
        return "\(base) · \(pending)"
    }

    /// Header never indexes into roster/avatar arrays — preview counts come from summary only.
    static func safeMemberCount(_ raw: Int) -> Int {
        max(0, raw)
    }
}
