import CoreLocation
import Foundation
import UserMessagingPlatform
import UserNotifications
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif

struct FanGeoPrivacyPermissionsSnapshot: Equatable {
    let locationStatusLabel: String
    let locationSettingsActionTitle: String
    let notificationStatusLabel: String
    let personalizedAdsStatusLabel: String
    let personalizedAdsUsesUMPPrivacyOptions: Bool
    let personalizedAdsPrefersSystemSettings: Bool

    static let placeholder = FanGeoPrivacyPermissionsSnapshot(
        locationStatusLabel: "Not Asked",
        locationSettingsActionTitle: "Open iPhone Settings",
        notificationStatusLabel: "Not Asked",
        personalizedAdsStatusLabel: "Not Asked",
        personalizedAdsUsesUMPPrivacyOptions: false,
        personalizedAdsPrefersSystemSettings: true
    )
}

enum FanGeoPrivacyPermissionsStatusReader {
    @MainActor
    static func currentSnapshot() async -> FanGeoPrivacyPermissionsSnapshot {
        let location = locationDisplayState()
        let notification = await notificationDisplayState()
        let ads = personalizedAdsDisplayState()

        print("[PrivacySettingsDebug] locationStatus=\(location.debugToken)")
        print("[PrivacySettingsDebug] notificationStatus=\(notification.debugToken)")
        print("[PrivacySettingsDebug] adsStatus=\(ads.debugToken)")

        return FanGeoPrivacyPermissionsSnapshot(
            locationStatusLabel: location.label,
            locationSettingsActionTitle: location.settingsActionTitle,
            notificationStatusLabel: notification.label,
            personalizedAdsStatusLabel: ads.label,
            personalizedAdsUsesUMPPrivacyOptions: ads.usesUMPPrivacyOptions,
            personalizedAdsPrefersSystemSettings: ads.prefersSystemSettings
        )
    }

    private struct DisplayState {
        let label: String
        let debugToken: String
    }

    private struct LocationDisplayState {
        let label: String
        let debugToken: String
        let settingsActionTitle: String
    }

    private struct PersonalizedAdsDisplayState {
        let label: String
        let debugToken: String
        let usesUMPPrivacyOptions: Bool
        let prefersSystemSettings: Bool
    }

    private static func locationDisplayState() -> LocationDisplayState {
        let status = CLLocationManager().authorizationStatus
        let label: String
        switch status {
        case .notDetermined:
            label = "Not Asked"
        case .denied:
            label = "Off"
        case .restricted:
            label = "Restricted"
        case .authorizedWhenInUse:
            label = "While Using App"
        case .authorizedAlways:
            label = "Always Allowed"
        @unknown default:
            label = "Unknown"
        }

        let isAuthorized = status == .authorizedWhenInUse || status == .authorizedAlways
        let settingsActionTitle = isAuthorized ? "Manage in iPhone Settings" : "Open iPhone Settings"
        return LocationDisplayState(
            label: label,
            debugToken: status.debugToken,
            settingsActionTitle: settingsActionTitle
        )
    }

    private static func notificationDisplayState() async -> DisplayState {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let label: String
        switch status {
        case .notDetermined:
            label = "Not Asked"
        case .denied:
            label = "Off"
        case .authorized:
            label = "On"
        case .provisional:
            label = "Provisional"
        case .ephemeral:
            label = "Scheduled Summary"
        @unknown default:
            label = "Restricted"
        }
        return DisplayState(label: label, debugToken: status.debugToken)
    }

    private static func personalizedAdsDisplayState() -> PersonalizedAdsDisplayState {
        let usesUMPPrivacyOptions = GoogleMobileAdsBootstrap.privacyOptionsRequired
        let prefersSystemSettings = isATTNotDetermined
        let label: String
        let debugToken: String

        if #available(iOS 14, *) {
            let attStatus = ATTrackingManager.trackingAuthorizationStatus
            switch attStatus {
            case .notDetermined:
                label = "Not Asked"
                debugToken = "notDetermined"
            case .denied, .restricted:
                label = "Limited Ads"
                debugToken = attStatus.debugToken
            case .authorized:
                if allowsPersonalizedAdsWhenAvailable {
                    label = "On"
                    debugToken = "personalizedOn"
                } else {
                    label = "Limited Ads"
                    debugToken = "limitedAds"
                }
            @unknown default:
                label = "Limited Ads"
                debugToken = "unknown"
            }
        } else {
            if allowsPersonalizedAdsWhenAvailable {
                label = "On"
                debugToken = "personalizedOn"
            } else {
                label = "Limited Ads"
                debugToken = "limitedAds"
            }
        }

        return PersonalizedAdsDisplayState(
            label: label,
            debugToken: debugToken,
            usesUMPPrivacyOptions: usesUMPPrivacyOptions,
            prefersSystemSettings: prefersSystemSettings
        )
    }

    private static var isATTNotDetermined: Bool {
        if #available(iOS 14, *) {
            return ATTrackingManager.trackingAuthorizationStatus == .notDetermined
        }
        return false
    }

    private static var allowsPersonalizedAdsWhenAvailable: Bool {
        guard ConsentInformation.shared.canRequestAds else { return false }
        switch ConsentInformation.shared.consentStatus {
        case .obtained, .notRequired:
            break
        case .required, .unknown:
            return false
        @unknown default:
            return false
        }

        if #available(iOS 14, *) {
            return ATTrackingManager.trackingAuthorizationStatus == .authorized
        }
        return true
    }
}

private extension CLAuthorizationStatus {
    var debugToken: String {
        switch self {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        @unknown default: return "unknown(\(rawValue))"
        }
    }
}

#if canImport(AppTrackingTransparency)
@available(iOS 14, *)
private extension ATTrackingManager.AuthorizationStatus {
    var debugToken: String {
        switch self {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }
}
#endif

private extension UNAuthorizationStatus {
    var debugToken: String {
        switch self {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }
}
