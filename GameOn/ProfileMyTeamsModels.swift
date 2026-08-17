import Foundation
import SwiftUI

/// Global profile visibility for FanGeo Fan Team memberships (Phase 1).
/// Distinct from hero Favorite Team (primary favorite club) and Favorite Teams catalog.
/// Never write this into `user_favorite_teams` / `primaryFavoriteTeamID`.
enum FanTeamProfileVisibility: String, Codable, CaseIterable, Identifiable, Sendable {
    case everyone
    case friends
    case teamMembers = "team_members"
    case onlyMe = "only_me"

    var id: String { rawValue }

    /// Social default: FanGeo Teams are visible on profile unless the user opts into a tighter audience.
    static let productDefault: FanTeamProfileVisibility = .everyone

    /// Prior product default (`only_me`). Used only to detect never-explicitly-chosen legacy rows.
    static let legacyProductDefault: FanTeamProfileVisibility = .onlyMe

    static func parse(_ raw: String?) -> FanTeamProfileVisibility {
        let normalized = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        switch normalized {
        case "everyone", "all":
            return .everyone
        case "friends", "all_friends":
            return .friends
        case "team_members", "teammembers", "team_members_only":
            return .teamMembers
        case "only_me", "onlyme", "private", "me":
            return .onlyMe
        default:
            return .productDefault
        }
    }

    var localizedTitleKey: String {
        switch self {
        case .everyone: return "profile_my_teams_visibility_everyone"
        case .friends: return "profile_my_teams_visibility_friends"
        case .teamMembers: return "profile_my_teams_visibility_team_members"
        case .onlyMe: return "profile_my_teams_visibility_only_me"
        }
    }

    /// Edit Profile chip icon. Copy may say “Fans on FanGeo”; stored token remains `friends`.
    var editProfileChipSystemImage: String {
        switch self {
        case .everyone: return "person.2.fill"
        case .friends: return "person.3.fill"
        case .teamMembers: return "shield.fill"
        case .onlyMe: return "lock.fill"
        }
    }

    func localizedTitle(languageCode: String) -> String {
        L10n.t(localizedTitleKey, languageCode: languageCode)
    }
}

/// Minimal safe Fan Team membership for profile surfaces (no roster/schedule/chat).
struct ProfileFanTeamMembership: Identifiable, Hashable, Sendable {
    var id: UUID { teamId }
    let teamId: UUID
    let name: String
    let sport: String
    let logoURL: String?
    let logoThumbnailURL: String?
    let colorHex: String?
    let role: FanTeamMemberRole
    /// True when the viewer may open Team Detail (self or active co-member).
    let viewerCanOpen: Bool

    var sportDisplayLabel: String {
        let trimmed = sport.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return AppSportCatalog.displayLabel(forSportToken: trimmed)
    }

    func applyingIdentityChange(_ change: FanTeamIdentityChange) -> ProfileFanTeamMembership {
        guard change.teamId == teamId else { return self }
        return ProfileFanTeamMembership(
            teamId: teamId,
            name: change.name.isEmpty ? name : change.name,
            sport: change.sport.isEmpty ? sport : change.sport,
            logoURL: change.logoURL,
            logoThumbnailURL: change.logoThumbnailURL,
            colorHex: change.colorHex ?? colorHex,
            role: role,
            viewerCanOpen: viewerCanOpen
        )
    }
}

struct ProfileFanTeamMembershipsPayload: Sendable {
    let visible: Bool
    let visibility: FanTeamProfileVisibility
    let memberships: [ProfileFanTeamMembership]

    static let empty = ProfileFanTeamMembershipsPayload(
        visible: false,
        visibility: .productDefault,
        memberships: []
    )
}

/// Presentation helpers for profile My Teams cards (no network).
enum ProfileMyTeamsPresentation {
    static func accessibilityLabel(
        membership: ProfileFanTeamMembership,
        languageCode: String,
        opensTeam: Bool
    ) -> String {
        var parts: [String] = [membership.name]
        let sport = membership.sportDisplayLabel
        if !sport.isEmpty { parts.append(sport) }
        parts.append(L10n.t(membership.role.localizedKey, languageCode: languageCode))
        var label = parts.joined(separator: ". ")
        if opensTeam {
            label += ". " + L10n.t("profile_my_teams_opens_team_a11y", languageCode: languageCode)
        }
        return label
    }

    /// Kept for Edit Profile / tests — not shown on profile section headers.
    static func ownerVisibilityCaption(
        visibility: FanTeamProfileVisibility,
        languageCode: String
    ) -> String {
        String(
            format: L10n.t("profile_my_teams_visible_to_format", languageCode: languageCode),
            locale: Locale(identifier: L10n.normalizedLanguageCode(languageCode)),
            visibility.localizedTitle(languageCode: languageCode)
        )
    }
}

extension Notification.Name {
    /// Account → Teams tab (View All / Create Team from profile My Teams).
    static let fanGeoSelectTeamsTab = Notification.Name("fanGeoSelectTeamsTab")
}
