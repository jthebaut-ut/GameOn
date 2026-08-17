import SwiftUI

/// Compact Team Schedule Directions control — sibling of card-open / RSVP (never nested).
/// Reuses ``FanGeoDirectionsActions`` with the same coordinate-first gate as event detail.
struct FanTeamScheduleDirectionsButton: View {
    let game: FanTeamGame
    let languageCode: String
    var accent: Color = FGColor.accentBlue

    @Environment(\.colorScheme) private var colorScheme
    @State private var showDirectionsChooser = false

    private var destinationLabel: String {
        game.directionsDestinationName
    }

    private var accessibilityName: String {
        let line = game.locationLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty { return line }
        return destinationLabel
    }

    var body: some View {
        Button {
            showDirectionsChooser = true
        } label: {
            ZStack {
                Circle()
                    .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.24 : 0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FGColor.accentBlue)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String(
                format: L10n.t("Directions to %@", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                accessibilityName
            )
        )
        .accessibilityHint(L10n.t("pickup_detail_directions_a11y_hint", languageCode: languageCode))
        .confirmationDialog(
            L10n.t("Directions", languageCode: languageCode),
            isPresented: $showDirectionsChooser,
            titleVisibility: .visible
        ) {
            if let lat = game.latitude, let lon = game.longitude,
               FanGeoDirectionsActions.hasUsableCoordinate(latitude: lat, longitude: lon) {
                Button(L10n.t("Apple Maps", languageCode: languageCode)) {
                    FanGeoDirectionsActions.openAppleMapsDirections(
                        latitude: lat,
                        longitude: lon,
                        name: destinationLabel
                    )
                }
                if FanGeoDirectionsActions.isGoogleMapsInstalled {
                    Button(L10n.t("Google Maps", languageCode: languageCode)) {
                        FanGeoDirectionsActions.openGoogleMapsDirections(
                            latitude: lat,
                            longitude: lon,
                            name: destinationLabel
                        )
                    }
                }
                let addressLine = game.locationLine
                if !addressLine.isEmpty {
                    Button(L10n.t("Copy Address", languageCode: languageCode)) {
                        FanGeoDirectionsActions.copyAddress(addressLine)
                    }
                }
            }
            Button(L10n.t("Cancel", languageCode: languageCode), role: .cancel) {}
        }
    }
}
