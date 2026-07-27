import Foundation
import Supabase

/// Server-backed venue rating aggregates from `public.venue_ratings`
/// (one row per user via PK `(venue_id, user_id)`).
struct VenueRatingStats: Equatable, Sendable {
    var averageRating: Double?
    var ratingCount: Int
    var myRating: Int?

    static let empty = VenueRatingStats(averageRating: nil, ratingCount: 0, myRating: nil)

    /// Compact social-proof line for the rating sheet.
    func socialProofLine(languageCode: String) -> String {
        let lang = L10n.normalizedLanguageCode(languageCode)
        let count = max(0, ratingCount)
        let countText: String
        switch count {
        case 0:
            return L10n.t("venue_rating_none", languageCode: lang)
        case 1:
            countText = L10n.t("venue_rating_one", languageCode: lang)
        default:
            let formatted = count.formatted(.number.grouping(.automatic))
            countText = String(format: L10n.t("venue_rating_many_format", languageCode: lang), formatted)
        }

        guard let avg = averageRating, count > 0 else {
            return countText
        }
        let avgText = String(format: "%.1f", avg)
        return String(
            format: L10n.t("venue_rating_average_and_count_format", languageCode: lang),
            avgText,
            formattedCountForAverageLine(count: count, languageCode: lang)
        )
    }

    func accessibilityLabel(languageCode: String) -> String {
        socialProofLine(languageCode: languageCode)
    }

    private func formattedCountForAverageLine(count: Int, languageCode: String) -> String {
        switch count {
        case 1:
            return L10n.t("venue_rating_one", languageCode: languageCode)
        default:
            let formatted = count.formatted(.number.grouping(.automatic))
            return String(format: L10n.t("venue_rating_many_format", languageCode: languageCode), formatted)
        }
    }
}

private struct VenueRatingStatsRPCRow: Decodable {
    let venue_id: UUID
    let average_rating: PickupRPCNumericOrString?
    let rating_count: Int64
    let my_rating: Int16?

    func toStats() -> VenueRatingStats {
        let count = max(0, Int(rating_count))
        let avg: Double? = count > 0 ? average_rating?.doubleValue : nil
        let mine = my_rating.map { Int($0) }
        return VenueRatingStats(averageRating: avg, ratingCount: count, myRating: mine)
    }
}

private struct VenueRatingOwnRow: Decodable {
    let rating: Int16
}

private struct VenueRatingUpsertRow: Encodable {
    let venue_id: UUID
    let user_id: UUID
    let rating: Int
}

/// Venue star ratings: authoritative store is ``public.venue_ratings`` +
/// ``get_venue_rating_stats`` / ``upsert_my_venue_rating``. Local UserDefaults mirrors
/// the caller's own stars for offline star selection only.
extension MapViewModel {

    private static let venueStarsDefaultsKey = "gameon.venueUserStars.v1"
    private static let venueRatingSaveCountsKey = "gameon.venueRatingSaveCounts.v1"

    func reloadVenueUserRatingsFromStorage() {
        venueUserStarRatings = Self.decodeUUIDIntDict(Self.venueStarsDefaultsKey)
        // Legacy local contribution counters are no longer used for display.
        venueRatingContributionCount = Self.decodeUUIDIntDict(Self.venueRatingSaveCountsKey)
    }

    /// Loads community average + distinct-user count (+ my rating when available) for one venue.
    @MainActor
    func refreshVenueRatingStats(for venueID: UUID) async {
        guard canRateVenues || isAuthenticatedForSocialFeatures else { return }
        do {
            let stats = try await fetchVenueRatingStats(venueIDs: [venueID])[venueID] ?? .empty
            applyVenueRatingStats(stats, venueID: venueID)
        } catch {
#if DEBUG
            print("[VenueRating] refresh failed venue=\(venueID) error=\(error.localizedDescription)")
#endif
        }
    }

    /// Upserts the caller's rating and refreshes displayed average/count from the server.
    @MainActor
    func saveUserVenueRating(venueID: UUID, stars: Int) async {
        guard canRateVenues else {
            logBusinessUserGateBlocked(action: "rateVenue")
            return
        }
        let clamped = min(5, max(1, stars))
        let hadExisting = (venueRatingStatsByVenueId[venueID]?.myRating != nil)
            || (venueUserStarRatings[venueID] != nil)

        // Optimistic local star selection only — do not bump community count here.
        venueUserStarRatings[venueID] = clamped
        Self.encodeUUIDIntDict(venueUserStarRatings, key: Self.venueStarsDefaultsKey)

        do {
            let stats = try await upsertVenueRatingOnServer(venueID: venueID, stars: clamped)
            applyVenueRatingStats(stats, venueID: venueID)
#if DEBUG
            print("[VenueRating] saved venue=\(venueID) stars=\(clamped) firstTime=\(!hadExisting) count=\(stats.ratingCount) avg=\(stats.averageRating.map { String(format: "%.1f", $0) } ?? "nil")")
#endif
        } catch {
#if DEBUG
            print("[VenueRating] save failed venue=\(venueID) error=\(error.localizedDescription)")
#endif
            // Keep local stars; refresh stats so count is not optimistically wrong.
            await refreshVenueRatingStats(for: venueID)
        }
    }

    func removeLocalVenueRating(venueID: UUID) {
        venueUserStarRatings.removeValue(forKey: venueID)
        venueRatingContributionCount.removeValue(forKey: venueID)
        venueRatingStatsByVenueId.removeValue(forKey: venueID)
        Self.encodeUUIDIntDict(venueUserStarRatings, key: Self.venueStarsDefaultsKey)
        Self.encodeUUIDIntDict(venueRatingContributionCount, key: Self.venueRatingSaveCountsKey)
    }

    /// Community average when ratings exist; otherwise the caller's local stars (legacy card badge).
    func mergedDisplayRating(for bar: BarVenue) -> Double? {
        if let stats = venueRatingStatsByVenueId[bar.id], stats.ratingCount > 0, let avg = stats.averageRating {
            return avg
        }
        guard let stars = venueUserStarRatings[bar.id] else { return nil }
        return Double(stars)
    }

    /// Distinct users who rated (server). Falls back to 0/1 from local mirror only when stats missing.
    func reviewCountDisplay(for bar: BarVenue) -> Int {
        if let stats = venueRatingStatsByVenueId[bar.id] {
            return max(0, stats.ratingCount)
        }
        guard venueUserStarRatings[bar.id] != nil else { return 0 }
        return 1
    }

    func venueRatingSocialProof(for venueID: UUID, languageCode: String) -> String {
        let stats = venueRatingStatsByVenueId[venueID] ?? .empty
        return stats.socialProofLine(languageCode: languageCode)
    }

    // MARK: - Network

    private func fetchVenueRatingStats(venueIDs: [UUID]) async throws -> [UUID: VenueRatingStats] {
        guard !venueIDs.isEmpty else { return [:] }
        struct Params: Encodable {
            let p_venue_ids: [UUID]
        }
        let rows: [VenueRatingStatsRPCRow] = try await supabase
            .rpc("get_venue_rating_stats", params: Params(p_venue_ids: venueIDs))
            .execute()
            .value

        var out: [UUID: VenueRatingStats] = [:]
        for id in venueIDs {
            out[id] = .empty
        }
        for row in rows {
            out[row.venue_id] = row.toStats()
        }

        // Current production RPC may omit my_rating until 20260873; fill from own SELECT.
        let missingMine = venueIDs.filter { out[$0]?.myRating == nil }
        if !missingMine.isEmpty, let me = try? await supabase.auth.session.user.id {
            let own: [VenueRatingOwnRowWithVenue] = try await supabase
                .from("venue_ratings")
                .select("venue_id,rating")
                .eq("user_id", value: me)
                .in("venue_id", values: missingMine.map { $0.uuidString.lowercased() })
                .execute()
                .value
            for row in own {
                var stats = out[row.venue_id] ?? .empty
                stats.myRating = Int(row.rating)
                out[row.venue_id] = stats
            }
        }
        return out
    }

    private struct VenueRatingOwnRowWithVenue: Decodable {
        let venue_id: UUID
        let rating: Int16
    }

    private func upsertVenueRatingOnServer(venueID: UUID, stars: Int) async throws -> VenueRatingStats {
        // Prefer single-round-trip RPC from 20260873 when available.
        struct UpsertParams: Encodable {
            let p_venue_id: UUID
            let p_rating: Int
        }
        do {
            let rows: [VenueRatingStatsRPCRow] = try await supabase
                .rpc("upsert_my_venue_rating", params: UpsertParams(p_venue_id: venueID, p_rating: stars))
                .execute()
                .value
            if let row = rows.first {
                return row.toStats()
            }
        } catch {
#if DEBUG
            print("[VenueRating] upsert_my_venue_rating unavailable; falling back to table upsert: \(error.localizedDescription)")
#endif
        }

        let me = try await supabase.auth.session.user.id
        try await supabase
            .from("venue_ratings")
            .upsert(
                VenueRatingUpsertRow(venue_id: venueID, user_id: me, rating: stars),
                onConflict: "venue_id,user_id"
            )
            .execute()

        let fetched = try await fetchVenueRatingStats(venueIDs: [venueID])
        var stats = fetched[venueID] ?? .empty
        stats.myRating = stars
        return stats
    }

    @MainActor
    private func applyVenueRatingStats(_ stats: VenueRatingStats, venueID: UUID) {
        venueRatingStatsByVenueId[venueID] = stats
        if let mine = stats.myRating {
            venueUserStarRatings[venueID] = mine
            Self.encodeUUIDIntDict(venueUserStarRatings, key: Self.venueStarsDefaultsKey)
        }
    }

    private static func decodeUUIDIntDict(_ key: String) -> [UUID: Int] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let raw = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        var out: [UUID: Int] = [:]
        for (k, v) in raw {
            if let id = UUID(uuidString: k) {
                out[id] = v
            }
        }
        return out
    }

    private static func encodeUUIDIntDict(_ dict: [UUID: Int], key: String) {
        let raw = Dictionary(uniqueKeysWithValues: dict.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
