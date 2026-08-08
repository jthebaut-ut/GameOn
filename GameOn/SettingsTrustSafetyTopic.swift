import SwiftUI

/// Informational Trust & Safety topics shown from Settings.
/// Designed so future topics (E2E encryption status, login history, trusted devices, etc.)
/// can be added without redesigning the destination screen layout.
enum SettingsTrustSafetyTopic: String, CaseIterable, Identifiable, Hashable, Sendable {
    case chatSecurity
    case reportingModeration
    case blockingUsers
    case privacyLocationSharing
    case communityGuidelines

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .chatSecurity: return "lock.shield"
        case .reportingModeration: return "flag.badge.ellipsis"
        case .blockingUsers: return "hand.raised.fill"
        case .privacyLocationSharing: return "location.viewfinder"
        case .communityGuidelines: return "person.2.badge.gearshape"
        }
    }

    var accent: SettingsTrustSafetyAccent {
        switch self {
        case .chatSecurity, .privacyLocationSharing:
            return .blue
        case .reportingModeration, .blockingUsers, .communityGuidelines:
            return .green
        }
    }

    func title(languageCode: String) -> String {
        L10n.t(titleKey, languageCode: languageCode)
    }

    func subtitle(languageCode: String) -> String {
        L10n.t(subtitleKey, languageCode: languageCode)
    }

    func cards(languageCode: String) -> [SettingsTrustSafetyCardModel] {
        cardKeys.map { key in
            SettingsTrustSafetyCardModel(
                id: key.heading,
                heading: L10n.t(key.heading, languageCode: languageCode),
                body: L10n.t(key.body, languageCode: languageCode)
            )
        }
    }

    var route: ProfileSettingsRoute {
        switch self {
        case .chatSecurity: return .chatSecurity
        case .reportingModeration: return .reportingModeration
        case .blockingUsers: return .blockingUsersInfo
        case .privacyLocationSharing: return .privacyLocationSharing
        case .communityGuidelines: return .communityGuidelines
        }
    }

    private var titleKey: String {
        switch self {
        case .chatSecurity: return "settings_trust_chat_security_title"
        case .reportingModeration: return "settings_trust_reporting_title"
        case .blockingUsers: return "settings_trust_blocking_title"
        case .privacyLocationSharing: return "settings_trust_location_title"
        case .communityGuidelines: return "community_guidelines"
        }
    }

    private var subtitleKey: String {
        switch self {
        case .chatSecurity: return "settings_trust_chat_security_subtitle"
        case .reportingModeration: return "settings_trust_reporting_subtitle"
        case .blockingUsers: return "settings_trust_blocking_subtitle"
        case .privacyLocationSharing: return "settings_trust_location_subtitle"
        case .communityGuidelines: return "settings_trust_guidelines_subtitle"
        }
    }

    private var cardKeys: [(heading: String, body: String)] {
        switch self {
        case .chatSecurity:
            return [
                ("settings_trust_chat_secure_connections_heading", "settings_trust_chat_secure_connections_body"),
                ("settings_trust_chat_private_heading", "settings_trust_chat_private_body"),
                ("settings_trust_chat_account_heading", "settings_trust_chat_account_body"),
                ("settings_trust_chat_spam_heading", "settings_trust_chat_spam_body"),
                ("settings_trust_chat_location_heading", "settings_trust_chat_location_body"),
                ("settings_trust_chat_moderation_heading", "settings_trust_chat_moderation_body"),
                ("settings_trust_chat_e2e_heading", "settings_trust_chat_e2e_body")
            ]
        case .reportingModeration:
            return [
                ("settings_trust_reporting_what_heading", "settings_trust_reporting_what_body"),
                ("settings_trust_reporting_review_heading", "settings_trust_reporting_review_body"),
                ("settings_trust_reporting_consequences_heading", "settings_trust_reporting_consequences_body")
            ]
        case .blockingUsers:
            return [
                ("settings_trust_blocking_effect_heading", "settings_trust_blocking_effect_body"),
                ("settings_trust_blocking_history_heading", "settings_trust_blocking_history_body"),
                ("settings_trust_blocking_unblock_heading", "settings_trust_blocking_unblock_body")
            ]
        case .privacyLocationSharing:
            return [
                ("settings_trust_location_optional_heading", "settings_trust_location_optional_body"),
                ("settings_trust_location_control_heading", "settings_trust_location_control_body"),
                ("settings_trust_location_expiry_heading", "settings_trust_location_expiry_body"),
                ("settings_trust_location_public_heading", "settings_trust_location_public_body")
            ]
        case .communityGuidelines:
            return [
                ("settings_trust_guidelines_respect_heading", "settings_trust_guidelines_respect_body"),
                ("settings_trust_guidelines_prohibited_heading", "settings_trust_guidelines_prohibited_body"),
                ("settings_trust_guidelines_pickup_heading", "settings_trust_guidelines_pickup_body"),
                ("settings_trust_guidelines_enforcement_heading", "settings_trust_guidelines_enforcement_body")
            ]
        }
    }
}

enum SettingsTrustSafetyAccent: Sendable {
    case blue
    case green

    var color: Color {
        switch self {
        case .blue: return FGColor.accentBlue
        case .green: return FGColor.accentGreen
        }
    }
}

struct SettingsTrustSafetyCardModel: Identifiable, Hashable, Sendable {
    let id: String
    let heading: String
    let body: String
}
