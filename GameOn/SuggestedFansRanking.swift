import Foundation

/// Authoritative Suggested Fans component scoring (mirrors `get_profile_friend_suggestions` / 20260895).
/// Used for DEBUG self-tests and client “Why suggested?” precedence. Does not expose distance.
enum SuggestedFansRanking {
    static let nearbyRadiusMiles: Double = SuggestedFansProduct.nearbyRadiusMiles

    enum ReasonType: String, CaseIterable, Sendable {
        case mutualFriends = "mutual_friends"
        case pickupGame = "pickup_game"
        case myTeam = "my_team"
        case myTeamAffinity = "my_team_affinity"
        case proximity = "proximity"
        case venueEvent = "venue_event"
        case favoriteTeam = "favorite_team"
        case favoriteVenue = "favorite_venue"
        case recentActivity = "recent_activity"
        case reputation = "reputation"
        case fallback = "fallback"

        /// Deterministic tie-break when component scores are equal (strongest first).
        var tieBreakPriority: Int {
            switch self {
            case .mutualFriends: return 1
            case .pickupGame: return 2
            case .myTeam, .myTeamAffinity: return 3
            case .proximity: return 4
            case .venueEvent: return 5
            case .favoriteTeam: return 6
            case .favoriteVenue: return 7
            case .recentActivity: return 8
            case .reputation: return 9
            case .fallback: return 10
            }
        }
    }

    struct ComponentScores: Equatable, Sendable {
        var mutualFriends: Int = 0
        var pickupGame: Int = 0
        var proximity: Int = 0
        var myTeam: Int = 0
        var myTeamAffinity: Int = 0
        var favoriteTeam: Int = 0
        var venueEvent: Int = 0
        var favoriteVenue: Int = 0
        var recentActivity: Int = 0
        var reputation: Int = 0
        /// Raw fallback input. Authoritative `total` / `strongestReason` ignore this when any meaningful signal is present.
        var fallback: Int = 0

        /// Any non-fallback ranking signal (mirrors SQL `meaningful_reasons`).
        var meaningfulTotal: Int {
            mutualFriends
                + pickupGame
                + proximity
                + myTeam
                + myTeamAffinity
                + favoriteTeam
                + venueEvent
                + favoriteVenue
                + recentActivity
                + reputation
        }

        var hasMeaningfulSignal: Bool { meaningfulTotal > 0 }

        /// Fallback contributes only when there is no meaningful signal (never stacks).
        var authoritativeFallback: Int {
            hasMeaningfulSignal ? 0 : max(0, fallback)
        }

        var total: Int {
            meaningfulTotal + authoritativeFallback
        }

        /// Strongest component for “Why suggested?” (score DESC, then tie-break priority ASC).
        /// Fallback is only eligible when it is the sole signal.
        var strongestReason: ReasonType {
            let parts: [(ReasonType, Int)] = [
                (.mutualFriends, mutualFriends),
                (.pickupGame, pickupGame),
                (.myTeam, myTeam),
                (.myTeamAffinity, myTeamAffinity),
                (.proximity, proximity),
                (.venueEvent, venueEvent),
                (.favoriteTeam, favoriteTeam),
                (.favoriteVenue, favoriteVenue),
                (.recentActivity, recentActivity),
                (.reputation, reputation),
                (.fallback, authoritativeFallback)
            ]
            return parts
                .filter { $0.1 > 0 }
                .sorted {
                    if $0.1 != $1.1 { return $0.1 > $1.1 }
                    return $0.0.tieBreakPriority < $1.0.tieBreakPriority
                }
                .first?
                .0 ?? .fallback
        }
    }

    // MARK: - Component formulas

    static func mutualFriendsScore(count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(1_100, 800 + (count - 1) * 100)
    }

    static func pickupGameScore(sharedCount: Int) -> Int {
        guard sharedCount > 0 else { return 0 }
        return min(1_050, 750 + (sharedCount - 1) * 75)
    }

    /// Bucketed proximity. `nil` / missing → 0. Never returns miles to callers for UI.
    static func proximityScore(distanceMiles: Double?) -> Int {
        guard let miles = distanceMiles, miles.isFinite, miles >= 0 else { return 0 }
        if miles <= 2 { return 700 }
        if miles <= 5 { return 550 }
        if miles <= 10 { return 400 }
        if miles <= 20 { return 250 }
        if miles <= 30 { return 150 }
        if miles <= nearbyRadiusMiles { return 75 }
        return 0
    }

    /// Same Favorite Team (+600) wins over primary↔favorite affinity (+450). Never both.
    static func myTeamScores(
        viewerPrimaryTeamId: String?,
        candidatePrimaryTeamId: String?,
        viewerFavoriteTeamIds: Set<String>,
        candidateFavoriteTeamIds: Set<String>
    ) -> (same: Int, affinity: Int, consumedTeamIds: Set<String>) {
        let viewerPrimary = normalizedTeamId(viewerPrimaryTeamId)
        let candidatePrimary = normalizedTeamId(candidatePrimaryTeamId)

        if let viewerPrimary,
           let candidatePrimary,
           viewerPrimary == candidatePrimary {
            return (600, 0, [viewerPrimary])
        }

        var consumed: Set<String> = []
        if let viewerPrimary, candidateFavoriteTeamIds.contains(viewerPrimary) {
            consumed.insert(viewerPrimary)
            return (0, 450, consumed)
        }
        if let candidatePrimary, viewerFavoriteTeamIds.contains(candidatePrimary) {
            consumed.insert(candidatePrimary)
            return (0, 450, consumed)
        }
        return (0, 0, [])
    }

    static func ordinarySharedTeamsScore(
        sharedTeamIds: Set<String>,
        consumedByMyTeam: Set<String>
    ) -> Int {
        let ordinary = sharedTeamIds.subtracting(consumedByMyTeam)
        let count = ordinary.count
        guard count > 0 else { return 0 }
        return min(525, 300 + (count - 1) * 75)
    }

    static func watchPartyScore(sharedEventCount: Int) -> Int {
        guard sharedEventCount > 0 else { return 0 }
        return min(700, 500 + (sharedEventCount - 1) * 50)
    }

    static func favoriteVenueScore(sharedVenueCount: Int) -> Int {
        guard sharedVenueCount > 0 else { return 0 }
        return min(400, 250 + (sharedVenueCount - 1) * 50)
    }

    static func recentActivityScore(updatedWithinDays: Int?) -> Int {
        guard let days = updatedWithinDays, days >= 0 else { return 0 }
        if days <= 7 { return 125 }
        if days <= 30 { return 75 }
        return 0
    }

    static func reputationScore(level: Int, totalXP: Int) -> Int {
        guard level >= 3 || totalXP >= 500 else { return 0 }
        return min(100, max(0, level * 5 + totalXP / 500))
    }

    /// Returns +25 only for an eligible candidate with no meaningful ranking signals.
    /// Callers that already know meaningful components exist should pass `hasMeaningfulSignal: true`.
    static func fallbackScore(isEligibleFallback: Bool, hasMeaningfulSignal: Bool = false) -> Int {
        guard isEligibleFallback, !hasMeaningfulSignal else { return 0 }
        return 25
    }

    /// Assembles authoritative component scores: clears stacked fallback when meaningful signals exist.
    static func assemble(
        mutualFriends: Int = 0,
        pickupGame: Int = 0,
        proximity: Int = 0,
        myTeam: Int = 0,
        myTeamAffinity: Int = 0,
        favoriteTeam: Int = 0,
        venueEvent: Int = 0,
        favoriteVenue: Int = 0,
        recentActivity: Int = 0,
        reputation: Int = 0,
        isEligibleFallback: Bool = false
    ) -> ComponentScores {
        var components = ComponentScores(
            mutualFriends: mutualFriends,
            pickupGame: pickupGame,
            proximity: proximity,
            myTeam: myTeam,
            myTeamAffinity: myTeamAffinity,
            favoriteTeam: favoriteTeam,
            venueEvent: venueEvent,
            favoriteVenue: favoriteVenue,
            recentActivity: recentActivity,
            reputation: reputation,
            fallback: 0
        )
        components.fallback = fallbackScore(
            isEligibleFallback: isEligibleFallback,
            hasMeaningfulSignal: components.hasMeaningfulSignal
        )
        return components
    }

    // MARK: - Diversity (display list)

    /// Keeps top ~8 strongest, injects up to 2 stable next-tier candidates (score > 25).
    /// Stable for a UTC calendar day + viewer id. Never promotes pure fallback above strong rows.
    static func applyControlledDiversity(
        rankedByScoreDescending: [FriendSuggestionProfile],
        displayLimit: Int = FriendSuggestionsService.defaultDisplayLimit,
        viewerId: UUID,
        dayBucket: Date = Date()
    ) -> [FriendSuggestionProfile] {
        let limit = max(0, displayLimit)
        guard limit > 0 else { return [] }
        guard rankedByScoreDescending.count > 1 else {
            return Array(rankedByScoreDescending.prefix(limit))
        }

        let primaryN = min(8, limit)
        let diversityN = max(0, min(2, limit - primaryN))
        let primary = Array(rankedByScoreDescending.prefix(primaryN))
        guard diversityN > 0 else {
            return Array(rankedByScoreDescending.prefix(limit))
        }

        let dayKey = utcDayKey(dayBucket)
        let nextTier = rankedByScoreDescending
            .dropFirst(primaryN)
            .prefix(20)
            .filter { $0.score > 25 }

        let diversity = nextTier
            .sorted { lhs, rhs in
                let lh = diversityHash(viewerId: viewerId, dayKey: dayKey, candidateId: lhs.userID)
                let rh = diversityHash(viewerId: viewerId, dayKey: dayKey, candidateId: rhs.userID)
                if lh != rh { return lh < rh }
                return lhs.userID.uuidString < rhs.userID.uuidString
            }
            .prefix(diversityN)

        var used = Set(primary.map(\.userID))
        used.formUnion(diversity.map(\.userID))

        var output = primary + Array(diversity)
        for row in rankedByScoreDescending.dropFirst(primaryN) where !used.contains(row.userID) {
            guard output.count < limit else { break }
            output.append(row)
            used.insert(row.userID)
        }
        return Array(output.prefix(limit))
    }

    // MARK: - Private

    private static func normalizedTeamId(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func utcDayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func diversityHash(viewerId: UUID, dayKey: String, candidateId: UUID) -> UInt64 {
        let material = viewerId.uuidString.lowercased()
            + "|"
            + dayKey
            + "|"
            + candidateId.uuidString.lowercased()
        var hash: UInt64 = 5381
        for byte in material.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return hash
    }
}
