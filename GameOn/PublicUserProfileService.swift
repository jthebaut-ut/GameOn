import Foundation
import Supabase

/// Friend CTA state for ``PublicUserProfilePreviewView`` (derived from ``ChatViewModel/FriendshipChipKind``).
enum PublicProfileFriendButtonState: Equatable {
    case hidden
    case messageFriend
    case requestFriendship
    case friendshipRequested
}

/// Loaded public-safe profile payload (no email shown in UI).
struct PublicUserProfileData {
    let userId: UUID
    let displayName: String
    /// @handle line; may use temporary email-prefix fallback when username unset (email never shown).
    let publicHandleLine: String
    /// Raw `user_profiles.created_at` for inline fan-since handle copy (display only).
    let profileCreatedAt: String?
    let bio: String?
    let avatarURL: String?
    let avatarThumbnailURL: String?
    /// Authoritative Fan XP total from `user_xp` (defaults to 0).
    let totalXP: Int
    let reputation: FanReputationProfile
    let organizerStats: PickupCreatorPublicRatingStats?
    let favoriteTeams: [FavoriteTeam]
    let primaryFavoriteTeamID: String?
    let nationalTeam: NationalTeamIdentity?
    /// Resolved curated background key (always safe; defaults to FanGeo).
    let profileBackgroundKey: ProfileBackgroundKey
    let isBusinessAccount: Bool
    /// True when `user_profiles` row was loaded from network or cache (not purely synthetic).
    let hasResolvedIdentity: Bool
    /// False when the viewer cannot open this profile (blocked, missing, or not discoverable/friend).
    let isPubliclyVisible: Bool
    /// Global Discover My Profile flag. Independent of viewer access: accepted friends may
    /// see `isPubliclyVisible == true` while this remains `false`.
    let isDiscoverableByFans: Bool
    let memberSinceLabel: String?
    let openToItems: [PublicProfileOpenToItem]
    let mutualFansCount: Int
    let mutualFanAvatars: [PublicProfileMutualFanAvatar]
    let sharedTeamsCount: Int
    let venueCount: Int
    let venueCards: [PublicProfileVenueCard]
    let homeCrowd: HomeCrowdVenueSummary?
    /// Public home city line when `show_home_city` is enabled on the profile row (no GPS).
    let homeCityDisplayLine: String?
    let pickupHostedCount: Int
    let pickupJoinedCount: Int
    /// Latest eligible hosted-game `created_at` from organizer summary RPC (nil when none).
    let lastPickupGameCreatedAt: Date?
    let socialHighlightLabels: [String]
    let personalityTags: [String]
    let sharedTeamNames: [String]
    /// Privacy-gated `last_seen_at` for Last active UI (nil when hidden / unavailable).
    let lastSeenAtRaw: String?

    var publicHandleDisplayLine: String {
        FanGeoHandleRules.handleDisplayLine(
            base: publicHandleLine,
            profileCreatedAt: profileCreatedAt,
            showFanSince: !isBusinessAccount
        )
    }

    func replacingAvatars(avatarURL: String?, avatarThumbnailURL: String?) -> PublicUserProfileData {
        PublicUserProfileData(
            userId: userId,
            displayName: displayName,
            publicHandleLine: publicHandleLine,
            profileCreatedAt: profileCreatedAt,
            bio: bio,
            avatarURL: avatarURL,
            avatarThumbnailURL: avatarThumbnailURL,
            totalXP: totalXP,
            reputation: reputation,
            organizerStats: organizerStats,
            favoriteTeams: favoriteTeams,
            primaryFavoriteTeamID: primaryFavoriteTeamID,
            nationalTeam: nationalTeam,
            profileBackgroundKey: profileBackgroundKey,
            isBusinessAccount: isBusinessAccount,
            hasResolvedIdentity: hasResolvedIdentity,
            isPubliclyVisible: isPubliclyVisible,
            isDiscoverableByFans: isDiscoverableByFans,
            memberSinceLabel: memberSinceLabel,
            openToItems: openToItems,
            mutualFansCount: mutualFansCount,
            mutualFanAvatars: mutualFanAvatars,
            sharedTeamsCount: sharedTeamsCount,
            venueCount: venueCount,
            venueCards: venueCards,
            homeCrowd: homeCrowd,
            homeCityDisplayLine: homeCityDisplayLine,
            pickupHostedCount: pickupHostedCount,
            pickupJoinedCount: pickupJoinedCount,
            lastPickupGameCreatedAt: lastPickupGameCreatedAt,
            socialHighlightLabels: socialHighlightLabels,
            personalityTags: personalityTags,
            sharedTeamNames: sharedTeamNames,
            lastSeenAtRaw: lastSeenAtRaw
        )
    }

    /// Self-preview only: fill gaps from already-loaded owner state without changing public visibility rules.
    /// Prefer the owner's live My Team selection so national-fan sport subtitles stay consistent.
    func seededForSelfPreview(
        homeCrowd ownerHomeCrowd: HomeCrowdVenueSummary?,
        openToPreferences ownerPreferences: FanIdentityPreferences,
        primaryFavoriteTeamID ownerPrimaryFavoriteTeamID: String? = nil,
        favoriteTeams ownerFavoriteTeams: [FavoriteTeam]? = nil,
        profileBackgroundKey ownerProfileBackgroundKey: ProfileBackgroundKey? = nil
    ) -> PublicUserProfileData {
        let seededHome = homeCrowd ?? ownerHomeCrowd
        let seededFavoriteTeams: [FavoriteTeam] = {
            guard let ownerFavoriteTeams, !ownerFavoriteTeams.isEmpty else { return favoriteTeams }
            return ownerFavoriteTeams
        }()
        let seededPrimaryID = FavoriteTeamsStore.explicitPrimaryTeamID(
            ownerPrimaryFavoriteTeamID ?? primaryFavoriteTeamID,
            within: seededFavoriteTeams.map(\.id)
        )
        let seededBackground = ownerProfileBackgroundKey ?? profileBackgroundKey
        let ownerOpenTo = PublicProfileOpenToBuilder.items(
            preferences: ownerPreferences,
            favoriteTeams: seededFavoriteTeams,
            venueCount: venueCount,
            pickupHostedCount: pickupHostedCount,
            pickupJoinedCount: pickupJoinedCount
        )
        let seededOpenTo = openToItems.count >= ownerOpenTo.count ? openToItems : ownerOpenTo
        let homeChanged = seededHome?.venueId != homeCrowd?.venueId
        let openToChanged = seededOpenTo.count != openToItems.count
        let teamsChanged = seededFavoriteTeams.map(\.id) != favoriteTeams.map(\.id)
        let primaryChanged = seededPrimaryID != primaryFavoriteTeamID
        let backgroundChanged = seededBackground != profileBackgroundKey
        guard homeChanged || openToChanged || teamsChanged || primaryChanged || backgroundChanged else {
            return self
        }
        return PublicUserProfileData(
            userId: userId,
            displayName: displayName,
            publicHandleLine: publicHandleLine,
            profileCreatedAt: profileCreatedAt,
            bio: bio,
            avatarURL: avatarURL,
            avatarThumbnailURL: avatarThumbnailURL,
            totalXP: totalXP,
            reputation: reputation,
            organizerStats: organizerStats,
            favoriteTeams: seededFavoriteTeams,
            primaryFavoriteTeamID: seededPrimaryID,
            nationalTeam: nationalTeam,
            profileBackgroundKey: seededBackground,
            isBusinessAccount: isBusinessAccount,
            hasResolvedIdentity: hasResolvedIdentity,
            isPubliclyVisible: isPubliclyVisible,
            isDiscoverableByFans: isDiscoverableByFans,
            memberSinceLabel: memberSinceLabel,
            openToItems: seededOpenTo,
            mutualFansCount: mutualFansCount,
            mutualFanAvatars: mutualFanAvatars,
            sharedTeamsCount: sharedTeamsCount,
            venueCount: venueCount,
            venueCards: venueCards,
            homeCrowd: seededHome,
            homeCityDisplayLine: homeCityDisplayLine,
            pickupHostedCount: pickupHostedCount,
            pickupJoinedCount: pickupJoinedCount,
            lastPickupGameCreatedAt: lastPickupGameCreatedAt,
            socialHighlightLabels: socialHighlightLabels,
            personalityTags: personalityTags,
            sharedTeamNames: sharedTeamNames,
            lastSeenAtRaw: lastSeenAtRaw
        )
    }
}

/// Compact venue chip for public profile cards (city only — no coordinates).
struct PublicProfileVenueCard: Equatable, Identifiable {
    let venueId: UUID?
    let venueName: String
    let cityLabel: String
    let thumbnailURL: String?

    var id: String {
        venueId?.uuidString.lowercased() ?? "\(venueName)-\(cityLabel)"
    }
}

/// Mutual friend avatar for stacked display.
struct PublicProfileMutualFanAvatar: Equatable, Identifiable {
    let userId: UUID
    let displayName: String
    let avatarURL: String?

    var id: UUID { userId }
}

enum PublicUserProfileService {
    private static let profileSelect =
        "id,email,display_name,username,bio,avatar_url,avatar_thumbnail_url,is_deleted,admin_status,live_visibility_enabled,live_visibility_mode,selected_live_visibility_friend_ids,discoverable_by_fans,created_at,national_team_country_code,national_team_country_name,national_team_flag,national_team_supporter_label,national_team_updated_at,home_city,home_region,home_country,show_home_city,profile_background_key"

    /// Always returns a displayable profile; optional sections use safe fallbacks.
    /// - Parameter isSelfPreview: When `true` and `userId` matches the authenticated session user,
    ///   loads the signed-in fan’s public projection even if discoverability is off.
    ///   Does not weaken visibility for other viewers.
    static func load(
        userId: UUID,
        cachedProfile: UserProfileRow? = nil,
        isSelfPreview: Bool = false
    ) async -> PublicUserProfileData {
#if DEBUG
        print("[PublicProfilePreview] requested selfPreview=\(isSelfPreview)")
#endif
        if isSelfPreview {
            let authId = await authenticatedSessionUserId()
            let ownershipMatch = authId == userId
#if DEBUG
            print("[PublicProfilePreview] ownershipMatch=\(ownershipMatch)")
#endif
            if ownershipMatch {
#if DEBUG
                print("[PublicProfilePreview] loaderPath=self")
#endif
                return await loadSelfPublicProjection(userId: userId, cachedProfile: cachedProfile)
            }
#if DEBUG
            print("[PublicProfilePreview] rejected reason=idMismatch")
            print("[PublicProfilePreview] loaderPath=public")
#endif
        } else {
#if DEBUG
            print("[PublicProfilePreview] ownershipMatch=false")
            print("[PublicProfilePreview] loaderPath=public")
#endif
        }

#if DEBUG
        print("[PublicProfileLoadDebug] requestedUserId=\(userId.uuidString.lowercased())")
#endif
        if cachedProfile?.isDeletedAccount == true {
            logPublicProfileBlocked(userId: userId, reason: "deleted_cached")
#if DEBUG
            print("[PublicProfilePreview] rejected reason=missingProfile")
            print("[PublicProfilePreview] loaded success=false")
#endif
            return hiddenProfile(userId: userId)
        }

        if let identity = await fetchPublicIdentityRPC(targetUserId: userId) {
            SuggestedFanProfileOpenDebug.rpcReceived(visible: identity.visible)
            if identity.visible {
                let assembled = await assembleFromIdentityRPC(identity, userId: userId, cachedProfile: cachedProfile)
#if DEBUG
                print("[PublicProfilePreview] loaded success=true")
#endif
                return assembled
            }
            logPublicProfileBlocked(userId: userId, reason: "identity_not_visible")
#if DEBUG
            print("[PublicProfilePreview] rejected reason=discoverability")
            print("[PublicProfilePreview] loaded success=false")
#endif
            SuggestedFanProfileOpenDebug.failure("identity_not_visible")
            return hiddenProfile(userId: userId)
        }

        return await loadLegacy(userId: userId, cachedProfile: cachedProfile)
    }

    /// Authenticated own-profile public projection for WYSIWYG self-preview.
    /// Bypasses discoverability / “viewer ≠ target” RPC gates only for `auth.uid() == userId`.
    private static func loadSelfPublicProjection(
        userId: UUID,
        cachedProfile: UserProfileRow?
    ) async -> PublicUserProfileData {
        let fetched = await fetchProfileRow(userId: userId)
        let row: UserProfileRow?
        if let fetchedRow = fetched.row {
            row = fetchedRow
        } else if let cached = cachedProfile, cached.id == userId {
            row = cached
        } else {
            row = nil
        }
        let profileQuerySuccess = fetched.success || row != nil

        if row == nil && !profileQuerySuccess {
#if DEBUG
            print("[PublicProfilePreview] rejected reason=queryFailure")
            print("[PublicProfilePreview] loaded success=false")
#endif
            return hiddenProfile(userId: userId)
        }

        if row?.isDeletedAccount == true {
            logPublicProfileBlocked(userId: userId, reason: "deleted_self_preview")
#if DEBUG
            print("[PublicProfilePreview] rejected reason=missingProfile")
            print("[PublicProfilePreview] loaded success=false")
#endif
            return hiddenProfile(userId: userId)
        }

        let isBusiness = await resolveIsBusinessAccount(userId: userId, profileRow: row)
        if isBusiness {
            logPublicProfileBlocked(userId: userId, reason: "business_self_preview")
#if DEBUG
            print("[PublicProfilePreview] rejected reason=missingProfile")
            print("[PublicProfilePreview] loaded success=false")
#endif
            return hiddenProfile(userId: userId)
        }

        if let adminStatus = row?.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !adminStatus.isEmpty,
           adminStatus != "active" {
            logPublicProfileBlocked(userId: userId, reason: "inactive_self_preview")
#if DEBUG
            print("[PublicProfilePreview] rejected reason=missingProfile")
            print("[PublicProfilePreview] loaded success=false")
#endif
            return hiddenProfile(userId: userId)
        }

        let (fanXP, _) = await loadPublicXP(userId: userId)
        let organizerSummary = await fetchOrganizerProfileSummary(userId: userId)
        let organizerStats = PickupCreatorPublicRatingStats(
            avgRating: organizerSummary.averageRating ?? 0,
            ratingCount: organizerSummary.ratingCount
        )
        let pickupHosted = organizerSummary.hostedCount
        let favoriteSelection = await fetchPublicFavoriteTeamSelection(userId: userId)
        let favoriteTeams = FavoriteTeamsStore.resolvedTeams(fromIDs: favoriteSelection.teamIDs)
        let preferences = await fetchFanIdentityPreferences(userId: userId) ?? .empty
        // Public home-crowd RPCs intentionally return nil when viewer == target.
        // Self-preview must use the owner-safe profile pointer path so WYSIWYG
        // matches what other fans see via those RPCs.
        let homeCrowd = await fetchSelfHomeCrowdForPublicProjection(userId: userId)
        let lastSeenAtRaw = row?.last_seen_at

        let built = buildProfileData(
            userId: userId,
            row: row,
            fanXP: fanXP,
            organizerStats: organizerStats,
            favoriteTeams: favoriteTeams,
            primaryFavoriteTeamID: favoriteSelection.primaryTeamID,
            isBusinessAccount: false,
            hasResolvedIdentity: profileQuerySuccess,
            isPubliclyVisible: true,
            isDiscoverableByFans: row?.discoverableByFans ?? true,
            memberSinceLabel: resolveMemberSinceLabel(
                rpcMemberSince: nil,
                profileCreatedAt: row?.created_at
            ),
            openToItems: resolvePublicOpenToItems(
                preferences: preferences,
                favoriteTeams: favoriteTeams,
                venueCount: 0,
                pickupHostedCount: pickupHosted,
                pickupJoinedCount: 0
            ),
            mutualFansCount: 0,
            mutualFanAvatars: [],
            sharedTeamsCount: 0,
            venueCount: 0,
            venueCards: [],
            homeCrowd: homeCrowd,
            pickupHostedCount: pickupHosted,
            pickupJoinedCount: 0,
            lastPickupGameCreatedAt: organizerSummary.lastPickupGameCreatedAt,
            sharedTeamNames: [],
            lastSeenAtRaw: lastSeenAtRaw
        )

#if DEBUG
        print("[PublicProfilePreview] loaded success=true")
#endif
        logRenderedHomeCrowd(built.homeCrowd?.venueId)
        return built
    }

    private static func authenticatedSessionUserId() async -> UUID? {
        (try? await supabase.auth.session)?.user.id
    }

    /// Discovery eligibility for Suggested Fans / Nearby-style filters.
    /// Uses global discoverability — not mere friend-visible profile access.
    static func isPublicIdentityVisible(userId: UUID) async -> Bool {
        if let identity = await fetchPublicIdentityRPC(targetUserId: userId) {
            // Friend exception can yield visible=true while discoverable_by_fans=false.
            return identity.visible && (identity.discoverable_by_fans ?? true)
        }

        let fetched = await fetchProfileRow(userId: userId)
        guard let row = fetched.row else { return false }
        if row.isDeletedAccount { return false }
        if row.isBusinessIdentity { return false }
        if !row.discoverableByFans { return false }
        if let adminStatus = row.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !adminStatus.isEmpty,
           adminStatus != "active" {
            return false
        }
        return true
    }

#if DEBUG
    private static func logPublicProfileBlocked(userId: UUID, reason: String) {
        print("[PublicProfileDebug] loadBlocked reason=\(reason) user_id=\(userId.uuidString.lowercased())")
    }
#else
    private static func logPublicProfileBlocked(userId: UUID, reason: String) {}
#endif

    static func userProfileRow(from preview: UserPreview, includeAvatars: Bool = true) -> UserProfileRow {
        UserProfileRow(
            id: preview.id,
            email: preview.email,
            display_name: preview.displayName,
            username: preview.username,
            bio: nil,
            avatar_url: includeAvatars ? preview.avatarURL : nil,
            avatar_thumbnail_url: includeAvatars ? preview.avatarThumbnailURL : nil,
            is_business_account: preview.isBusinessAccount,
            admin_status: "active",
            live_visibility_enabled: true,
            live_visibility_mode: LiveVisibilityMode.allFriends.rawValue,
            selected_live_visibility_friend_ids: [],
            is_deleted: preview.isDeleted
        )
    }

    static func friendButtonState(
        for userId: UUID,
        chipKind: ChatViewModel.FriendshipChipKind,
        isBlocked: Bool,
        isSelf: Bool,
        isBusiness: Bool
    ) -> PublicProfileFriendButtonState {
        if isSelf || isBlocked || isBusiness { return .hidden }
        switch chipKind {
        case .friends:
            return .messageFriend
        case .addFriend, .declinedOutgoing:
            return .requestFriendship
        case .pendingOutgoing, .pendingIncoming:
            return .friendshipRequested
        }
    }

    // MARK: - RPC

    private struct PublicIdentityRPCResponse: Decodable {
        let visible: Bool
        /// Present after friend-exception migration; nil on older backends defaults to discoverable.
        let discoverable_by_fans: Bool?
        let user_id: UUID?
        let display_name: String?
        let username: String?
        let bio: String?
        let avatar_url: String?
        let avatar_thumbnail_url: String?
        let member_since: String?
        let favorite_team_ids: [String]?
        let primary_favorite_team_id: String?
        let mutual_fans_count: Int?
        let shared_teams_count: Int?
        let venue_count: Int?
        let pickup_hosted_count: Int?
        let pickup_joined_count: Int?
        let mutual_fan_avatars: [MutualFanRow]?
        let venue_cards: [VenueCardRow]?
        let fan_identity_preferences: FanIdentityPreferences?
        let shared_team_ids: [String]?
        let home_crowd_venue: HomeCrowdVenueSummary?
        let national_team_country_code: String?
        let national_team_country_name: String?
        let national_team_flag: String?
        let national_team_supporter_label: String?
        let home_city: String?
        let home_region: String?
        let home_country: String?
        let show_home_city: Bool?
        /// Present after 20260871; nil on older backends triggers optional user_xp fallback.
        let total_xp: Int?
        let xp_level: Int?
        let xp_title: String?
        /// Present after 20260874; nil on older backends triggers organizer stats fallback RPC.
        let pickup_games_hosted_count: Int?
        let pickup_organizer_average_rating: PickupRPCNumericOrString?
        let pickup_organizer_rating_count: Int?
        /// Present after 20260875; ISO timestamptz string when hosted games exist.
        let last_pickup_game_created_at: String?
        /// Present after 20260885; curated background catalog key.
        let profile_background_key: String?

        struct MutualFanRow: Decodable {
            let user_id: UUID?
            let display_name: String?
            let avatar_url: String?
        }

        struct VenueCardRow: Decodable {
            let venue_id: UUID?
            let venue_name: String?
            let city_label: String?
            let thumbnail_url: String?
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            visible = try c.decode(Bool.self, forKey: .visible)
            discoverable_by_fans = try? c.decode(Bool.self, forKey: .discoverable_by_fans)
            user_id = try? c.decode(UUID.self, forKey: .user_id)
            display_name = try? c.decode(String.self, forKey: .display_name)
            username = try? c.decode(String.self, forKey: .username)
            bio = try? c.decode(String.self, forKey: .bio)
            avatar_url = try? c.decode(String.self, forKey: .avatar_url)
            avatar_thumbnail_url = try? c.decode(String.self, forKey: .avatar_thumbnail_url)
            member_since = try? c.decode(String.self, forKey: .member_since)
            favorite_team_ids = try? c.decode([String].self, forKey: .favorite_team_ids)
            primary_favorite_team_id = try? c.decode(String.self, forKey: .primary_favorite_team_id)
            mutual_fans_count = try? c.decode(Int.self, forKey: .mutual_fans_count)
            shared_teams_count = try? c.decode(Int.self, forKey: .shared_teams_count)
            venue_count = try? c.decode(Int.self, forKey: .venue_count)
            pickup_hosted_count = try? c.decode(Int.self, forKey: .pickup_hosted_count)
            pickup_joined_count = try? c.decode(Int.self, forKey: .pickup_joined_count)
            mutual_fan_avatars = try? c.decode([MutualFanRow].self, forKey: .mutual_fan_avatars)
            venue_cards = try? c.decode([VenueCardRow].self, forKey: .venue_cards)
            shared_team_ids = try? c.decode([String].self, forKey: .shared_team_ids)
            national_team_country_code = try? c.decode(String.self, forKey: .national_team_country_code)
            national_team_country_name = try? c.decode(String.self, forKey: .national_team_country_name)
            national_team_flag = try? c.decode(String.self, forKey: .national_team_flag)
            national_team_supporter_label = try? c.decode(String.self, forKey: .national_team_supporter_label)
            home_city = try? c.decode(String.self, forKey: .home_city)
            home_region = try? c.decode(String.self, forKey: .home_region)
            home_country = try? c.decode(String.self, forKey: .home_country)
            show_home_city = try? c.decode(Bool.self, forKey: .show_home_city)
            total_xp = try? c.decode(Int.self, forKey: .total_xp)
            xp_level = try? c.decode(Int.self, forKey: .xp_level)
            xp_title = try? c.decode(String.self, forKey: .xp_title)
            pickup_games_hosted_count = try? c.decode(Int.self, forKey: .pickup_games_hosted_count)
            pickup_organizer_average_rating = try? c.decode(PickupRPCNumericOrString.self, forKey: .pickup_organizer_average_rating)
            pickup_organizer_rating_count = try? c.decode(Int.self, forKey: .pickup_organizer_rating_count)
            last_pickup_game_created_at = try? c.decode(String.self, forKey: .last_pickup_game_created_at)
            profile_background_key = try? c.decode(String.self, forKey: .profile_background_key)
            if c.contains(.home_crowd_venue) {
                if (try? c.decodeNil(forKey: .home_crowd_venue)) == true {
                    home_crowd_venue = nil
                    print("[HomeCrowdDebug] publicRpcHomeCrowd= null")
                } else if let nested = try? c.superDecoder(forKey: .home_crowd_venue),
                          let lenient = HomeCrowdVenueSummary.decodeLenient(from: nested) {
                    home_crowd_venue = lenient
                    print(
                        "[HomeCrowdDebug] publicRpcHomeCrowd= venueId=\(lenient.venueId.uuidString.lowercased()) name=\(lenient.name) source=lenient"
                    )
                } else if let decoded = try? c.decode(HomeCrowdVenueSummary.self, forKey: .home_crowd_venue) {
                    home_crowd_venue = decoded
                    print(
                        "[HomeCrowdDebug] publicRpcHomeCrowd= venueId=\(decoded.venueId.uuidString.lowercased()) name=\(decoded.name) source=strict"
                    )
                } else {
                    home_crowd_venue = nil
                    print("[HomeCrowdDebug] publicRpcHomeCrowdDecodeFailed")
                }
            } else {
                home_crowd_venue = nil
                print("[HomeCrowdDebug] publicRpcHomeCrowd= missing_key")
            }

            if let prefs = try? c.decode(FanIdentityPreferences.self, forKey: .fan_identity_preferences) {
                fan_identity_preferences = prefs
            } else {
                fan_identity_preferences = nil
                print("[OpenToDebug] publicRpcPreferencesDecodeFailed")
            }
        }

        private enum CodingKeys: String, CodingKey {
            case visible
            case discoverable_by_fans
            case user_id
            case display_name
            case username
            case bio
            case avatar_url
            case avatar_thumbnail_url
            case member_since
            case favorite_team_ids
            case primary_favorite_team_id
            case mutual_fans_count
            case shared_teams_count
            case venue_count
            case pickup_hosted_count
            case pickup_joined_count
            case mutual_fan_avatars
            case venue_cards
            case fan_identity_preferences
            case shared_team_ids
            case home_crowd_venue
            case national_team_country_code
            case national_team_country_name
            case national_team_flag
            case national_team_supporter_label
            case home_city
            case home_region
            case home_country
            case show_home_city
            case total_xp
            case xp_level
            case xp_title
            case pickup_games_hosted_count
            case pickup_organizer_average_rating
            case pickup_organizer_rating_count
            case last_pickup_game_created_at
            case profile_background_key
        }
    }

    private static func fetchPublicIdentityRPC(targetUserId: UUID) async -> PublicIdentityRPCResponse? {
        struct Params: Encodable {
            let p_target_user_id: UUID
        }

        do {
            let payload: PublicIdentityRPCResponse = try await supabase
                .rpc(
                    "get_public_fan_identity_profile",
                    params: Params(p_target_user_id: targetUserId)
                )
                .execute()
                .value
#if DEBUG
            print(
                "[PublicProfileLoadDebug] identityRPC visible=\(payload.visible) mutual=\(payload.mutual_fans_count ?? 0) venues=\(payload.venue_count ?? 0)"
            )
#endif
            let prefs = payload.fan_identity_preferences ?? .empty
            print(
                "[OpenToDebug] publicRpcPreferences= ids=\(prefs.resolvedOpenToItemIDs) keyPresent=\(prefs.openToItemsKeyPresent)"
            )
            return payload
        } catch {
#if DEBUG
            print("[PublicProfileLoadDebug] identityRPC_failed error=\(error.localizedDescription)")
#endif
            print("[OpenToDebug] publicRpcPreferences= decode_failed error=\(error.localizedDescription)")
            return nil
        }
    }

    private static func fetchFanIdentityPreferences(userId: UUID) async -> FanIdentityPreferences? {
        struct Row: Decodable {
            let fan_identity_preferences: FanIdentityPreferences?
        }

        do {
            let rows: [Row] = try await supabase
                .from("user_profiles")
                .select("fan_identity_preferences")
                .eq("id", value: userId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value
            return rows.first?.fan_identity_preferences
        } catch {
            print("[OpenToDebug] fetchFanIdentityPreferences failed userId=\(userId.uuidString.lowercased()) error=\(error.localizedDescription)")
            return nil
        }
    }

    private static func resolvePublicHomeCrowd(_ rpcVenue: HomeCrowdVenueSummary?) -> HomeCrowdVenueSummary? {
        guard let rpcVenue else {
            print("[HomeCrowdDebug] decodedPublicHomeCrowd= nil")
            logRenderedHomeCrowd(nil)
            return nil
        }
        let trimmedName = rpcVenue.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            print(
                "[HomeCrowdDebug] decodedPublicHomeCrowd= rejected_empty_name venueId=\(rpcVenue.venueId.uuidString.lowercased())"
            )
            logRenderedHomeCrowd(nil)
            return nil
        }
        let normalized = normalizedHomeCrowdSummary(rpcVenue)
        print(
            "[HomeCrowdDebug] decodedPublicHomeCrowd= venueId=\(normalized.venueId.uuidString.lowercased()) name=\(normalized.name)"
        )
        logRenderedHomeCrowd(normalized.venueId)
        return normalized
    }

    private static func logRenderedHomeCrowd(_ venueId: UUID?) {
        let value = venueId?.uuidString.lowercased() ?? "nil"
        print("[HomeCrowdDebug] renderedHomeCrowd venueId=\(value)")
    }

    private static func fetchPublicHomeCrowdForLegacyProfile(userId: UUID) async -> HomeCrowdVenueSummary? {
        if let identity = await fetchPublicIdentityRPC(targetUserId: userId), identity.visible,
           let crowd = resolvePublicHomeCrowd(identity.home_crowd_venue) {
            print("[HomeCrowdDebug] legacyHomeCrowd= source=identity_rpc")
            return crowd
        }

        if let crowd = await fetchSupplementalPublicHomeCrowd(userId: userId) {
            print("[HomeCrowdDebug] legacyHomeCrowd= source=supplemental")
            return crowd
        }

        print("[HomeCrowdDebug] legacyHomeCrowd= nil")
        logRenderedHomeCrowd(nil)
        return nil
    }

    /// Dedicated public Home Crowd RPCs / pointer fallbacks when the identity payload omits the venue.
    private static func fetchSupplementalPublicHomeCrowd(userId: UUID) async -> HomeCrowdVenueSummary? {
        if let dedicated = await HomeCrowdService.fetchPublicHomeCrowdForFan(targetUserId: userId),
           let crowd = resolvePublicHomeCrowd(dedicated) {
            print("[HomeCrowdDebug] supplementalHomeCrowd= source=dedicated_rpc")
            return crowd
        }

        if let pointer = await HomeCrowdService.fetchPublicHomeCrowdPointer(targetUserId: userId) {
            if let summary = await HomeCrowdService.fetchVenueSummaryForPublicProfile(
                venueId: pointer.venue_id,
                setAt: pointer.home_crowd_set_at,
                excludeUserId: userId
            ), let crowd = resolvePublicHomeCrowd(summary) {
                print("[HomeCrowdDebug] supplementalHomeCrowd= source=venue_summary_rpc")
                return crowd
            }

            if let tableSummary = await HomeCrowdService.fetchVenueSummaryFromTable(
                venueId: pointer.venue_id,
                setAt: pointer.home_crowd_set_at
            ), let crowd = resolvePublicHomeCrowd(tableSummary) {
                print("[HomeCrowdDebug] supplementalHomeCrowd= source=venues_table")
                return crowd
            }
        }

        print("[HomeCrowdDebug] supplementalHomeCrowd= nil")
        return nil
    }

    /// Owner-safe Home Crowd load for self public-profile preview.
    /// Does not use public RPCs that reject `viewer == target`.
    private static func fetchSelfHomeCrowdForPublicProjection(userId: UUID) async -> HomeCrowdVenueSummary? {
        let loaded = await HomeCrowdService.loadSelfHomeCrowd(userId: userId)
        if let summary = resolvePublicHomeCrowd(loaded.summary) {
            print("[HomeCrowdDebug] selfPreviewHomeCrowd= source=owner_profile_pointer")
            return summary
        }

        // Venue id present but summary RPC failed — fall back to venues table identity.
        if let venueId = loaded.venueId,
           let tableSummary = await HomeCrowdService.fetchVenueSummaryFromTable(
                venueId: venueId,
                setAt: nil
           ),
           let crowd = resolvePublicHomeCrowd(tableSummary) {
            print("[HomeCrowdDebug] selfPreviewHomeCrowd= source=venues_table")
            return crowd
        }

        print("[HomeCrowdDebug] selfPreviewHomeCrowd= nil")
        logRenderedHomeCrowd(nil)
        return nil
    }

    private static func resolvePublicOpenToItems(
        preferences: FanIdentityPreferences,
        favoriteTeams: [FavoriteTeam],
        venueCount: Int,
        pickupHostedCount: Int,
        pickupJoinedCount: Int
    ) -> [PublicProfileOpenToItem] {
        print("[OpenToDebug] decodedOpenToItems= \(preferences.resolvedOpenToItemIDs)")
        let items = PublicProfileOpenToBuilder.items(
            preferences: preferences,
            favoriteTeams: favoriteTeams,
            venueCount: venueCount,
            pickupHostedCount: pickupHostedCount,
            pickupJoinedCount: pickupJoinedCount
        )
        print("[OpenToDebug] renderedOpenToCount= \(items.count)")
        return items
    }

    private static func assembleFromIdentityRPC(
        _ rpc: PublicIdentityRPCResponse,
        userId: UUID,
        cachedProfile: UserProfileRow?
    ) async -> PublicUserProfileData {
        var teamIDs = rpc.favorite_team_ids ?? []
        let rpcPrimaryRaw = rpc.primary_favorite_team_id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var primaryTeamID: String? = !rpcPrimaryRaw.isEmpty && teamIDs.contains(rpcPrimaryRaw)
            ? rpcPrimaryRaw
            : nil
        if primaryTeamID == nil, !teamIDs.isEmpty {
            let selection = await fetchPublicFavoriteTeamSelection(userId: userId)
            if !selection.teamIDs.isEmpty {
                teamIDs = selection.teamIDs
                primaryTeamID = selection.primaryTeamID
            }
        }
        let favoriteTeams = FavoriteTeamsStore.resolvedTeams(fromIDs: teamIDs)

        let resolvedBio = resolveProfileBio(rpcBio: rpc.bio, cachedBio: cachedProfile?.bio)
#if DEBUG
        print("[ProfileBioDebug] publicProfileLoadedBio=\(resolvedBio ?? "")")
#endif

        let isDiscoverableByFans = rpc.discoverable_by_fans ?? true

        let row = UserProfileRow(
            id: userId,
            email: cachedProfile?.email,
            display_name: rpc.display_name,
            username: rpc.username,
            bio: resolvedBio,
            avatar_url: rpc.avatar_url,
            avatar_thumbnail_url: rpc.avatar_thumbnail_url,
            is_business_account: false,
            admin_status: "active",
            live_visibility_enabled: true,
            live_visibility_mode: LiveVisibilityMode.allFriends.rawValue,
            selected_live_visibility_friend_ids: [],
            discoverable_by_fans: isDiscoverableByFans,
            created_at: {
                let rpcSince = rpc.member_since?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !rpcSince.isEmpty { return rpcSince }
                return cachedProfile?.created_at
            }(),
            national_team_country_code: rpc.national_team_country_code,
            national_team_country_name: rpc.national_team_country_name,
            national_team_flag: rpc.national_team_flag,
            national_team_supporter_label: rpc.national_team_supporter_label,
            home_city: rpc.show_home_city == true ? rpc.home_city : nil,
            home_region: rpc.show_home_city == true ? rpc.home_region : nil,
            home_country: rpc.show_home_city == true ? rpc.home_country : nil,
            show_home_city: rpc.show_home_city,
            profile_background_key: rpc.profile_background_key
        )

        let organizerStats: PickupCreatorPublicRatingStats
        if let count = rpc.pickup_organizer_rating_count {
            // 20260874 embeds organizer aggregates; prefer them to avoid a second RPC.
            let avg = rpc.pickup_organizer_average_rating?.doubleValue
            if count <= 0 {
                organizerStats = PickupCreatorPublicRatingStats(avgRating: 0, ratingCount: 0)
            } else {
                organizerStats = PickupCreatorPublicRatingStats(avgRating: avg ?? 0, ratingCount: count)
            }
        } else {
            organizerStats = await fetchOrganizerStats(userId: userId)
                ?? PickupCreatorPublicRatingStats(avgRating: 0, ratingCount: 0)
        }
        let venueCount = max(0, rpc.venue_count ?? 0)
        let pickupHosted = max(
            0,
            rpc.pickup_games_hosted_count ?? rpc.pickup_hosted_count ?? 0
        )
        let pickupJoined = max(0, rpc.pickup_joined_count ?? 0)
        let lastPickupCreated: Date? = {
            guard let raw = rpc.last_pickup_game_created_at?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            return PickupGameModels.parseSupabaseTimestamptz(raw)
        }()
        var preferences = rpc.fan_identity_preferences ?? .empty
        let rpcOpenToMissing = rpc.fan_identity_preferences == nil
        if rpcOpenToMissing || preferences.resolvedOpenToItemIDs.isEmpty,
           let fetched = await fetchFanIdentityPreferences(userId: userId) {
            // Prefer table fetch when RPC omitted/failed prefs, or when it yields more Open To ids.
            if rpcOpenToMissing
                || fetched.resolvedOpenToItemIDs.count >= preferences.resolvedOpenToItemIDs.count {
                preferences = fetched
                print("[OpenToDebug] publicRpcPreferences= used_profile_fetch ids=\(preferences.resolvedOpenToItemIDs)")
            }
        }
        let sharedTeamNames = FavoriteTeamsStore.resolvedTeams(fromIDs: rpc.shared_team_ids ?? [])
            .map { ($0.shortCode?.isEmpty == false) ? $0.shortCode! : $0.name }

        let fanXP: FanXPState
        if rpc.total_xp != nil || rpc.xp_level != nil || rpc.xp_title != nil {
            let total = max(0, rpc.total_xp ?? 0)
            let level = max(1, rpc.xp_level ?? FanXPLevelCalculator.levelForXP(total))
            let titleRaw = (rpc.xp_title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            fanXP = FanXPState(
                totalXP: total,
                level: level,
                title: titleRaw.isEmpty ? FanXPLevelCalculator.titleForLevel(level) : titleRaw
            )
        } else {
            // Pre-20260871 backends: one user_xp read (same path as legacy fallback).
            let loaded = await loadPublicXP(userId: userId)
            fanXP = loaded.0
        }

        var homeCrowd = resolvePublicHomeCrowd(rpc.home_crowd_venue)
        if homeCrowd == nil {
            homeCrowd = await fetchSupplementalPublicHomeCrowd(userId: userId)
        }

        let built = buildProfileData(
            userId: userId,
            row: row,
            fanXP: fanXP,
            organizerStats: organizerStats,
            favoriteTeams: favoriteTeams,
            primaryFavoriteTeamID: primaryTeamID,
            isBusinessAccount: false,
            hasResolvedIdentity: true,
            isPubliclyVisible: true,
            isDiscoverableByFans: isDiscoverableByFans,
            memberSinceLabel: resolveMemberSinceLabel(
                rpcMemberSince: rpc.member_since,
                profileCreatedAt: cachedProfile?.created_at
            ),
            openToItems: resolvePublicOpenToItems(
                preferences: preferences,
                favoriteTeams: favoriteTeams,
                venueCount: venueCount,
                pickupHostedCount: pickupHosted,
                pickupJoinedCount: pickupJoined
            ),
            mutualFansCount: max(0, rpc.mutual_fans_count ?? 0),
            mutualFanAvatars: {
                let rawRows = rpc.mutual_fan_avatars ?? []
                let decoded = rawRows.compactMap { avatarRow -> PublicProfileMutualFanAvatar? in
                    guard let id = avatarRow.user_id else { return nil }
                    let name = (avatarRow.display_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return PublicProfileMutualFanAvatar(
                        userId: id,
                        displayName: name.isEmpty ? "Fan" : name,
                        avatarURL: ImageDisplayURL.canonicalStorageURLString(avatarRow.avatar_url)
                    )
                }
#if DEBUG
                let count = max(0, rpc.mutual_fans_count ?? 0)
                print(
                    "[PublicProfileMutualFriends] rpcDecode targetUserId=\(userId.uuidString.lowercased()) totalCount=\(count) payloadIdentityCount=\(rawRows.count) decodedCount=\(decoded.count)"
                )
                if count > 0, decoded.isEmpty {
                    print(
                        "[PublicProfileMutualFriends] identityOmitted reason=rpc_returned_count_without_identities totalCount=\(count) payloadIdentityCount=\(rawRows.count)"
                    )
                }
#endif
                return decoded
            }(),
            sharedTeamsCount: max(0, rpc.shared_teams_count ?? 0),
            venueCount: venueCount,
            venueCards: (rpc.venue_cards ?? []).compactMap { card in
                let name = (card.venue_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                let thumb = ImageDisplayURL.canonicalStorageURLString(card.thumbnail_url)
                return PublicProfileVenueCard(
                    venueId: card.venue_id,
                    venueName: name,
                    cityLabel: (card.city_label ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    thumbnailURL: thumb.isEmpty ? nil : thumb
                )
            },
            homeCrowd: homeCrowd,
            homeCityDisplayLine: resolvePublicHomeCityDisplay(from: rpc),
            pickupHostedCount: pickupHosted,
            pickupJoinedCount: pickupJoined,
            lastPickupGameCreatedAt: lastPickupCreated,
            sharedTeamNames: sharedTeamNames,
            lastSeenAtRaw: await fetchVisibleActivityLastSeen(userId: userId)
        )

        logRenderedHomeCrowd(built.homeCrowd?.venueId)
        if let homeId = built.homeCrowd?.venueId {
            print("[HomeCrowd] publicProfile venueId=\(homeId.uuidString.lowercased())")
        }
#if DEBUG
        print(
            "[PublicProfileHomeCity] source=rpc visible=\(built.homeCityDisplayLine != nil) line=\(built.homeCityDisplayLine ?? "nil")"
        )
#endif

#if DEBUG
        print(
            "[PublicProfileLoadDebug] finalProfile userId=\(built.userId.uuidString.lowercased()) name=\(built.displayName) handle=\(built.publicHandleLine) reputation=\(built.reputation.title)"
        )
#endif

        return built
    }

    private static func hiddenProfile(userId: UUID) -> PublicUserProfileData {
        PublicUserProfileData(
            userId: userId,
            displayName: "Fan",
            publicHandleLine: "",
            profileCreatedAt: nil,
            bio: nil,
            avatarURL: nil,
            avatarThumbnailURL: nil,
            totalXP: 0,
            reputation: FanReputationEngine.evaluate(FanReputationSignals(fanXP: .rookie)),
            organizerStats: nil,
            favoriteTeams: [],
            primaryFavoriteTeamID: nil,
            nationalTeam: nil,
            profileBackgroundKey: .fangeo,
            isBusinessAccount: false,
            hasResolvedIdentity: false,
            isPubliclyVisible: false,
            isDiscoverableByFans: false,
            memberSinceLabel: nil,
            openToItems: [],
            mutualFansCount: 0,
            mutualFanAvatars: [],
            sharedTeamsCount: 0,
            venueCount: 0,
            venueCards: [],
            homeCrowd: nil,
            homeCityDisplayLine: nil,
            pickupHostedCount: 0,
            pickupJoinedCount: 0,
            lastPickupGameCreatedAt: nil,
            socialHighlightLabels: [],
            personalityTags: [],
            sharedTeamNames: [],
            lastSeenAtRaw: nil
        )
    }

    private static func resolvePublicHomeCityDisplay(from row: UserProfileRow?) -> String? {
        guard row?.showsHomeCityOnProfile == true else { return nil }
        return row?.profileHomeCityDisplayLine
    }

    /// RPC path: server privacy-gates home city; client double-checks `show_home_city`.
    private static func resolvePublicHomeCityDisplay(from rpc: PublicIdentityRPCResponse) -> String? {
        guard rpc.show_home_city == true else { return nil }
        return ProfileHomeCityIdentity.displayLine(
            city: rpc.home_city,
            region: rpc.home_region,
            country: rpc.home_country,
            languageCode: UserDefaults.standard.string(forKey: L10n.appLanguageKey)
        )
    }

    // MARK: - Legacy fallback

    private static func loadLegacy(userId: UUID, cachedProfile: UserProfileRow?) async -> PublicUserProfileData {
        let fetched = await fetchProfileRow(userId: userId)
        let row: UserProfileRow?
        if let fetchedRow = fetched.row {
            row = fetchedRow
        } else if let cached = cachedProfile, cached.id == userId {
            row = cached
        } else {
            row = nil
        }
        let profileQuerySuccess = fetched.success || row != nil
#if DEBUG
        let loadedBio = row?.bio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        print("[ProfileBioDebug] publicProfileLoadedBio=\(loadedBio)")
#endif

        if row?.isDeletedAccount == true {
            logPublicProfileBlocked(userId: userId, reason: "deleted_legacy")
            return hiddenProfile(userId: userId)
        }

        let (fanXP, _) = await loadPublicXP(userId: userId)
        let organizerStats = await fetchOrganizerStats(userId: userId)
        let favoriteSelection = await fetchPublicFavoriteTeamSelection(userId: userId)
        let favoriteTeams = FavoriteTeamsStore.resolvedTeams(fromIDs: favoriteSelection.teamIDs)
        let isBusiness = await resolveIsBusinessAccount(userId: userId, profileRow: row)
        let discoverable = row?.discoverableByFans ?? true

        if isBusiness {
            logPublicProfileBlocked(userId: userId, reason: "business_legacy")
#if DEBUG
            print("[PublicProfilePreview] rejected reason=missingProfile")
            print("[PublicProfilePreview] loaded success=false")
#endif
            return hiddenProfile(userId: userId)
        }

        // Fail closed: without the friend-aware identity RPC, only allow undiscoverable
        // targets when an accepted user↔user friendship can be proven.
        if discoverable == false {
            let isAcceptedFriend = await viewerHasAcceptedFriendship(with: userId)
            guard isAcceptedFriend else {
                logPublicProfileBlocked(userId: userId, reason: "not_discoverable_legacy")
#if DEBUG
                print("[PublicProfilePreview] rejected reason=discoverability")
                print("[PublicProfilePreview] loaded success=false")
#endif
                return hiddenProfile(userId: userId)
            }
        }

        let venueCount = 0
        let pickupHosted = 0
        let pickupJoined = 0
        let preferences = await fetchFanIdentityPreferences(userId: userId) ?? .empty
        if preferences.resolvedOpenToItemIDs.isEmpty {
            print("[OpenToDebug] legacyLoadPreferences= empty_or_unavailable")
        } else {
            print("[OpenToDebug] legacyLoadPreferences= ids=\(preferences.resolvedOpenToItemIDs)")
        }

        let legacyHomeCrowd = await fetchPublicHomeCrowdForLegacyProfile(userId: userId)
        let lastSeenAtRaw = await fetchVisibleActivityLastSeen(userId: userId)

        let built = buildProfileData(
            userId: userId,
            row: row,
            fanXP: fanXP,
            organizerStats: organizerStats,
            favoriteTeams: favoriteTeams,
            primaryFavoriteTeamID: favoriteSelection.primaryTeamID,
            isBusinessAccount: isBusiness,
            hasResolvedIdentity: profileQuerySuccess,
            isPubliclyVisible: true,
            isDiscoverableByFans: discoverable,
            memberSinceLabel: resolveMemberSinceLabel(
                rpcMemberSince: nil,
                profileCreatedAt: row?.created_at
            ),
            openToItems: resolvePublicOpenToItems(
                preferences: preferences,
                favoriteTeams: favoriteTeams,
                venueCount: venueCount,
                pickupHostedCount: pickupHosted,
                pickupJoinedCount: pickupJoined
            ),
            mutualFansCount: 0,
            mutualFanAvatars: [],
            sharedTeamsCount: 0,
            venueCount: venueCount,
            venueCards: [],
            homeCrowd: legacyHomeCrowd,
            pickupHostedCount: pickupHosted,
            pickupJoinedCount: pickupJoined,
            sharedTeamNames: [],
            lastSeenAtRaw: lastSeenAtRaw
        )

        logRenderedHomeCrowd(built.homeCrowd?.venueId)
#if DEBUG
        print("[PublicProfilePreview] loaded success=true")
#endif
        return built
    }

    /// Resolves hero member-since from RPC `member_since` or `user_profiles.created_at` fallback.
    private static func resolveMemberSinceLabel(
        rpcMemberSince: String?,
        profileCreatedAt: String?
    ) -> String? {
        let candidates: [(source: String, raw: String?)] = [
            ("rpc_member_since", rpcMemberSince),
            ("profile_created_at", profileCreatedAt)
        ]

        for candidate in candidates {
            guard let raw = candidate.raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            if let label = PublicProfileMemberSinceFormatter.label(from: raw) {
                print("[PublicProfileMemberSince] rendered value=\(label) source=\(candidate.source)")
                return label
            }
            print(
                "[PublicProfileMemberSince] missing reason=unparseable source=\(candidate.source) raw=\(raw.prefix(48))"
            )
        }

        let rpcPresent = !(rpcMemberSince?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let profilePresent = !(profileCreatedAt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if !rpcPresent && !profilePresent {
            print("[PublicProfileMemberSince] missing reason=no_timestamp_fields")
        } else {
            print("[PublicProfileMemberSince] missing reason=all_candidates_unparseable")
        }
        return nil
    }

    private static func normalizedHomeCrowdSummary(_ summary: HomeCrowdVenueSummary) -> HomeCrowdVenueSummary {
        let thumb = ImageDisplayURL.canonicalStorageURLString(summary.thumbnailURL)
        return HomeCrowdVenueSummary(
            venueId: summary.venueId,
            name: summary.name,
            locationLabel: summary.locationLabel,
            thumbnailURL: thumb.isEmpty ? nil : thumb,
            setAtRaw: summary.setAtRaw,
            fanCount: summary.fanCount,
            fanAvatars: summary.fanAvatars
        )
    }

    private static func socialHighlights(
        venueCount: Int,
        pickupHosted: Int,
        pickupJoined: Int,
        sharedTeams: Int
    ) -> [String] {
        var labels: [String] = []
        if sharedTeams > 0 {
            labels.append(sharedTeams == 1 ? "1 shared favorite team" : "\(sharedTeams) shared favorite teams")
        }
        if venueCount > 0 {
            labels.append(venueCount == 1 ? "Visits favorite venues" : "Visits \(venueCount) favorite venues")
        }
        if pickupHosted > 0 {
            labels.append(pickupHosted == 1 ? "Hosts pickup games" : "Hosts pickup games regularly")
        } else if pickupJoined > 0 {
            labels.append("Joins local pickup games")
        }
        return Array(labels.prefix(3))
    }

    // MARK: - Profile row fetch

    private struct ProfileFetchResult {
        let row: UserProfileRow?
        let success: Bool
        let decodeError: String?
        let missingField: String?
    }

    private static func fetchProfileRow(userId: UUID) async -> ProfileFetchResult {
        do {
            let rows: [UserProfileRow] = try await supabase
                .from("user_profiles")
                .select(profileSelect)
                .eq("id", value: userId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value

            if let row = rows.first {
                return ProfileFetchResult(row: row, success: true, decodeError: nil, missingField: nil)
            }
            return ProfileFetchResult(row: nil, success: false, decodeError: nil, missingField: "no_rows")
        } catch {
            return ProfileFetchResult(row: nil, success: false, decodeError: String(describing: error), missingField: nil)
        }
    }

    private static func loadPublicXP(userId: UUID) async -> (FanXPState, Bool) {
        struct Row: Decodable {
            let total_xp: Int?
            let level: Int?
            let title: String?
        }

        do {
            let rows: [Row] = try await supabase
                .from("user_xp")
                .select("total_xp,level,title")
                .eq("user_id", value: userId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value

            if let row = rows.first {
                return (
                    FanXPState(
                        totalXP: row.total_xp ?? 0,
                        level: max(1, row.level ?? 1),
                        title: (row.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? FanXPLevelCalculator.titleForLevel(max(1, row.level ?? 1))
                            : row.title!
                    ),
                    true
                )
            }
        } catch {
#if DEBUG
            print("[PublicProfileLoadDebug] xpQuery error=\(error.localizedDescription)")
#endif
        }

        return (FanXPState.rookie, false)
    }

    private static func fetchPublicFavoriteTeamSelection(userId: UUID) async -> FavoriteTeamsSyncService.FavoriteTeamSelection {
        await FavoriteTeamsSyncService.fetchTeamSelection(userId: userId)
    }

    private static func resolveProfileBio(rpcBio: String?, cachedBio: String?) -> String? {
        let rpcTrimmed = rpcBio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !rpcTrimmed.isEmpty { return rpcTrimmed }
        let cachedTrimmed = cachedBio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cachedTrimmed.isEmpty ? nil : cachedTrimmed
    }

    private static func buildProfileData(
        userId: UUID,
        row: UserProfileRow?,
        fanXP: FanXPState,
        organizerStats: PickupCreatorPublicRatingStats?,
        favoriteTeams: [FavoriteTeam],
        primaryFavoriteTeamID: String?,
        isBusinessAccount: Bool,
        hasResolvedIdentity: Bool,
        isPubliclyVisible: Bool,
        isDiscoverableByFans: Bool,
        memberSinceLabel: String?,
        openToItems: [PublicProfileOpenToItem],
        mutualFansCount: Int,
        mutualFanAvatars: [PublicProfileMutualFanAvatar],
        sharedTeamsCount: Int,
        venueCount: Int,
        venueCards: [PublicProfileVenueCard],
        homeCrowd: HomeCrowdVenueSummary?,
        homeCityDisplayLine: String? = nil,
        pickupHostedCount: Int,
        pickupJoinedCount: Int,
        lastPickupGameCreatedAt: Date? = nil,
        sharedTeamNames: [String],
        lastSeenAtRaw: String? = nil
    ) -> PublicUserProfileData {
        let emailNorm = OwnerBusinessEmail.normalized(row?.email ?? "")
        let display = (row?.display_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedName: String
        if !display.isEmpty {
            resolvedName = display
        } else if OwnerBusinessEmail.isValidStrict(emailNorm) {
            let local = emailNorm.split(separator: "@").first.map(String.init) ?? ""
            resolvedName = local.isEmpty ? "Fan" : local
        } else {
            resolvedName = "Fan"
        }

        let storedUsername = (row?.username ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let handleLine: String
        if !storedUsername.isEmpty {
            handleLine = FanGeoHandleRules.displayHandle(stored: storedUsername)
        } else if OwnerBusinessEmail.isValidStrict(emailNorm) {
            handleLine = FanGeoHandleRules.temporaryFallbackHandle(email: emailNorm)
        } else {
            handleLine = "@fan"
        }

        let avatarFull = ImageDisplayURL.canonicalStorageURLString(row?.avatar_url)
        let avatarThumb = ImageDisplayURL.canonicalStorageURLString(row?.avatar_thumbnail_url)
        let trimmedBio = row?.bio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let uniquedTeams = Self.uniquedFavoriteTeams(favoriteTeams)
        let uniquedMutualAvatars = Self.uniquedMutualFanAvatars(mutualFanAvatars)
        let uniquedVenueCards = Self.uniquedVenueCards(venueCards)
        SuggestedFanProfileOpenDebug.decodingCompleted(
            mutualAvatarCount: mutualFanAvatars.count,
            uniqueMutualAvatarCount: uniquedMutualAvatars.count,
            teamCount: favoriteTeams.count,
            uniqueTeamCount: uniquedTeams.count,
            openToCount: openToItems.count
        )

        let reputation = FanReputationEngine.evaluate(
            FanReputationSignals(
                fanXP: fanXP,
                favoriteTeams: uniquedTeams,
                savedVenueCount: venueCount,
                pickupHostedCount: pickupHostedCount,
                pickupJoinedCount: pickupJoinedCount,
                organizerStats: organizerStats
            ),
            shouldLog: false
        )

        return PublicUserProfileData(
            userId: userId,
            displayName: resolvedName,
            publicHandleLine: handleLine,
            profileCreatedAt: row?.created_at,
            bio: trimmedBio.isEmpty ? nil : trimmedBio,
            avatarURL: avatarFull.isEmpty ? nil : avatarFull,
            avatarThumbnailURL: avatarThumb.isEmpty ? nil : avatarThumb,
            totalXP: max(0, fanXP.totalXP),
            reputation: reputation,
            organizerStats: organizerStats,
            favoriteTeams: uniquedTeams,
            primaryFavoriteTeamID: {
                let raw = primaryFavoriteTeamID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !raw.isEmpty, uniquedTeams.contains(where: { $0.id == raw }) else { return nil }
                return raw
            }(),
            nationalTeam: row?.nationalTeamIdentity,
            profileBackgroundKey: ProfileBackgroundCatalog.resolveKey(row?.profile_background_key),
            isBusinessAccount: isBusinessAccount,
            hasResolvedIdentity: hasResolvedIdentity,
            isPubliclyVisible: isPubliclyVisible,
            isDiscoverableByFans: isDiscoverableByFans,
            memberSinceLabel: memberSinceLabel,
            openToItems: openToItems,
            mutualFansCount: mutualFansCount,
            mutualFanAvatars: uniquedMutualAvatars,
            sharedTeamsCount: sharedTeamsCount,
            venueCount: venueCount,
            venueCards: uniquedVenueCards,
            homeCrowd: homeCrowd,
            homeCityDisplayLine: homeCityDisplayLine ?? resolvePublicHomeCityDisplay(from: row),
            pickupHostedCount: pickupHostedCount,
            pickupJoinedCount: pickupJoinedCount,
            lastPickupGameCreatedAt: lastPickupGameCreatedAt,
            socialHighlightLabels: socialHighlights(
                venueCount: venueCount,
                pickupHosted: pickupHostedCount,
                pickupJoined: pickupJoinedCount,
                sharedTeams: sharedTeamsCount
            ),
            personalityTags: [],
            sharedTeamNames: sharedTeamNames,
            lastSeenAtRaw: lastSeenAtRaw
        )
    }

    /// Privacy-gated last_seen for public profile badge (companion RPC; nil if unavailable).
    private static func fetchVisibleActivityLastSeen(userId: UUID) async -> String? {
        struct Params: Encodable { let p_user_id: UUID }
        do {
            let value: String? = try await supabase
                .rpc("get_visible_activity_last_seen", params: Params(p_user_id: userId))
                .execute()
                .value
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ActivityStatusDebug.lifecycle("presence record received", details: "source=public_profile_rpc")
                return value
            }
            return nil
        } catch {
            // Pre-migration backends: fall back to no badge (do not claim Online).
            ActivityStatusDebug.lifecycle("statistics request failed", details: "reason=activity_rpc_unavailable")
            return nil
        }
    }

    /// SwiftUI `ForEach` fatals on duplicate `Identifiable.id` values — mutual avatar RPC can
    /// emit the same friend more than once when friendship edges are duplicated.
    private static func uniquedMutualFanAvatars(
        _ avatars: [PublicProfileMutualFanAvatar]
    ) -> [PublicProfileMutualFanAvatar] {
        var seen = Set<UUID>()
        var out: [PublicProfileMutualFanAvatar] = []
        out.reserveCapacity(avatars.count)
        for avatar in avatars {
            guard seen.insert(avatar.userId).inserted else { continue }
            out.append(avatar)
        }
        return out
    }

    private static func uniquedFavoriteTeams(_ teams: [FavoriteTeam]) -> [FavoriteTeam] {
        var seen = Set<String>()
        var out: [FavoriteTeam] = []
        out.reserveCapacity(teams.count)
        for team in teams {
            guard seen.insert(team.id).inserted else { continue }
            out.append(team)
        }
        return out
    }

    private static func uniquedVenueCards(_ cards: [PublicProfileVenueCard]) -> [PublicProfileVenueCard] {
        var seen = Set<String>()
        var out: [PublicProfileVenueCard] = []
        out.reserveCapacity(cards.count)
        for card in cards {
            guard seen.insert(card.id).inserted else { continue }
            out.append(card)
        }
        return out
    }

    /// Accepted user↔user friendship check for legacy fallback (fail closed on error).
    private static func viewerHasAcceptedFriendship(with targetUserId: UUID) async -> Bool {
        struct Params: Encodable {
            let p_user_a: UUID
            let p_user_b: UUID
        }
        guard let viewerId = await authenticatedSessionUserId() else { return false }
        do {
            let areFriends: Bool = try await supabase
                .rpc(
                    "pickup_invite_users_are_friends",
                    params: Params(p_user_a: viewerId, p_user_b: targetUserId)
                )
                .execute()
                .value
            return areFriends
        } catch {
#if DEBUG
            print("[PublicProfileLoadDebug] friendshipCheckFailed error=\(error.localizedDescription)")
#endif
            return false
        }
    }

    private static func resolveIsBusinessAccount(userId: UUID, profileRow: UserProfileRow?) async -> Bool {
        if profileRow?.is_business_account == true { return true }

        struct BizRow: Decodable {
            let id: UUID?
        }

        let rows: [BizRow] = (try? await supabase
            .from("businesses")
            .select("id")
            .eq("owner_user_id", value: userId.uuidString.lowercased())
            .eq("admin_status", value: "active")
            .limit(1)
            .execute()
            .value) ?? []

        return rows.first?.id != nil
    }

    private static func fetchOrganizerStats(userId: UUID) async -> PickupCreatorPublicRatingStats? {
        struct Params: Encodable {
            let p_creator_user_id: UUID
        }

        do {
            let rows: [PickupCreatorPublicRatingStatsRPCRow] = try await supabase
                .rpc("pickup_creator_public_rating_stats", params: Params(p_creator_user_id: userId))
                .execute()
                .value

            return rows.first?.toPublicStats()
                ?? PickupCreatorPublicRatingStats(avgRating: 0, ratingCount: 0)
        } catch {
            return PickupCreatorPublicRatingStats(avgRating: 0, ratingCount: 0)
        }
    }

    /// Prefer `pickup_organizer_profile_summary` (hosted + ratings). Falls back to rating-only RPC.
    private static func fetchOrganizerProfileSummary(userId: UUID) async -> PickupOrganizerSummary {
        struct Params: Encodable {
            let p_user_id: UUID
        }
        struct Row: Decodable {
            let pickup_games_hosted_count: Int64?
            let pickup_organizer_average_rating: PickupRPCNumericOrString?
            let pickup_organizer_rating_count: Int64?
            let last_pickup_game_created_at: String?
        }

        do {
            let rows: [Row] = try await supabase
                .rpc("pickup_organizer_profile_summary", params: Params(p_user_id: userId))
                .execute()
                .value
            if let row = rows.first {
                let count = max(0, Int(row.pickup_organizer_rating_count ?? 0))
                let avg: Double? = count > 0 ? row.pickup_organizer_average_rating?.doubleValue : nil
                let lastCreated: Date? = {
                    guard let raw = row.last_pickup_game_created_at?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !raw.isEmpty else { return nil }
                    return PickupGameModels.parseSupabaseTimestamptz(raw)
                }()
                return PickupOrganizerSummary(
                    hostedCount: max(0, Int(row.pickup_games_hosted_count ?? 0)),
                    averageRating: avg,
                    ratingCount: count,
                    lastPickupGameCreatedAt: lastCreated
                )
            }
        } catch {
#if DEBUG
            print("[PickupOrganizerSummary] public self-preview summary rpc failed: \(error.localizedDescription)")
#endif
        }

        let stats = await fetchOrganizerStats(userId: userId)
        return PickupOrganizerSummary(hostedCount: 0, stats: stats)
    }
}
