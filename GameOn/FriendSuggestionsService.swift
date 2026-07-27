import Foundation
import Supabase

/// Public-safe profile payload returned by the friend suggestions RPC.
struct FriendSuggestionMutualFanAvatar: Identifiable, Decodable, Hashable, Sendable {
    let userID: UUID
    let displayName: String?
    let avatarURL: String?
    let avatarThumbnailURL: String?

    var id: UUID { userID }

    private enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case avatarThumbnailURL = "avatar_thumbnail_url"
    }
}

struct FriendSuggestionProfile: Identifiable, Decodable, Hashable, Sendable {
    let userID: UUID
    let email: String?
    let displayName: String?
    /// Stored handle without requiring UI formatting; falls back to `username` when the RPC returns that column.
    let handle: String?
    let avatarURL: String?
    let avatarThumbnailURL: String?
    let bio: String?
    let sharedFavoriteTeamsCount: Int
    let sharedEventInterestCount: Int
    let sharedPickupGameCount: Int
    let mutualFriendCount: Int
    let mutualFriendAvatars: [FriendSuggestionMutualFanAvatar]
    let score: Double
    let reasonType: String?
    let reasonLabel: String?

    var id: UUID { userID }

    private enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case email
        case displayName = "display_name"
        case handle
        case username
        case avatarURL = "avatar_url"
        case avatarThumbnailURL = "avatar_thumbnail_url"
        case bio
        case sharedFavoriteTeamsCount = "shared_favorite_teams_count"
        case sharedEventInterestCount = "shared_event_interest_count"
        case sharedPickupGameCount = "shared_pickup_game_count"
        case mutualFriendCount = "mutual_friend_count"
        case mutualFriendAvatars = "mutual_friend_avatars"
        case score
        case reasonType = "reason_type"
        case reasonLabel = "reason_label"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        userID = try Self.decodeUUID(from: container, preferredKey: .userID, fallbackKey: .id)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        handle = try container.decodeIfPresent(String.self, forKey: .handle)
            ?? container.decodeIfPresent(String.self, forKey: .username)
        avatarURL = try container.decodeIfPresent(String.self, forKey: .avatarURL)
            ?? container.decodeIfPresent(String.self, forKey: .avatarThumbnailURL)
        avatarThumbnailURL = try container.decodeIfPresent(String.self, forKey: .avatarThumbnailURL)
        bio = try container.decodeIfPresent(String.self, forKey: .bio)
        sharedFavoriteTeamsCount = Self.decodeIntIfPresent(from: container, forKey: .sharedFavoriteTeamsCount) ?? 0
        sharedEventInterestCount = Self.decodeIntIfPresent(from: container, forKey: .sharedEventInterestCount) ?? 0
        sharedPickupGameCount = Self.decodeIntIfPresent(from: container, forKey: .sharedPickupGameCount) ?? 0
        mutualFriendCount = Self.decodeIntIfPresent(from: container, forKey: .mutualFriendCount) ?? 0
        mutualFriendAvatars = (try? container.decodeIfPresent([FriendSuggestionMutualFanAvatar].self, forKey: .mutualFriendAvatars)) ?? []
        score = Self.decodeDoubleIfPresent(from: container, forKey: .score) ?? 0
        reasonType = try container.decodeIfPresent(String.self, forKey: .reasonType)
        reasonLabel = try container.decodeIfPresent(String.self, forKey: .reasonLabel)
    }

    init(
        userID: UUID,
        email: String?,
        displayName: String?,
        handle: String?,
        avatarURL: String?,
        avatarThumbnailURL: String?,
        bio: String?,
        sharedFavoriteTeamsCount: Int,
        sharedEventInterestCount: Int,
        sharedPickupGameCount: Int,
        mutualFriendCount: Int,
        mutualFriendAvatars: [FriendSuggestionMutualFanAvatar],
        score: Double,
        reasonType: String?,
        reasonLabel: String?
    ) {
        self.userID = userID
        self.email = email
        self.displayName = displayName
        self.handle = handle
        self.avatarURL = avatarURL
        self.avatarThumbnailURL = avatarThumbnailURL
        self.bio = bio
        self.sharedFavoriteTeamsCount = sharedFavoriteTeamsCount
        self.sharedEventInterestCount = sharedEventInterestCount
        self.sharedPickupGameCount = sharedPickupGameCount
        self.mutualFriendCount = mutualFriendCount
        self.mutualFriendAvatars = mutualFriendAvatars
        self.score = score
        self.reasonType = reasonType
        self.reasonLabel = reasonLabel
    }

    func replacingAvatars(avatarURL: String?, avatarThumbnailURL: String?) -> FriendSuggestionProfile {
        FriendSuggestionProfile(
            userID: userID,
            email: email,
            displayName: displayName,
            handle: handle,
            avatarURL: avatarURL,
            avatarThumbnailURL: avatarThumbnailURL,
            bio: bio,
            sharedFavoriteTeamsCount: sharedFavoriteTeamsCount,
            sharedEventInterestCount: sharedEventInterestCount,
            sharedPickupGameCount: sharedPickupGameCount,
            mutualFriendCount: mutualFriendCount,
            mutualFriendAvatars: mutualFriendAvatars,
            score: score,
            reasonType: reasonType,
            reasonLabel: reasonLabel
        )
    }

    private static func decodeUUID(
        from container: KeyedDecodingContainer<CodingKeys>,
        preferredKey: CodingKeys,
        fallbackKey: CodingKeys
    ) throws -> UUID {
        if let uuid = try? container.decodeIfPresent(UUID.self, forKey: preferredKey) {
            return uuid
        }
        if let raw = try? container.decodeIfPresent(String.self, forKey: preferredKey),
           let uuid = UUID(uuidString: raw) {
            return uuid
        }
        if let uuid = try? container.decodeIfPresent(UUID.self, forKey: fallbackKey) {
            return uuid
        }
        if let raw = try? container.decodeIfPresent(String.self, forKey: fallbackKey),
           let uuid = UUID(uuidString: raw) {
            return uuid
        }

        throw DecodingError.keyNotFound(
            preferredKey,
            DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Expected UUID-compatible friend suggestion user_id."
            )
        )
    }

    private static func decodeIntIfPresent(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        if let raw = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int(raw)
        }
        return nil
    }

    private static func decodeDoubleIfPresent(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let raw = try? container.decodeIfPresent(String.self, forKey: key) {
            return Double(raw)
        }
        return nil
    }

    var reasonSignalsDebugDescription: String {
        var signals: [String] = []
        if mutualFriendCount > 0 { signals.append("mutual_fans:\(mutualFriendCount)") }
        if sharedFavoriteTeamsCount > 0 { signals.append("same_team:\(sharedFavoriteTeamsCount)") }
        if sharedEventInterestCount > 0 { signals.append("same_watch_party:\(sharedEventInterestCount)") }
        if sharedPickupGameCount > 0 { signals.append("same_pickup_game:\(sharedPickupGameCount)") }
        if let reasonType, !reasonType.isEmpty { signals.append("primary:\(reasonType)") }
        return signals.isEmpty ? "none" : signals.joined(separator: ",")
    }

    /// Client-only “Why suggested?” rows from already-decoded overlap counts.
    /// Never invents reasons and never surfaces score, distance, or private fields.
    func whySuggestedExplanations(max: Int = 3) -> [SuggestedFanWhyExplanation] {
        SuggestedFanWhyExplanation.make(from: self, max: max)
    }

    fileprivate var normalizedReasonType: String {
        (reasonType ?? "")
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    fileprivate var indicatesFavoriteVenueOverlap: Bool {
        switch normalizedReasonType {
        case "favorite_venue", "shared_venue", "venue":
            return true
        default:
            break
        }
        let label = (reasonLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return label == "Same venue"
            || label == "Both follow this venue"
    }

    fileprivate var indicatesSimilarVenueOverlap: Bool {
        if sharedEventInterestCount > 0 { return true }
        if indicatesFavoriteVenueOverlap { return true }
        switch normalizedReasonType {
        case "venue_event", "watch_party", "shared_event", "event_interest", "event":
            return true
        default:
            return false
        }
    }
}

/// Compact public-safe explanation derived from server reason + overlap fields.
/// Precedence follows strongest scoring component (server `reason_type`), not a hard-coded UI order.
enum SuggestedFanWhyExplanation: Equatable, Hashable, Sendable {
    case mutualFans(Int)
    case similarPickupGames
    case sameMyTeam
    case myTeamAffinity
    case nearby
    case similarWatchParty
    case sharedFavoriteTeams(Int)
    case similarVenues

    static func make(from profile: FriendSuggestionProfile, max: Int = 3) -> [SuggestedFanWhyExplanation] {
        guard max > 0 else { return [] }

        let primary = explanation(forServerReasonType: profile.reasonType, profile: profile)
        var ordered: [SuggestedFanWhyExplanation] = []
        if let primary {
            ordered.append(primary)
        }

        var secondary: [(SuggestedFansRanking.ReasonType, SuggestedFanWhyExplanation)] = []
        if profile.mutualFriendCount > 0 {
            secondary.append((.mutualFriends, .mutualFans(profile.mutualFriendCount)))
        }
        if profile.sharedPickupGameCount > 0 {
            secondary.append((.pickupGame, .similarPickupGames))
        }
        if profile.normalizedReasonType == "my_team" {
            secondary.append((.myTeam, .sameMyTeam))
        }
        if profile.normalizedReasonType == "my_team_affinity" {
            secondary.append((.myTeamAffinity, .myTeamAffinity))
        }
        if profile.normalizedReasonType == "proximity" {
            secondary.append((.proximity, .nearby))
        }
        if profile.sharedEventInterestCount > 0 {
            secondary.append((.venueEvent, .similarWatchParty))
        }
        if profile.sharedFavoriteTeamsCount > 0 {
            secondary.append((.favoriteTeam, .sharedFavoriteTeams(profile.sharedFavoriteTeamsCount)))
        }
        if profile.indicatesFavoriteVenueOverlap {
            secondary.append((.favoriteVenue, .similarVenues))
        }

        for (_, explanation) in secondary.sorted(by: { $0.0.tieBreakPriority < $1.0.tieBreakPriority }) {
            if ordered.contains(explanation) { continue }
            ordered.append(explanation)
            if ordered.count >= max { break }
        }

        return Array(ordered.prefix(max))
    }

    private static func explanation(
        forServerReasonType raw: String?,
        profile: FriendSuggestionProfile
    ) -> SuggestedFanWhyExplanation? {
        switch profile.normalizedReasonType {
        case "mutual_friends":
            return .mutualFans(max(profile.mutualFriendCount, 1))
        case "pickup_game":
            return .similarPickupGames
        case "my_team":
            return .sameMyTeam
        case "my_team_affinity":
            return .myTeamAffinity
        case "proximity":
            return .nearby
        case "venue_event", "watch_party", "shared_event", "event_interest", "event":
            return .similarWatchParty
        case "favorite_team", "shared_team", "team":
            return .sharedFavoriteTeams(max(profile.sharedFavoriteTeamsCount, 1))
        case "favorite_venue", "shared_venue", "venue":
            return .similarVenues
        case "recent_activity", "reputation", "fallback":
            // Soft quality / fallback — prefer a concrete overlap signal if present.
            if profile.mutualFriendCount > 0 { return .mutualFans(profile.mutualFriendCount) }
            if profile.sharedPickupGameCount > 0 { return .similarPickupGames }
            if profile.sharedFavoriteTeamsCount > 0 {
                return .sharedFavoriteTeams(profile.sharedFavoriteTeamsCount)
            }
            if profile.sharedEventInterestCount > 0 { return .similarWatchParty }
            return nil
        default:
            if let raw, !raw.isEmpty {
                return nil
            }
            return nil
        }
    }

    var systemImage: String {
        switch self {
        case .mutualFans: return "person.2.fill"
        case .similarPickupGames: return "figure.run"
        case .sameMyTeam, .myTeamAffinity, .sharedFavoriteTeams: return "sportscourt.fill"
        case .nearby: return "location.fill"
        case .similarWatchParty: return "tv.fill"
        case .similarVenues: return "building.2.fill"
        }
    }

    func localizedText(languageCode: String) -> String {
        let language = L10n.normalizedLanguageCode(languageCode)
        let locale = Locale(identifier: language)
        switch self {
        case .sharedFavoriteTeams(let count):
            let safe = max(count, 1)
            let countText = safe.formatted(.number.locale(locale))
            let key = safe == 1
                ? "suggested_fan_why_shared_teams_one_format"
                : "suggested_fan_why_shared_teams_other_format"
            return String(
                format: L10n.t(key, languageCode: language),
                locale: locale,
                countText
            )
        case .similarPickupGames:
            return L10n.t("suggested_fan_why_same_pickup", languageCode: language)
        case .similarWatchParty:
            return L10n.t("suggested_fan_why_same_watch_party", languageCode: language)
        case .similarVenues:
            return L10n.t("suggested_fan_why_same_venue_follow", languageCode: language)
        case .mutualFans(let count):
            let safe = max(count, 1)
            let countText = safe.formatted(.number.locale(locale))
            let key = safe == 1
                ? "suggested_fan_why_mutual_one_format"
                : "suggested_fan_why_mutual_other_format"
            return String(
                format: L10n.t(key, languageCode: language),
                locale: locale,
                countText
            )
        case .sameMyTeam:
            return L10n.t("suggested_fan_why_same_my_team", languageCode: language)
        case .myTeamAffinity:
            return L10n.t("suggested_fan_why_my_team_affinity", languageCode: language)
        case .nearby:
            return L10n.t("suggested_fan_why_nearby", languageCode: language)
        }
    }
}

/// Service-only wrapper for profile friend suggestions. UI and friendship flows remain separate.
final class FriendSuggestionsService {
    private let client: SupabaseClient

    /// Authoritative nearby radius for location-backed ranking (miles).
    /// Prefer ``SuggestedFansProduct/nearbyRadiusMiles``; kept identical for call-site clarity.
    nonisolated static let nearbyRadiusMiles = SuggestedFansProduct.nearbyRadiusMiles

    init(client: SupabaseClient = supabase) {
        self.client = client
    }

    nonisolated static let defaultFetchPoolLimit = 30
    nonisolated static let defaultDisplayLimit = 10

    func fetchSuggestions(
        limit: Int = defaultFetchPoolLimit,
        radiusMiles: Double = SuggestedFansProduct.nearbyRadiusMiles,
        centerLat: Double? = nil,
        centerLng: Double? = nil
    ) async throws -> [FriendSuggestionProfile] {
        #if DEBUG
        let coordinatesAvailable = centerLat != nil && centerLng != nil
        print(
            "[FriendSuggestionsService] fetch start limit=\(limit) radiusMiles=\(radiusMiles) coordinatesAvailable=\(coordinatesAvailable)"
        )
        #endif

        struct Params: Encodable {
            let p_limit: Int
            let p_radius_miles: Double
            let p_center_lat: Double?
            let p_center_lng: Double?
        }

        // Always send p_radius_miles explicitly; server default is also 45 (20260895).
        let resolvedRadiusMiles = radiusMiles > 0 ? radiusMiles : SuggestedFansProduct.nearbyRadiusMiles

        do {
            let rows: [FriendSuggestionProfile] = try await client
                .rpc(
                    "get_profile_friend_suggestions",
                    params: Params(
                        p_limit: limit,
                        p_radius_miles: resolvedRadiusMiles,
                        p_center_lat: centerLat,
                        p_center_lng: centerLng
                    )
                )
                .execute()
                .value

            #if DEBUG
            print("[FriendSuggestionsService] fetch success count=\(rows.count)")
            for row in rows {
                print("[FriendSuggestionsDebug] mutualFriendCount=\(row.mutualFriendCount) user_id=\(row.userID.uuidString.lowercased())")
                print("[FriendSuggestionsDebug] reasonSignals=\(row.reasonSignalsDebugDescription) user_id=\(row.userID.uuidString.lowercased())")
                print("[FriendSuggestionsDebug] rankingScore=\(row.score) user_id=\(row.userID.uuidString.lowercased())")
                print("[FriendSuggestionsDebug] reasonType=\(row.reasonType ?? "nil") user_id=\(row.userID.uuidString.lowercased())")
            }
            #endif

            // Preserve authoritative server order (already diversity-shaped for the fetch pool).
            return rows
        } catch {
            #if DEBUG
            print("[FriendSuggestionsService] fetch failed error=\(error.localizedDescription)")
            #endif
            throw error
        }
    }

    func dismissSuggestion(dismissedUserId: UUID) async throws {
        let session = try await client.auth.session
        let viewerId = session.user.id

        struct Row: Encodable {
            let user_id: UUID
            let dismissed_user_id: UUID
        }

        try await client
            .from("suggested_fan_dismissals")
            .upsert(Row(user_id: viewerId, dismissed_user_id: dismissedUserId), onConflict: "user_id,dismissed_user_id")
            .execute()
    }
}
