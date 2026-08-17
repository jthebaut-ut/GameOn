import CoreLocation
import Foundation
import MapKit
import SwiftUI

private let discoverFanTeamsRegionalCacheTTL: TimeInterval = 180
private let discoverFanTeamsRegionalCacheMaxEntries = 12

extension MapViewModel {
    private var discoverFanTeamsCurrentFetchKey: String {
        guard let bounds = currentMapRegionBounds() else { return "no-bounds" }
        let sportKey = selectedSport.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            String(format: "%.4f", bounds.minLat),
            String(format: "%.4f", bounds.maxLat),
            String(format: "%.4f", bounds.minLon),
            String(format: "%.4f", bounds.maxLon),
            sportKey.isEmpty ? "all-sports" : sportKey.lowercased()
        ].joined(separator: "|")
    }

    func refreshDiscoverableFanTeamsForMap(force: Bool = false) async {
        guard force || (discoverMapContentMode == .pickupGames && discoverPickupSubMode == .places) else { return }
        guard discoverGeographicNetworkFetchAllowed(), let bounds = currentMapRegionBounds() else {
            isLoadingDiscoverableFanTeamsForMap = false
            return
        }

        let fetchKey = discoverFanTeamsCurrentFetchKey
        if !force, fetchKey == lastDiscoverFanTeamsFetchKey, !discoverableFanTeamsForMap.isEmpty {
            return
        }

        let requestID = UUID()
        discoverFanTeamsRequestID = requestID
        let cached = discoverFanTeamsRegionalCache[fetchKey]
        let cachedIsFresh = cached.map { Date().timeIntervalSince($0.fetchedAt) < discoverFanTeamsRegionalCacheTTL } ?? false
        if !force, let cached {
            discoverableFanTeamsForMap = cached.rows
            lastDiscoverFanTeamsFetchKey = fetchKey
            isLoadingDiscoverableFanTeamsForMap = false
            if cachedIsFresh {
                pruneSelectedDiscoverableFanTeamIfNeeded()
                return
            }
        } else {
            isLoadingDiscoverableFanTeamsForMap = true
        }

        let sport = selectedSport.trimmingCharacters(in: .whitespacesAndNewlines)
        let sportParam: String? = (sport.isEmpty || sport.caseInsensitiveCompare("All") == .orderedSame)
            ? nil
            : sport

        do {
            let rows = try await FanTeamsService().listDiscoverableFanTeamsInBounds(
                minLat: bounds.minLat,
                maxLat: bounds.maxLat,
                minLon: bounds.minLon,
                maxLon: bounds.maxLon,
                sport: sportParam
            )
            guard discoverFanTeamsRequestID == requestID else { return }
            discoverableFanTeamsForMap = rows
            lastDiscoverFanTeamsFetchKey = fetchKey
            storeDiscoverFanTeamsRegionalCache(rows, fetchKey: fetchKey)
            isLoadingDiscoverableFanTeamsForMap = false
            pruneSelectedDiscoverableFanTeamIfNeeded()
        } catch {
            guard discoverFanTeamsRequestID == requestID else { return }
            isLoadingDiscoverableFanTeamsForMap = false
#if DEBUG
            print("[DiscoverFanTeams] fetchFailed error=\(error.localizedDescription) key=\(fetchKey)")
#endif
        }
    }

    private func storeDiscoverFanTeamsRegionalCache(_ rows: [DiscoverableFanTeamMapRow], fetchKey: String) {
        discoverFanTeamsRegionalCache[fetchKey] = (rows, Date())
        if discoverFanTeamsRegionalCache.count > discoverFanTeamsRegionalCacheMaxEntries {
            let oldest = discoverFanTeamsRegionalCache.min { $0.value.fetchedAt < $1.value.fetchedAt }?.key
            if let oldest {
                discoverFanTeamsRegionalCache.removeValue(forKey: oldest)
            }
        }
    }

    func discoverableFanTeamsVisibleAsMapPins(
        for bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)? = nil
    ) -> [DiscoverableFanTeamMapRow] {
        var rows = discoverableFanTeamsForMap.filter { team in
            guard CLLocationCoordinate2DIsValid(team.coordinate) else { return false }
            if let bounds {
                guard team.latitude >= bounds.minLat,
                      team.latitude <= bounds.maxLat,
                      team.longitude >= bounds.minLon,
                      team.longitude <= bounds.maxLon else { return false }
            }
            return true
        }

        let selected = selectedSport.trimmingCharacters(in: .whitespacesAndNewlines)
        if selected != "All" {
            rows = rows.filter { discoverableTeam($0, matchesSport: selected) }
        }

        let q = effectiveDiscoverSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return rows }
        return rows.filter { discoverableTeam($0, matchesSearch: q) }
    }

    var discoverVisibleFanTeamCount: Int {
        discoverableFanTeamsVisibleAsMapPins(for: currentMapRegionBounds()).count
    }

    func discoverableTeam(_ team: DiscoverableFanTeamMapRow, matchesSport selected: String) -> Bool {
        AppSportCatalog.sport(team.sport, matchesDiscoverSelection: selected)
            || SportFilterCatalog.storedSport(team.sport, matchesSearchQuery: selected)
            || SportSubtypeCatalog.matchesSearch(sport: team.sport, subtype: team.sportSubtype, query: selected)
    }

    func discoverableTeam(_ team: DiscoverableFanTeamMapRow, matchesSearch query: String) -> Bool {
        if team.name.localizedCaseInsensitiveContains(query) { return true }
        if team.sport.localizedCaseInsensitiveContains(query) { return true }
        if AppSportCatalog.sport(team.sport, matchesDiscoverSelection: query) { return true }
        if SportSubtypeCatalog.matchesSearch(sport: team.sport, subtype: team.sportSubtype, query: query) {
            return true
        }
        if team.localityDisplayLine().localizedCaseInsensitiveContains(query) { return true }
        if let place = team.placeName, place.localizedCaseInsensitiveContains(query) { return true }
        return false
    }

    func clusteredDiscoverableFanTeamsForMap(rows: [DiscoverableFanTeamMapRow]) -> [DiscoverableFanTeamCluster] {
        let source = rows.filter { CLLocationCoordinate2DIsValid($0.coordinate) }
        guard !source.isEmpty else { return [] }
        let grouped = Dictionary(grouping: source) { team in
            DiscoverVenueClusterTuning.clusterKey(
                for: team.coordinate,
                visibleLatitudeDelta: visibleLatitudeDelta
            )
        }
        return grouped.map { key, teams in
            let avgLat = teams.map(\.latitude).reduce(0, +) / Double(teams.count)
            let avgLon = teams.map(\.longitude).reduce(0, +) / Double(teams.count)
            return DiscoverableFanTeamCluster(
                id: "discover-team-\(key)",
                rows: teams,
                coordinate: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
            )
        }
        .sorted { $0.id < $1.id }
    }

    func selectDiscoverableFanTeamOnMap(_ team: DiscoverableFanTeamMapRow) {
        selectedBar = nil
        selectedEvent = nil
        selectedPickupGameForMap = nil
        selectedPickupPlaceForMap = nil
        discoverRemotePreviewHoldVenueId = nil
        selectedDiscoverableFanTeamForMap = team
    }

    func centerMap(on team: DiscoverableFanTeamMapRow, selectForPreview: Bool = true) {
        if selectForPreview {
            selectDiscoverableFanTeamOnMap(team)
        }
        let spanVal = min(max(visibleLatitudeDelta * 0.35, 0.04), 0.35)
        cameraPosition = .region(
            MKCoordinateRegion(
                center: team.coordinate,
                span: MKCoordinateSpan(latitudeDelta: spanVal, longitudeDelta: spanVal)
            )
        )
    }

    func pruneSelectedDiscoverableFanTeamIfNeeded() {
        guard let selected = selectedDiscoverableFanTeamForMap else { return }
        if !discoverableFanTeamsForMap.contains(where: { $0.id == selected.id }) {
            selectedDiscoverableFanTeamForMap = nil
        }
    }

    func distanceMiles(to team: DiscoverableFanTeamMapRow) -> Double? {
        guard let user = currentUserLocation,
              CLLocationCoordinate2DIsValid(user),
              CLLocationCoordinate2DIsValid(team.coordinate) else { return nil }
        let from = CLLocation(latitude: user.latitude, longitude: user.longitude)
        let to = CLLocation(latitude: team.latitude, longitude: team.longitude)
        return from.distance(from: to) / 1609.344
    }
}