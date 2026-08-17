import Foundation
import Supabase

enum FanTeamLocationServiceError: LocalizedError {
    case notAuthenticated
    case listFailed
    case saveFailed
    case updateFailed
    case removeFailed
    case clearFailed
    case usageFailed
    case incompleteLocation

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not authenticated"
        case .listFailed: return "Could not load Team locations"
        case .saveFailed: return "Could not save Team location"
        case .updateFailed: return "Could not update Team location"
        case .removeFailed: return "Could not remove saved location"
        case .clearFailed: return "Could not clear recent locations"
        case .usageFailed: return "Could not update location usage"
        case .incompleteLocation: return "Location is incomplete"
        }
    }
}

final class FanTeamLocationService {
    private let client: SupabaseClient

    init(client: SupabaseClient = supabase) {
        self.client = client
    }

    func listLocations(teamId: UUID) async throws -> [FanTeamLocation] {
        struct Params: Encodable { let p_team_id: UUID }
        do {
            let rows: [FanTeamLocation] = try await client
                .rpc("list_fan_team_locations", params: Params(p_team_id: teamId))
                .execute()
                .value
            let split = FanTeamLocationPresentation.split(locations: rows)
            TeamLocationDebug.log(
                "savedLocationsLoaded",
                detail: "teamID=\(teamId.uuidString.lowercased()) count=\(split.saved.count)"
            )
            TeamLocationDebug.log(
                "recentLocationsLoaded",
                detail: "teamID=\(teamId.uuidString.lowercased()) count=\(split.recent.count)"
            )
            return rows
        } catch {
            TeamLocationDebug.log(
                "savedLocationsLoaded",
                detail: "teamID=\(teamId.uuidString.lowercased()) error=\(error.localizedDescription)"
            )
            throw map(error, fallback: .listFailed)
        }
    }

    func upsertUsage(
        teamId: UUID,
        selection: FanTeamLocationSelection
    ) async throws -> FanTeamLocation {
        guard selection.hasValidCoordinate else {
            throw FanTeamLocationServiceError.incompleteLocation
        }
        struct Params: Encodable {
            let p_team_id: UUID
            let p_place_name: String?
            let p_address: String?
            let p_city: String?
            let p_state: String?
            let p_latitude: Double?
            let p_longitude: Double?
            let p_provider_place_id: String?
            let p_postal_code: String?
            let p_country_code: String?
        }
        let place = selection.placeName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = selection.persistableAddress
        let city = selection.city.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = selection.state.trimmingCharacters(in: .whitespacesAndNewlines)
        let postal = selection.zipCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let country = selection.countryCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = selection.providerPlaceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let dedupe = FanTeamLocationPresentation.identityKey(
            providerPlaceId: provider,
            latitude: selection.latitude,
            longitude: selection.longitude,
            address: address,
            city: city,
            state: state,
            placeName: place
        )
        do {
            let row: FanTeamLocation = try await client
                .rpc(
                    "upsert_fan_team_location_usage",
                    params: Params(
                        p_team_id: teamId,
                        p_place_name: place.flatMap { $0.isEmpty ? nil : $0 },
                        p_address: address.isEmpty ? nil : address,
                        p_city: city.isEmpty ? nil : city,
                        p_state: state.isEmpty ? nil : state,
                        p_latitude: selection.latitude,
                        p_longitude: selection.longitude,
                        p_provider_place_id: provider.flatMap { $0.isEmpty ? nil : $0 },
                        p_postal_code: postal.isEmpty ? nil : postal,
                        p_country_code: country.isEmpty ? nil : country
                    )
                )
                .execute()
                .value
            TeamLocationDebug.log(
                "recentUsageUpsert",
                detail: "teamID=\(teamId.uuidString.lowercased()) locationID=\(row.id.uuidString.lowercased()) usageCount=\(row.usageCount) lastUsedAt=\(row.lastUsedAt?.description ?? "nil") dedupeMatchType=\(dedupePrefix(dedupe)) country=\(country)"
            )
            return row
        } catch {
            TeamLocationDebug.log(
                "recentUsageUpsert",
                detail: "teamID=\(teamId.uuidString.lowercased()) error=\(error.localizedDescription)"
            )
            throw map(error, fallback: .usageFailed)
        }
    }

    func upsertUsageFromFormFields(
        teamId: UUID,
        placeName: String?,
        address: String?,
        city: String?,
        state: String?,
        latitude: Double?,
        longitude: Double?,
        providerPlaceId: String? = nil,
        postalCode: String? = nil,
        countryCode: String? = nil
    ) async throws -> FanTeamLocation? {
        guard let latitude, let longitude else { return nil }
        let selection = FanTeamLocationSelection(
            teamLocationId: nil,
            nickname: nil,
            placeName: placeName,
            address: address ?? "",
            city: city ?? "",
            state: state ?? "",
            zipCode: postalCode ?? "",
            countryCode: countryCode ?? "",
            latitude: latitude,
            longitude: longitude,
            providerPlaceId: providerPlaceId
        )
        guard selection.hasValidCoordinate else { return nil }
        return try await upsertUsage(teamId: teamId, selection: selection)
    }

    func saveLocation(
        teamId: UUID,
        selection: FanTeamLocationSelection,
        nickname: String?,
        setDefault: Bool = false,
        locationId: UUID? = nil
    ) async throws -> FanTeamLocation {
        struct Params: Encodable {
            let p_team_id: UUID
            let p_nickname: String?
            let p_place_name: String?
            let p_address: String?
            let p_city: String?
            let p_state: String?
            let p_latitude: Double?
            let p_longitude: Double?
            let p_provider_place_id: String?
            let p_set_default: Bool
            let p_location_id: UUID?
            let p_postal_code: String?
            let p_country_code: String?
        }
        let nick = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = selection.placeName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = selection.persistableAddress
        let postal = selection.zipCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let country = selection.countryCode.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let row: FanTeamLocation = try await client
                .rpc(
                    "save_fan_team_location",
                    params: Params(
                        p_team_id: teamId,
                        p_nickname: nick.flatMap { $0.isEmpty ? nil : $0 },
                        p_place_name: place.flatMap { $0.isEmpty ? nil : $0 },
                        p_address: address.isEmpty ? nil : address,
                        p_city: selection.city.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                        p_state: selection.state.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                        p_latitude: selection.latitude,
                        p_longitude: selection.longitude,
                        p_provider_place_id: selection.providerPlaceId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                        p_set_default: setDefault,
                        p_location_id: locationId ?? selection.teamLocationId,
                        p_postal_code: postal.nilIfEmpty,
                        p_country_code: country.nilIfEmpty
                    )
                )
                .execute()
                .value
            TeamLocationDebug.log(
                "locationSaved",
                detail: "teamID=\(teamId.uuidString.lowercased()) locationID=\(row.id.uuidString.lowercased()) isDefault=\(row.isDefault) country=\(country)"
            )
            if setDefault {
                TeamLocationDebug.log(
                    "defaultLocationChanged",
                    detail: "teamID=\(teamId.uuidString.lowercased()) locationID=\(row.id.uuidString.lowercased())"
                )
            }
            return row
        } catch {
            throw map(error, fallback: .saveFailed)
        }
    }

    func updateLocation(
        locationId: UUID,
        nickname: String?,
        clearNickname: Bool = false,
        isDefault: Bool? = nil,
        selection: FanTeamLocationSelection? = nil
    ) async throws -> FanTeamLocation {
        struct Params: Encodable {
            let p_location_id: UUID
            let p_nickname: String?
            let p_clear_nickname: Bool
            let p_is_default: Bool?
            let p_place_name: String?
            let p_address: String?
            let p_city: String?
            let p_state: String?
            let p_latitude: Double?
            let p_longitude: Double?
            let p_provider_place_id: String?
            let p_postal_code: String?
            let p_country_code: String?
        }
        do {
            let row: FanTeamLocation = try await client
                .rpc(
                    "update_fan_team_location",
                    params: Params(
                        p_location_id: locationId,
                        p_nickname: nickname?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                        p_clear_nickname: clearNickname,
                        p_is_default: isDefault,
                        p_place_name: selection?.placeName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                        p_address: selection?.persistableAddress.nilIfEmpty,
                        p_city: selection?.city.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                        p_state: selection?.state.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                        p_latitude: selection?.latitude,
                        p_longitude: selection?.longitude,
                        p_provider_place_id: selection?.providerPlaceId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                        p_postal_code: selection?.zipCode.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                        p_country_code: selection?.countryCode.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    )
                )
                .execute()
                .value
            if let isDefault {
                TeamLocationDebug.log(
                    "defaultLocationChanged",
                    detail: "locationID=\(locationId.uuidString.lowercased()) isDefault=\(isDefault)"
                )
            }
            return row
        } catch {
            throw map(error, fallback: .updateFailed)
        }
    }

    func removeSavedLocation(locationId: UUID) async throws {
        struct Params: Encodable { let p_location_id: UUID }
        do {
            try await client
                .rpc("remove_fan_team_saved_location", params: Params(p_location_id: locationId))
                .execute()
            TeamLocationDebug.log(
                "locationUnsaved",
                detail: "locationID=\(locationId.uuidString.lowercased())"
            )
            TeamLocationDebug.log(
                "locationRemoved",
                detail: "locationID=\(locationId.uuidString.lowercased())"
            )
        } catch {
            throw map(error, fallback: .removeFailed)
        }
    }

    func clearRecentLocations(teamId: UUID) async throws -> Int {
        struct Params: Encodable { let p_team_id: UUID }
        do {
            let count: Int = try await client
                .rpc("clear_fan_team_recent_locations", params: Params(p_team_id: teamId))
                .execute()
                .value
            TeamLocationDebug.log(
                "recentHistoryCleared",
                detail: "teamID=\(teamId.uuidString.lowercased()) cleared=\(count)"
            )
            return count
        } catch {
            throw map(error, fallback: .clearFailed)
        }
    }

    private func dedupePrefix(_ key: String?) -> String {
        guard let key, let colon = key.firstIndex(of: ":") else { return "none" }
        return String(key[..<colon])
    }

    private func map(_ error: Error, fallback: FanTeamLocationServiceError) -> FanTeamLocationServiceError {
        let text = error.localizedDescription.lowercased()
        if text.contains("not authenticated") { return .notAuthenticated }
        if text.contains("incomplete") { return .incompleteLocation }
        return fallback
    }
}

private extension String {
    /// Trims whitespace before emptiness check (Team location RPC payloads).
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
