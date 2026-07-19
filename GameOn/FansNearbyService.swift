import CoreLocation
import Foundation
import Supabase

/// Privacy-safe Fans nearby aggregate + batched Live Now membership.
/// Never exposes coordinates, distances, cities, or unrelated profile fields.
@MainActor
enum FansNearbyProduct {
    /// Matches ``SuggestedFansProduct/nearbyRadiusMiles``.
    static let nearbyRadiusMiles: Double = SuggestedFansProduct.nearbyRadiusMiles
    /// Matches ``PresenceOnlineStatus/onlineWindowSeconds`` / Fans Live Now online-now rule.
    static let presenceWindowSeconds: TimeInterval = PresenceOnlineStatus.onlineWindowSeconds
    static let cacheTTLSeconds: TimeInterval = 90
    /// Matches ``ChatFansLiveNowSessionCache/displayLimit``.
    static let amongCandidateCap: Int = 12
}

enum FansNearbyCountValue: Equatable {
    case loading
    case loaded(Int)
    case unavailable
}

@MainActor
final class FansNearbyService {
    static let shared = FansNearbyService()

    private struct CacheEntry: Equatable {
        let authId: UUID
        let count: Int
        let fetchedAt: Date
        let centerLatBucket: Int
        let centerLngBucket: Int
    }

    private struct AmongCacheEntry: Equatable {
        let authId: UUID
        let candidateSignature: String
        let centerLatBucket: Int
        let centerLngBucket: Int
        let nearbyIds: Set<UUID>
        let fetchedAt: Date
    }

    private struct NearbyCountParams: Encodable {
        let p_center_lat: Double
        let p_center_lng: Double
        let p_radius_miles: Double
    }

    private struct NearbyCountRow: Decodable {
        let fan_count: Int
        let generated_at: String?
    }

    private struct NearbyIdRow: Decodable {
        let user_id: UUID

        private enum CodingKeys: String, CodingKey {
            case user_id
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let uuid = try? container.decode(UUID.self, forKey: .user_id) {
                user_id = uuid
            } else if let raw = try? container.decode(String.self, forKey: .user_id),
                      let uuid = UUID(uuidString: raw) {
                user_id = uuid
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .user_id,
                    in: container,
                    debugDescription: "Expected UUID for nearby user_id."
                )
            }
        }
    }

    private let client: SupabaseClient
    private var cache: CacheEntry?
    private var amongCache: AmongCacheEntry?
    private var inFlightAuthId: UUID?
    private var amongInFlightKey: String?
    /// Shared in-flight among-RPC so concurrent callers await the same result (never apply empty mid-flight).
    private var amongInFlightTask: Task<Set<UUID>, Never>?
    /// Monotonic generation so an older in-flight RPC cannot overwrite a newer authoritative result.
    private var amongFetchGeneration: UInt64 = 0
    /// Monotonic generation so an older count RPC cannot overwrite a newer center's result.
    private var countFetchGeneration: UInt64 = 0

    private init() {
        self.client = supabase
    }

    func clear(reason: String) {
        cache = nil
        amongCache = nil
        inFlightAuthId = nil
        amongInFlightKey = nil
        amongInFlightTask?.cancel()
        amongInFlightTask = nil
        amongFetchGeneration &+= 1
        countFetchGeneration &+= 1
#if DEBUG
        print("[FansNearby] unavailable reason=\(debugUnavailableToken(forClearReason: reason))")
#endif
    }

    /// Drop batched Nearby membership so the next Chat refresh re-queries the authoritative RPC.
    func invalidateAmongMembership(reason: String) {
        invalidateAmongCache(reason: reason)
    }

    /// Drop batched Nearby membership so the next Chat refresh re-queries the authoritative RPC.
    private func invalidateAmongCache(reason: String) {
        amongCache = nil
        amongInFlightKey = nil
        amongInFlightTask?.cancel()
        amongInFlightTask = nil
        amongFetchGeneration &+= 1
#if DEBUG
        print("[ChatNearby] refresh reason=invalidateAmong:\(reason)")
#endif
    }

    /// Cached value for synchronous Activity Panel presentation (never invents zero while loading).
    /// When ``center`` is provided, only returns a loaded count for that coarse center bucket —
    /// never a stale other-city total.
    func cachedCount(
        for authId: UUID?,
        center: CLLocationCoordinate2D? = nil
    ) -> FansNearbyCountValue {
        guard let authId else { return .unavailable }
        guard let cache, cache.authId == authId else {
            return inFlightAuthId == authId ? .loading : .unavailable
        }
        if let center, CLLocationCoordinate2DIsValid(center) {
            let latBucket = Int((center.latitude * 100).rounded())
            let lngBucket = Int((center.longitude * 100).rounded())
            if cache.centerLatBucket != latBucket || cache.centerLngBucket != lngBucket {
                return inFlightAuthId == authId ? .loading : .unavailable
            }
        }
        if Date().timeIntervalSince(cache.fetchedAt) > FansNearbyProduct.cacheTTLSeconds {
            return .loaded(cache.count) // stale-while-revalidate: retain last good count for same center
        }
        return .loaded(cache.count)
    }

    func refreshIfNeeded(
        authId: UUID?,
        isBusinessAccount: Bool,
        center: CLLocationCoordinate2D?,
        force: Bool = false,
        reason: String
    ) async {
        guard let authId else {
            clear(reason: "signedOut")
            return
        }
        if isBusinessAccount {
            clear(reason: "businessAccount")
            return
        }
        guard let center, CLLocationCoordinate2DIsValid(center) else {
#if DEBUG
            print("[FansNearby] unavailable reason=noRequesterCenter")
#endif
            // Keep last good count for this auth if we have one; otherwise unavailable.
            if cache?.authId != authId {
                cache = nil
            }
            return
        }

        let latBucket = Int((center.latitude * 100).rounded())
        let lngBucket = Int((center.longitude * 100).rounded())
        if !force,
           let cache,
           cache.authId == authId,
           cache.centerLatBucket == latBucket,
           cache.centerLngBucket == lngBucket,
           Date().timeIntervalSince(cache.fetchedAt) < FansNearbyProduct.cacheTTLSeconds {
            return
        }

        countFetchGeneration &+= 1
        let generation = countFetchGeneration
        inFlightAuthId = authId
#if DEBUG
        print("[FansNearby] requestStarted reason=\(reason)")
#endif
        defer {
            if inFlightAuthId == authId, generation == countFetchGeneration {
                inFlightAuthId = nil
            }
        }

        let params = NearbyCountParams(
            p_center_lat: center.latitude,
            p_center_lng: center.longitude,
            p_radius_miles: FansNearbyProduct.nearbyRadiusMiles
        )

        do {
            let count = try await fetchNearbyCount(params: params)
            guard generation == countFetchGeneration else { return }
            cache = CacheEntry(
                authId: authId,
                count: count,
                fetchedAt: Date(),
                centerLatBucket: latBucket,
                centerLngBucket: lngBucket
            )
            // Count and Chat membership must agree after an authoritative refresh.
            invalidateAmongCache(reason: "countRefresh:\(reason)")
#if DEBUG
            print("[FansNearby] rpc result count=\(count)")
#endif
        } catch {
#if DEBUG
            print("[FansNearby] unavailable reason=\(debugUnavailableToken(forRPCError: error))")
#endif
            // Preserve last successful value for this account. Never invent 0 on error.
        }
    }

    /// Batched membership for already-visible Fans Live Now IDs only.
    /// Successful RPC results **replace** the cached ID set (including empty). Network failures
    /// preserve the last matching scoped result and are never treated as authoritative empty.
    func nearbyIdsAmong(
        authId: UUID?,
        isBusinessAccount: Bool,
        center: CLLocationCoordinate2D?,
        candidateIds: [UUID],
        force: Bool = false,
        reason: String
    ) async -> Set<UUID> {
        guard let authId, !isBusinessAccount else { return [] }
        let capped = Array(
            candidateIds
                .filter { $0 != authId }
                .prefix(FansNearbyProduct.amongCandidateCap)
        )
#if DEBUG
        print("[ChatNearbyTest] candidateCount=\(capped.count)")
#endif
        guard !capped.isEmpty else { return [] }
        guard let center, CLLocationCoordinate2DIsValid(center) else {
#if DEBUG
            print("[FansNearby] among skipped reason=noRequesterCenter")
            print("[ChatNearby] refresh reason=\(reason)")
            print("[ChatNearbyTest] excluded reason=missingLocation")
            print("[ChatNearbyTest] cache source=cache force=\(force)")
            print("[ChatNearbyTest] rpc nearbyCount=0")
#endif
            return []
        }

        let latBucket = Int((center.latitude * 100).rounded())
        let lngBucket = Int((center.longitude * 100).rounded())
        let signature = capped.map(\.uuidString).sorted().joined(separator: ",")
        let previousCount = matchingAmongCache(
            authId: authId,
            signature: signature,
            latBucket: latBucket,
            lngBucket: lngBucket
        )?.nearbyIds.count ?? 0

#if DEBUG
        print("[ChatNearby] refresh reason=\(reason)")
#endif

        if !force,
           let hit = matchingAmongCache(
            authId: authId,
            signature: signature,
            latBucket: latBucket,
            lngBucket: lngBucket
           ),
           Date().timeIntervalSince(hit.fetchedAt) < FansNearbyProduct.cacheTTLSeconds {
#if DEBUG
            print(
                "[ChatNearby] cache result previousCount=\(previousCount) newCount=\(hit.nearbyIds.count) source=cache"
            )
            print("[ChatNearbyTest] cache source=cache force=false")
            print("[ChatNearbyTest] rpc nearbyCount=\(hit.nearbyIds.count)")
#endif
            return hit.nearbyIds
        }

        let flightKey = "\(authId.uuidString.lowercased())|\(signature)|\(latBucket)|\(lngBucket)"
        if !force, amongInFlightKey == flightKey, let existing = amongInFlightTask {
            return await existing.value
        }

        if force {
            amongInFlightTask?.cancel()
            amongInFlightTask = nil
            amongInFlightKey = nil
        }

        amongFetchGeneration &+= 1
        let generation = amongFetchGeneration
        let centerLat = center.latitude
        let centerLng = center.longitude
        let radius = FansNearbyProduct.nearbyRadiusMiles

        let task = Task { @MainActor () -> Set<UUID> in
#if DEBUG
            print("[FansNearby] among requestStarted reason=\(reason) candidates=\(capped.count)")
#endif
            struct Params: Encodable {
                let p_center_lat: Double
                let p_center_lng: Double
                let p_candidate_user_ids: [String]
                let p_radius_miles: Double
            }

            do {
                let rows: [NearbyIdRow] = try await self.client
                    .rpc(
                        "get_nearby_fan_ids_among",
                        params: Params(
                            p_center_lat: centerLat,
                            p_center_lng: centerLng,
                            p_candidate_user_ids: capped.map { $0.uuidString.lowercased() },
                            p_radius_miles: radius
                        )
                    )
                    .execute()
                    .value

                guard generation == self.amongFetchGeneration else {
#if DEBUG
                    print("[ChatNearby] staleResultIgnored=true")
                    print("[ChatNearbyTest] excluded reason=staleResult")
#endif
                    return self.matchingAmongCache(
                        authId: authId,
                        signature: signature,
                        latBucket: latBucket,
                        lngBucket: lngBucket
                    )?.nearbyIds ?? []
                }

                let ids = Set(rows.map(\.user_id)).intersection(Set(capped))
                let priorCount = self.matchingAmongCache(
                    authId: authId,
                    signature: signature,
                    latBucket: latBucket,
                    lngBucket: lngBucket
                )?.nearbyIds.count ?? previousCount
                // Authoritative replace — including empty set.
                self.amongCache = AmongCacheEntry(
                    authId: authId,
                    candidateSignature: signature,
                    centerLatBucket: latBucket,
                    centerLngBucket: lngBucket,
                    nearbyIds: ids,
                    fetchedAt: Date()
                )
#if DEBUG
                print("[FansNearby] among result count=\(ids.count)")
                print(
                    "[ChatNearby] cache result previousCount=\(priorCount) newCount=\(ids.count) source=rpc"
                )
                print("[ChatNearbyTest] cache source=rpc force=\(force)")
                print("[ChatNearbyTest] rpc nearbyCount=\(ids.count)")
                if ids.isEmpty {
                    print("[ChatNearby] authoritativeEmpty=true")
                }
#endif
                return ids
            } catch {
                guard generation == self.amongFetchGeneration else {
#if DEBUG
                    print("[ChatNearby] staleResultIgnored=true")
                    print("[ChatNearbyTest] excluded reason=staleResult")
#endif
                    return self.matchingAmongCache(
                        authId: authId,
                        signature: signature,
                        latBucket: latBucket,
                        lngBucket: lngBucket
                    )?.nearbyIds ?? []
                }
#if DEBUG
                let text = String(describing: error).lowercased()
                let token: String
                if text.contains("pgrst202") || text.contains("could not find the function") {
                    token = "rpcMissing"
                } else {
                    token = "rpcError"
                }
                print("[FansNearby] among unavailable reason=\(token)")
                print("[ChatNearbyTest] excluded reason=rpcFailure")
                // Failure is not authoritative empty — preserve last matching scoped result.
                let preserved = self.matchingAmongCache(
                    authId: authId,
                    signature: signature,
                    latBucket: latBucket,
                    lngBucket: lngBucket
                )?.nearbyIds ?? []
                print(
                    "[ChatNearby] cache result previousCount=\(previousCount) newCount=\(preserved.count) source=cache"
                )
                print("[ChatNearbyTest] cache source=cache force=\(force)")
                print("[ChatNearbyTest] rpc nearbyCount=\(preserved.count)")
#endif
                return self.matchingAmongCache(
                    authId: authId,
                    signature: signature,
                    latBucket: latBucket,
                    lngBucket: lngBucket
                )?.nearbyIds ?? []
            }
        }

        amongInFlightKey = flightKey
        amongInFlightTask = task
        let ids = await task.value
        if amongInFlightKey == flightKey {
            amongInFlightKey = nil
            amongInFlightTask = nil
        }
        return ids
    }

    private func matchingAmongCache(
        authId: UUID,
        signature: String,
        latBucket: Int,
        lngBucket: Int
    ) -> AmongCacheEntry? {
        guard let amongCache,
              amongCache.authId == authId,
              amongCache.candidateSignature == signature,
              amongCache.centerLatBucket == latBucket,
              amongCache.centerLngBucket == lngBucket else {
            return nil
        }
        return amongCache
    }

    private func fetchNearbyCount(params: NearbyCountParams) async throws -> Int {
        do {
            let rows: [NearbyCountRow] = try await client
                .rpc("get_nearby_fan_count", params: params)
                .execute()
                .value
            return max(0, rows.first?.fan_count ?? 0)
        } catch {
            // Some PostgREST shapes return a single object for one-row TABLE results.
            do {
                let row: NearbyCountRow = try await client
                    .rpc("get_nearby_fan_count", params: params)
                    .execute()
                    .value
                return max(0, row.fan_count)
            } catch let second {
                let wrapped = FansNearbyRPCError(
                    primary: error,
                    fallback: second
                )
                throw wrapped
            }
        }
    }

#if DEBUG
    private func debugUnavailableToken(forClearReason reason: String) -> String {
        switch reason {
        case "signedOut", "accountSwitch", "businessAccount":
            return "signedOut"
        case "noLocation", "noRequesterCenter":
            return "noRequesterCenter"
        default:
            return reason
        }
    }

    private func debugUnavailableToken(forRPCError error: Error) -> String {
        let text = String(describing: error).lowercased()
        if text.contains("pgrst202")
            || text.contains("could not find the function")
            || text.contains("function public.get_nearby_fan_count")
            || (text.contains("get_nearby_fan_count") && text.contains("not find")) {
            return "rpcMissing"
        }
        if text.contains("not authorized")
            || text.contains("jwt")
            || text.contains("28000")
            || text.contains("authentication required") {
            return "signedOut"
        }
        if text.contains("data couldn't be read")
            || text.contains("decoding")
            || text.contains("type mismatch")
            || text.contains("corrupt") {
            return "decodeFailure"
        }
        return "rpcError"
    }
#endif
}

private struct FansNearbyRPCError: Error {
    let primary: Error
    let fallback: Error
}

extension FansNearbyRPCError: CustomStringConvertible {
    var description: String {
        "primary=\(primary) fallback=\(fallback)"
    }
}
