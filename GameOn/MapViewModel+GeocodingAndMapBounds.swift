import CoreLocation
import Foundation
import MapKit
import SwiftUI

/// Why the Discover startup camera currently points where it does.
/// Broad provisional bases (device region / world) are for presentation only — not giant data fetches.
enum DiscoverStartupCameraBasis: String, Equatable {
    case gps
    case lastKnownLocation
    case userInteraction
    case deviceRegion
    case world

    /// Trusted local / explicit bases may load geographic content when the viewport span is bounded.
    var isTrustedForGeographicFetch: Bool {
        switch self {
        case .gps, .lastKnownLocation, .userInteraction:
            return true
        case .deviceRegion, .world:
            return false
        }
    }
}

/// Production Discover map defaults — never Lehi/Utah as a global fallback.
enum DiscoverMapRegionDefaults {
    /// Spans above this (degrees) are too broad for Phase‑1 venue/pickup network loads.
    /// Matches the existing `latSpan > 8` heavy-query threshold in venue fetch.
    static let geographicFetchMaxSpanDegrees: Double = 8

    /// Broad neutral world viewport when GPS is unavailable and no safer coarse hint exists.
    static let worldCenter = CLLocationCoordinate2D(latitude: 20, longitude: 10)
    static let worldSpan = MKCoordinateSpan(latitudeDelta: 100, longitudeDelta: 160)

    static var worldRegion: MKCoordinateRegion {
        MKCoordinateRegion(center: worldCenter, span: worldSpan)
    }

    /// Former production default (Lehi, Utah) — kept only to detect/replace legacy camera state.
    static let legacyLehiCenter = CLLocationCoordinate2D(latitude: 40.3916, longitude: -111.8508)

    static func isLegacyLehiFallbackCenter(_ coordinate: CLLocationCoordinate2D) -> Bool {
        abs(coordinate.latitude - legacyLehiCenter.latitude) < 0.05
            && abs(coordinate.longitude - legacyLehiCenter.longitude) < 0.05
    }

    /// Coarse country/region center from the device Locale region code (no location permission).
    /// Unknown codes return nil so callers can fall back to ``worldRegion``.
    static func coarseRegionForDeviceLocale() -> MKCoordinateRegion? {
        guard let raw = Locale.current.region?.identifier.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        let code = raw.uppercased()
        guard let center = approximateCountryCenters[code] else { return nil }
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 10)
        )
    }

    static func distanceMiles(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) / 1609.344
    }

    /// Approximate geographic centers for common ISO regions (device Locale only — not a GPS substitute).
    private static let approximateCountryCenters: [String: CLLocationCoordinate2D] = [
        "US": CLLocationCoordinate2D(latitude: 39.8, longitude: -98.5),
        "CA": CLLocationCoordinate2D(latitude: 56.1, longitude: -106.3),
        "MX": CLLocationCoordinate2D(latitude: 23.6, longitude: -102.5),
        "BR": CLLocationCoordinate2D(latitude: -14.2, longitude: -51.9),
        "AR": CLLocationCoordinate2D(latitude: -38.4, longitude: -63.6),
        "GB": CLLocationCoordinate2D(latitude: 54.0, longitude: -2.0),
        "IE": CLLocationCoordinate2D(latitude: 53.1, longitude: -8.0),
        "FR": CLLocationCoordinate2D(latitude: 46.2, longitude: 2.2),
        "DE": CLLocationCoordinate2D(latitude: 51.2, longitude: 10.4),
        "ES": CLLocationCoordinate2D(latitude: 40.5, longitude: -3.7),
        "PT": CLLocationCoordinate2D(latitude: 39.4, longitude: -8.2),
        "IT": CLLocationCoordinate2D(latitude: 41.9, longitude: 12.6),
        "NL": CLLocationCoordinate2D(latitude: 52.1, longitude: 5.3),
        "BE": CLLocationCoordinate2D(latitude: 50.5, longitude: 4.5),
        "CH": CLLocationCoordinate2D(latitude: 46.8, longitude: 8.2),
        "AT": CLLocationCoordinate2D(latitude: 47.5, longitude: 14.5),
        "PL": CLLocationCoordinate2D(latitude: 51.9, longitude: 19.1),
        "SE": CLLocationCoordinate2D(latitude: 60.1, longitude: 18.6),
        "NO": CLLocationCoordinate2D(latitude: 60.5, longitude: 8.5),
        "DK": CLLocationCoordinate2D(latitude: 56.3, longitude: 9.5),
        "FI": CLLocationCoordinate2D(latitude: 61.9, longitude: 25.7),
        "RU": CLLocationCoordinate2D(latitude: 61.5, longitude: 105.3),
        "UA": CLLocationCoordinate2D(latitude: 48.4, longitude: 31.2),
        "TR": CLLocationCoordinate2D(latitude: 39.0, longitude: 35.2),
        "GR": CLLocationCoordinate2D(latitude: 39.1, longitude: 21.8),
        "AL": CLLocationCoordinate2D(latitude: 41.2, longitude: 20.2),
        "AU": CLLocationCoordinate2D(latitude: -25.3, longitude: 133.8),
        "NZ": CLLocationCoordinate2D(latitude: -40.9, longitude: 174.9),
        "JP": CLLocationCoordinate2D(latitude: 36.2, longitude: 138.3),
        "KR": CLLocationCoordinate2D(latitude: 35.9, longitude: 127.8),
        "CN": CLLocationCoordinate2D(latitude: 35.9, longitude: 104.2),
        "IN": CLLocationCoordinate2D(latitude: 20.6, longitude: 79.0),
        "ID": CLLocationCoordinate2D(latitude: -2.5, longitude: 118.0),
        "TH": CLLocationCoordinate2D(latitude: 15.9, longitude: 100.9),
        "VN": CLLocationCoordinate2D(latitude: 14.1, longitude: 108.3),
        "PH": CLLocationCoordinate2D(latitude: 12.9, longitude: 121.8),
        "SG": CLLocationCoordinate2D(latitude: 1.35, longitude: 103.8),
        "MY": CLLocationCoordinate2D(latitude: 4.2, longitude: 101.98),
        "AE": CLLocationCoordinate2D(latitude: 23.4, longitude: 53.8),
        "SA": CLLocationCoordinate2D(latitude: 23.9, longitude: 45.1),
        "ZA": CLLocationCoordinate2D(latitude: -30.6, longitude: 25.0),
        "EG": CLLocationCoordinate2D(latitude: 26.8, longitude: 30.8),
        "NG": CLLocationCoordinate2D(latitude: 9.1, longitude: 8.7),
        "KE": CLLocationCoordinate2D(latitude: 0.0, longitude: 37.9),
        "IL": CLLocationCoordinate2D(latitude: 31.0, longitude: 34.9),
        "CL": CLLocationCoordinate2D(latitude: -35.7, longitude: -71.5),
        "CO": CLLocationCoordinate2D(latitude: 4.6, longitude: -74.3),
        "PE": CLLocationCoordinate2D(latitude: -9.2, longitude: -75.0),
    ]
}

private enum DiscoverCitySearchVenueReloadConfig {
    static let radiusMiles = 25.0
}

fileprivate enum DiscoverLocationFetchResult {
    case coordinate(CLLocationCoordinate2D)
    case unavailable(reason: String)
}

struct BusinessVenueGeocodeResult: Sendable {
    let coordinate: CLLocationCoordinate2D
    let formattedAddress: String
}

struct BusinessVenueReverseGeocodeResult: Sendable {
    let addressLine1: String?
    let addressLine2: String?
    let locality: String?
    let region: String?
    let postalCode: String?
    let countryCode: String?
    let formattedAddress: String?
}

enum DiscoverVenueClusterTuning {
    private struct DenseDistrictBounds: Sendable {
        let latitude: ClosedRange<Double>
        let longitude: ClosedRange<Double>

        nonisolated func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
            latitude.contains(coordinate.latitude) && longitude.contains(coordinate.longitude)
        }
    }

    nonisolated private static let denseEntertainmentDistricts: [DenseDistrictBounds] = [
        // Las Vegas Strip / Paradise corridor.
        DenseDistrictBounds(latitude: 36.075...36.155, longitude: (-115.195)...(-115.140)),
        // Downtown Las Vegas / Fremont.
        DenseDistrictBounds(latitude: 36.160...36.185, longitude: (-115.160)...(-115.130)),
        // Miami Beach / South Beach.
        DenseDistrictBounds(latitude: 25.760...25.890, longitude: (-80.155)...(-80.110)),
        // Downtown Los Angeles / LA Live.
        DenseDistrictBounds(latitude: 34.030...34.070, longitude: (-118.285)...(-118.220)),
        // Manhattan.
        DenseDistrictBounds(latitude: 40.680...40.885, longitude: (-74.030)...(-73.905)),
        // Disney Springs / Lake Buena Vista.
        DenseDistrictBounds(latitude: 28.360...28.395, longitude: (-81.535)...(-81.490)),
        // Scottsdale entertainment district.
        DenseDistrictBounds(latitude: 33.485...33.515, longitude: (-111.945)...(-111.910)),
    ]

    nonisolated static func clusterKey(for coordinate: CLLocationCoordinate2D, visibleLatitudeDelta: Double) -> String {
        let gridSize = clusterGridSize(for: coordinate, visibleLatitudeDelta: visibleLatitudeDelta)
        let latKey = Int(coordinate.latitude / gridSize)
        let lonKey = Int(coordinate.longitude / gridSize)
        let gridKey = Int((gridSize * 1_000_000).rounded())
        return "g\(gridKey)-\(latKey)-\(lonKey)"
    }

    nonisolated static func clusterGridSize(for coordinate: CLLocationCoordinate2D, visibleLatitudeDelta: Double) -> Double {
        guard isDenseEntertainmentDistrict(coordinate) else {
            return visibleLatitudeDelta > 0.35 ? 0.08 : 0.035
        }

        if visibleLatitudeDelta > 0.35 {
            return 0.08
        } else if visibleLatitudeDelta > 0.18 {
            return 0.024
        } else if visibleLatitudeDelta > 0.08 {
            return 0.006
        } else if visibleLatitudeDelta > 0.035 {
            return 0.0025
        } else {
            return 0.0012
        }
    }

    nonisolated private static func isDenseEntertainmentDistrict(_ coordinate: CLLocationCoordinate2D) -> Bool {
        denseEntertainmentDistricts.contains { $0.contains(coordinate) }
    }
}

/// Watches for a late When-In-Use grant after startup timed out while authorization was still `.notDetermined`.
private final class DiscoverStartupLocationAuthObserver: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let onAuthorized: () -> Void
    private var hasFired = false

    init(onAuthorized: @escaping () -> Void) {
        self.onAuthorized = onAuthorized
        super.init()
    }

    func start() {
        manager.delegate = self
        let status = manager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            fireIfNeeded()
        }
    }

    func stop() {
        manager.delegate = nil
    }

    private func fireIfNeeded() {
        guard !hasFired else { return }
        hasFired = true
        onAuthorized()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            fireIfNeeded()
        case .denied, .restricted:
            fireIfNeeded() // handler no-ops GPS center; clears awaiting flag
        default:
            break
        }
    }
}

/// One-shot Core Location fetch for the Discover map “current location” control (no Utah/Lehi fallback).
private final class DiscoverCurrentLocationFetchSession: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<DiscoverLocationFetchResult, Never>?
    private let lock = NSLock()
    private var hasFinished = false
    private var timeoutTask: Task<Void, Never>?

    func fetchBestCoordinateOnce(timeoutSeconds: TimeInterval = 12) async -> DiscoverLocationFetchResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = kCLDistanceFilterNone

            let status = manager.authorizationStatus
#if DEBUG
            print("[CurrentLocationButton] permission=\(Self.authDebugLabel(status))")
#endif
            switch status {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            case .denied, .restricted:
                finishUnavailable(reason: "authorizationDeniedOrRestricted")
            @unknown default:
                finishUnavailable(reason: "unknownAuthorization")
            }

            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                guard let self else { return }
                let auth = self.manager.authorizationStatus
                if auth == .notDetermined {
                    self.finishUnavailable(reason: "timeoutWhileNotDetermined")
                } else {
                    self.finishUnavailable(reason: "timeout")
                }
            }
        }
    }

    private static func authDebugLabel(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private func tearDownLocationUpdates() {
        manager.stopUpdatingLocation()
        manager.delegate = nil
    }

    private func finishSuccess(_ coordinate: CLLocationCoordinate2D) {
        lock.lock()
        guard !hasFinished else {
            lock.unlock()
            return
        }
        hasFinished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        let cont = continuation
        continuation = nil
        lock.unlock()

        tearDownLocationUpdates()

        cont?.resume(returning: .coordinate(coordinate))
    }

    private func finishUnavailable(reason: String) {
        lock.lock()
        guard !hasFinished else {
            lock.unlock()
            return
        }
        hasFinished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        let cont = continuation
        continuation = nil
        lock.unlock()

        tearDownLocationUpdates()

        cont?.resume(returning: .unavailable(reason: reason))
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
#if DEBUG
        print("[CurrentLocationButton] permission=\(Self.authDebugLabel(status))")
#endif
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            finishUnavailable(reason: "authorizationDeniedOrRestricted")
        case .notDetermined:
            break
        @unknown default:
            finishUnavailable(reason: "unknownAuthorization")
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else {
            finishUnavailable(reason: "noLocationFix")
            return
        }
        let c = loc.coordinate
        guard CLLocationCoordinate2DIsValid(c) else {
            finishUnavailable(reason: "invalidCoordinate")
            return
        }
#if DEBUG
        print("[CurrentLocationButton] realLocation=\(c.latitude),\(c.longitude)")
#endif
        finishSuccess(c)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
#if DEBUG
        print("[CurrentLocationButton] locationManagerFailed error=\(error.localizedDescription)")
#endif
        finishUnavailable(reason: "locationError")
    }
}

extension MapViewModel {

    func recordCurrentUserLocation(_ coordinate: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        currentUserLocation = coordinate
    }

    /// Updates ``currentUserLocation`` when location permission is already granted (no new permission prompt).
    @discardableResult
    func refreshCurrentUserLocationIfAuthorized(timeoutSeconds: TimeInterval = 6) async -> Bool {
        let status = CLLocationManager().authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            return false
        }
        let session = DiscoverCurrentLocationFetchSession()
        let result = await session.fetchBestCoordinateOnce(timeoutSeconds: timeoutSeconds)
        guard case .coordinate(let coordinate) = result else {
            return false
        }
        recordCurrentUserLocation(coordinate)
        return true
    }

    func experience(for bar: BarVenue) -> VenueExperience? {
        venueExperiences.first { $0.venueName == bar.name }
    }

    func clusteredBars() -> [VenueCluster] {
        let source = mapVisibleBars
        guard !source.isEmpty else {
            discoverClusteredBarsCache = nil
            discoverClusteredBarsCacheKey = nil
            return []
        }

        let dayBucket = Int(selectedDate.timeIntervalSince1970 / 86400)
        let coordFingerprint = source.prefix(64).reduce(into: 0.0) { partial, bar in
            partial += bar.coordinate.latitude + bar.coordinate.longitude + Double(bar.games.count)
        }
        let idFingerprint = source.prefix(96).map { $0.id.uuidString.lowercased() }.joined(separator: ",")
        let cacheKey = "\(source.count)|\(idFingerprint)|\(dayBucket)|\(selectedSport)|\(mapDisplayMode.rawValue)|\(debouncedDiscoverSearchText.hashValue)|\(String(format: "%.5f", visibleLatitudeDelta))|\(String(format: "%.4f", coordFingerprint))"
        if cacheKey == discoverClusteredBarsCacheKey, let cached = discoverClusteredBarsCache {
            return cached
        }

        let grouped = Dictionary(grouping: source) { bar in
            DiscoverVenueClusterTuning.clusterKey(
                for: bar.coordinate,
                visibleLatitudeDelta: visibleLatitudeDelta
            )
        }

        let clusters = grouped.map { key, bars in
            let avgLat = bars.map { $0.coordinate.latitude }.reduce(0, +) / Double(bars.count)
            let avgLon = bars.map { $0.coordinate.longitude }.reduce(0, +) / Double(bars.count)
            return VenueCluster(
                id: "c-\(key)",
                bars: bars,
                coordinate: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
            )
        }

        discoverClusteredBarsCacheKey = cacheKey
        discoverClusteredBarsCache = clusters
        return clusters
    }

    func clusteredPickupPlaceBarsForDiscoverMap(rows: [BarVenue]) -> [VenueCluster] {
        let source = rows.filter { CLLocationCoordinate2DIsValid($0.coordinate) }
        guard !source.isEmpty else { return [] }

        let grouped = Dictionary(grouping: source) { bar in
            DiscoverVenueClusterTuning.clusterKey(
                for: bar.coordinate,
                visibleLatitudeDelta: visibleLatitudeDelta
            )
        }

        return grouped.map { key, bars in
            let avgLat = bars.map { $0.coordinate.latitude }.reduce(0, +) / Double(bars.count)
            let avgLon = bars.map { $0.coordinate.longitude }.reduce(0, +) / Double(bars.count)
            return VenueCluster(
                id: "pp-\(key)",
                bars: bars,
                coordinate: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
            )
        }
        .sorted { $0.id < $1.id }
    }

    /// Grid-bucketed pickup pins for Discover (same spacing idea as ``clusteredBars()``). Lightweight memo for map body churn.
    func clusteredPickupGamesForDiscoverMap(rows: [PickupGameRow]) -> [PickupGameCluster] {
        let withCoords = rows.filter { $0.latitude != nil && $0.longitude != nil }
        guard !withCoords.isEmpty else {
            discoverPickupClustersCache = nil
            discoverPickupClustersCacheKey = nil
            return []
        }

        let dayBucket = Int(selectedDate.timeIntervalSince1970 / 86400)
        let coordFingerprint = withCoords.prefix(48).reduce(into: 0.0) { partial, row in
            partial += (row.latitude ?? 0) + (row.longitude ?? 0)
        }
        let cacheKey = "\(withCoords.count)|\(dayBucket)|\(selectedSport)|\(debouncedDiscoverSearchText.hashValue)|\(String(format: "%.5f", visibleLatitudeDelta))|\(String(format: "%.4f", coordFingerprint))"
        if cacheKey == discoverPickupClustersCacheKey, let cached = discoverPickupClustersCache {
            return cached
        }

        var gridSize = 0.035
        if visibleLatitudeDelta > 0.35 {
            gridSize = 0.08
        }

        let grouped = Dictionary(grouping: withCoords) { row in
            let lat = row.latitude!
            let lon = row.longitude!
            let latKey = Int(lat / gridSize)
            let lonKey = Int(lon / gridSize)
            return "\(latKey)-\(lonKey)"
        }

        let clusters: [PickupGameCluster] = grouped.map { key, list in
            let avgLat = list.map { $0.latitude! }.reduce(0, +) / Double(list.count)
            let avgLon = list.map { $0.longitude! }.reduce(0, +) / Double(list.count)
            return PickupGameCluster(
                id: "p-\(key)",
                rows: list,
                coordinate: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
            )
        }
        .sorted { $0.id < $1.id }

        discoverPickupClustersCacheKey = cacheKey
        discoverPickupClustersCache = clusters
        return clusters
    }

    func invalidatePickupGameClusterAnnotationCache() {
        discoverPickupClustersCache = nil
        discoverPickupClustersCacheKey = nil
    }

    /// Zoom in on a multi-venue cluster (Discover); uses current span so repeated taps keep tightening.
    func zoomTowardCluster(center: CLLocationCoordinate2D) {
        let current = max(visibleLatitudeDelta, 0.02)
        let nextLat = max(min(current / 3.4, 1.4), 0.018)
        let nextLon = max(min(current / 3.4 * 1.08, 1.5), 0.018)
        cameraPosition = .region(
            MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: nextLat, longitudeDelta: nextLon)
            )
        )
    }

    /// Per-venue map energy using ``VenueMapEnergyScore`` (Going + vibes + unique commenters + LIVE).
    func mapPinEnergyScore(bar: BarVenue, gamesOnMapDay: [SportsEvent]) -> Int {
        mapPinEnergyBreakdown(bar: bar, gamesOnMapDay: gamesOnMapDay).total
    }

    func mapPinEnergyBreakdown(bar: BarVenue, gamesOnMapDay: [SportsEvent]) -> VenueMapEnergyScore.Breakdown {
        if let focused = discoverFocusedProGame?.externalGameId.trimmingCharacters(in: .whitespacesAndNewlines),
           !focused.isEmpty {
            let rows = venueEventRows.filter { row in
                guard row.venue_id == bar.id, row.id != nil else { return false }
                let rowGameID = row.external_game_id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard rowGameID == focused else { return false }
                let status = row.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                if !status.isEmpty, status != "active" { return false }
                return true
            }
            let activities: [VenueMapEnergyScore.EventActivity] = rows.compactMap { row in
                guard let eventID = row.id else { return nil }
                return VenueMapEnergyScore.eventActivity(
                    goingCount: interestCountForVenueEvent(eventID),
                    vibeCounts: venueEventVibeCounts[eventID] ?? [:],
                    uniqueCommenterCount: venueEventUniqueCommenterCounts[eventID] ?? 0,
                    isLiveNow: isVenueEventRowLiveNow(row)
                )
            }
            return VenueMapEnergyScore.score(events: activities)
        }

        var activities: [VenueMapEnergyScore.EventActivity] = []
        activities.reserveCapacity(gamesOnMapDay.count)
        for game in gamesOnMapDay {
            guard let id = cachedVenueEventID(for: bar, gameTitle: game.title) else { continue }
            let going = interestCountForVenueEvent(id)
            let vibes = venueEventVibeCounts[id] ?? [:]
            let commenters = venueEventUniqueCommenterCounts[id] ?? 0
            let live = hasLiveVenueEventNow(for: bar, game: game)
            activities.append(
                VenueMapEnergyScore.eventActivity(
                    goingCount: going,
                    vibeCounts: vibes,
                    uniqueCommenterCount: commenters,
                    isLiveNow: live
                )
            )
        }
        return VenueMapEnergyScore.score(events: activities)
    }

    private func hasLiveVenueEventNow(for bar: BarVenue, game: SportsEvent) -> Bool {
        hasLiveVenueEventNow(for: bar, events: [game])
    }

    /// Strongest venue energy in the cluster and that venue’s dominant sport glyph.
    func clusterVenueAnnotationEnergy(cluster: VenueCluster) -> (maxScore: Int, dominantSport: String?) {
        var maxScore = 0
        var dominantSport: String?
        for bar in cluster.bars {
            let gamesToday = selectedDayEventsForMap(bar)
            let score = mapPinEnergyScore(bar: bar, gamesOnMapDay: gamesToday)
            if score > maxScore {
                maxScore = score
                dominantSport = gamesToday.first?.sport ?? bar.primarySport
            }
        }
        return (maxScore, dominantSport)
    }

    /// Short label for cluster badge (aligned with ``VenueMapEnergyScore`` tiers).
    func mapClusterEnergyCaption(maxScore: Int) -> String? {
        VenueMapEnergyScore.tier(for: maxScore).clusterCaption
    }

    func centerMap(on bar: BarVenue, selectForPreview: Bool = true) {
        #if DEBUG
        let t0 = Date()
        #endif
        if selectForPreview {
            if let hold = discoverRemotePreviewHoldVenueId, hold != bar.id {
                discoverRemotePreviewHoldVenueId = nil
            }
            selectVenueForPreview(bar, source: "centerMap")
        }
        let spanVal = min(max(visibleLatitudeDelta * 0.35, 0.04), 0.35)
        cameraPosition = .region(
            MKCoordinateRegion(
                center: bar.coordinate,
                span: MKCoordinateSpan(latitudeDelta: spanVal, longitudeDelta: spanVal)
            )
        )
        #if DEBUG
        if selectForPreview {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[DiscoverPerf] venue preview open (centerMap) ms=\(ms) venue=\(bar.name)")
        }
        #endif
    }

    /// Centers the map on a coordinate (e.g. geocoded address) while optionally keeping a venue selected for the preview card.
    func centerMap(on coordinate: CLLocationCoordinate2D, selectedBar: BarVenue?) {
        if let selectedBar {
            if let hold = discoverRemotePreviewHoldVenueId, hold != selectedBar.id {
                discoverRemotePreviewHoldVenueId = nil
            }
            selectVenueForPreview(selectedBar, source: "centerMapCoordinate")
        }
        let spanVal = min(max(visibleLatitudeDelta * 0.35, 0.04), 0.35)
        cameraPosition = .region(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: spanVal, longitudeDelta: spanVal)
            )
        )
    }

    func searchMapLocation() {
        discoverSearchDebounceTask?.cancel()
        discoverSearchDebounceTask = nil

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            venueSearchResults = []
            debouncedDiscoverSearchText = ""
            return
        }

        debouncedDiscoverSearchText = q
        discoverClusteredBarsCacheKey = nil
        discoverClusteredBarsCache = nil

        let kind = discoverMapSearchKind(for: q)

        if q.count < 2 {
            Task { @MainActor [weak self] in
                guard let self else { return }
#if DEBUG
                let t0 = Date()
#endif
                if kind == .globalPlace {
                    self.venueSearchResults = []
                    if let coord = await self.geocodeAddress(q) {
                        self.cameraPosition = .region(
                            MKCoordinateRegion(
                                center: coord,
                                span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25)
                            )
                        )
                    }
#if DEBUG
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    print("[DiscoverMapSearchPerf] query=\"\(q)\" kind=\(kind.rawValue) candidates=\(self.venueSearchResults.count) elapsedMs=\(ms) cancelled=no")
#endif
                } else {
                    let localOnly = await self.discoverRegionBoundAppContentSearchOrderedDetached(query: q)
                    self.venueSearchResults = localOnly
#if DEBUG
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    print("[DiscoverMapSearchPerf] query=\"\(q)\" kind=\(kind.rawValue) candidates=\(localOnly.count) elapsedMs=\(ms) cancelled=no")
#endif
                }
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isDiscoverVenueSearchLoading = true
            defer { self.isDiscoverVenueSearchLoading = false }
#if DEBUG
            let t0 = Date()
#endif
            if kind == .globalPlace {
                let remote = await self.fetchDiscoverVenueSearchBars(query: q, useViewportTextSearchBounds: false)
                self.venueSearchResults = remote
#if DEBUG
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                print("[DiscoverMapSearchPerf] query=\"\(q)\" kind=\(kind.rawValue) candidates=\(remote.count) elapsedMs=\(ms) cancelled=no")
#endif
                if remote.isEmpty, let coord = await self.geocodeAddress(q) {
                    self.venueSearchResults = []
                    self.cameraPosition = .region(
                        MKCoordinateRegion(
                            center: coord,
                            span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25)
                        )
                    )
                }
                return
            }

            let localOrdered = await self.discoverRegionBoundAppContentSearchOrderedDetached(query: q)
            let remoteMatches = await self.fetchDiscoverVenueSearchBars(query: q, useViewportTextSearchBounds: false)
            var seen = Set(localOrdered.map(\.id))
            var merged: [BarVenue] = localOrdered
            for b in remoteMatches where seen.insert(b.id).inserted {
                merged.append(b)
            }
            self.venueSearchResults = merged
#if DEBUG
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[DiscoverMapSearchPerf] query=\"\(q)\" kind=\(kind.rawValue) candidates=\(merged.count) elapsedMs=\(ms) cancelled=no")
#endif
            if merged.isEmpty, let coord = await self.geocodeAddress(q) {
                self.venueSearchResults = []
                self.cameraPosition = .region(
                    MKCoordinateRegion(
                        center: coord,
                        span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25)
                    )
                )
            }
        }
    }

    func submitDiscoverAddressSearchFromReturn() async -> Bool {
        discoverSearchDebounceTask?.cancel()
        discoverSearchDebounceTask = nil

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            venueSearchResults = []
            debouncedDiscoverSearchText = ""
            return false
        }

        let kind = discoverMapSearchKind(for: q)
#if DEBUG
        print("[DiscoverSearchDebug] addressSearchSubmitted query=\(q)")
#endif

        isDiscoverVenueSearchLoading = true
        defer { isDiscoverVenueSearchLoading = false }

        if kind == .globalPlace, let resolution = await geocodeDiscoverAddressSearch(q) {
            applySuccessfulDiscoverAddressSearch(resolution: resolution, query: q)
            return true
        }

        let localOrdered = kind == .appContentRegionBound
            ? await discoverRegionBoundAppContentSearchOrderedDetached(query: q)
            : []
        let remoteMatches = await fetchDiscoverVenueSearchBars(query: q, useViewportTextSearchBounds: false)
        var seen = Set(localOrdered.map(\.id))
        var merged: [BarVenue] = localOrdered
        for bar in remoteMatches where seen.insert(bar.id).inserted {
            merged.append(bar)
        }

        if kind == .appContentRegionBound, merged.isEmpty, let resolution = await geocodeDiscoverAddressSearch(q) {
            applySuccessfulDiscoverAddressSearch(resolution: resolution, query: q)
            return true
        }

        debouncedDiscoverSearchText = q
        venueSearchResults = merged
        discoverClusteredBarsCacheKey = nil
        discoverClusteredBarsCache = nil
        discoverPickupClustersCacheKey = nil
        discoverPickupClustersCache = nil
        return false
    }

    private func applySuccessfulDiscoverAddressSearch(resolution: CitySearchVenueDebugContext, query: String) {
        selectedBar = nil
        selectedEvent = nil
        selectedPickupGameForMap = nil
        discoverRemotePreviewHoldVenueId = nil
        venueSearchResults = []
        searchText = ""
        debouncedDiscoverSearchText = ""
        discoverClusteredBarsCacheKey = nil
        discoverClusteredBarsCache = nil
        discoverPickupClustersCacheKey = nil
        discoverPickupClustersCache = nil
        pendingCitySearchVenueDebugContext = resolution
        cameraPosition = .region(
            MKCoordinateRegion(
                center: resolution.resolvedCoordinate,
                span: MKCoordinateSpan(
                    latitudeDelta: resolution.bounds.latSpan,
                    longitudeDelta: resolution.bounds.lonSpan
                )
            )
        )
#if DEBUG
        print("[CitySearchVenueDebug] query=\(query)")
        print("[CitySearchVenueDebug] resolvedCoordinate=\(resolution.resolvedCoordinate.latitude),\(resolution.resolvedCoordinate.longitude)")
        print("[CitySearchVenueDebug] resolvedCity=\(resolution.resolvedCity)")
        print("[CitySearchVenueDebug] resolvedState=\(resolution.resolvedState)")
        print("[CitySearchVenueDebug] radiusMiles=\(resolution.radiusMiles)")
        print("[CitySearchVenueDebug] bounds=\(Self.citySearchBoundsDescription(resolution.bounds))")
        print("[DiscoverSearchDebug] addressSearchClearedAfterSubmit=true")
#endif
    }

    private func geocodeDiscoverAddressSearch(_ address: String) async -> CitySearchVenueDebugContext? {
        guard let request = MKGeocodingRequest(addressString: address) else { return nil }
        do {
            guard let item = try await request.mapItems.first else {
                return nil
            }
            let coordinate = item.location.coordinate
            let radiusMiles = DiscoverCitySearchVenueReloadConfig.radiusMiles
            let bounds = Self.citySearchBounds(around: coordinate, radiusMiles: radiusMiles)
            let cityState = Self.discoverCitySearchLocationText(from: item)
            return CitySearchVenueDebugContext(
                query: address,
                resolvedCoordinate: coordinate,
                resolvedCity: cityState.city,
                resolvedState: cityState.state,
                radiusMiles: radiusMiles,
                bounds: bounds
            )
        } catch {
            return nil
        }
    }

    nonisolated private static func discoverCitySearchLocationText(from item: MKMapItem) -> (city: String, state: String) {
        if #available(iOS 26.0, *) {
            let representations = item.addressRepresentations
            let city = trimmedNonEmpty(representations?.cityName) ?? ""
            let lines = addressLines(from: representations, address: item.address)
            let regionPostal = stateAndPostalCode(from: lines, city: city)
            let state = stateAbbreviation(from: trimmedNonEmpty(representations?.cityWithContext), city: city)
                ?? regionPostal.state
                ?? ""
            return (city, state)
        }
        // Pre-iOS 26 unavailable while deployment target is 26+. Keep empty fallback shape.
        return ("", "")
    }

    nonisolated private static func citySearchBounds(
        around coordinate: CLLocationCoordinate2D,
        radiusMiles: Double
    ) -> DiscoverMapBoundsWindow {
        let latDelta = radiusMiles / 69.0
        let lonMilesPerDegree = max(cos(coordinate.latitude * .pi / 180) * 69.172, 0.01)
        let lonDelta = radiusMiles / lonMilesPerDegree
        return DiscoverMapBoundsWindow(
            minLat: coordinate.latitude - latDelta,
            maxLat: coordinate.latitude + latDelta,
            minLon: coordinate.longitude - lonDelta,
            maxLon: coordinate.longitude + lonDelta
        )
    }

    nonisolated private static func citySearchBoundsDescription(_ bounds: DiscoverMapBoundsWindow) -> String {
        String(
            format: "%.5f...%.5f,%.5f...%.5f",
            bounds.minLat,
            bounds.maxLat,
            bounds.minLon,
            bounds.maxLon
        )
    }

    func geocodeAddress(_ address: String) async -> CLLocationCoordinate2D? {
        guard let request = MKGeocodingRequest(addressString: address) else { return nil }
        do {
            let items = try await request.mapItems
            return items.first?.location.coordinate
        } catch {
            return nil
        }
    }

    func geocodeBusinessVenueAddress(_ query: String, fallbackFormattedAddress: String) async -> BusinessVenueGeocodeResult? {
#if DEBUG
        print("[InternationalAddressDebug] geocodeQuery=\(query)")
#endif
        guard let request = MKGeocodingRequest(addressString: query) else {
#if DEBUG
            print("[InternationalAddressDebug] addressValidation=geocodeRequestInvalid")
#endif
            return nil
        }
        do {
            let item = try await request.mapItems.first
            guard let coordinate = item?.location.coordinate else {
#if DEBUG
                print("[InternationalAddressDebug] addressValidation=geocodeNoResult")
#endif
                return nil
            }
            let formatted = Self.formattedBusinessVenueAddress(from: item) ?? fallbackFormattedAddress
#if DEBUG
            print("[InternationalAddressDebug] addressValidation=geocodeResolved")
            print("[InternationalAddressDebug] formattedAddress=\(formatted)")
            print("[InternationalAddressDebug] latitude=\(coordinate.latitude)")
            print("[InternationalAddressDebug] longitude=\(coordinate.longitude)")
#endif
            return BusinessVenueGeocodeResult(coordinate: coordinate, formattedAddress: formatted)
        } catch {
#if DEBUG
            print("[InternationalAddressDebug] addressValidation=geocodeFailed \(error.localizedDescription)")
#endif
            return nil
        }
    }

    func reverseGeocodeBusinessVenueLocation(for coordinate: CLLocationCoordinate2D) async -> BusinessVenueReverseGeocodeResult {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let result: BusinessVenueReverseGeocodeResult
        if #available(iOS 26.0, *) {
            // MapKit is the supported geocoder on iOS 26+ (`MKReverseGeocodingRequest` +
            // `MKAddressRepresentations` / `MKAddress`). No CLGeocoder / placemark path.
            result = await Self.businessVenueReverseGeocodeResultUsingMapKit(for: location)
        } else {
            // Pre-iOS 26 deployment path (inactive while IPHONEOS_DEPLOYMENT_TARGET >= 26).
            result = await Self.businessVenueReverseGeocodeResultUsingLegacyCLGeocoder(for: location)
        }
#if DEBUG
        if result.formattedAddress != nil || result.addressLine1 != nil {
            print("[InternationalAddressDebug] reverseGeocodeSuccess=true")
        } else {
            print("[InternationalAddressDebug] reverseGeocodeSuccess=false")
        }
        print(
            "[BusinessVenuePinSync] reverseGeocodeNormalized line1=\(result.addressLine1 ?? "") locality=\(result.locality ?? "") region=\(result.region ?? "") postal=\(result.postalCode ?? "") country=\(result.countryCode ?? "")"
        )
#endif
        return result
    }

    /// Legacy Core Location reverse geocode retained for potential future lower deployment targets.
    /// Isolated so the iOS 26 build path does not reference deprecated `CLGeocoder` APIs.
    @available(iOS, deprecated: 26.0, message: "Use MKReverseGeocodingRequest on iOS 26+")
    nonisolated private static func businessVenueReverseGeocodeResultUsingLegacyCLGeocoder(
        for location: CLLocation
    ) async -> BusinessVenueReverseGeocodeResult {
        // Intentionally empty on the current iOS 26+ deployment: CLGeocoder is deprecated and
        // must not be linked from the primary path. Callers on iOS 26+ use MapKit instead.
        _ = location
        return BusinessVenueReverseGeocodeResult(
            addressLine1: nil,
            addressLine2: nil,
            locality: nil,
            region: nil,
            postalCode: nil,
            countryCode: nil,
            formattedAddress: nil
        )
    }

    @available(iOS 26.0, *)
    nonisolated private static func businessVenueReverseGeocodeResultUsingMapKit(for location: CLLocation) async -> BusinessVenueReverseGeocodeResult {
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first else {
            return BusinessVenueReverseGeocodeResult(
                addressLine1: nil,
                addressLine2: nil,
                locality: nil,
                region: nil,
                postalCode: nil,
                countryCode: nil,
                formattedAddress: nil
            )
        }

        let representations = item.addressRepresentations
        let lines = addressLines(from: representations, address: item.address)
        let locality = trimmedNonEmpty(representations?.cityName)
        let cityContext = trimmedNonEmpty(representations?.cityWithContext)
        let regionPostal = stateAndPostalCode(from: lines, city: locality)
        let region = stateAbbreviation(from: cityContext, city: locality) ?? regionPostal.state
        let formatted = formattedBusinessVenueAddress(from: item)
        let countryCode = mapKitRegionCountryCode(from: representations)
            ?? countryCodeFromFormattedAddress(formatted)
            ?? countryCodeFromAddressLines(lines)

        return BusinessVenueReverseGeocodeResult(
            addressLine1: streetLine(from: lines, city: locality),
            addressLine2: nil,
            locality: locality,
            region: region,
            postalCode: regionPostal.postalCode,
            countryCode: countryCode,
            formattedAddress: formatted
        )
    }

    func fetchCurrentCoordinateForBusinessPin(timeoutSeconds: TimeInterval = 12) async -> CLLocationCoordinate2D? {
        let session = DiscoverCurrentLocationFetchSession()
        let result = await session.fetchBestCoordinateOnce(timeoutSeconds: timeoutSeconds)
        guard case .coordinate(let coordinate) = result else { return nil }
        recordCurrentUserLocation(coordinate)
        return coordinate
    }

    nonisolated static func distanceMeters(
        from lhs: CLLocationCoordinate2D,
        to rhs: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        let a = CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
        let b = CLLocation(latitude: rhs.latitude, longitude: rhs.longitude)
        return a.distance(from: b)
    }

    nonisolated private static func formattedBusinessVenueAddress(from item: MKMapItem?) -> String? {
        guard let item else { return nil }
        if #available(iOS 26.0, *) {
            let formatted = item.addressRepresentations?.fullAddress(includingRegion: true, singleLine: true)
                ?? item.address?.fullAddress
                ?? item.address?.shortAddress
            return trimmedNonEmpty(formatted)
        }
        return nil
    }

    @available(iOS 26.0, *)
    nonisolated private static func mapKitRegionCountryCode(from representations: MKAddressRepresentations?) -> String? {
        guard let representations else { return nil }
        // Refined Swift API for ObjC `regionCode` — ISO region such as "US".
        if let regionIdentifier = trimmedNonEmpty(representations.region?.identifier) {
            return BusinessLocationCountryPolicy.normalizedStoredCountryCode(regionIdentifier)
        }
        return countryCodeFromFormattedAddress(trimmedNonEmpty(representations.regionName))
    }

    /// Reverse geocode for pickup map pin (street line, city, state, postal code); all nil if lookup fails.
    func reverseGeocodeAddressFields(for coordinate: CLLocationCoordinate2D) async -> (
        street: String?,
        city: String?,
        state: String?,
        postalCode: String?
    ) {
#if DEBUG
        print("[PickupLocationDebug] reverseGeocodeStarted coordinate=\(coordinate.latitude),\(coordinate.longitude)")
#endif
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        do {
            let fields: (street: String?, city: String?, state: String?, postalCode: String?)
            if #available(iOS 26.0, *) {
                fields = try await Self.reverseGeocodedAddressFieldsUsingMapKit(for: location)
            } else {
                fields = await Self.reverseGeocodedAddressFieldsUsingLegacyCLGeocoder(for: location)
            }
#if DEBUG
            print("[PickupLocationDebug] reverseGeocodeResult street=\(fields.street ?? "")")
            print("[PickupLocationDebug] reverseGeocodeResult city=\(fields.city ?? "")")
            print("[PickupLocationDebug] reverseGeocodeResult state=\(fields.state ?? "")")
            print("[PickupLocationDebug] reverseGeocodeResult postalCode=\(fields.postalCode ?? "")")
#endif
            return fields
        } catch {
#if DEBUG
            print("[PickupLocationDebug] reverseGeocodeResult street=")
            print("[PickupLocationDebug] reverseGeocodeResult city=")
            print("[PickupLocationDebug] reverseGeocodeResult state=")
            print("[PickupLocationDebug] reverseGeocodeResult postalCode=")
#endif
            return (nil, nil, nil, nil)
        }
    }

    @available(iOS, deprecated: 26.0, message: "Use MKReverseGeocodingRequest on iOS 26+")
    nonisolated private static func reverseGeocodedAddressFieldsUsingLegacyCLGeocoder(
        for location: CLLocation
    ) async -> (street: String?, city: String?, state: String?, postalCode: String?) {
        // Inactive while deployment target is iOS 26+; keeps the availability branch shape without
        // referencing deprecated CLGeocoder APIs in the modern build.
        _ = location
        return (nil, nil, nil, nil)
    }

    /// iOS 26+ reverse geocoding via ``MKReverseGeocodingRequest``.
    /// Field extraction uses MapKit address representations only (no deprecated placemark path).
    @available(iOS 26.0, *)
    nonisolated private static func reverseGeocodedAddressFieldsUsingMapKit(for location: CLLocation) async throws -> (
        street: String?,
        city: String?,
        state: String?,
        postalCode: String?
    ) {
        guard let request = MKReverseGeocodingRequest(location: location) else {
            return (nil, nil, nil, nil)
        }

        let item = try await request.mapItems.first
        let representations = item?.addressRepresentations
        let lines = Self.addressLines(from: representations, address: item?.address)
        let city = Self.trimmedNonEmpty(representations?.cityName)
        let cityContext = Self.trimmedNonEmpty(representations?.cityWithContext)
        let street = Self.streetLine(from: lines, city: city)
        let statePostal = Self.stateAndPostalCode(from: lines, city: city)
        let state = Self.stateAbbreviation(from: cityContext, city: city) ?? statePostal.state
        let postalCode = statePostal.postalCode

        return (street, city, state, postalCode)
    }

    @available(iOS 26.0, *)
    nonisolated private static func addressLines(from representations: MKAddressRepresentations?, address: MKAddress?) -> [String] {
        let addressText = representations?.fullAddress(includingRegion: false, singleLine: false)
            ?? address?.fullAddress
            ?? address?.shortAddress
        return addressText?
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
    }

    nonisolated private static func streetLine(from lines: [String], city: String?) -> String? {
        guard let city, !city.isEmpty else { return lines.first }
        // Prefer a true street/thoroughfare line over the "City, ST ZIP" line.
        // Do not reject landmark names that merely contain the city as a substring (e.g. "Provo Bay").
        if let street = lines.first(where: { line in
            !isCityStatePostalLine(line, city: city)
        }) {
            return street
        }
        return lines.first
    }

    nonisolated private static func isCityStatePostalLine(_ line: String, city: String) -> Bool {
        guard line.localizedCaseInsensitiveContains(city), line.contains(",") else { return false }
        let remainder = line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
        guard remainder.count == 2 else { return false }
        let left = remainder[0].trimmingCharacters(in: .whitespacesAndNewlines)
        return left.caseInsensitiveCompare(city) == .orderedSame
    }

    nonisolated private static func countryCodeFromFormattedAddress(_ formatted: String?) -> String? {
        guard let formatted else { return nil }
        let parts = formatted
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let last = parts.last else { return nil }
        return BusinessLocationCountryPolicy.supportedCountryCodes.first {
            BusinessLocationCountryPolicy.countryName(for: $0).caseInsensitiveCompare(last) == .orderedSame
        }
    }

    nonisolated private static func countryCodeFromAddressLines(_ lines: [String]) -> String? {
        guard let last = lines.last else { return nil }
        return countryCodeFromFormattedAddress(last)
    }

    nonisolated private static func stateAbbreviation(from cityContext: String?, city: String?) -> String? {
        guard
            let cityContext,
            let city,
            cityContext.localizedCaseInsensitiveContains(city),
            let commaIndex = cityContext.firstIndex(of: ",")
        else {
            return nil
        }

        let remainder = cityContext[cityContext.index(after: commaIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.split(separator: ",").first.map(String.init).flatMap(Self.trimmedNonEmpty)
    }

    nonisolated private static func stateAndPostalCode(from lines: [String], city: String?) -> (state: String?, postalCode: String?) {
        guard
            let city,
            let cityLine = lines.first(where: { $0.localizedCaseInsensitiveContains(city) }),
            let commaIndex = cityLine.firstIndex(of: ",")
        else {
            return (nil, nil)
        }

        let statePostal = cityLine[cityLine.index(after: commaIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = statePostal.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        return (
            pieces.first.flatMap(Self.trimmedNonEmpty),
            pieces.dropFirst().first.flatMap(Self.trimmedNonEmpty)
        )
    }

    nonisolated private static func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// Discover “my location” control: centers on a real GPS fix using the same span rule as ``centerMap(on:selectedBar:)`` (not Utah/Lehi fallback).
    @discardableResult
    func centerDiscoverMapOnUserPhysicalLocationIfPossible() async -> Bool {
        let session = DiscoverCurrentLocationFetchSession()
        let result = await session.fetchBestCoordinateOnce(timeoutSeconds: 12)
        guard case .coordinate(let coordinate) = result else {
#if DEBUG
            print("[CurrentLocationButton] noRealLocationAvailable requestingPermissionOrUpdate")
#endif
            return false
        }
        let spanVal = min(max(visibleLatitudeDelta * 0.35, 0.04), 0.35)
        recordCurrentUserLocation(coordinate)
        applyDiscoverCameraRegion(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: spanVal, longitudeDelta: spanVal)
            ),
            programmatic: true
        )
#if DEBUG
        print("[CurrentLocationButton] centeredMapOnUserLocation")
#endif
        return true
    }

    private static let startupDiscoverInitialRadiusMiles: Double = 9

    /// Programmatic Discover camera write (startup / my-location / search). Marks the write so
    /// ``onMapCameraChange`` does not treat it as user intent during startup.
    func applyDiscoverCameraRegion(_ region: MKCoordinateRegion, programmatic: Bool) {
        if programmatic {
            discoverProgrammaticCameraWriteGeneration += 1
            let generation = discoverProgrammaticCameraWriteGeneration
            discoverProgrammaticCameraWritePending = true
            cameraPosition = .region(region)
            visibleLatitudeDelta = region.span.latitudeDelta
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(750))
                guard let self else { return }
                guard self.discoverProgrammaticCameraWriteGeneration == generation else { return }
                self.discoverProgrammaticCameraWritePending = false
            }
        } else {
            cameraPosition = .region(region)
            visibleLatitudeDelta = region.span.latitudeDelta
        }
    }

    /// Called from Discover when the user pans/zooms. Blocks later startup GPS/locale snaps.
    func noteDiscoverUserCameraInteractionIfStartupPending() {
        guard !discoverProgrammaticCameraWritePending else { return }
        // Any explicit pan/zoom on a provisional broad camera becomes a trusted user viewport.
        if !discoverStartupCameraBasis.isTrustedForGeographicFetch {
            discoverStartupCameraOverrideEnabled = false
            discoverStartupCameraBasis = .userInteraction
#if DEBUG
            print("[StartupDiscover] userCameraIntent=preserved skippingLaterAutomaticCenter")
            print("[StartupMapRegionDebug] basis=userInteraction")
#endif
            return
        }
        let shouldPreserve =
            !didFinishStartupDiscoverPrepare
            || startupAwaitingLateLocationAuthorization
        guard shouldPreserve else { return }
        discoverStartupCameraOverrideEnabled = false
        discoverStartupCameraBasis = .userInteraction
#if DEBUG
        print("[StartupDiscover] userCameraIntent=preserved skippingLaterAutomaticCenter")
        print("[StartupMapRegionDebug] basis=userInteraction")
#endif
    }

    /// Whether the current camera span is narrow enough for a normal Discover geographic network load.
    func discoverGeographicNetworkFetchAllowed() -> Bool {
        guard let bounds = currentMapRegionBounds() else {
#if DEBUG
            print("[StartupDiscover] broadFetchSkipped reason=noCameraBounds basis=\(discoverStartupCameraBasis.rawValue)")
#endif
            return false
        }
        let latSpan = bounds.maxLat - bounds.minLat
        let lonSpan = bounds.maxLon - bounds.minLon
        if latSpan > DiscoverMapRegionDefaults.geographicFetchMaxSpanDegrees
            || lonSpan > DiscoverMapRegionDefaults.geographicFetchMaxSpanDegrees {
#if DEBUG
            print(
                "[StartupDiscover] broadFetchSkipped reason=viewportTooBroad "
                    + "latSpan=\(String(format: "%.2f", latSpan)) lonSpan=\(String(format: "%.2f", lonSpan)) "
                    + "basis=\(discoverStartupCameraBasis.rawValue) maxSpan=\(DiscoverMapRegionDefaults.geographicFetchMaxSpanDegrees)"
            )
#endif
            return false
        }
        return true
    }

    /// Startup: optional GPS center + local region. Does not itself fetch venues.
    /// Runs once per launch for the initial attempt; late permission grant may refine via ``handleLateStartupLocationAuthorizationGranted()``.
    func prepareInitialDiscoverRegionAndPreload() async {
        guard !didFinishStartupDiscoverPrepare else { return }
        defer {
            didFinishStartupDiscoverPrepare = true
            startupDiscoverPreloadCompletionLogPending = true
        }

        let session = DiscoverCurrentLocationFetchSession()
        let result = await session.fetchBestCoordinateOnce(timeoutSeconds: 3)

        guard discoverStartupCameraOverrideEnabled else {
            discoverStartupCameraBasis = .userInteraction
#if DEBUG
            print("[StartupDiscover] skippedAutomaticCenter reason=userCameraIntent")
            print("[StartupMapRegionDebug] basis=userInteraction")
#endif
            return
        }

        switch result {
        case .coordinate(let c):
#if DEBUG
            print("[StartupDiscover] userLocationFound lat=\(c.latitude) lon=\(c.longitude)")
            print("[StartupDiscover] usingInitialRadiusMiles=\(Self.startupDiscoverInitialRadiusMiles)")
#endif
            recordCurrentUserLocation(c)
            let region = Self.discoverStartupMKRegion(center: c, radiusMiles: Self.startupDiscoverInitialRadiusMiles)
            applyDiscoverCameraRegion(region, programmatic: true)
            discoverStartupCameraBasis = .gps
#if DEBUG
            print("[StartupMapRegionDebug] initialSpan=\(region.span.latitudeDelta),\(region.span.longitudeDelta)")
            print("[StartupMapRegionDebug] basis=gps")
#endif
        case .unavailable(let reason):
            if reason == "timeoutWhileNotDetermined" {
                startupAwaitingLateLocationAuthorization = true
                applyProvisionalStartupCameraFallback(reason: reason)
                startLateStartupLocationAuthorizationObserverIfNeeded()
#if DEBUG
                print("[StartupDiscover] awaitingLateAuthorization=true")
#endif
            } else {
                applyProvisionalStartupCameraFallback(reason: reason)
            }
        }

#if DEBUG
        print("[StartupDiscover] preloadStarted basis=\(discoverStartupCameraBasis.rawValue)")
#endif
    }

    private func applyProvisionalStartupCameraFallback(reason: String) {
        if let lastKnown = currentUserLocation {
            let region = Self.discoverStartupMKRegion(
                center: lastKnown,
                radiusMiles: Self.startupDiscoverInitialRadiusMiles
            )
            applyDiscoverCameraRegion(region, programmatic: true)
            discoverStartupCameraBasis = .lastKnownLocation
#if DEBUG
            print("[StartupDiscover] fallbackToLastKnownSessionLocation reason=\(reason)")
            print("[StartupMapRegionDebug] basis=lastKnownLocation")
#endif
        } else if let localeRegion = DiscoverMapRegionDefaults.coarseRegionForDeviceLocale() {
            applyDiscoverCameraRegion(localeRegion, programmatic: true)
            discoverStartupCameraBasis = .deviceRegion
#if DEBUG
            print("[StartupDiscover] fallbackToDeviceLocaleRegion reason=\(reason)")
            print("[StartupMapRegionDebug] basis=deviceRegion")
#endif
        } else {
            applyDiscoverCameraRegion(DiscoverMapRegionDefaults.worldRegion, programmatic: true)
            discoverStartupCameraBasis = .world
#if DEBUG
            print("[StartupDiscover] fallbackToNeutralWorldRegion reason=\(reason)")
            print("[StartupMapRegionDebug] basis=world")
#endif
        }
    }

    /// After a permission dialog was still pending when the startup location timeout fired.
    func handleLateStartupLocationAuthorizationGranted() async {
        guard startupAwaitingLateLocationAuthorization else { return }
        guard discoverStartupCameraOverrideEnabled else {
            startupAwaitingLateLocationAuthorization = false
            stopLateStartupLocationAuthorizationObserver()
#if DEBUG
            print("[StartupDiscover] lateGPSSkipped reason=userCameraIntent")
#endif
            return
        }

        let status = CLLocationManager().authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            if status == .denied || status == .restricted {
                startupAwaitingLateLocationAuthorization = false
                stopLateStartupLocationAuthorizationObserver()
#if DEBUG
                print("[StartupDiscover] lateAuthorizationDenied")
#endif
            }
            return
        }

        let session = DiscoverCurrentLocationFetchSession()
        let result = await session.fetchBestCoordinateOnce(timeoutSeconds: 8)
        guard case .coordinate(let c) = result else { return }
        guard discoverStartupCameraOverrideEnabled else {
            startupAwaitingLateLocationAuthorization = false
            stopLateStartupLocationAuthorizationObserver()
            return
        }

        recordCurrentUserLocation(c)
        let region = Self.discoverStartupMKRegion(center: c, radiusMiles: Self.startupDiscoverInitialRadiusMiles)
        applyDiscoverCameraRegion(region, programmatic: true)
        discoverStartupCameraBasis = .gps
        startupAwaitingLateLocationAuthorization = false
        stopLateStartupLocationAuthorizationObserver()
#if DEBUG
        print("[StartupDiscover] lateGPSApplied lat=\(c.latitude) lon=\(c.longitude)")
        print("[StartupMapRegionDebug] basis=gps")
#endif
        applyPendingDiscoverCoreSnapshotIfGeographicallyRelevant()
        await refreshDiscoverCoreInBackground(forceVenueRefresh: true)
    }

    private func startLateStartupLocationAuthorizationObserverIfNeeded() {
        guard lateStartupLocationAuthObserver == nil else { return }
        let observer = DiscoverStartupLocationAuthObserver { [weak self] in
            Task { @MainActor in
                await self?.handleLateStartupLocationAuthorizationGranted()
            }
        }
        lateStartupLocationAuthObserver = observer
        observer.start()
#if DEBUG
        print("[StartupDiscover] lateAuthorizationObserverStarted=true")
#endif
    }

    private func stopLateStartupLocationAuthorizationObserver() {
        (lateStartupLocationAuthObserver as? DiscoverStartupLocationAuthObserver)?.stop()
        lateStartupLocationAuthObserver = nil
    }

    private static func discoverStartupMKRegion(center: CLLocationCoordinate2D, radiusMiles: Double) -> MKCoordinateRegion {
        let latHalf = radiusMiles / 69.0
        let cosLat = max(cos(center.latitude * .pi / 180.0), 0.01)
        let lonMilesPerDegree = cosLat * 69.172
        let lonHalf = radiusMiles / lonMilesPerDegree
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: max(latHalf * 2, 0.02),
                longitudeDelta: max(lonHalf * 2, 0.02)
            )
        )
    }

    /// Axis-aligned bounds of the current map camera region (Supabase venue windowing).
    func currentMapRegionBounds() -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)? {
        guard let region = cameraPosition.region else { return nil }
        let center = region.center
        let span = region.span
        let minLat = center.latitude - span.latitudeDelta / 2
        let maxLat = center.latitude + span.latitudeDelta / 2
        let minLon = center.longitude - span.longitudeDelta / 2
        let maxLon = center.longitude + span.longitudeDelta / 2
        return (minLat, maxLat, minLon, maxLon)
    }

    // MARK: - Discover activity panel viewed locality

    /// Coarse bucket (~0.05°) so small pans do not thrash reverse geocode.
    static func discoverActivityLocalityBucket(
        for coordinate: CLLocationCoordinate2D
    ) -> (lat: Int, lng: Int) {
        (
            lat: Int((coordinate.latitude * 20).rounded()),
            lng: Int((coordinate.longitude * 20).rounded())
        )
    }

    /// Drop stale city names immediately when the settled viewport changes materially.
    func invalidateDiscoverSettledViewedLocality(reason: String) {
        discoverViewedLocalityResolveTask?.cancel()
        discoverViewedLocalityResolveTask = nil
        if discoverSettledViewedLocalityLabel != nil {
            discoverSettledViewedLocalityLabel = nil
        }
        discoverViewedLocalityCenterBucket = nil
#if DEBUG
        print("[DiscoverActivityLocality] invalidated reason=\(reason)")
#endif
    }

    /// After map settle: reverse-geocode map center once per coarse bucket when pins lack a city.
    /// Cancels any prior in-flight resolve. Never blocks map interaction.
    func scheduleDiscoverSettledViewedLocalityResolve(
        center: CLLocationCoordinate2D,
        pinDerivedLocality: String?
    ) {
        guard CLLocationCoordinate2DIsValid(center) else { return }
        let bucket = Self.discoverActivityLocalityBucket(for: center)

        if let pinDerivedLocality {
            let trimmed = pinDerivedLocality.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 2 {
                discoverViewedLocalityResolveTask?.cancel()
                discoverViewedLocalityResolveTask = nil
                discoverViewedLocalityCenterBucket = bucket
                if discoverSettledViewedLocalityLabel != trimmed {
                    discoverSettledViewedLocalityLabel = trimmed
                }
                return
            }
        }

        if discoverViewedLocalityCenterBucket?.lat == bucket.lat,
           discoverViewedLocalityCenterBucket?.lng == bucket.lng,
           let existing = discoverSettledViewedLocalityLabel,
           !existing.isEmpty {
            return
        }

        if discoverViewedLocalityCenterBucket?.lat != bucket.lat
            || discoverViewedLocalityCenterBucket?.lng != bucket.lng {
            discoverViewedLocalityCenterBucket = bucket
            if discoverSettledViewedLocalityLabel != nil {
                discoverSettledViewedLocalityLabel = nil
            }
        }

        discoverViewedLocalityResolveTask?.cancel()
        discoverViewedLocalityResolveTask = Task { @MainActor in
            let fields = await reverseGeocodeAddressFields(for: center)
            guard !Task.isCancelled else { return }
            guard discoverViewedLocalityCenterBucket?.lat == bucket.lat,
                  discoverViewedLocalityCenterBucket?.lng == bucket.lng else { return }

            let city = (fields.city ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard city.count >= 2 else { return }
            let state = (fields.state ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = state.isEmpty ? city : "\(city), \(state)"
            let label = DiscoverActivityPanelPresentationBuilder.formatLocalityForDisplay(raw)
            guard !label.isEmpty else { return }
            discoverSettledViewedLocalityLabel = label
#if DEBUG
            print("[DiscoverActivityLocality] resolved label=\(label)")
#endif
        }
    }

    /// Nearby vs Viewing with hysteresis to avoid flicker near the threshold.
    /// Enter Viewing when beyond the Suggested Fans radius; re-enter Nearby slightly inside it.
    func discoverActivityPanelIsNearUser(distanceMeters: CLLocationDistance) -> Bool {
        let nearbyRadiusMeters = SuggestedFansProduct.nearbyRadiusMiles * 1609.344
        let enterNearbyMeters = nearbyRadiusMeters * 0.85
        let leaveNearbyMeters = nearbyRadiusMeters * 1.12

        let latched = discoverActivityPanelNearUserLatched
        let next: Bool
        if let latched {
            if latched {
                next = distanceMeters <= leaveNearbyMeters
            } else {
                next = distanceMeters <= enterNearbyMeters
            }
        } else {
            next = distanceMeters <= nearbyRadiusMeters
        }
        discoverActivityPanelNearUserLatched = next
        return next
    }
}
