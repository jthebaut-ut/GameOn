import Foundation

enum ProfileSettingsRoute: Hashable {
    case liveActivitySharing
    case notifications
    case timeZone
    case language
    case appearance
    case helpAndTutorial
    case support
    case communityGuidelines
    case trustSafety
    case privacyPolicy
    case termsOfService
    case resetPassword
    case venueResetPassword

    var debugName: String {
        switch self {
        case .liveActivitySharing: return "liveActivitySharing"
        case .notifications: return "notifications"
        case .timeZone: return "timeZone"
        case .language: return "language"
        case .appearance: return "appearance"
        case .helpAndTutorial: return "helpAndTutorial"
        case .support: return "support"
        case .communityGuidelines: return "communityGuidelines"
        case .trustSafety: return "trustSafety"
        case .privacyPolicy: return "privacyPolicy"
        case .termsOfService: return "termsOfService"
        case .resetPassword: return "resetPassword"
        case .venueResetPassword: return "venueResetPassword"
        }
    }
}
