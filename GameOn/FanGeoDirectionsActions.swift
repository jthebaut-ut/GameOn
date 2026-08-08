import CoreLocation
import MapKit
import UIKit

/// Shared Apple / Google Maps + copy-address actions for pickup (and similar) locations.
enum FanGeoDirectionsActions {
    static func openAppleMapsDirections(
        latitude: Double,
        longitude: Double,
        name: String
    ) {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let item = MKMapItem(location: location, address: nil)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        item.name = trimmed.isEmpty ? "Destination" : trimmed
        item.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }

    static func openGoogleMapsDirections(
        latitude: Double,
        longitude: Double,
        name: String
    ) {
        _ = name
        let dest = "\(latitude),\(longitude)"

        if let appURL = URL(string: "comgooglemaps://?daddr=\(dest)&directionsmode=driving"),
           UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL)
            return
        }

        if let webURL = URL(
            string: "https://www.google.com/maps/dir/?api=1&destination=\(dest)&travelmode=driving"
        ) {
            UIApplication.shared.open(webURL)
        }
    }

    static func copyAddress(_ address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UIPasteboard.general.string = trimmed
    }

    /// Pure numeric validation — safe off the MainActor (used by structured-message decode).
    nonisolated static func hasUsableCoordinate(latitude: Double?, longitude: Double?) -> Bool {
        guard let latitude, let longitude else { return false }
        guard latitude.isFinite, longitude.isFinite else { return false }
        guard abs(latitude) <= 90, abs(longitude) <= 180 else { return false }
        return !(latitude == 0 && longitude == 0)
    }

    /// True when the Google Maps app URL scheme can be opened on this device.
    static var isGoogleMapsInstalled: Bool {
        guard let url = URL(string: "comgooglemaps://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }
}
