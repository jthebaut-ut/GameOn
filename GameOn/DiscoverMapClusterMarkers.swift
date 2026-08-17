import CoreLocation
import MapKit
import SwiftUI

/// Discover Places-mode cluster kinds.
/// Teams are purple branded chrome. Pickup Places restore original gray chips.
enum DiscoverMapClusterKind: Equatable, Sendable {
    case teams
    case places
    case mixed

    var accent: Color {
        switch self {
        case .teams: return FGColor.intentTeams
        case .places: return FGColor.intentPlay
        case .mixed: return Color.gray
        }
    }

    var iconSystemName: String {
        switch self {
        case .teams: return "shield.fill"
        case .places: return "sportscourt.fill"
        case .mixed: return "circle.grid.2x1.fill"
        }
    }
}

enum DiscoverMapClusterChrome {
    static func diameter(count: Int) -> CGFloat {
        switch count {
        case ..<5: return 48
        case ..<13: return 54
        default: return 60
        }
    }

    static func iconPointSize(count: Int) -> CGFloat {
        diameter(count: count) * 0.26
    }

    static func countPointSize(count: Int) -> CGFloat {
        diameter(count: count) * 0.28
    }
}

/// When a Team cluster and a Place cluster land on the same grid cell, nudge them
/// apart so both branded markers stay readable. Does not merge into a mixed cluster.
enum DiscoverPlacesClusterSeparation {
    static let teamIDPrefix = "discover-team-"
    static let placeIDPrefix = "pickup-place-"

    static func gridKey(fromClusterId id: String, prefix: String) -> String? {
        guard id.hasPrefix(prefix) else { return nil }
        return String(id.dropFirst(prefix.count))
    }

    static func separateOverlapping(
        teams: [DiscoverableFanTeamCluster],
        places: [PickupPlaceCluster],
        visibleLatitudeDelta: Double
    ) -> (teams: [DiscoverableFanTeamCluster], places: [PickupPlaceCluster]) {
        guard !teams.isEmpty, !places.isEmpty else { return (teams, places) }
        let span = overlapSpan(visibleLatitudeDelta: visibleLatitudeDelta)
        var nextTeams = teams
        var displacedPlaceIDs: Set<String> = []

        for i in nextTeams.indices {
            guard let place = places.first(where: { candidate in
                !displacedPlaceIDs.contains(candidate.id)
                    && coordinatesAreOverlapping(nextTeams[i].coordinate, candidate.coordinate, span: span)
            }) else { continue }
            displacedPlaceIDs.insert(place.id)
            nextTeams[i] = nextTeams[i].relocated(
                to: offset(nextTeams[i].coordinate, latitude: span * 0.55, longitude: -span * 0.42)
            )
        }

        let nextPlaces = places.map { place -> PickupPlaceCluster in
            guard displacedPlaceIDs.contains(place.id) else { return place }
            return place.relocated(
                to: offset(place.coordinate, latitude: -span * 0.55, longitude: span * 0.42)
            )
        }
        return (nextTeams, nextPlaces)
    }

    static func overlapSpan(visibleLatitudeDelta: Double) -> Double {
        // Scale with viewport so a ~60pt cluster disk stays readable at far zoom.
        min(max(visibleLatitudeDelta * 0.08, 0.00018), 0.45)
    }

    static func coordinatesAreOverlapping(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D,
        span: Double
    ) -> Bool {
        let dLat = a.latitude - b.latitude
        let dLon = a.longitude - b.longitude
        return (dLat * dLat + dLon * dLon) < (span * 2.2) * (span * 2.2)
    }

    private static func offset(
        _ coordinate: CLLocationCoordinate2D,
        latitude: Double,
        longitude: Double
    ) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: min(90, max(-90, coordinate.latitude + latitude)),
            longitude: min(180, max(-180, coordinate.longitude + longitude))
        )
    }
}

extension DiscoverableFanTeamCluster {
    func relocated(to coordinate: CLLocationCoordinate2D) -> DiscoverableFanTeamCluster {
        DiscoverableFanTeamCluster(id: id, rows: rows, coordinate: coordinate)
    }
}

extension PickupPlaceCluster {
    func relocated(to coordinate: CLLocationCoordinate2D) -> PickupPlaceCluster {
        PickupPlaceCluster(id: id, rows: rows, coordinate: coordinate)
    }
}

/// High-contrast Team cluster chrome. Pickup Place clusters use
/// `DiscoverPickupPlaceClusterMarker` (original gray style).
struct DiscoverMapEntityClusterMarker: View {
    let kind: DiscoverMapClusterKind
    let count: Int
    let languageCode: String
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var diameter: CGFloat { DiscoverMapClusterChrome.diameter(count: count) }
    private var accent: Color { kind.accent }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(accent.opacity(colorScheme == .dark ? 0.55 : 0.42))
                    .frame(width: diameter + 16, height: diameter + 16)
                    .blur(radius: 7)

                Circle()
                    .fill(accent)
                    .frame(width: diameter, height: diameter)
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white, lineWidth: 3)
                    }
                    .shadow(color: accent.opacity(colorScheme == .dark ? 0.55 : 0.38), radius: 8, y: 3)
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.38 : 0.22), radius: 6, y: 4)

                VStack(spacing: 0) {
                    Image(systemName: kind.iconSystemName)
                        .font(.system(size: DiscoverMapClusterChrome.iconPointSize(count: count), weight: .bold))
                    Text("\(count)")
                        .font(.system(
                            size: DiscoverMapClusterChrome.countPointSize(count: count),
                            weight: .heavy,
                            design: .rounded
                        ))
                        .monospacedDigit()
                }
                .foregroundStyle(Color.white)
                .shadow(color: Color.black.opacity(0.28), radius: 1, y: 0.5)
            }
            .frame(width: max(56, diameter + 10), height: max(56, diameter + 10))
            .contentShape(Circle())
            .animation(.easeInOut(duration: 0.22), value: count)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabel: String {
        switch kind {
        case .teams:
            return String(
                format: L10n.t("discover_team_cluster_a11y_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                Int64(count)
            )
        case .places:
            return String(
                format: L10n.t("discover_place_cluster_a11y_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                Int64(count)
            )
        case .mixed:
            return String(
                format: L10n.t("discover_mixed_cluster_a11y_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                Int64(count)
            )
        }
    }
}

/// Original FanGeo Pickup Place cluster: compact gray chip, thin gray ring,
/// orange place icon + orange count. No orange glow, halo, or enlarged disc.
struct DiscoverPickupPlaceClusterMarker: View {
    let count: Int
    let languageCode: String
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(Color.gray.opacity(colorScheme == .dark ? 0.24 : 0.16))
                    .frame(width: 48, height: 48)
                    .blur(radius: 0)

                Circle()
                    .fill(colorScheme == .dark ? Color.black.opacity(0.82) : Color.white.opacity(0.92))
                    .frame(width: 36, height: 36)
                    .overlay {
                        Circle()
                            .strokeBorder(Color.gray.opacity(0.56), lineWidth: 1.25)
                    }
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.12), radius: 5, y: 2)

                VStack(spacing: -1) {
                    Image(systemName: DiscoverMapClusterKind.places.iconSystemName)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                    Text("\(count)")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(FGColor.intentPlay)
            }
            .frame(width: 48, height: 48)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(
                format: L10n.t("discover_place_cluster_a11y_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                Int64(count)
            )
        )
        .accessibilityAddTraits(.isButton)
    }
}

#if DEBUG
/// Simulator visual-QA only. Inert unless `debugDiscoverQALatitudeDelta` is set via defaults.
enum DiscoverClusterVisualQA {
    static let latKey = "debugDiscoverQALatitude"
    static let lonKey = "debugDiscoverQALongitude"
    static let deltaKey = "debugDiscoverQALatitudeDelta"
    static let dismissBannersKey = "debugDiscoverQADismissBanners"

    @MainActor
    static func applyIfNeeded(to viewModel: MapViewModel) {
        if UserDefaults.standard.bool(forKey: dismissBannersKey) {
            for announcement in viewModel.discoverBannerAnnouncements {
                viewModel.dismissDiscoverBannerAnnouncement(announcement)
            }
        }
        let delta = UserDefaults.standard.double(forKey: deltaKey)
        guard delta > 0 else { return }
        var lat = UserDefaults.standard.double(forKey: latKey)
        var lon = UserDefaults.standard.double(forKey: lonKey)
        if lat == 0, lon == 0 {
            lat = 40.387
            lon = -111.849
        }
        viewModel.noteDiscoverUserCameraInteractionIfStartupPending()
        viewModel.visibleLatitudeDelta = delta
        viewModel.cameraPosition = .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                span: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta * 0.72)
            )
        )
    }
}
#endif
