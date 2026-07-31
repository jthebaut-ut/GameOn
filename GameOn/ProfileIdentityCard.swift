import CoreLocation
import CryptoKit
import Photos
import PhotosUI
import Supabase
import SwiftUI

@MainActor
enum ProfilePhase1PersonalizationCache {
    static let ttlSeconds: TimeInterval = 600

    static var incomingPokesLoadedAtByAuthId: [UUID: Date] = [:]
    static var incomingPokesByAuthId: [UUID: [ProfilePokeIncomingItem]] = [:]
    static var suggestedFansLoadedAtByAuthId: [UUID: Date] = [:]
    static var suggestedFansByAuthId: [UUID: [FriendSuggestionProfile]] = [:]

    static func dismissCachedSuggestedFan(authId: UUID?, dismissedUserId: UUID) {
        guard let authId else { return }
        suggestedFansByAuthId[authId]?.removeAll { $0.userID == dismissedUserId }
    }

    static func invalidateSuggestedFans(for authId: UUID?) {
        guard let authId else { return }
        suggestedFansLoadedAtByAuthId.removeValue(forKey: authId)
        suggestedFansByAuthId.removeValue(forKey: authId)
    }

    /// Merges a remote/local avatar URL change into cached Suggested Fans rows (viewer caches keyed by auth id).
    static func applyAvatarChange(_ change: FanProfileAvatarChange) {
        let target = change.userId
        let full = change.avatarURL.isEmpty ? nil : change.avatarURL
        let thumb = change.avatarThumbnailURL
        for authId in suggestedFansByAuthId.keys {
            guard var rows = suggestedFansByAuthId[authId] else { continue }
            var changed = false
            rows = rows.map { row in
                guard row.userID == target else { return row }
                let next = row.replacingAvatars(avatarURL: full ?? row.avatarURL, avatarThumbnailURL: thumb ?? row.avatarThumbnailURL)
                if next != row { changed = true }
                return next
            }
            if changed {
                suggestedFansByAuthId[authId] = rows
            }
        }
    }

    static func storeIncomingPokes(_ items: [ProfilePokeIncomingItem], for authId: UUID) {
        incomingPokesByAuthId[authId] = items
        incomingPokesLoadedAtByAuthId[authId] = Date()
    }

    static func clear(for authId: UUID?) {
        guard let authId else {
            incomingPokesLoadedAtByAuthId.removeAll()
            incomingPokesByAuthId.removeAll()
            suggestedFansLoadedAtByAuthId.removeAll()
            suggestedFansByAuthId.removeAll()
            return
        }
        incomingPokesLoadedAtByAuthId.removeValue(forKey: authId)
        incomingPokesByAuthId.removeValue(forKey: authId)
        suggestedFansLoadedAtByAuthId.removeValue(forKey: authId)
        suggestedFansByAuthId.removeValue(forKey: authId)
    }
}

private enum ProfileAvatarRefreshToken {
#if DEBUG
    private static var loggedMaterials: Set<String> = []
#endif

    static func stable(
        userId: UUID,
        thumbnailURL: String?,
        avatarURL: String?,
        versionSuffix: String = ""
    ) -> UUID {
        let material = "\(userId.uuidString.lowercased())|\(thumbnailURL ?? "")|\(avatarURL ?? "")|\(versionSuffix)"
        let digest = Insecure.MD5.hash(data: Data(material.utf8))
        let token = digest.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            return UUID(
                uuid: (
                    bytes[0], bytes[1], bytes[2], bytes[3],
                    bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11],
                    bytes[12], bytes[13], bytes[14], bytes[15]
                )
            )
        }
#if DEBUG
        if loggedMaterials.insert(material).inserted {
            print("[PerfPhase1] avatarTokenStable userId=\(userId.uuidString.lowercased())")
        }
#endif
        return token
    }
}

/// Unified Account-tab “Profile & Identity” card: compact profile, reputation, and favorite teams in one surface.
struct ProfileIdentityCard: View {
    @ObservedObject var viewModel: MapViewModel
    /// Intentionally not `@ObservedObject`: FanUpdates realtime maps must not rebuild the whole identity card.
    /// Comment/reaction totals for reputation use equality-gated `@State` via `onReceive`.
    private let fanUpdatesStore: FanUpdatesRealtimeStore
    /// When false, Pokes / Suggested Fans loads wait until the Account tab is selected.
    var isAccountTabActive: Bool = true
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedIdentityField: EditProfileFocusField?

    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @AppStorage(FavoriteTeamsStore.appStorageKey) private var favoriteTeamIDsRaw: String = ""
    @AppStorage(FavoriteTeamsStore.primaryTeamIDAppStorageKey) private var primaryFavoriteTeamIDRaw: String = ""
    @State private var showFavoriteTeamsPicker = false
    @State private var showNationalTeamPicker = false
    @State private var showHandleSetup = false
    @State private var showIdentityEditor = false
    @State private var showFanIdentityEditor = false
    @State private var showBioEmojiPicker = false
    @State private var showProfileBackgroundPicker = false
    @State private var showShareOwnProfileSheet = false
    @State private var ownShareProfile: PublicUserProfileData?
    @State private var isLoadingOwnShareProfile = false
    @State private var ownShareProfileError: String?
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var editedDisplayName = ""
    @State private var editedUsername = ""
    @State private var editedBio = ""
    @State private var editedHomeCity = ""
    @State private var editedHomeRegion = ""
    @State private var editedHomeCountry = ""
    @State private var editedHomeCityDisplay = ""
    @State private var editedShowHomeCity = false
    @State private var editedProfileBackgroundKey: ProfileBackgroundKey = .fangeo
    @State private var identityMessage = ""
    @State private var handleStatusMessage = ""
    @State private var handleStatusIsPositive = false
    @State private var availabilityTask: Task<Void, Never>?
    @State private var isSavingIdentity = false
    @State private var isUploadingAvatar = false
    @State private var localAvatarPreviewImage: UIImage?
    @State private var incomingPokes: [ProfilePokeIncomingItem] = []
    @State private var incomingPokeTotalCount = 0
    @State private var locallyLoadedCommentCount = 0
    @State private var locallyLoadedReactionCount = 0
    @State private var isLoadingIncomingPokes = false
    @State private var isClearingAllPokes = false
    @State private var incomingPokesMessage: String?
    @State private var showPokesHistorySheet = false
    @State private var showClearAllPokesConfirmation = false
    @State private var pokeWaveBadgeDidPlayUnseenIntro = false
    @State private var pokeWaveBadgeIntroScale: CGFloat = 1
    @State private var suggestedFans: [FriendSuggestionProfile] = []
    @State private var isLoadingSuggestedFans = false
    @State private var hasCompletedSuggestedFansLoad = false
    @State private var suggestedFansLoadStartedAt: Date?
    @State private var suggestedFansMessage: String?
    @State private var suggestedFansLoadFailed = false
    @State private var sendingSuggestedFanRequestIds: Set<UUID> = []
    @State private var suggestedFansSignalRefreshTask: Task<Void, Never>?
    @State private var suggestedFansLoadTask: Task<Void, Never>?
    @State private var lastSuggestedFansSignalFingerprint = ""
    @State private var suggestedFansLoadGeneration: UInt64 = 0
    @State private var profileStatsCounts: ProfileStatsCounts?
    @State private var animatedTrophyTeamID: String?
    @State private var demotedTrophyTeamID: String?
    @State private var trophyShimmerProgress: CGFloat = -0.6
    @State private var trophyAnimationTask: Task<Void, Never>?
    @State private var sponsoredVenueDetail: BarVenue?
    @State private var sponsoredProfileRecommendation: SponsoredProfileVenueRecommendation?
    @State private var isSponsoredProfilePlacementLoading = false
    @State private var lastSponsoredProfilePlacementRefreshAt: Date?
    @State private var showSponsoredPromotionSupportSheet = false
    @AppStorage("profileSponsoredPlacement.lastVenueId") private var lastSponsoredProfileVenueIDRaw = ""
    @AppStorage("profileSponsoredPlacement.lastPlacementId") private var lastSponsoredProfilePlacementIDRaw = ""
    @AppStorage("profileSponsoredPlacement.repeatCount") private var sponsoredProfileVenueRepeatCount = 0
    @State private var profileBelowFoldSectionsReady = false
    @State private var lastIncomingPokesFingerprint = ""

    private static let bioCharacterLimit = 160
    private static let incomingPokesHighlightsLimit = 50
    private static let suggestedFansDisplayLimit = 10
    private static let suggestedFansFetchLimit = 30
    /// Scroll anchor for Discover Today dashboard → Suggested Fans.
    static let suggestedFansScrollAnchorID = "profile.suggestedFans"
    private static let incomingPokesFreshnessIntervalSeconds: TimeInterval = 60
    private static let incomingPokesLiveRefreshIntervalSeconds = 20
    private static let incomingPokesLiveRefreshIntervalNs: UInt64 =
        UInt64(incomingPokesLiveRefreshIntervalSeconds) * 1_000_000_000
    /// Yields the first Account-tab paint before non-critical profile network extras.
    private static let profileExtrasFirstPaintDeferNanoseconds: UInt64 = 400_000_000
    private static let profileHeroAvatarDiameter: CGFloat = 133
    private static let profileHeroAvatarRingWidth: CGFloat = 4
    private static let profileHeroAvatarOuterPadding: CGFloat = 4
    private static let profileHeroCameraButtonDiameter: CGFloat = 31
    private static let profileHeroCameraIconSize: CGFloat = 11.5
    private static let profileHomeCrowdAccent = Color(red: 0.56, green: 0.32, blue: 0.96)
    private static let profileTealAccent = Color(red: 0.08, green: 0.72, blue: 0.74)
    private static let favoriteTeamsCarouselHeight: CGFloat = FavoriteTeamRichCardStyle.ownProfile.carouselHeight
    private static let favoriteTeamCardHeight: CGFloat = FavoriteTeamRichCardStyle.ownProfile.height
    private static let favoriteTeamsHomeCrowdBottomSpacing: CGFloat = 8
    private static let profileMajorSectionSpacing: CGFloat = 22
    private static let sponsoredPlacementRefreshDebounceSeconds: TimeInterval = 0.75
    private static let sponsoredPlacementDebugDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let profilePokesService = ProfilePokesService()
    private let friendSuggestionsService = FriendSuggestionsService()
    private let socialIdentityService = SocialIdentityService()
    private let sponsoredPlacementService = SponsoredPlacementService()

    private enum ProfileSectionHierarchy {
        case hero
        case primary
        case secondary
        case utility
    }

    init(viewModel: MapViewModel, isAccountTabActive: Bool = true) {
        self.isAccountTabActive = isAccountTabActive
        _viewModel = ObservedObject(wrappedValue: viewModel)
        self.fanUpdatesStore = viewModel.fanUpdatesStore
    }

    private var profilePersonalizationLoadToken: String {
        let auth = viewModel.currentUserAuthId?.uuidString ?? "anonymous"
        return "\(auth)|active=\(isAccountTabActive)"
    }

    private var accountProfileHydrationRecoveryToken: String {
        let auth = viewModel.currentUserAuthId?.uuidString ?? "none"
        return "\(auth)|active=\(isAccountTabActive)|loaded=\(viewModel.hasLoadedUserProfileForPresentation)|loading=\(viewModel.isUserProfileLoadingForPresentation)"
    }

    private var pokesLiveRefreshLoopToken: String {
        let auth = viewModel.currentUserAuthId?.uuidString ?? "anonymous"
        return "\(auth)|pokesLive=\(isAccountTabActive)"
    }

    private var profileStatsLoadToken: String {
        let auth = viewModel.currentUserAuthId?.uuidString ?? "anonymous"
        let email = viewModel.currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let teams = FavoriteTeamsStore.decodeIDs(from: favoriteTeamIDsRaw).sorted().joined(separator: ",")
        return "\(auth)|\(email)|teams=\(teams)|active=\(isAccountTabActive)"
    }

    private var sponsoredPlacementLoadToken: String {
        let auth = viewModel.currentUserAuthId?.uuidString ?? "anonymous"
        let sport = sponsoredProfileSportTarget ?? "any"
        let location = [
            sponsoredProfileCountryTarget,
            sponsoredProfileStateTarget,
            sponsoredProfileCityTarget
        ]
            .compactMap { $0 }
            .joined(separator: "|")
        return "\(auth)|active=\(isAccountTabActive)|sport=\(sport)|location=\(location)"
    }

    private var selectedTeams: [FavoriteTeam] {
        // Observe hydration generation so AppStorage writes from background login reload refresh this view.
        _ = viewModel.favoriteTeamsHydrationGeneration
        return FavoriteTeamsStore.resolvedTeams(from: favoriteTeamIDsRaw)
    }

    private var selectedIDSet: Set<String> {
        Set(FavoriteTeamsStore.decodeIDs(from: favoriteTeamIDsRaw))
    }

    private var selectedTeamIDs: [String] {
        FavoriteTeamsStore.decodeIDs(from: favoriteTeamIDsRaw)
    }

    private var primaryFavoriteTeamID: String? {
        FavoriteTeamsStore.explicitPrimaryTeamID(primaryFavoriteTeamIDRaw, within: selectedTeamIDs)
    }

    private var primaryFavoriteTeam: FavoriteTeam? {
        guard let primaryFavoriteTeamID else { return nil }
        return selectedTeams.first { $0.id == primaryFavoriteTeamID }
    }

    private var displayName: String {
        let current = viewModel.currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty { return current }
        let email = viewModel.currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = email.split(separator: "@").first.map(String.init) ?? ""
        guard !local.isEmpty else { return "Fan" }
        return local.prefix(1).uppercased() + local.dropFirst()
    }

    /// Persisted @handle without fan-since suffix (shown separately in compact identity rows).
    /// Matches business header: `Handle: @username` via shared `handle` L10n key.
    private var handleLine: String {
        let display: String
        let stored = viewModel.currentUserUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        if !viewModel.hasLoadedUserProfileForPresentation || viewModel.isUserProfileLoadingForPresentation {
            guard !stored.isEmpty else { return "" }
            display = FanGeoHandleRules.handleDisplayLine(
                base: FanGeoHandleRules.displayHandle(stored: stored),
                profileCreatedAt: viewModel.currentUserProfileCreatedAt,
                showFanSince: false
            )
        } else {
            let base = FanGeoHandleRules.publicHandleLine(
                storedUsername: viewModel.currentUserUsername,
                email: viewModel.currentUserEmail
            )
            display = FanGeoHandleRules.handleDisplayLine(
                base: base,
                profileCreatedAt: viewModel.currentUserProfileCreatedAt,
                showFanSince: false
            )
        }
        let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return "\(L10n.t("handle", languageCode: appLanguageRaw)): \(trimmed)"
    }

    private var shouldShowHandlePromptBanner: Bool {
        viewModel.hasLoadedUserProfileForPresentation
            && !viewModel.isUserProfileLoadingForPresentation
            && viewModel.needsFanHandleSelection
            && !viewModel.needsBlockingFanIdentitySetup
    }

    private var avatarPresentationIdentity: String {
        [
            viewModel.currentUserAuthId?.uuidString ?? "none",
            viewModel.currentUserAvatarURL,
            viewModel.currentUserAvatarThumbnailURL,
            viewModel.currentUserAvatarDisplayRefreshToken.uuidString
        ].joined(separator: "|")
    }

    private var profileHeroIdentityCards: [ProfileHeroIdentityCardItem] {
        // Use the shared hometown formatter line as-is (city, region, country).
        let locationLine = viewModel.currentUserVisibleHomeCityDisplayLine
        let crowdName = viewModel.currentUserHomeCrowdVenue?.name
        return ProfileHeroIdentityCardsBuilder.cards(
            myTeam: primaryFavoriteTeam,
            homeCrowdName: crowdName,
            homeCrowdSubtitle: (crowdName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? L10n.t("home_crowd", languageCode: appLanguageRaw)
                : nil,
            locationPrimary: locationLine,
            locationSecondary: nil,
            fanSincePrimary: FanGeoHandleRules.fanSinceMonthYear(from: viewModel.currentUserProfileCreatedAt),
            fanSinceSecondary: nil,
            nationalTeam: viewModel.currentUserNationalTeam,
            languageCode: appLanguageRaw,
            onMyTeam: { showFavoriteTeamsPicker = true },
            onHomeCrowd: {
                if viewModel.currentUserHomeCrowdVenue != nil {
                    viewModel.focusDiscoverOnHomeCrowdVenue()
                }
            },
            onNationalTeam: { openNationalTeamPicker() }
        )
    }

    private var bioLine: String {
        FanProfileDefaults.displayBio(viewModel.currentUserBio, languageCode: appLanguageRaw)
    }

    private var fanXP: FanXPState {
        viewModel.currentUserFanXP
    }

    private var reputation: FanReputationProfile {
        FanReputationEngine.evaluate(
            FanReputationSignals(
                fanXP: fanXP,
                favoriteTeams: selectedTeams,
                localContext: localContext,
                savedVenueCount: savedVenueCount,
                venuePlanCount: viewModel.followingTabGoingItems.count,
                pickupHostedCount: viewModel.myPickupGamesForSettings.count + viewModel.myRemovedPickupGamesForSettings.count,
                pickupJoinedCount: viewModel.myPickupGameJoinRequestCards.count,
                organizerStats: currentOrganizerStats,
                commentCount: locallyLoadedCommentCount,
                reactionCount: locallyLoadedReactionCount
            ),
            shouldLog: false
        )
    }

    private var currentOrganizerStats: PickupCreatorPublicRatingStats? {
        guard let uid = viewModel.currentUserAuthId else { return nil }
        return viewModel.pickupCreatorTrustStats(for: uid)
    }

    private var ownPickupOrganizerSummary: PickupOrganizerSummary {
        guard let uid = viewModel.currentUserAuthId else { return .empty }
        if viewModel.myPickupOrganizerSummaryLoadedForUserId == uid {
            return viewModel.myPickupOrganizerSummary
        }
        return PickupOrganizerSummary(
            hostedCount: viewModel.myPickupGamesForSettings.count
                + viewModel.myRemovedPickupGamesForSettings.count,
            stats: currentOrganizerStats,
            lastPickupGameCreatedAt: {
                let rows = viewModel.myPickupGamesForSettings + viewModel.myRemovedPickupGamesForSettings
                return rows.compactMap { row -> Date? in
                    guard let raw = row.created_at else { return nil }
                    return PickupGameModels.parseSupabaseTimestamptz(raw)
                }.max()
            }()
        )
    }

    private func pickupGamesProfileSection(userId: UUID) -> some View {
        ProfileIdentityPickupGamesSection(
            viewModel: viewModel,
            userId: userId,
            summary: ownPickupOrganizerSummary,
            languageCode: appLanguageRaw
        )
    }

    private var localContext: String? {
        FanReputationEngine.localContext(
            latitude: viewModel.currentUserLocation?.latitude,
            longitude: viewModel.currentUserLocation?.longitude
        )
    }

    private func refreshLocallyLoadedFanUpdateTotals(reason: String) {
        let nextComments = fanUpdatesStore.venueEventComments.values.reduce(0) { $0 + $1.count }
        let nextReactions = fanUpdatesStore.venueEventVibeCounts.values.reduce(0) { total, counts in
            total + counts.values.reduce(0, +)
        }
        let commentsChanged = nextComments != locallyLoadedCommentCount
        let reactionsChanged = nextReactions != locallyLoadedReactionCount
        guard commentsChanged || reactionsChanged else {
            SwiftUIRecompPerf.identicalSnapshotSkipped(
                source: "profile.fanUpdateTotals.\(reason)",
                rows: nextComments + nextReactions
            )
            return
        }
        if commentsChanged { locallyLoadedCommentCount = nextComments }
        if reactionsChanged { locallyLoadedReactionCount = nextReactions }
        SwiftUIRecompPerf.immutableSnapshotPublished(
            source: "profile.fanUpdateTotals.\(reason)",
            rows: nextComments + nextReactions
        )
        SwiftUIRecompPerf.rootInvalidated(screen: "ProfileIdentity", source: "fanUpdateTotals.\(reason)")
    }

    private var savedVenueCount: Int {
        max(viewModel.favoriteVenueIDs.count, viewModel.followingTabSavedVenues.count)
    }

    private func loadProfileStatsIfNeeded() async {
        guard isAccountTabActive, let userId = viewModel.currentUserAuthId else { return }
        guard !viewModel.shouldSuppressAuthenticatedRefreshForSafeLogout else { return }
        let email = await viewModel.strictNormalizedSessionEmailForSocialTables()
            ?? viewModel.currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let counts = await ProfileStatsService.shared.loadStats(
            userId: userId,
            userEmail: email,
            forceRefresh: false
        )
        await MainActor.run {
            profileStatsCounts = counts
#if DEBUG
            print("[ProfileStatsDebug] pickupGamesCount=\(counts.pickupGamesCount)")
            print("[ProfileStatsDebug] venueGamesCount=\(counts.venueGamesCount)")
            print("[ProfileStatsDebug] favoriteTeamsCount=\(counts.favoriteTeamsCount)")
            print("[ProfileStatsDebug] friendsCount=\(counts.friendsCount)")
#endif
        }
    }

    private var canShowOwnerPokesHighlights: Bool {
        viewModel.isLoggedIn && viewModel.currentUserAuthId != nil
    }

    private var canShowSuggestedFans: Bool {
        viewModel.isLoggedIn && viewModel.currentUserAuthId != nil
    }

    private var shouldBlockFanIdentityCardForBusiness: Bool {
        viewModel.venueOwnerMode || viewModel.isVenueOwnerLoggedIn || viewModel.currentUserIsBusinessAccount
    }

    var body: some View {
        let _ = SwiftUIRecompPerf.rootBodyEvaluated(screen: "ProfileIdentity")
        if shouldBlockFanIdentityCardForBusiness {
            EmptyView()
                .onAppear {
                    SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] profileIdentityCardBypassed=true reason=businessProfileContext")
#if DEBUG
                    print("[BusinessDashboardCleanup] FAN_LEVEL_CARD_BLOCKED_FOR_BUSINESS")
#endif
                }
        } else {
            // Collapse ProfileIdentityCard.body to AnyView so SettingsScreen / Account
            // never embeds this card's nested SwiftUI generic metadata.
            AnyView(
                profileIdentityCardContent
                    .onAppear { refreshLocallyLoadedFanUpdateTotals(reason: "appear") }
                    .onReceive(fanUpdatesStore.$venueEventComments) { _ in
                        refreshLocallyLoadedFanUpdateTotals(reason: "comments")
                    }
                    .onReceive(fanUpdatesStore.$venueEventVibeCounts) { _ in
                        refreshLocallyLoadedFanUpdateTotals(reason: "vibes")
                    }
            )
        }
    }

    private var profileIdentityCardContent: some View {
            // Shallow LazyVStack: every major section is a dedicated leaf + AnyView chrome.
            LazyVStack(alignment: .leading, spacing: Self.profileMajorSectionSpacing) {
                if shouldShowHandlePromptBanner {
                    AnyView(
                        handlePromptBanner
                            .padding(.horizontal, 16)
                    )
                }

                AnyView(
                    ProfileIdentitySectionChrome(
                        hierarchy: .hero,
                        accent: nil,
                        profileBackgroundKey: viewModel.currentUserProfileBackgroundKey
                    ) {
                        ProfileIdentityHeroSection(
                            viewModel: viewModel,
                            selectedAvatarItem: $selectedAvatarItem,
                            isUploadingAvatar: isUploadingAvatar,
                            isSavingIdentity: isSavingIdentity,
                            localAvatarPreviewImage: localAvatarPreviewImage,
                            displayName: displayName,
                            handleLine: handleLine,
                            bioLine: bioLine,
                            identityCards: profileHeroIdentityCards,
                            onEditDisplayName: { presentIdentityEditor(focusedField: .displayName) },
                            onEditBio: { presentIdentityEditor(focusedField: .bio) },
                            onEditProfile: { presentIdentityEditor(focusedField: .displayName) },
                            onShareProfile: { presentShareOwnProfile() }
                        )
                    }
                )

                if profileBelowFoldSectionsReady, canShowOwnerPokesHighlights {
                    AnyView(
                        ProfileIdentitySectionChrome(hierarchy: .utility, accent: nil) {
                            AnyView(pokesHighlightsSection)
                        }
                    )
                }

                AnyView(
                    ProfileIdentitySectionChrome(
                        hierarchy: .primary,
                        accent: [FGColor.accentBlue, Self.profileHomeCrowdAccent]
                    ) {
                        ProfileIdentityFavoriteTeamsSection(
                            languageCode: appLanguageRaw,
                            teamsEmpty: selectedTeams.isEmpty,
                            onEdit: { showFavoriteTeamsPicker = true },
                            carouselContent: AnyView(favoriteTeamsCarouselOnly)
                        )
                    }
                )

                AnyView(
                    ProfileIdentitySectionChrome(
                        hierarchy: .secondary,
                        accent: [Self.profileHomeCrowdAccent]
                    ) {
                        ProfileIdentityHomeVenueSection(viewModel: viewModel)
                    }
                )

                AnyView(
                    ProfileIdentitySectionChrome(
                        hierarchy: .secondary,
                        accent: [FGColor.accentBlue]
                    ) {
                        ProfileIdentityOpenToSection(
                            languageCode: appLanguageRaw,
                            previewItems: FanOpenToCatalog.publicDisplayItems(
                                from: viewModel.currentUserFanIdentityPreferences.resolvedOpenToItemIDs
                            ),
                            onEdit: { showFanIdentityEditor = true },
                            onQuickRemove: { quickRemoveOpenToItem($0) }
                        )
                    }
                )

                if let uid = viewModel.currentUserAuthId {
                    AnyView(
                        ProfileIdentitySectionChrome(
                            hierarchy: .secondary,
                            accent: [FGColor.accentBlue, FGColor.accentGreen]
                        ) {
                            pickupGamesProfileSection(userId: uid)
                        }
                    )
                }

                if profileBelowFoldSectionsReady, canShowSuggestedFans {
                    AnyView(
                        ProfileIdentitySectionChrome(
                            hierarchy: .secondary,
                            accent: [FGColor.accentBlue, Self.profileTealAccent]
                        ) {
                            AnyView(suggestedFansSection)
                        }
                        .id(Self.suggestedFansScrollAnchorID)
                    )
                }

                if profileBelowFoldSectionsReady, let slot = sponsoredProfileSlotContent {
                    AnyView(
                        ProfileIdentitySectionChrome(
                            hierarchy: .secondary,
                            accent: [FGColor.accentGreen]
                        ) {
                            sponsoredProfileSlotView(slot)
                                .id(slot.stableIdentity)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    )
                }
            }
            .padding(.top, 14)
            .padding(.bottom, 24)
            .background(cardShellBackground)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(cardBorder)
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.06), radius: 14, y: 8)
            .profileReadableContentWidth()
            .onAppear {
#if DEBUG
                print("[SettingsPerf] profileIdentityCard appear isAccountTabActive=\(isAccountTabActive)")
#endif
#if DEBUG
                SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] profileIdentityCardAppeared=true isAccountTabActive=\(isAccountTabActive)")
#endif
#if DEBUG
                print("[FanUpdatesStoreMigrationDebug] ProfileIdentityReadsStore=true")
                print("[ProfileIdentityCardDebug] layout=modern_light_social_profile")
                print("[ProfileBioDebug] identityCardDisplayedBio=\(bioLine)")
                print("[ProfileHierarchyDebug] sectionSpacingApplied=\(Int(Self.profileMajorSectionSpacing))")
                print("[ProfileHierarchyDebug] cardElevationUpdated=true")
                print("[ProfileHierarchyDebug] sectionGroupingEnabled=true")
#endif
                DebugLogGate.debug("[PokesConsolidation] propsUIRemoved")
                DebugLogGate.debug("[PokesConsolidation] primarySocialSurface=pokes")
                FanReputationEngine.log(reputation)
                scheduleProfileBelowFoldSectionsIfNeeded()
            }
            .onChange(of: viewModel.currentUserBio) { _, newValue in
#if DEBUG
                print("[ProfileBioDebug] identityCardDisplayedBio=\(newValue.trimmingCharacters(in: .whitespacesAndNewlines))")
#endif
            }
            .onChange(of: viewModel.currentUserAuthId) { oldAuthId, _ in
                ProfilePhase1PersonalizationCache.invalidateSuggestedFans(for: oldAuthId)
                resetSuggestedFansLoadStateForAuthChange()
                if showIdentityEditor {
                    resetIdentityDraft()
                }
            }
            .onChange(of: viewModel.profileEditPresentationEvaluationKey) { _, _ in
                // Only re-seed the draft when the sheet opens onto a freshly hydrated profile —
                // never while the user is mid-edit or mid-save (wiping edits made Save look like a no-op).
                guard showIdentityEditor,
                      !isSavingIdentity,
                      viewModel.hasLoadedUserProfileForPresentation,
                      !viewModel.isUserProfileLoadingForPresentation else { return }
                // Skip if the user has already typed beyond the last seeded values.
                guard !identityDraftLooksDirty else { return }
                resetIdentityDraft()
            }
            .onChange(of: isAccountTabActive) { _, isActive in
                if isActive {
                    scheduleProfileBelowFoldSectionsIfNeeded()
                }
            }
            .sheet(isPresented: $showHandleSetup) {
                FanGeoIdentitySetupView(viewModel: viewModel, mode: .handleOnly)
            }
            .sheet(isPresented: $showIdentityEditor) {
                identityEditorSheet
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showShareOwnProfileSheet) {
                if let ownShareProfile,
                   ownShareProfile.isPubliclyVisible,
                   ownShareProfile.isDiscoverableByFans {
                    ShareFanProfileSheet(profile: ownShareProfile, mapViewModel: viewModel)
                        .environmentObject(chatViewModel)
                } else {
                    NavigationStack {
                        VStack(spacing: 12) {
                            Text(ownShareProfileError
                                 ?? L10n.t("share_profile_unavailable", languageCode: appLanguageRaw))
                                .font(.body)
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .multilineTextAlignment(.center)
                                .padding()
                            Spacer()
                        }
                        .navigationTitle(L10n.t("share_profile", languageCode: appLanguageRaw))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(L10n.t("close", languageCode: appLanguageRaw)) {
                                    showShareOwnProfileSheet = false
                                }
                            }
                        }
                    }
                    .presentationDetents([.medium])
                }
            }
            .sheet(isPresented: $showFanIdentityEditor) {
                FanIdentityPreferencesEditorView(viewModel: viewModel)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .task {
                await viewModel.loadFanIdentityPreferencesFromProfile()
            }
            .task(id: profileStatsLoadToken) {
                await loadProfileStatsIfNeeded()
            }
            .task(id: sponsoredPlacementLoadToken) {
#if DEBUG
                SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] profileTaskStarted=true token=\(sponsoredPlacementLoadToken)")
#endif
                try? await Task.sleep(nanoseconds: Self.profileExtrasFirstPaintDeferNanoseconds)
                guard !Task.isCancelled, isAccountTabActive else { return }
                await loadSponsoredProfileRecommendation(reason: "profileTask")
                if Task.isCancelled {
#if DEBUG
                    SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] taskCancelledAfterLoader=true reason=profileTask")
#endif
                }
            }
            .sheet(isPresented: $showSponsoredPromotionSupportSheet) {
                ContactGameOnSupportSheet(
                    viewModel: viewModel,
                    onRequestSignIn: {
                        showSponsoredPromotionSupportSheet = false
                        routeSponsoredFallbackToVenueOwnerTools()
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showFavoriteTeamsPicker) {
                FavoriteTeamsPickerSheet(
                    selectedIDs: Binding(
                        get: { selectedIDSet },
                        set: { newSet in
                            let previous = selectedIDSet
                            let addedIDs = newSet.subtracting(previous)
                            let sorted = Array(newSet).sorted()
                            let nextPrimary = FavoriteTeamsStore.normalizedPrimaryTeamID(primaryFavoriteTeamIDRaw, within: sorted)
                            favoriteTeamIDsRaw = FavoriteTeamsStore.encodeIDs(sorted)
                            primaryFavoriteTeamIDRaw = nextPrimary ?? ""
                            Task {
                                let didSync = await viewModel.syncFavoriteTeamsToSupabase(teamIDs: sorted, primaryTeamID: nextPrimary)
                                guard didSync else { return }
                                // One toast max per save: prefer lexicographically last added id (stable when
                                // multi-select order is unavailable from the Binding).
                                guard let addedID = addedIDs.sorted().last else { return }
                                let teams = FavoriteTeamsStore.resolvedTeams(fromIDs: [addedID])
                                guard let team = teams.first else { return }
                                await MainActor.run {
                                    viewModel.presentFavoriteTeamWowMoment(team: team, languageCode: appLanguageRaw)
                                }
                            }
                        }
                    )
                )
            }
            .sheet(isPresented: $showNationalTeamPicker) {
                NationalTeamPickerSheet(currentIdentity: viewModel.currentUserNationalTeam) { identity in
                    Task { await saveNationalTeamIdentity(identity) }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showPokesHistorySheet) {
                pokesHistorySheet
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $sponsoredVenueDetail) { venue in
                sponsoredVenueDetailSheet(for: venue)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .onChange(of: showPokesHistorySheet) { _, isPresented in
                if isPresented {
                    DebugLogGate.debug("[PokesUI] history opened")
                    viewModel.acknowledgeIncomingPokes(reason: "pokesHistorySheet")
                }
            }
            .task(id: accountProfileHydrationRecoveryToken) {
                guard isAccountTabActive else { return }
                await viewModel.recoverUserProfilePresentationForAccountTabIfNeeded()
            }
            .task(id: profilePersonalizationLoadToken) {
                guard isAccountTabActive else {
#if DEBUG
                    print("[PerfPhase1C] profileLoadDeferred reason=accountTabHidden")
#endif
                    return
                }
                try? await Task.sleep(nanoseconds: Self.profileExtrasFirstPaintDeferNanoseconds)
                guard !Task.isCancelled, isAccountTabActive else { return }
#if DEBUG
                print("[PerfPhase1C] profileLoadStarted reason=accountTabVisible")
#endif
                primeSuggestedFansLoadingStateIfNeeded()
                await refreshIncomingPokesLive(reason: "accountVisible")
                await loadSuggestedFans()
                // Ensure favorite teams hydrate even if warm preload raced ahead of auth id / cleared AppStorage.
                let localEmpty = FavoriteTeamsStore.decodeIDs(from: favoriteTeamIDsRaw).isEmpty
                if localEmpty, viewModel.currentUserAuthId != nil {
                    await viewModel.loadFavoriteTeamsFromSupabase(forceRefresh: true)
                    scheduleSuggestedFansRefreshAfterSignalsChanged(reason: "favoriteTeamsHydrated")
                } else {
                    rememberSuggestedFansSignalFingerprint()
                }
            }
            .onChange(of: favoriteTeamIDsRaw) { _, _ in
                scheduleSuggestedFansRefreshAfterSignalsChanged(reason: "favoriteTeamsChanged")
            }
            .onChange(of: viewModel.currentUserNationalTeam?.countryCode) { _, _ in
                scheduleSuggestedFansRefreshAfterSignalsChanged(reason: "nationalTeamChanged")
            }
            .onChange(of: viewModel.hasLoadedUserProfileForPresentation) { _, loaded in
                guard loaded else { return }
                scheduleSuggestedFansRefreshAfterSignalsChanged(reason: "profilePresentationReady")
            }
            .onChange(of: viewModel.currentUserLocation?.latitude) { _, _ in
                scheduleSuggestedFansRefreshAfterSignalsChanged(reason: "locationAvailable")
            }
            .task(id: pokesLiveRefreshLoopToken) {
                guard isAccountTabActive else { return }
                try? await Task.sleep(nanoseconds: Self.profileExtrasFirstPaintDeferNanoseconds)
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: Self.incomingPokesLiveRefreshIntervalNs)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled, isAccountTabActive else { return }
                    await refreshIncomingPokesLive(reason: "slowInterval")
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else {
#if DEBUG
                    SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] foregroundRefreshSkipped=true reason=scenePhaseInactive phase=\(String(describing: phase))")
#endif
                    return
                }
                guard isAccountTabActive else {
#if DEBUG
                    SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] foregroundRefreshSkipped=true reason=accountTabInactive")
#endif
                    return
                }
                Task {
                    await refreshIncomingPokesLive(reason: "foreground")
                    await loadSponsoredProfileRecommendation(reason: "foreground")
                }
            }
            .onChange(of: selectedAvatarItem) { _, item in
                guard let item else { return }
                Task { await replaceAvatar(with: item) }
            }
            .onChange(of: viewModel.currentUserLocation?.latitude) { _, _ in
                refreshSponsoredPlacementDistanceIfNeeded()
                refreshSponsoredProfilePlacement(reason: "currentUserLatitudeChanged")
            }
            .onChange(of: viewModel.currentUserLocation?.longitude) { _, _ in
                refreshSponsoredPlacementDistanceIfNeeded()
                refreshSponsoredProfilePlacement(reason: "currentUserLongitudeChanged")
            }
            .onChange(of: editedUsername) { _, newValue in
                let normalized = FanGeoHandleRules.normalizeForStorage(newValue)
                if normalized != newValue {
                    editedUsername = normalized
                    return
                }
                scheduleHandleAvailabilityCheck()
            }
            .onChange(of: editedBio) { _, newValue in
                let limited = limitedBio(newValue)
                if limited != newValue {
                    editedBio = limited
                }
            }
    }

    // MARK: - Shell

    private var cardShellBackground: some View {
        ZStack {
            Color(.secondarySystemGroupedBackground)
            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.08 : 0.96),
                    Color(red: 0.94, green: 0.98, blue: 1.0).opacity(colorScheme == .dark ? 0.05 : 0.72),
                    FGColor.accentGreen.opacity(colorScheme == .dark ? 0.035 : 0.055)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.10 : 0.92),
                        FGColor.accentBlue.opacity(colorScheme == .dark ? 0.08 : 0.12),
                        Color.black.opacity(colorScheme == .dark ? 0.02 : 0.055)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.75
            )
    }

    private func profileSectionContainer<Content: View>(
        _ hierarchy: ProfileSectionHierarchy,
        accent: [Color]? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(profileSectionInnerPadding(for: hierarchy))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(profileSectionBackground(for: hierarchy))
            .clipShape(RoundedRectangle(cornerRadius: profileSectionCornerRadius(for: hierarchy), style: .continuous))
            .overlay(alignment: .top) {
                if let accent {
                    profileSectionTopAccent(accent)
                }
            }
            .overlay(profileSectionBorder(for: hierarchy))
            .shadow(
                color: profileSectionShadowColor(for: hierarchy),
                radius: profileSectionShadowRadius(for: hierarchy),
                x: 0,
                y: profileSectionShadowYOffset(for: hierarchy)
            )
            .padding(.horizontal, 16)
    }

    private func profileSectionTopAccent(_ accent: [Color]) -> some View {
        let baseColors = accent.isEmpty ? [FGColor.accentBlue] : accent
        let gradientColors = baseColors.count == 1 ? [baseColors[0], baseColors[0]] : baseColors
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(
                LinearGradient(
                    colors: gradientColors.map {
                        $0.opacity(colorScheme == .dark ? 0.76 : 0.58)
                    },
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 4)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func profileSectionInnerPadding(for hierarchy: ProfileSectionHierarchy) -> EdgeInsets {
        switch hierarchy {
        case .hero:
            EdgeInsets(top: 0, leading: 0, bottom: 16, trailing: 0)
        case .primary:
            EdgeInsets(top: 16, leading: 14, bottom: 16, trailing: 14)
        case .secondary:
            EdgeInsets(top: 16, leading: 13, bottom: 16, trailing: 13)
        case .utility:
            EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
        }
    }

    private func profileSectionCornerRadius(for hierarchy: ProfileSectionHierarchy) -> CGFloat {
        switch hierarchy {
        case .hero:
            26
        case .primary:
            24
        case .secondary, .utility:
            22
        }
    }

    private func profileSectionBackground(for hierarchy: ProfileSectionHierarchy) -> some View {
        RoundedRectangle(cornerRadius: profileSectionCornerRadius(for: hierarchy), style: .continuous)
            .fill(
                LinearGradient(
                    colors: profileSectionBackgroundColors(for: hierarchy),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private func profileSectionBorder(for hierarchy: ProfileSectionHierarchy) -> some View {
        RoundedRectangle(cornerRadius: profileSectionCornerRadius(for: hierarchy), style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: profileSectionBorderColors(for: hierarchy),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: profileSectionBorderWidth(for: hierarchy)
            )
    }

    private func profileSectionBackgroundColors(for hierarchy: ProfileSectionHierarchy) -> [Color] {
        switch hierarchy {
        case .hero:
            return [
                Color.white.opacity(colorScheme == .dark ? 0.085 : 0.98),
                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.075 : 0.070),
                FGColor.accentGreen.opacity(colorScheme == .dark ? 0.045 : 0.050)
            ]
        case .primary:
            return [
                Color.white.opacity(colorScheme == .dark ? 0.075 : 0.96),
                FGColor.accentGreen.opacity(colorScheme == .dark ? 0.060 : 0.055),
                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.050 : 0.045)
            ]
        case .secondary:
            return [
                Color.white.opacity(colorScheme == .dark ? 0.050 : 0.88),
                Color.white.opacity(colorScheme == .dark ? 0.030 : 0.64),
                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.035 : 0.030)
            ]
        case .utility:
            return [
                Color.white.opacity(colorScheme == .dark ? 0.040 : 0.80),
                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.035 : 0.032)
            ]
        }
    }

    private func profileSectionBorderColors(for hierarchy: ProfileSectionHierarchy) -> [Color] {
        switch hierarchy {
        case .hero:
            return [
                Color.white.opacity(colorScheme == .dark ? 0.13 : 0.92),
                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.18),
                Color.black.opacity(colorScheme == .dark ? 0.04 : 0.08)
            ]
        case .primary:
            return [
                Color.white.opacity(colorScheme == .dark ? 0.10 : 0.86),
                FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.17),
                Color.black.opacity(colorScheme == .dark ? 0.03 : 0.065)
            ]
        case .secondary:
            return [
                Color.white.opacity(colorScheme == .dark ? 0.075 : 0.72),
                Color.black.opacity(colorScheme == .dark ? 0.025 : 0.055)
            ]
        case .utility:
            return [
                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.10 : 0.10),
                Color.black.opacity(colorScheme == .dark ? 0.02 : 0.05)
            ]
        }
    }

    private func profileSectionBorderWidth(for hierarchy: ProfileSectionHierarchy) -> CGFloat {
        switch hierarchy {
        case .hero, .primary:
            1
        case .secondary, .utility:
            0.85
        }
    }

    private func profileSectionShadowColor(for hierarchy: ProfileSectionHierarchy) -> Color {
        switch hierarchy {
        case .hero:
            return Color.black.opacity(colorScheme == .dark ? 0.26 : 0.075)
        case .primary:
            return FGColor.accentBlue.opacity(colorScheme == .dark ? 0.13 : 0.075)
        case .secondary:
            return Color.black.opacity(colorScheme == .dark ? 0.14 : 0.040)
        case .utility:
            return FGColor.accentBlue.opacity(colorScheme == .dark ? 0.08 : 0.035)
        }
    }

    private func profileSectionShadowRadius(for hierarchy: ProfileSectionHierarchy) -> CGFloat {
        switch hierarchy {
        case .hero:
            20
        case .primary:
            16
        case .secondary:
            10
        case .utility:
            8
        }
    }

    private func profileSectionShadowYOffset(for hierarchy: ProfileSectionHierarchy) -> CGFloat {
        switch hierarchy {
        case .hero:
            10
        case .primary:
            8
        case .secondary:
            5
        case .utility:
            3
        }
    }

    // MARK: - Pokes highlights

    @ViewBuilder
    private var pokesHighlightsSection: some View {
        if shouldShowCompactPokesRow {
            let recentPokers = uniqueRecentPokersForAvatars
            let peopleCount = recentPokers.count
            let title = compactPokesCardTitle(peopleCount: peopleCount)
            let body = compactPokesCardBody(recentPokers: recentPokers)
            Button {
#if DEBUG
                print("[PokeUIFlowDebug] openingFullPokeSheet=true")
#endif
                showPokesHistorySheet = true
            } label: {
                HStack(spacing: 10) {
                    compactPokesAvatarStack(recentPokers: recentPokers)
                        .accessibilityHidden(true)

                    compactPokesWaveBadge
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(title)
                                .font(.system(size: 13.5, weight: .heavy, design: .rounded))
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)

                            if viewModel.hasUnseenPokes, viewModel.unseenPokesCount > 0 {
                                Text(compactPokesNewBadgeCopy(count: viewModel.unseenPokesCount))
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule(style: .continuous).fill(FGColor.accentBlue))
                                    .accessibilityHidden(true)
                            }
                        }

                        Text(body)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }

                    Spacer(minLength: 4)

                    HStack(spacing: 3) {
                        Text(L10n.t("profile_pokes_view_history", languageCode: appLanguageRaw))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.92 : 0.88))
                    .accessibilityHidden(true)
                }
                .padding(.horizontal, 12)
                .frame(height: 66)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .background {
                    pokesHighlightsCardBackground
                }
                .pokesUnseenHighlightsEmphasis(isActive: viewModel.hasUnseenPokes)
            }
            .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.985))
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(pokesHighlightsAccessibilityLabel(title: title, body: body))
            .accessibilityHint(L10n.t("profile_pokes_open_history_a11y", languageCode: appLanguageRaw))
            .onAppear {
                playPokeWaveBadgeUnseenIntroIfNeeded()
            }
            .onChange(of: viewModel.hasUnseenPokes) { _, hasUnseen in
                if hasUnseen {
                    playPokeWaveBadgeUnseenIntroIfNeeded()
                } else {
                    pokeWaveBadgeDidPlayUnseenIntro = false
                    pokeWaveBadgeIntroScale = 1
                }
            }
        }
    }

    private var compactPokesWaveBadge: some View {
        Image(systemName: "hand.wave.fill")
            .font(.system(size: 15.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(
                LinearGradient(
                    colors: [
                        Color.orange.opacity(0.95),
                        FGColor.accentGreen.opacity(0.92)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Circle()
            )
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.22 : 0.94), lineWidth: 1.25)
            }
            .shadow(color: Color.orange.opacity(colorScheme == .dark ? 0.28 : 0.18), radius: 4, y: 1)
            .scaleEffect(pokeWaveBadgeIntroScale)
    }

    private func playPokeWaveBadgeUnseenIntroIfNeeded() {
        guard viewModel.hasUnseenPokes, !pokeWaveBadgeDidPlayUnseenIntro else { return }
        pokeWaveBadgeDidPlayUnseenIntro = true
        pokeWaveBadgeIntroScale = 0.82
        withAnimation(.spring(response: 0.34, dampingFraction: 0.62)) {
            pokeWaveBadgeIntroScale = 1.08
        }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.78).delay(0.16)) {
            pokeWaveBadgeIntroScale = 1
        }
    }

    private var pokesHighlightsCardBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.08 : 0.97),
                        Color.orange.opacity(colorScheme == .dark ? 0.10 : 0.07),
                        FGColor.accentGreen.opacity(colorScheme == .dark ? 0.08 : 0.055),
                        FGColor.accentBlue.opacity(colorScheme == .dark ? 0.08 : 0.055)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.orange.opacity(colorScheme == .dark ? 0.20 : 0.17),
                                FGColor.accentGreen.opacity(colorScheme == .dark ? 0.18 : 0.14),
                                Color.white.opacity(colorScheme == .dark ? 0.06 : 0.78)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
            }
    }

    private func compactPokesAvatarStack(recentPokers: [ProfilePokeIncomingItem]) -> some View {
        ZStack {
            if recentPokers.isEmpty {
                Circle()
                    .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.14 : 0.10))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: "hand.wave.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(FGColor.accentBlue)
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.95), lineWidth: 1.5)
                    }
            } else {
                let visiblePokers = Array(recentPokers.prefix(3))
                ZStack(alignment: .leading) {
                    ForEach(Array(visiblePokers.enumerated()), id: \.element.id) { index, poke in
                        pokesAvatar(poke)
                            .offset(x: CGFloat(index) * 14)
                            .zIndex(Double(visiblePokers.count - index))
                    }
                }
                .frame(
                    width: CGFloat(max(visiblePokers.count - 1, 0)) * 14 + 30,
                    height: 34,
                    alignment: .leading
                )
            }
        }
        .frame(width: 58, alignment: .leading)
        .accessibilityHidden(true)
    }

    private var uniqueRecentPokersForAvatars: [ProfilePokeIncomingItem] {
        var seen = Set<UUID>()
        var ordered: [ProfilePokeIncomingItem] = []
        for poke in incomingPokes {
            if seen.insert(poke.pokerUserId).inserted {
                ordered.append(poke)
            }
        }
        return ordered
    }

    private func pokesAvatar(_ poke: ProfilePokeIncomingItem) -> some View {
        pokeAvatarView(poke, size: 30)
        .overlay {
            Circle()
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.92 : 1), lineWidth: 2)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.10), radius: 3, y: 1)
    }

    @ViewBuilder
    private func pokeAvatarView(_ poke: ProfilePokeIncomingItem, size: CGFloat) -> some View {
        if poke.isDeleted {
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .frame(width: size, height: size)
                .background(Circle().fill(Color(white: 0.88)))
                .clipShape(Circle())
        } else {
        UserAvatarView(
            avatarThumbnailURL: poke.pokerAvatarThumbnailURL,
            avatarURL: poke.pokerAvatarURL ?? "",
            avatarDisplayRefreshToken: ProfileAvatarRefreshToken.stable(
                userId: poke.pokerUserId,
                thumbnailURL: poke.pokerAvatarThumbnailURL,
                avatarURL: poke.pokerAvatarURL,
                versionSuffix: poke.createdAt ?? ""
            ),
            displayName: poke.pokerDisplayName,
            email: "",
            size: size,
            fallbackStyle: .lightOnWhiteChrome,
            imagePlaceholderTint: FGColor.accentBlue
        )
        }
    }

    private var shouldShowCompactPokesRow: Bool {
        incomingPokeTotalCount > 0
    }

    private func compactPokesSafeDisplayName(_ poke: ProfilePokeIncomingItem?) -> String {
        let trimmed = poke?.pokerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return L10n.t("profile_pokes_fallback_fan_name", languageCode: appLanguageRaw)
    }

    private func compactPokesCardTitle(peopleCount: Int) -> String {
        if peopleCount <= 1 {
            return L10n.t("profile_pokes_card_title_one", languageCode: appLanguageRaw)
        }
        return String(
            format: L10n.t("profile_pokes_card_title_count_format", languageCode: appLanguageRaw),
            locale: Locale(identifier: L10n.normalizedLanguageCode(appLanguageRaw)),
            peopleCount
        )
    }

    private func compactPokesCardBody(recentPokers: [ProfilePokeIncomingItem]) -> String {
        let peopleCount = recentPokers.count
        let firstName = compactPokesSafeDisplayName(recentPokers.first)
        guard peopleCount > 0 else { return "" }
        if peopleCount == 1 {
            return String(
                format: L10n.t("profile_pokes_card_body_one_format", languageCode: appLanguageRaw),
                locale: Locale(identifier: L10n.normalizedLanguageCode(appLanguageRaw)),
                firstName
            )
        }
        let others = peopleCount - 1
        if others == 1 {
            return String(
                format: L10n.t("profile_pokes_card_body_one_other_format", languageCode: appLanguageRaw),
                locale: Locale(identifier: L10n.normalizedLanguageCode(appLanguageRaw)),
                firstName
            )
        }
        return String(
            format: L10n.t("profile_pokes_card_body_many_others_format", languageCode: appLanguageRaw),
            locale: Locale(identifier: L10n.normalizedLanguageCode(appLanguageRaw)),
            firstName,
            others
        )
    }

    private func compactPokesNewBadgeCopy(count: Int) -> String {
        let safe = max(count, 1)
        if safe == 1 {
            return L10n.t("profile_pokes_new", languageCode: appLanguageRaw)
        }
        return String(
            format: L10n.t("profile_pokes_new_count_format", languageCode: appLanguageRaw),
            locale: Locale(identifier: L10n.normalizedLanguageCode(appLanguageRaw)),
            safe
        )
    }

    private func pokesHighlightsAccessibilityLabel(title: String, body: String) -> String {
        let combined = [title, body]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
        if viewModel.hasUnseenPokes, viewModel.unseenPokesCount > 0 {
            return "\(combined). \(compactPokesNewBadgeCopy(count: viewModel.unseenPokesCount))"
        }
        return combined
    }

    private var pokesHistorySheet: some View {
        NavigationStack {
            Group {
                if isLoadingIncomingPokes && incomingPokes.isEmpty {
                    ProgressView(L10n.t("profile_pokes_loading", languageCode: appLanguageRaw))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if incomingPokes.isEmpty {
                    ContentUnavailableView(
                        L10n.t("profile_pokes_empty_title", languageCode: appLanguageRaw),
                        systemImage: "hand.wave.fill",
                        description: Text(L10n.t("profile_pokes_empty_body", languageCode: appLanguageRaw))
                    )
                } else {
                    List(incomingPokes) { poke in
                        if poke.isDeleted {
                            pokesHistoryRow(poke)
                        } else {
                            Button {
                                viewModel.presentPublicProfile(
                                    userId: poke.pokerUserId,
                                    context: "pokes_history",
                                    activeSheet: "Pokes"
                                )
                            } label: {
                                pokesHistoryRow(poke)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(L10n.t("profile_pokes_history_title", languageCode: appLanguageRaw))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Done", languageCode: appLanguageRaw)) { showPokesHistorySheet = false }
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        Button {
#if DEBUG
                            print("[FanPokesDebug] clearAllTapped=true")
#endif
                            showClearAllPokesConfirmation = true
                        } label: {
                            Text(L10n.t("profile_pokes_clear", languageCode: appLanguageRaw))
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                        }
                        .disabled(incomingPokes.isEmpty || isLoadingIncomingPokes || isClearingAllPokes)
                        .foregroundStyle(FGColor.dangerRed)
                        .accessibilityLabel(L10n.t("profile_pokes_clear_all_a11y", languageCode: appLanguageRaw))

                        Button {
                            Task { await forceRefreshIncomingPokes() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(isLoadingIncomingPokes || isClearingAllPokes)
                        .accessibilityLabel(L10n.t("profile_pokes_refresh_a11y", languageCode: appLanguageRaw))
                    }
                }
            }
            .alert(L10n.t("profile_pokes_clear_all_title", languageCode: appLanguageRaw), isPresented: $showClearAllPokesConfirmation) {
                Button(L10n.t("Cancel", languageCode: appLanguageRaw), role: .cancel) {}
                Button(L10n.t("profile_pokes_clear_all_confirm", languageCode: appLanguageRaw), role: .destructive) {
#if DEBUG
                    print("[FanPokesDebug] clearAllConfirmed=true")
#endif
                    Task { await clearAllIncomingPokes() }
                }
            } message: {
                Text(L10n.t("profile_pokes_clear_all_message", languageCode: appLanguageRaw))
            }
            .task {
                await forceRefreshIncomingPokes()
            }
            .refreshable {
                await forceRefreshIncomingPokes()
            }
        }
    }

    private func pokesHistoryRow(_ poke: ProfilePokeIncomingItem) -> some View {
        HStack(spacing: 12) {
            pokeAvatarView(poke, size: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(poke.pokerDisplayName)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)

                if !poke.publicHandleLine.isEmpty {
                    Text(poke.publicHandleLine)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(poke.relativePokedLabel)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func forceRefreshIncomingPokes() async {
        await refreshIncomingPokesLive(reason: "manual", forceRefresh: true)
    }

    private func clearAllIncomingPokes() async {
        guard !isClearingAllPokes else { return }
        await MainActor.run {
            isClearingAllPokes = true
            incomingPokesMessage = nil
        }

        do {
            let clearedCount = try await profilePokesService.clearIncomingPokesHistoryForCurrentUser()
            await MainActor.run {
                incomingPokes = []
                incomingPokeTotalCount = 0
                incomingPokesMessage = nil
                isClearingAllPokes = false
                if let authId = viewModel.currentUserAuthId {
                    ProfilePhase1PersonalizationCache.incomingPokesLoadedAtByAuthId[authId] = Date()
                }
                viewModel.clearUnseenPokesBadgeState()
#if DEBUG
                print("[FanPokesDebug] clearAllCompleted count=\(clearedCount)")
#endif
            }
        } catch {
            await MainActor.run {
                incomingPokesMessage = "Couldn't clear Pokes"
                isClearingAllPokes = false
#if DEBUG
                print("[FanPokesDebug] clearAllFailed error=\(error.localizedDescription)")
#endif
            }
        }
    }

    private func refreshIncomingPokesLive(reason: String, forceRefresh: Bool = false) async {
        guard isAccountTabActive else { return }
        await loadIncomingPokes(ignoreCache: forceRefresh, reason: reason)
    }

    @MainActor
    private func scheduleProfileBelowFoldSectionsIfNeeded() {
        guard isAccountTabActive, !profileBelowFoldSectionsReady else { return }
        guard !viewModel.shouldSuppressAuthenticatedRefreshForSafeLogout else { return }
        Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, isAccountTabActive else { return }
            guard !viewModel.shouldSuppressAuthenticatedRefreshForSafeLogout else { return }
            profileBelowFoldSectionsReady = true
            primeSuggestedFansLoadingStateIfNeeded()
#if DEBUG
            print("[SettingsPerf] profileBelowFoldSections rendered")
#endif
        }
    }

    /// Clears tab/avatar/card unseen state after the Pokes card has loaded on Account (not on tab select alone).
    private func acknowledgePokesCardAfterSuccessfulLoad() {
        guard isAccountTabActive, viewModel.hasUnseenPokes else { return }
        viewModel.acknowledgeIncomingPokes(reason: "pokesCardLoaded")
    }

    private func loadIncomingPokes(ignoreCache: Bool = false, reason: String = "ordinary") async {
        guard canShowOwnerPokesHighlights, let authId = viewModel.currentUserAuthId else {
            await MainActor.run {
                incomingPokes = []
                incomingPokeTotalCount = 0
                incomingPokesMessage = nil
                isLoadingIncomingPokes = false
            }
            return
        }

        // Coalesce with badge refresh so tab preload + Profile appear share one fetch.
        await viewModel.refreshUnseenPokesBadgeIfNeeded()

        if !ignoreCache,
           let loadedAt = ProfilePhase1PersonalizationCache.incomingPokesLoadedAtByAuthId[authId],
           Date().timeIntervalSince(loadedAt) < Self.incomingPokesFreshnessIntervalSeconds,
           let cached = ProfilePhase1PersonalizationCache.incomingPokesByAuthId[authId] {
            let age = Date().timeIntervalSince(loadedAt)
#if DEBUG
            TabPerfDebug.log("[TabPerfDebug] accountPokesRefreshSkipped reason=fresh age=\(String(format: "%.1f", age))")
            print("[SmoothPerf] operation=accountPokesRefresh coalescedOrFresh=true reason=\(reason)")
#endif
            await MainActor.run {
                incomingPokes = cached
                incomingPokeTotalCount = cached.count
                incomingPokesMessage = nil
                isLoadingIncomingPokes = false
                lastIncomingPokesFingerprint = cached.map(\.id.uuidString).joined(separator: "|")
            }
            acknowledgePokesCardAfterSuccessfulLoad()
            return
        }

        if !ignoreCache,
           let loadedAt = ProfilePhase1PersonalizationCache.incomingPokesLoadedAtByAuthId[authId],
           Date().timeIntervalSince(loadedAt) < Self.incomingPokesFreshnessIntervalSeconds {
            let age = Date().timeIntervalSince(loadedAt)
#if DEBUG
            TabPerfDebug.log("[TabPerfDebug] accountPokesRefreshSkipped reason=fresh age=\(String(format: "%.1f", age))")
#endif
            acknowledgePokesCardAfterSuccessfulLoad()
            return
        }

#if DEBUG
        TabPerfDebug.log("[TabPerfDebug] accountPokesRefreshStarted reason=\(reason)")
#endif

        await MainActor.run {
            isLoadingIncomingPokes = true
            incomingPokesMessage = nil
        }

        do {
            let items = try await profilePokesService.fetchMyIncomingPokes(limit: Self.incomingPokesHighlightsLimit)
            let fingerprint = items.map(\.id.uuidString).joined(separator: "|")

            await MainActor.run {
                ProfilePhase1PersonalizationCache.storeIncomingPokes(items, for: authId)
                if fingerprint == lastIncomingPokesFingerprint,
                   incomingPokeTotalCount == items.count {
                    isLoadingIncomingPokes = false
                    acknowledgePokesCardAfterSuccessfulLoad()
                    return
                }
                lastIncomingPokesFingerprint = fingerprint
                incomingPokes = items
                incomingPokeTotalCount = items.count
                incomingPokesMessage = nil
                isLoadingIncomingPokes = false
                viewModel.applyIncomingPokesFetch(items)
                acknowledgePokesCardAfterSuccessfulLoad()
            }
            DebugLogGate.debug("[PokesUI] incoming load count=\(items.count) total=\(items.count)")
#if DEBUG
            TabPerfDebug.log("[TabPerfDebug] accountPokesRefreshSucceeded count=\(items.count)")
#endif
        } catch {
            await MainActor.run {
                incomingPokes = []
                incomingPokeTotalCount = 0
                incomingPokesMessage = "Couldn't load Pokes"
                isLoadingIncomingPokes = false
            }
        }
    }

    // MARK: - Suggested fans

    private var displayedSuggestedFans: [FriendSuggestionProfile] {
        guard let viewerId = viewModel.currentUserAuthId else {
            return Array(suggestedFans.prefix(Self.suggestedFansDisplayLimit))
        }
        // Re-order by score then apply stable 8+2 diversity for the visible 10.
        // Exact distance is never present on these profiles.
        let scoreOrdered = suggestedFans.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.userID.uuidString < rhs.userID.uuidString
        }
        return SuggestedFansRanking.applyControlledDiversity(
            rankedByScoreDescending: scoreOrdered,
            displayLimit: Self.suggestedFansDisplayLimit,
            viewerId: viewerId
        )
    }

    private var suggestedFansSection: some View {
        ProfileSuggestedFansSection(
            suggestions: displayedSuggestedFans,
            hasCompletedLoad: hasCompletedSuggestedFansLoad,
            isRefreshing: isLoadingSuggestedFans && !displayedSuggestedFans.isEmpty,
            message: suggestedFansMessage,
            loadFailed: suggestedFansLoadFailed,
            sendingRequestIds: sendingSuggestedFanRequestIds,
            chipKind: { chatViewModel.chipKind(forOtherUserId: $0) },
            onAdd: { suggestion in
                Task { await addSuggestedFan(suggestion) }
            },
            onCancel: { suggestion in
                Task { await cancelSuggestedFanRequest(suggestion) }
            },
            onDismiss: { suggestion in
                Task { await dismissSuggestedFan(suggestion) }
            },
            onRetry: {
                Task { await loadSuggestedFans(ignoreCache: true) }
            }
        )
    }

    private func suggestedFansSignalFingerprint() -> String {
        let auth = viewModel.currentUserAuthId?.uuidString.lowercased() ?? "anonymous"
        let teams = FavoriteTeamsStore.decodeIDs(from: favoriteTeamIDsRaw).sorted().joined(separator: ",")
        let country = viewModel.currentUserNationalTeam?.countryCode.uppercased() ?? ""
        let hasLocation = viewModel.currentUserLocation != nil ? "1" : "0"
        let profileReady = viewModel.hasLoadedUserProfileForPresentation ? "1" : "0"
        return "\(auth)|teams=\(teams)|country=\(country)|loc=\(hasLocation)|ready=\(profileReady)"
    }

    @MainActor
    private func rememberSuggestedFansSignalFingerprint() {
        lastSuggestedFansSignalFingerprint = suggestedFansSignalFingerprint()
    }

    @MainActor
    private func scheduleSuggestedFansRefreshAfterSignalsChanged(reason: String) {
        guard canShowSuggestedFans, isAccountTabActive else { return }
        let fingerprint = suggestedFansSignalFingerprint()
        guard fingerprint != lastSuggestedFansSignalFingerprint || suggestedFansLoadFailed else {
            return
        }

        suggestedFansSignalRefreshTask?.cancel()
        suggestedFansSignalRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, isAccountTabActive, canShowSuggestedFans else { return }
            let nextFingerprint = suggestedFansSignalFingerprint()
            guard nextFingerprint != lastSuggestedFansSignalFingerprint || suggestedFansLoadFailed else {
                return
            }
            lastSuggestedFansSignalFingerprint = nextFingerprint
            ProfilePhase1PersonalizationCache.invalidateSuggestedFans(for: viewModel.currentUserAuthId)
#if DEBUG
            print("[SuggestedFansUI] signalRefresh reason=\(reason)")
#endif
            await loadSuggestedFans(ignoreCache: true)
        }
    }

    private func loadSuggestedFans(ignoreCache: Bool = false) async {
        guard canShowSuggestedFans else {
            await MainActor.run {
                suggestedFans = []
                suggestedFansMessage = nil
                suggestedFansLoadFailed = false
                isLoadingSuggestedFans = false
                hasCompletedSuggestedFansLoad = false
                suggestedFansLoadStartedAt = nil
                sendingSuggestedFanRequestIds = []
            }
            return
        }

        if let authId = viewModel.currentUserAuthId,
           !ignoreCache,
           let loadedAt = ProfilePhase1PersonalizationCache.suggestedFansLoadedAtByAuthId[authId],
           Date().timeIntervalSince(loadedAt) < ProfilePhase1PersonalizationCache.ttlSeconds {
            let cached = ProfilePhase1PersonalizationCache.suggestedFansByAuthId[authId] ?? []
            await MainActor.run {
                suggestedFans = cached
                suggestedFansMessage = nil
                suggestedFansLoadFailed = false
                isLoadingSuggestedFans = false
                hasCompletedSuggestedFansLoad = true
                suggestedFansLoadStartedAt = nil
                rememberSuggestedFansSignalFingerprint()
            }
#if DEBUG
            print("[PerfPhase1C] profileCacheHit key=suggestedFans")
            print("[SuggestedFansUI] loadCoalescedOrFresh reason=ttlHit")
            SuggestedFansDebug.loadingFinished(count: cached.count)
#endif
            return
        }

        if let inFlight = suggestedFansLoadTask, !ignoreCache {
#if DEBUG
            print("[SuggestedFansUI] loadCoalescedOrFresh reason=inFlight")
#endif
            await inFlight.value
            return
        }

        if ignoreCache {
            suggestedFansLoadTask?.cancel()
            suggestedFansLoadTask = nil
        }

        suggestedFansLoadGeneration &+= 1
        let generation = suggestedFansLoadGeneration
        let task = Task { @MainActor in
            await self.performSuggestedFansLoad(generation: generation)
        }
        suggestedFansLoadTask = task
        await task.value
        if suggestedFansLoadTask == task {
            suggestedFansLoadTask = nil
        }
    }

    private func performSuggestedFansLoad(generation: UInt64) async {
#if DEBUG
        print("[SuggestedFansUI] load start")
#endif
        let favoritesCount = FavoriteTeamsStore.decodeIDs(from: favoriteTeamIDsRaw).count
        let countryCode = viewModel.currentUserNationalTeam?.countryCode
        let coordinatesAvailable = viewModel.currentUserLocation != nil
        let center = viewModel.currentUserLocation

        await MainActor.run {
            if suggestedFansLoadStartedAt == nil {
                suggestedFansLoadStartedAt = Date()
                SuggestedFansDebug.loadingStarted()
            }
            isLoadingSuggestedFans = true
            suggestedFansMessage = nil
            suggestedFansLoadFailed = false
            SuggestedFansDebug.requestStarted(currentUserId: viewModel.currentUserAuthId)
            SuggestedFansDebug.profileReady(
                favoritesCount: favoritesCount,
                countryCode: countryCode,
                coordinatesAvailable: coordinatesAvailable
            )
        }

        do {
            let suggestions = try await friendSuggestionsService.fetchSuggestions(
                limit: Self.suggestedFansFetchLimit,
                radiusMiles: SuggestedFansProduct.nearbyRadiusMiles,
                centerLat: center?.latitude,
                centerLng: center?.longitude
            )
            let profileRowsById = await SuggestedFansEligibility.fetchProfileRows(
                for: suggestions.map(\.userID)
            )
            let (filteredSuggestions, summary) = await SuggestedFansEligibility.filterSuggestions(
                suggestions,
                viewerId: viewModel.currentUserAuthId,
                profileRowsById: profileRowsById,
                isBlocked: { chatViewModel.isEitherDirectionBlocked(with: $0) }
            )
            SuggestedFansDebug.filterSummary(summary)
            await MainActor.run {
                guard generation == suggestedFansLoadGeneration else {
#if DEBUG
                    print("[SuggestedFansUI] staleResultIgnored generation=\(generation)")
#endif
                    return
                }
                let startedAt = suggestedFansLoadStartedAt
                suggestedFans = filteredSuggestions
                suggestedFansMessage = nil
                suggestedFansLoadFailed = false
                isLoadingSuggestedFans = false
                hasCompletedSuggestedFansLoad = true
                rememberSuggestedFansSignalFingerprint()
                if let authId = viewModel.currentUserAuthId {
                    if filteredSuggestions.isEmpty {
                        // Do not sticky-cache empty pools; new-user signals can arrive shortly after.
                        ProfilePhase1PersonalizationCache.invalidateSuggestedFans(for: authId)
                    } else {
                        ProfilePhase1PersonalizationCache.suggestedFansLoadedAtByAuthId[authId] = Date()
                        ProfilePhase1PersonalizationCache.suggestedFansByAuthId[authId] = filteredSuggestions
                    }
                }
                if let startedAt, !filteredSuggestions.isEmpty {
                    let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
                    SuggestedFansDebug.firstContentVisibleMs(ms)
                }
                suggestedFansLoadStartedAt = nil
                SuggestedFansDebug.loadingFinished(count: filteredSuggestions.count)
            }
#if DEBUG
            print("[SuggestedFansUI] load success count=\(filteredSuggestions.count)")
#endif
        } catch {
            await MainActor.run {
                guard generation == suggestedFansLoadGeneration else { return }
                suggestedFans = []
                suggestedFansMessage = "Couldn't load fan suggestions"
                suggestedFansLoadFailed = true
                isLoadingSuggestedFans = false
                hasCompletedSuggestedFansLoad = true
                suggestedFansLoadStartedAt = nil
                // Do not cache failures as empty matches.
                ProfilePhase1PersonalizationCache.invalidateSuggestedFans(for: viewModel.currentUserAuthId)
                SuggestedFansDebug.loadingFinished(count: 0)
            }
#if DEBUG
            print("[SuggestedFansUI] load failed error=\(error.localizedDescription)")
#endif
        }
    }

    @MainActor
    private func primeSuggestedFansLoadingStateIfNeeded() {
        guard canShowSuggestedFans else { return }

        if let authId = viewModel.currentUserAuthId {
            let cached = ProfilePhase1PersonalizationCache.suggestedFansByAuthId[authId] ?? []
            let isFresh = ProfilePhase1PersonalizationCache.suggestedFansLoadedAtByAuthId[authId].map {
                Date().timeIntervalSince($0) < ProfilePhase1PersonalizationCache.ttlSeconds
            } ?? false

            if isFresh {
                if suggestedFans.isEmpty {
                    suggestedFans = cached
                }
                isLoadingSuggestedFans = false
                hasCompletedSuggestedFansLoad = true
                suggestedFansLoadFailed = false
                suggestedFansMessage = nil
                suggestedFansLoadStartedAt = nil
                rememberSuggestedFansSignalFingerprint()
#if DEBUG
                SuggestedFansDebug.loadingFinished(count: cached.count)
#endif
                return
            }

            if !cached.isEmpty {
                if suggestedFans.isEmpty {
                    suggestedFans = cached
                }
                hasCompletedSuggestedFansLoad = true
                suggestedFansLoadFailed = false
                if suggestedFansLoadStartedAt == nil {
                    suggestedFansLoadStartedAt = Date()
                    SuggestedFansDebug.loadingStarted()
                }
                isLoadingSuggestedFans = true
                suggestedFansMessage = nil
                return
            }
        }

        guard !hasCompletedSuggestedFansLoad, suggestedFans.isEmpty else { return }
        if suggestedFansLoadStartedAt == nil {
            suggestedFansLoadStartedAt = Date()
            SuggestedFansDebug.loadingStarted()
        }
        isLoadingSuggestedFans = true
        suggestedFansLoadFailed = false
        suggestedFansMessage = nil
    }

    @MainActor
    private func resetSuggestedFansLoadStateForAuthChange() {
        suggestedFansSignalRefreshTask?.cancel()
        suggestedFansSignalRefreshTask = nil
        suggestedFansLoadTask?.cancel()
        suggestedFansLoadTask = nil
        suggestedFansLoadGeneration &+= 1
        lastSuggestedFansSignalFingerprint = ""
        hasCompletedSuggestedFansLoad = false
        suggestedFansLoadStartedAt = nil
        suggestedFans = []
        isLoadingSuggestedFans = false
        suggestedFansMessage = nil
        suggestedFansLoadFailed = false
        sendingSuggestedFanRequestIds = []
    }

    private func addSuggestedFan(_ suggestion: FriendSuggestionProfile) async {
        guard canShowSuggestedFans else { return }
        guard !sendingSuggestedFanRequestIds.contains(suggestion.userID) else { return }

#if DEBUG
        print("[SuggestedFansUI] add tapped user_id=\(suggestion.userID.uuidString.lowercased())")
#endif
        await MainActor.run {
            _ = sendingSuggestedFanRequestIds.insert(suggestion.userID)
        }
        await chatViewModel.sendFriendRequest(to: suggestion.userID)
        await MainActor.run {
            _ = sendingSuggestedFanRequestIds.remove(suggestion.userID)
        }
    }

    private func cancelSuggestedFanRequest(_ suggestion: FriendSuggestionProfile) async {
        guard canShowSuggestedFans else { return }
#if DEBUG
        print("[SuggestedFansUI] cancel request tapped user_id=\(suggestion.userID.uuidString.lowercased())")
#endif
        await chatViewModel.cancelOutgoingFriendRequest(to: suggestion.userID)
    }

    @MainActor
    private func dismissSuggestedFan(_ suggestion: FriendSuggestionProfile) async {
        guard canShowSuggestedFans else { return }
        let dismissedId = suggestion.userID
        let visibleBefore = displayedSuggestedFans.map(\.userID)

        suggestedFans.removeAll { $0.userID == dismissedId }
        sendingSuggestedFanRequestIds.remove(dismissedId)
        ProfilePhase1PersonalizationCache.dismissCachedSuggestedFan(
            authId: viewModel.currentUserAuthId,
            dismissedUserId: dismissedId
        )

        print("[SuggestedFans] dismissed user=\(dismissedId.uuidString.lowercased())")

        if let replacementId = displayedSuggestedFans.map(\.userID).first(where: { !visibleBefore.contains($0) }) {
            print("[SuggestedFans] replacement loaded user=\(replacementId.uuidString.lowercased())")
        }

        do {
            try await friendSuggestionsService.dismissSuggestion(dismissedUserId: dismissedId)
        } catch {
            DebugLogGate.debug("[SuggestedFans] dismiss persist failed user=\(dismissedId.uuidString.lowercased()) error=\(error.localizedDescription)")
        }
    }

    // MARK: - Sponsored profile recommendation

    private var sponsoredProfileSportTarget: String? {
        let sport = primaryFavoriteTeam?.sport.chipTitle
            ?? selectedTeams.first?.sport.chipTitle
        let trimmed = sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var sponsoredProfileLocationParts: (city: String?, state: String?, country: String?) {
        let raw = viewModel.currentUserHomeCrowdVenue?.locationLabel
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return (nil, nil, nil) }

        let parts = raw
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (
            parts.first,
            parts.dropFirst().first,
            parts.dropFirst(2).first
        )
    }

    private var sponsoredProfileCityTarget: String? {
        sponsoredProfileLocationParts.city
    }

    private var sponsoredProfileStateTarget: String? {
        sponsoredProfileLocationParts.state
    }

    private var sponsoredProfileCountryTarget: String? {
        sponsoredProfileLocationParts.country
    }

    private var sponsoredProfileSlotContent: SponsoredProfileSlotContent? {
        guard isAccountTabActive else { return nil }
        if let recommendation = sponsoredProfileRecommendation, recommendation.isSponsored {
            return .venue(recommendation)
        }
        if viewModel.canUseFanSocialFeatures, let promotion = sponsoredProfileFallbackPromotion() {
            return .fallback(promotion)
        }
        return nil
    }

    @ViewBuilder
    private func sponsoredProfileSlotView(_ slot: SponsoredProfileSlotContent) -> some View {
        switch slot {
        case .venue(let recommendation):
            SponsoredProfileRecommendationCard(
                recommendation: recommendation,
                colorScheme: colorScheme,
                onTap: {
                    openSponsoredProfileVenue(recommendation)
                }
            )
        case .fallback(let promotion):
            SponsoredProfileFallbackPromotionCard(
                promotion: promotion,
                colorScheme: colorScheme,
                onTap: {
                    handleSponsoredProfileFallbackTap(promotion)
                }
            )
        }
    }

    private func loadSponsoredProfileRecommendation(reason: String) async {
        SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] loaderStarted=true reason=\(reason) isAccountTabActive=\(isAccountTabActive) isLoggedIn=\(viewModel.isLoggedIn) authId=\(viewModel.currentUserAuthId?.uuidString.lowercased() ?? "nil") taskCancelled=\(Task.isCancelled)")
        guard !Task.isCancelled else {
            SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] exclusionReason=taskCancelledBeforeFetch reason=\(reason)")
            return
        }
        guard isAccountTabActive else {
            SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] exclusionReason=accountTabInactive")
            return
        }
        guard viewModel.isLoggedIn else {
            SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] exclusionReason=noAuthSession")
            sponsoredProfileRecommendation = nil
            return
        }
        guard viewModel.currentUserAuthId != nil || !viewModel.currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] exclusionReason=noAuthSession authId=nil emailEmpty=true")
            sponsoredProfileRecommendation = nil
            return
        }
        guard beginSponsoredPlacementLoadIfAllowed(reason: reason) else { return }
        defer { finishSponsoredPlacementLoad(reason: reason) }

        let userLocation = await currentSponsoredPlacementUserLocation(reason: "profileRecommendationLoad")
        guard !Task.isCancelled else {
            SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] exclusionReason=taskCancelledAfterLocation reason=\(reason)")
            return
        }
        let locationTargets = await sponsoredProfileResolvedLocationTargets(userLocation: userLocation)
        do {
            let placements = try await sponsoredPlacementService.fetchProfileRecommendedPlacements(
                country: locationTargets.country,
                state: locationTargets.state,
                city: locationTargets.city,
                sport: sponsoredProfileSportTarget,
                userLocation: userLocation
            )
            if Task.isCancelled {
                SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] exclusionReason=taskCancelledAfterQuery reason=\(reason)")
                return
            }
            await MainActor.run {
                let recommendation = activeSponsoredProfileRecommendation(from: placements, userLocation: userLocation)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                    sponsoredProfileRecommendation = recommendation
                }
#if DEBUG
                if let recommendation {
                    print("[SponsoredProfileDebug] source=\(recommendation.sourceDebugLabel)")
                    print("[SponsoredProfileDebug] sponsoredVenue=\(recommendation.venue.name)")
                } else {
                    print("[SponsoredProfileDebug] source=none")
                    print("[SponsoredProfileDebug] noActiveSponsoredPlacement=true")
                }
#endif
            }
        } catch {
            await MainActor.run {
                sponsoredProfileRecommendation = nil
                if error is CancellationError {
                    SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] exclusionReason=taskCancelledDuringFetch reason=\(reason)")
                } else {
                    SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] exclusionReason=loadFailed error=\(error.localizedDescription)")
                }
#if DEBUG
                print("[SponsoredProfileDebug] source=none")
                print("[SponsoredProfileDebug] noActiveSponsoredPlacement=true")
                print("[SponsoredProfileDebug] loadFailed=\(error.localizedDescription)")
#endif
            }
        }
    }

    private func beginSponsoredPlacementLoadIfAllowed(reason: String) -> Bool {
        if isSponsoredProfilePlacementLoading {
            SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] exclusionReason=alreadyLoading reason=\(reason)")
            return false
        }

        let now = Date()
        if let lastSponsoredProfilePlacementRefreshAt,
           now.timeIntervalSince(lastSponsoredProfilePlacementRefreshAt) < Self.sponsoredPlacementRefreshDebounceSeconds {
            SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] exclusionReason=skippedDueToRefreshDebounce reason=\(reason) elapsed=\(String(format: "%.2f", now.timeIntervalSince(lastSponsoredProfilePlacementRefreshAt)))")
            return false
        }

        isSponsoredProfilePlacementLoading = true
        lastSponsoredProfilePlacementRefreshAt = now
        SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] loadAllowed=true reason=\(reason)")
        return true
    }

    private func finishSponsoredPlacementLoad(reason: String) {
        isSponsoredProfilePlacementLoading = false
        SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] loaderFinished=true reason=\(reason)")
    }

    private func currentSponsoredPlacementUserLocation(reason: String) async -> CLLocationCoordinate2D? {
        if SponsoredProfileVenueRecommendation.hasValidLocation(viewModel.currentUserLocation) {
            logSponsoredPlacementUserLocation(viewModel.currentUserLocation, source: "cachedCurrentUserLocation", reason: reason)
            return viewModel.currentUserLocation
        }

        let refreshed = await viewModel.refreshCurrentUserLocationIfAuthorized(timeoutSeconds: 4)
        if refreshed, SponsoredProfileVenueRecommendation.hasValidLocation(viewModel.currentUserLocation) {
            logSponsoredPlacementUserLocation(viewModel.currentUserLocation, source: "deviceLocationRefresh", reason: reason)
            return viewModel.currentUserLocation
        }

        if let homeCrowdCoordinate = sponsoredProfileHomeCrowdCoordinate(),
           SponsoredProfileVenueRecommendation.hasValidLocation(homeCrowdCoordinate) {
            logSponsoredPlacementUserLocation(homeCrowdCoordinate, source: "homeCrowdVenue", reason: reason)
            return homeCrowdCoordinate
        } else if viewModel.currentUserHomeCrowdVenueId != nil {
            SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] exclusionReason=missingVenue reason=homeCrowdVenueCoordinateUnavailable venueId=\(viewModel.currentUserHomeCrowdVenueId?.uuidString.lowercased() ?? "nil")")
        }

        logSponsoredPlacementUserLocation(nil, source: refreshed ? "deviceLocationInvalid" : "noAuthorizedDeviceLocation", reason: reason)
        SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] exclusionReason=missingLocation reason=\(refreshed ? "deviceLocationInvalid" : "noAuthorizedDeviceLocation")")
        return nil
    }

    private func sponsoredProfileHomeCrowdCoordinate() -> CLLocationCoordinate2D? {
        guard let homeCrowdVenueId = viewModel.currentUserHomeCrowdVenueId else { return nil }
        return uniqueOrganicRecommendationCandidates()
            .first(where: { $0.id == homeCrowdVenueId })?
            .coordinate
    }

    private func sponsoredProfileResolvedLocationTargets(
        userLocation: CLLocationCoordinate2D?
    ) async -> (city: String?, state: String?, country: String?) {
        var city = sponsoredProfileCityTarget
        var state = sponsoredProfileStateTarget
        var country = sponsoredProfileCountryTarget

        if (city?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || (state?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
           let userLocation,
           SponsoredProfileVenueRecommendation.hasValidLocation(userLocation) {
            let fields = await viewModel.reverseGeocodeAddressFields(for: userLocation)
            city = city?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? city : fields.city
            state = state?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? state : fields.state
        }

        if (country?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
           let userLocation,
           SponsoredProfileVenueRecommendation.hasValidLocation(userLocation) {
            country = await reverseGeocodeSponsoredPlacementCountry(for: userLocation)
        }

        SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] targetCity=\(city ?? "nil") targetState=\(state ?? "nil") targetCountry=\(country ?? "nil")")
        return (city, state, country)
    }

    private func reverseGeocodeSponsoredPlacementCountry(for _: CLLocationCoordinate2D) async -> String? {
        SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] countrySource=defaultCountryCodeForCurrentDevice")
        return BusinessLocationCountryPolicy.defaultCountryCode
    }

    private func activeSponsoredProfileRecommendation(
        from paidPlacements: [SponsoredProfileVenueRecommendation],
        userLocation: CLLocationCoordinate2D?
    ) -> SponsoredProfileVenueRecommendation? {
        guard !paidPlacements.isEmpty else {
            SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] exclusionReason=noActivePlacementReturned")
            print("[SponsoredPlacementRotation] eligibleCount=0")
            return nil
        }
        let now = Date()
        var eligiblePlacements: [SponsoredProfileVenueRecommendation] = []

        for paidPlacement in paidPlacements {
            let eligibility = paidPlacement.regionalEligibility(for: userLocation, now: now)
            SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] placementId=\(paidPlacement.placementID.uuidString.lowercased())")
            SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] venueId=\(paidPlacement.venue.id.uuidString.lowercased()) venueName=\(paidPlacement.venue.name)")
            SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] starts_at=\(paidPlacement.startsAtRaw ?? "nil") ends_at=\(paidPlacement.endsAtRaw ?? "nil") currentTime=\(Self.sponsoredPlacementDebugDateFormatter.string(from: now))")
            SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] userLat=\(userLocation.map { "\($0.latitude)" } ?? "nil") userLng=\(userLocation.map { "\($0.longitude)" } ?? "nil")")
            SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] radiusCheck=\(eligibility.isEligible) distanceMiles=\(eligibility.distanceMiles.map { String(format: "%.2f", $0) } ?? "nil") radiusMiles=\(paidPlacement.targetRadiusMiles.map { "\($0)" } ?? "nil")")
            if eligibility.isEligible {
                eligiblePlacements.append(paidPlacement)
            } else {
                SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] exclusionReason=\(eligibility.reason)")
            }
        }

        let selected = weightedSponsoredProfilePlacement(from: eligiblePlacements)
        if let selected {
            recordSponsoredProfilePlacementSelection(selected)
        }
        return selected
    }

    private func recordSponsoredProfilePlacementSelection(_ selected: SponsoredProfileVenueRecommendation) {
        let previousVenueId = lastSponsoredProfileVenueIDRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let selectedVenueId = selected.venue.id.uuidString.lowercased()
        let nextRepeatCount = previousVenueId == selectedVenueId
            ? max(sponsoredProfileVenueRepeatCount, 0) + 1
            : 1

        lastSponsoredProfileVenueIDRaw = selectedVenueId
        lastSponsoredProfilePlacementIDRaw = selected.placementID.uuidString.lowercased()
        sponsoredProfileVenueRepeatCount = nextRepeatCount
        print("[SponsoredPlacementRotation] selectedRepeatCount=\(nextRepeatCount)")
    }

    private func weightedSponsoredProfilePlacement(
        from eligiblePlacements: [SponsoredProfileVenueRecommendation]
    ) -> SponsoredProfileVenueRecommendation? {
        print("[SponsoredPlacementRotation] eligibleCount=\(eligiblePlacements.count)")
        guard !eligiblePlacements.isEmpty else { return nil }

        for placement in eligiblePlacements {
            print("[SponsoredPlacementRotation] placementId=\(placement.placementID.uuidString.lowercased()) venueName=\(placement.venue.name) priority_weight=\(placement.priorityWeight)")
        }

        let lastVenueId = lastSponsoredProfileVenueIDRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let repeatCount = max(sponsoredProfileVenueRepeatCount, 0)
        print("[SponsoredPlacementRotation] lastShownVenueId=\(lastVenueId.isEmpty ? "none" : lastVenueId)")
        print("[SponsoredPlacementRotation] repeatCount=\(repeatCount)")

        let rotationPool: [SponsoredProfileVenueRecommendation]
        let repeatGuardApplied: Bool
        if eligiblePlacements.count >= 3, !lastVenueId.isEmpty {
            let withoutRecentVenue = eligiblePlacements.filter {
                $0.venue.id.uuidString.lowercased() != lastVenueId
            }
            if withoutRecentVenue.isEmpty {
                rotationPool = eligiblePlacements
                repeatGuardApplied = false
                print("[SponsoredPlacementRotation] recentlyExcludedPlacement=none")
            } else {
                rotationPool = withoutRecentVenue
                repeatGuardApplied = true
                let recentlyExcluded = eligiblePlacements
                    .filter { $0.venue.id.uuidString.lowercased() == lastVenueId }
                    .map { "\($0.placementID.uuidString.lowercased()):\($0.venue.name)" }
                    .joined(separator: ",")
                print("[SponsoredPlacementRotation] recentlyExcludedPlacement=\(recentlyExcluded.isEmpty ? "none" : recentlyExcluded)")
            }
        } else if eligiblePlacements.count == 2, !lastVenueId.isEmpty, repeatCount >= 2 {
            let withoutRepeatedVenue = eligiblePlacements.filter {
                $0.venue.id.uuidString.lowercased() != lastVenueId
            }
            if withoutRepeatedVenue.isEmpty {
                rotationPool = eligiblePlacements
                repeatGuardApplied = false
                print("[SponsoredPlacementRotation] recentlyExcludedPlacement=none")
            } else {
                rotationPool = withoutRepeatedVenue
                repeatGuardApplied = true
                let recentlyExcluded = eligiblePlacements
                    .filter { $0.venue.id.uuidString.lowercased() == lastVenueId }
                    .map { "\($0.placementID.uuidString.lowercased()):\($0.venue.name)" }
                    .joined(separator: ",")
                print("[SponsoredPlacementRotation] recentlyExcludedPlacement=\(recentlyExcluded.isEmpty ? "none" : recentlyExcluded)")
            }
        } else {
            rotationPool = eligiblePlacements
            repeatGuardApplied = false
            print("[SponsoredPlacementRotation] recentlyExcludedPlacement=none")
        }
        print("[SponsoredPlacementRotation] repeatGuardApplied=\(repeatGuardApplied)")

        let totalWeight = rotationPool.reduce(0) { $0 + $1.priorityWeight }
        print("[SponsoredPlacementRotation] totalWeight=\(totalWeight)")
        guard totalWeight > 0 else {
            let selected = rotationPool.first
            print("[SponsoredPlacementRotation] selectionRandomValue=nil")
            print("[SponsoredPlacementRotation] selectedPlacement=\(selected?.placementID.uuidString.lowercased() ?? "nil") venueName=\(selected?.venue.name ?? "nil")")
            return selected
        }

        let randomValue = Int.random(in: 1...totalWeight)
        print("[SponsoredPlacementRotation] selectionRandomValue=\(randomValue)")
        var ticket = randomValue
        for placement in rotationPool {
            ticket -= placement.priorityWeight
            if ticket <= 0 {
                print("[SponsoredPlacementRotation] selectedPlacement=\(placement.placementID.uuidString.lowercased()) venueName=\(placement.venue.name)")
                return placement
            }
        }

        let selected = rotationPool.last
        print("[SponsoredPlacementRotation] selectedPlacement=\(selected?.placementID.uuidString.lowercased() ?? "nil") venueName=\(selected?.venue.name ?? "nil")")
        return selected
    }

    private func sponsoredProfileFallbackPromotion() -> SponsoredProfileFallbackPromotion? {
        guard viewModel.canUseFanSocialFeatures else { return nil }
        return SponsoredProfileFallbackPromotion.businessGrowthCard(
            languageCode: L10n.normalizedLanguageCode(appLanguageRaw)
        )
    }

    private func handleSponsoredProfileFallbackTap(_ promotion: SponsoredProfileFallbackPromotion) {
#if DEBUG
        print("[SponsoredProfileDebug] fallbackCardTapped=true")
        print("[SponsoredProfileDebug] fallbackId=\(promotion.id)")
#endif
        routeSponsoredFallbackToVenueOwnerTools()
    }

    private func routeSponsoredFallbackToVenueOwnerTools() {
        viewModel.switchToAccountForVenueClaim = true
        viewModel.openVenueOwnerAuthSheetFromClaimFlow = true
    }

    private func refreshSponsoredPlacementDistanceIfNeeded() {
        guard let current = sponsoredProfileRecommendation else { return }
        let nextDistance = SponsoredPlacementService.distanceLine(
            from: viewModel.currentUserLocation,
            to: current.venue
        )
        guard nextDistance != current.distanceLine else { return }
        sponsoredProfileRecommendation = current.withDistanceLine(nextDistance)
    }

    private func refreshSponsoredProfilePlacement(reason: String) {
        Task {
            SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] refreshRequested reason=\(reason)")
            await loadSponsoredProfileRecommendation(reason: reason)
        }
    }

    private func logSponsoredPlacementUserLocation(_ location: CLLocationCoordinate2D?, source: String, reason: String) {
        SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] locationSource=\(source) reason=\(reason)")
        SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] userLat=\(location.map { "\($0.latitude)" } ?? "nil") userLng=\(location.map { "\($0.longitude)" } ?? "nil")")
    }

    private func organicProfileRecommendation() -> SponsoredProfileVenueRecommendation? {
        guard let venue = organicRecommendedVenue() else { return nil }
        let sport = venue.primarySport.trimmingCharacters(in: .whitespacesAndNewlines)
        let gameLine = organicGameLine(for: venue, sport: sport)
        return SponsoredProfileVenueRecommendation(
            placementID: venue.id,
            title: venue.name,
            venue: venue,
            gameLine: gameLine,
            distanceLine: SponsoredPlacementService.distanceLine(from: viewModel.currentUserLocation, to: venue),
            fansGoingText: organicFansGoingText(for: venue),
            ctaLabel: "View Venue",
            imageURLString: nil,
            isSponsored: false,
            startsAtRaw: nil,
            endsAtRaw: nil,
            targetLatitude: nil,
            targetLongitude: nil,
            targetRadiusMiles: nil,
            priorityWeight: 1
        )
    }

    private func organicRecommendedVenue() -> BarVenue? {
        let candidates = uniqueOrganicRecommendationCandidates()
            .filter { organicVenueIsDisplayable($0) }
        guard !candidates.isEmpty else { return nil }

        let sportTarget = sponsoredProfileSportTarget?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sportMatched = candidates.filter { venue in
            guard let sportTarget, !sportTarget.isEmpty else { return true }
            return organicVenue(venue, matchesSport: sportTarget)
        }
        let pool = sportMatched.isEmpty ? candidates : sportMatched
        return nearestOrganicVenue(in: pool) ?? pool.first
    }

    private func uniqueOrganicRecommendationCandidates() -> [BarVenue] {
        var seen = Set<UUID>()
        var venues: [BarVenue] = []
        for venue in viewModel.mapVisibleBars + viewModel.followingTabSavedVenues + viewModel.bars {
            guard seen.insert(venue.id).inserted else { continue }
            venues.append(venue)
        }
        return venues
    }

    private func organicVenueIsDisplayable(_ venue: BarVenue) -> Bool {
        let name = venue.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        let status = venue.adminStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "active"
        guard status.isEmpty || status == "active" else { return false }
        return true
    }

    private func organicVenue(_ venue: BarVenue, matchesSport sportTarget: String) -> Bool {
        let primary = venue.primarySport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if primary == sportTarget { return true }
        if venue.sportTags.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == sportTarget }) {
            return true
        }
        return venue.games.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains(sportTarget) }
    }

    private func nearestOrganicVenue(in venues: [BarVenue]) -> BarVenue? {
        guard let userLocation = viewModel.currentUserLocation,
              CLLocationCoordinate2DIsValid(userLocation) else {
            return nil
        }
        let origin = CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
        return venues
            .filter { CLLocationCoordinate2DIsValid($0.coordinate) }
            .min { lhs, rhs in
                let lhsLocation = CLLocation(latitude: lhs.coordinate.latitude, longitude: lhs.coordinate.longitude)
                let rhsLocation = CLLocation(latitude: rhs.coordinate.latitude, longitude: rhs.coordinate.longitude)
                return origin.distance(from: lhsLocation) < origin.distance(from: rhsLocation)
            }
    }

    private func organicGameLine(for venue: BarVenue, sport: String) -> String {
        if let game = venue.games
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return game
        }
        return sport.isEmpty ? "Sports tonight" : "\(sport) tonight"
    }

    private func organicFansGoingText(for venue: BarVenue) -> String {
        let count = max(venue.goingCounts.values.max() ?? 0, viewModel.displayedGoingCount(for: venue))
        return count > 0 ? "\(count) fans going" : "Fans are checking this spot"
    }

    private func openSponsoredProfileVenue(_ recommendation: SponsoredProfileVenueRecommendation) {
#if DEBUG
        print("[SponsoredProfileDebug] cardTapped=true")
        print("[SponsoredProfileDebug] \(recommendation.isSponsored ? "sponsoredVenue" : "organicVenue")=\(recommendation.venue.name)")
#endif
        sponsoredVenueDetail = recommendation.venue
    }

    private func sponsoredVenueDetailSheet(for venue: BarVenue) -> some View {
        NavigationStack {
            let effectiveBusinessId = viewModel.effectiveBusinessIdForVenueChat(for: venue)
            let canOpenVenueChat = viewModel.canUseFanSocialFeatures && effectiveBusinessId != nil
            let openVenueChatAction: (() async -> Void)? = {
                guard canOpenVenueChat else { return nil }
                return { await openSponsoredVenueChat(for: venue) }
            }()
            VenueDetailView(
                bar: venue,
                selectedEvent: nil,
                isFavorite: viewModel.canFavoriteVenues && viewModel.favoriteVenueIDs.contains(venue.id),
                goingCount: viewModel.displayedGoingCount(for: venue),
                iconForSport: viewModel.iconForSport,
                mergedRating: viewModel.mergedDisplayRating(for: venue),
                ratingCount: viewModel.reviewCountDisplay(for: venue),
                displaySport: venue.primarySport,
                sportsSupported: venue.sportTags.isEmpty ? [venue.primarySport].filter { !$0.isEmpty } : venue.sportTags,
                selectedTimeZone: viewModel.selectedTimeZone,
                hasGamesScheduledToday: !venue.games.isEmpty,
                isBusinessConfirmed: effectiveBusinessId != nil,
                onDirections: { viewModel.openDirections(to: venue) },
                onCall: { viewModel.callVenue(venue) },
                onFavorite: { viewModel.toggleFavorite(venue) },
                onAddressTap: { viewModel.openDirections(to: venue) },
                onRateVenue: nil,
                experience: viewModel.experience(for: venue),
                coverPhotoURL: venue.coverPhotoURL,
                menuPhotoURL: venue.menuPhotoURL,
                showsBusinessOwnershipSection: false,
                showsFanOnlyActionButtons: viewModel.canUseFanSocialFeatures,
                onFanFeatureBlocked: { action in
                    viewModel.logBusinessUserGateBlocked(action: action)
                },
                showsHomeCrowdControls: viewModel.canUseFanSocialFeatures,
                isHomeCrowdVenue: viewModel.isHomeCrowdVenue(venue.id),
                onToggleHomeCrowd: {
                    await viewModel.toggleHomeCrowd(for: venue)
                },
                onOpenVenueChat: openVenueChatAction,
                effectiveBusinessId: effectiveBusinessId
            )
            .navigationTitle(venue.name)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await viewModel.refreshApprovedVenueOwnershipState(for: venue)
            }
        }
    }

    private func openSponsoredVenueChat(for venue: BarVenue) async {
        guard viewModel.isAuthenticatedForSocialFeatures else { return }
        guard viewModel.canUseFanSocialFeatures else {
            viewModel.logBusinessUserGateBlocked(action: "venueChat")
            return
        }
        let chatBar = viewModel.barVenueForVenueChat(venue)
        let outcome = await chatViewModel.openBusinessVenueConversationFromVenueDetail(bar: chatBar)
        switch outcome {
        case .openedChat:
            sponsoredVenueDetail = nil
        case .needsVenuePicker, .informational:
            break
        }
    }

    // MARK: - Handle prompt

    private var handlePromptBanner: some View {
        Button {
            showHandleSetup = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "at")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(FGColor.accentGreen)
                Text("Choose your @handle for friend search")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(FGColor.accentGreen.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Hero

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerRow

            if !profileHeroIdentityCards.isEmpty {
                ProfileHeroIdentityCardsRow(cards: profileHeroIdentityCards)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, ProfileHeroMetrics.identityTopInset)
        .padding(.bottom, 18)
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 14) {
            PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
                avatarStack
            }
            .disabled(isUploadingAvatar || isSavingIdentity)
            .buttonStyle(.plain)
            .accessibilityLabel("Update profile photo")

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    presentIdentityEditor(focusedField: .displayName)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)

                        Text(handleLine)
                            .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit display name and handle")

                // Compact identity stack: handle → XP (~5pt) → bio (~7pt).
                FanXpSummaryLine(
                    totalXP: viewModel.currentUserFanXP.totalXP,
                    languageCode: appLanguageRaw
                )
                .padding(.top, 5)

                Button {
                    presentIdentityEditor(focusedField: .bio)
                } label: {
                    Text(
                        bioLine.isEmpty
                            ? L10n.t("profile_bio_placeholder", languageCode: appLanguageRaw)
                            : bioLine
                    )
                        .font(.system(size: 14.5, weight: .medium, design: .rounded))
                        .foregroundStyle(bioLine.isEmpty ? FGColor.mutedText(colorScheme) : FGColor.primaryText(colorScheme).opacity(0.88))
                        .lineLimit(3)
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(bioLine.isEmpty ? "Add bio" : "Edit bio")
                .padding(.top, 7)

                editProfileHeroButton
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var editProfileHeroButton: some View {
        Button {
            presentIdentityEditor(focusedField: .displayName)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 9, weight: .bold))
                Text(L10n.t("edit_profile_hero_button", languageCode: appLanguageRaw))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(FGColor.accentBlue)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                Capsule()
                    .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.14 : 0.10))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("edit_profile", languageCode: appLanguageRaw))
    }

    private var profileHeroIdentityPanel: some View {
        ProfileHeroIdentityCardsRow(cards: profileHeroIdentityCards)
    }

    private var profileHeroIdentityPanelFill: Color {
        colorScheme == .dark
            ? Color(red: 0.10, green: 0.14, blue: 0.20).opacity(0.92)
            : Color(red: 0.93, green: 0.95, blue: 0.99)
    }

    private var profileHeroIdentityPanelBorder: Color {
        colorScheme == .dark
            ? FGColor.divider(colorScheme).opacity(0.65)
            : Color(red: 0.84, green: 0.88, blue: 0.95)
    }

    private func profileHeroIdentityColumnView(_ column: ProfileIdentityHeroStripColumn) -> some View {
        let content = VStack(spacing: 8) {
            profileHeroIdentityIcon(for: column)

            Text(column.title)
                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme).opacity(0.92))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: false, vertical: true)

            Text(column.subtitle)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(profileHeroIdentityColumnAccessibilityLabel(column))

        return Group {
            if let action = column.action {
                Button(action: action) {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private func profileHeroIdentityColumnAccessibilityLabel(_ column: ProfileIdentityHeroStripColumn) -> String {
        switch column.id {
        case .myTeam:
            let heading = L10n.t("my_team", languageCode: appLanguageRaw)
            return "\(heading), \(column.title), \(column.subtitle)"
        case .nationalTeam:
            let heading = L10n.t("national_team", languageCode: appLanguageRaw)
            return "\(heading), \(column.title), \(column.subtitle)"
        case .homeCrowd, .homeCity, .fanSince:
            return "\(column.title), \(column.subtitle)"
        }
    }

    @ViewBuilder
    private func profileHeroIdentityIcon(for column: ProfileIdentityHeroStripColumn) -> some View {
        switch column.id {
        case .myTeam:
            if let team = column.favoriteTeam {
                SportsIdentityArtworkView(favoriteTeam: team, diameter: 38)
            } else {
                profileHeroIdentitySymbolIcon("trophy.fill", tint: FGColor.accentYellow)
            }
        case .nationalTeam:
            if let flag = viewModel.currentUserNationalTeam?.flag.trimmingCharacters(in: .whitespacesAndNewlines),
               !flag.isEmpty {
                Text(flag)
                    .font(.system(size: 20))
                    .frame(width: 38, height: 38)
                    .background {
                        Circle()
                            .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    }
            } else {
                profileHeroIdentitySymbolIcon("globe.americas.fill", tint: FGColor.accentGreen)
            }
        case .homeCrowd:
            profileHeroIdentitySymbolIcon(
                "sportscourt.fill",
                tint: Color(red: 0.58, green: 0.42, blue: 0.92)
            )
        case .homeCity:
            profileHeroIdentitySymbolIcon(
                "mappin.and.ellipse",
                tint: Color(red: 0.22, green: 0.48, blue: 0.96)
            )
        case .fanSince:
            profileHeroIdentitySymbolIcon(
                "calendar",
                tint: Color(red: 0.22, green: 0.48, blue: 0.96)
            )
        }
    }

    private func profileHeroIdentitySymbolIcon(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 38, height: 38)
            .background {
                Circle()
                    .fill(tint.opacity(colorScheme == .dark ? 0.2 : 0.12))
            }
    }

    private var profileHeroPokesBadgeVisible: Bool {
        viewModel.hasUnseenPokes
    }

    private var avatarStack: some View {
        ZStack(alignment: .topTrailing) {
            avatarStackCore

            if profileHeroPokesBadgeVisible {
                PokesUnseenAvatarBadge(style: .profileHero)
                    .offset(x: 3, y: 1)
            }
        }
        .onAppear {
            DebugLogGate.debug("[PokesBadgeUI] avatarBadge visible=\(profileHeroPokesBadgeVisible)")
        }
        .onChange(of: profileHeroPokesBadgeVisible) { _, visible in
            DebugLogGate.debug("[PokesBadgeUI] avatarBadge visible=\(visible)")
        }
    }

    private var avatarStackCore: some View {
        ZStack(alignment: .bottomTrailing) {
            UserAvatarView(
                avatarThumbnailURL: viewModel.currentUserAvatarThumbnailURL,
                avatarURL: viewModel.currentUserAvatarURL,
                avatarDisplayRefreshToken: viewModel.currentUserAvatarDisplayRefreshToken,
                localPreviewImage: localAvatarPreviewImage,
                displayName: displayName,
                email: viewModel.currentUserEmail,
                size: Self.profileHeroAvatarDiameter,
                fallbackStyle: .lightOnWhiteChrome,
                imagePlaceholderTint: FGColor.accentBlue
            )
            .overlay {
                Circle()
                    .strokeBorder(
                        AngularGradient(
                            colors: [
                                FGColor.accentBlue,
                                FGColor.accentGreen,
                                Color(red: 0.98, green: 0.67, blue: 0.33),
                                FGColor.accentBlue
                            ],
                            center: .center
                        ),
                        lineWidth: Self.profileHeroAvatarRingWidth
                    )
            }
            .padding(Self.profileHeroAvatarOuterPadding)
            .background(Circle().fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.96)))
            .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.16), radius: 12, y: 5)
            .id(avatarPresentationIdentity)
            .onAppear {
#if DEBUG
                ProfileAvatarDebug.avatarViewResolved(
                    context: "ProfileIdentityCard.avatarStackCore",
                    thumbnailInput: viewModel.currentUserAvatarThumbnailURL,
                    fullInput: viewModel.currentUserAvatarURL,
                    displayURLString: ImageDisplayURL.forListDisplay(
                        thumbnail: viewModel.currentUserAvatarThumbnailURL,
                        full: viewModel.currentUserAvatarURL,
                        refreshToken: viewModel.currentUserAvatarDisplayRefreshToken
                    ),
                    urlParseSucceeded: ImageDisplayURL.forListDisplay(
                        thumbnail: viewModel.currentUserAvatarThumbnailURL,
                        full: viewModel.currentUserAvatarURL,
                        refreshToken: viewModel.currentUserAvatarDisplayRefreshToken
                    ).flatMap { URL(string: $0) } != nil,
                    fallbackReason: viewModel.currentUserAvatarURL.isEmpty
                        && viewModel.currentUserAvatarThumbnailURL.isEmpty
                        ? "view_model_avatar_urls_empty"
                        : "awaiting_UserAvatarView_image_layer"
                )
#endif
            }

            Circle()
                .fill(Color(.secondarySystemGroupedBackground))
                .frame(width: Self.profileHeroCameraButtonDiameter, height: Self.profileHeroCameraButtonDiameter)
                .overlay {
                    // Keep this overlay type shallow — inline ProgressView/Image ConditionalContent
                    // previously exploded SwiftUI metadata and crashed Profile tab (stack guard).
                    ProfileHeroAvatarCameraGlyph(
                        isUploading: isUploadingAvatar,
                        iconSize: Self.profileHeroCameraIconSize,
                        tint: FGColor.accentGreen
                    )
                }
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.14 : 0.95), lineWidth: 1.75)
                }
                .offset(x: 5, y: 5)
        }
    }

    // MARK: - Inline identity editing

    private var identityEditorSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    EditProfilePhotoHeader(
                        viewModel: viewModel,
                        selectedAvatarItem: $selectedAvatarItem,
                        isUploadingAvatar: isUploadingAvatar,
                        isSavingIdentity: isSavingIdentity,
                        localAvatarPreviewImage: localAvatarPreviewImage,
                        previewDisplayName: editedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? displayName
                            : editedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines),
                        previewHandleLine: {
                            let raw = FanGeoHandleRules.normalizeForStorage(editedUsername)
                            return raw.isEmpty ? "" : "@\(raw)"
                        }(),
                        languageCode: appLanguageRaw
                    )

                    EditProfileSection(title: L10n.t("public_profile", languageCode: appLanguageRaw)) {
                        EditProfileDisplayNameRow(
                            displayName: $editedDisplayName,
                            focusedField: $focusedIdentityField,
                            languageCode: appLanguageRaw
                        )
                        EditProfileRowDivider()
                        EditProfileHandleRow(
                            username: $editedUsername,
                            focusedField: $focusedIdentityField,
                            handleStatusMessage: handleStatusMessage,
                            handleStatusIsPositive: handleStatusIsPositive,
                            languageCode: appLanguageRaw
                        )
                        EditProfileRowDivider()
                        EditProfileBioRow(
                            bio: $editedBio,
                            focusedField: $focusedIdentityField,
                            characterLimit: Self.bioCharacterLimit,
                            languageCode: appLanguageRaw,
                            onAddEmoji: {
                                FGInteractionHaptics.selection()
                                showBioEmojiPicker = true
                            }
                        )
                    }

                    EditProfileSection(title: L10n.t("location", languageCode: appLanguageRaw)) {
                        EditProfileHomeCityRow(
                            city: $editedHomeCity,
                            region: $editedHomeRegion,
                            country: $editedHomeCountry,
                            displayText: $editedHomeCityDisplay,
                            languageCode: appLanguageRaw
                        )
                        EditProfileRowDivider()
                        EditProfileShowOnProfileRow(
                            isOn: $editedShowHomeCity,
                            isDisabled: editedHomeCityDisplay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            languageCode: appLanguageRaw
                        )
                    }

                    EditProfileSection(title: L10n.t("appearance", languageCode: appLanguageRaw)) {
                        EditProfileBackgroundRow(
                            backgroundKey: editedProfileBackgroundKey,
                            languageCode: appLanguageRaw,
                            onTap: {
                                FGInteractionHaptics.selection()
                                showProfileBackgroundPicker = true
                            }
                        )
                    }

                    EditProfileSection(title: L10n.t("account", languageCode: appLanguageRaw)) {
                        EditProfileAccountRow(
                            email: viewModel.currentUserEmail,
                            languageCode: appLanguageRaw
                        )
                    }

                    if !identityMessage.isEmpty {
                        Text(identityMessage)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(
                                identityMessage.contains("updated") || identityMessage == "Saved."
                                    ? FGColor.accentGreen
                                    : FGColor.dangerRed
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(L10n.t("Profile", languageCode: appLanguageRaw))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("close", languageCode: appLanguageRaw)) {
                        showIdentityEditor = false
                    }
                    .disabled(isSavingIdentity || isUploadingAvatar)
                    .accessibilityLabel("Close profile editor")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSavingIdentity ? L10n.t("Saving...", languageCode: appLanguageRaw) : L10n.t("done", languageCode: appLanguageRaw)) {
#if DEBUG
                        print("[FanProfileSave] tap")
                        print("[FanProfileSave] handleState=\(fanProfileSaveHandleStateDebug)")
                        print("[FanProfileSave] profileLoaded=\(viewModel.hasLoadedUserProfileForPresentation) profileLoading=\(viewModel.isUserProfileLoadingForPresentation)")
#endif
                        Task { await saveIdentity() }
                    }
                    // Presentation-load flags are enforced inside `saveIdentity` with a visible message.
                    // Disabling Done on those flags made taps silently no-op when hydration raced.
                    .disabled(isSavingIdentity || isUploadingAvatar || !identityDraftLooksDirty)
                    .accessibilityLabel("Save profile changes")
                }
            }
            .onAppear {
                if viewModel.hasLoadedUserProfileForPresentation,
                   !viewModel.isUserProfileLoadingForPresentation {
                    resetIdentityDraft()
                }
            }
            .sheet(isPresented: $showBioEmojiPicker) {
                ProfileBioEmojiPickerSheet(languageCode: appLanguageRaw) { emoji in
                    insertBioEmoji(emoji)
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showProfileBackgroundPicker) {
                ProfileBackgroundPickerSheet(
                    selection: $editedProfileBackgroundKey,
                    languageCode: appLanguageRaw,
                    onDismiss: {}
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private func insertBioEmoji(_ emoji: String) {
        var draft = FanProfileDefaults.displayBio(editedBio, languageCode: appLanguageRaw)
        let inserted = ProfileBioEmojiInsertion.append(
            emoji: emoji,
            to: &draft,
            limit: Self.bioCharacterLimit
        )
        if inserted {
            editedBio = FanProfileDefaults.bioForStorage(limitedBio(draft))
            focusedIdentityField = .bio
        } else {
            FGInteractionHaptics.softImpact()
        }
    }

    private func presentShareOwnProfile() {
        guard let uid = viewModel.currentUserAuthId else {
            ownShareProfileError = L10n.t("share_profile_unavailable", languageCode: appLanguageRaw)
            showShareOwnProfileSheet = true
            return
        }
        guard !isLoadingOwnShareProfile else { return }
        isLoadingOwnShareProfile = true
        ownShareProfileError = nil
        Task {
            let loaded = await PublicUserProfileService.load(userId: uid, isSelfPreview: true)
            await MainActor.run {
                isLoadingOwnShareProfile = false
                ownShareProfile = loaded
                if !(loaded.isPubliclyVisible && loaded.isDiscoverableByFans) {
                    ownShareProfileError = L10n.t("share_profile_unavailable", languageCode: appLanguageRaw)
                }
                showShareOwnProfileSheet = true
            }
        }
    }

    private func presentIdentityEditor(focusedField: EditProfileFocusField) {
        if viewModel.hasLoadedUserProfileForPresentation, !viewModel.isUserProfileLoadingForPresentation {
            resetIdentityDraft()
            showIdentityEditor = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.focusedIdentityField = focusedField
            }
            return
        }

        Task {
            await viewModel.recoverUserProfilePresentationForAccountTabIfNeeded()
            await MainActor.run {
                guard viewModel.hasLoadedUserProfileForPresentation,
                      !viewModel.isUserProfileLoadingForPresentation else { return }
                resetIdentityDraft()
                showIdentityEditor = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.focusedIdentityField = focusedField
                }
            }
        }
    }

    private func resetIdentityDraft() {
        editedDisplayName = displayName
        editedUsername = viewModel.currentUserUsername
        editedBio = limitedBio(viewModel.currentUserBio)
        editedHomeCity = viewModel.currentUserHomeCity
        editedHomeRegion = viewModel.currentUserHomeRegion
        editedHomeCountry = viewModel.currentUserHomeCountry
        editedHomeCityDisplay = ProfileHomeCityIdentity.displayLine(
            city: viewModel.currentUserHomeCity,
            region: viewModel.currentUserHomeRegion,
            country: viewModel.currentUserHomeCountry,
            languageCode: appLanguageRaw
        ) ?? viewModel.currentUserHomeCity
        editedShowHomeCity = viewModel.currentUserShowHomeCity
        editedProfileBackgroundKey = viewModel.currentUserProfileBackgroundKey
        handleStatusMessage = ""
        handleStatusIsPositive = false
    }

    /// True when editor drafts differ from the currently hydrated profile (user has typed something).
    private var identityDraftLooksDirty: Bool {
        let nameDirty = editedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            != displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let handleDirty = FanGeoHandleRules.normalizeForStorage(editedUsername)
            != FanGeoHandleRules.normalizeForStorage(viewModel.currentUserUsername)
        let bioDirty = limitedBio(editedBio) != limitedBio(viewModel.currentUserBio)
        let cityDirty = editedHomeCity.trimmingCharacters(in: .whitespacesAndNewlines)
            != viewModel.currentUserHomeCity.trimmingCharacters(in: .whitespacesAndNewlines)
            || editedHomeRegion.trimmingCharacters(in: .whitespacesAndNewlines)
            != viewModel.currentUserHomeRegion.trimmingCharacters(in: .whitespacesAndNewlines)
            || editedHomeCountry.trimmingCharacters(in: .whitespacesAndNewlines)
            != viewModel.currentUserHomeCountry.trimmingCharacters(in: .whitespacesAndNewlines)
            || editedHomeCityDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
            != (ProfileHomeCityIdentity.displayLine(
                city: viewModel.currentUserHomeCity,
                region: viewModel.currentUserHomeRegion,
                country: viewModel.currentUserHomeCountry,
                languageCode: appLanguageRaw
            ) ?? viewModel.currentUserHomeCity).trimmingCharacters(in: .whitespacesAndNewlines)
            || editedShowHomeCity != viewModel.currentUserShowHomeCity
        let backgroundDirty = editedProfileBackgroundKey != viewModel.currentUserProfileBackgroundKey
        return nameDirty || handleDirty || bioDirty || cityDirty || backgroundDirty
    }

#if DEBUG
    private var fanProfileSaveHandleStateDebug: String {
        let stored = FanGeoHandleRules.normalizeForStorage(viewModel.currentUserUsername)
        let edited = FanGeoHandleRules.normalizeForStorage(editedUsername)
        let status = handleStatusMessage.isEmpty ? "none" : handleStatusMessage.replacingOccurrences(of: " ", with: "_")
        return "stored=\(stored) edited=\(edited) unchanged=\(stored == edited) uiStatus=\(status) positive=\(handleStatusIsPositive)"
    }
#endif

    private func limitedBio(_ raw: String) -> String {
        String(raw.prefix(Self.bioCharacterLimit))
    }

    private func profilePhotoPickFailureHint() -> String {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .denied, .restricted:
            return "Photo access is off. Turn it on in Settings > Privacy & Security > Photos to upload a profile picture."
        case .limited:
            return "Couldn’t use that photo. Try another image, or allow more photos for FanGeo in Settings."
        default:
            return "Unable to read that photo. Try a different image or check your connection."
        }
    }

    private func scheduleHandleAvailabilityCheck() {
        availabilityTask?.cancel()
        handleStatusMessage = ""
        handleStatusIsPositive = false

        let raw = editedUsername
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        let stored = FanGeoHandleRules.normalizeForStorage(raw)
        let currentStored = FanGeoHandleRules.normalizeForStorage(viewModel.currentUserUsername)
        print("[HandleValidationDebug] normalizedHandle=\(stored)")
        if stored == currentStored {
#if DEBUG
            print("[FanProfileValidation] handleAvailabilityState=skippedUnchangedOwnHandle")
#endif
            return
        }
        if let editError = FanIdentityValidation.validateHandleForEdit(
            raw,
            original: viewModel.currentUserUsername
        ) {
            if FanGeoHandleRules.validateFormat(raw) != nil {
                handleStatusMessage = "Invalid handle: \(editError)"
            } else {
                handleStatusMessage = editError
            }
            print("[HandleValidationDebug] handleRejected reason=editValidation")
            return
        }

        handleStatusMessage = "Checking availability..."
        availabilityTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            print("[HandleValidationDebug] availabilityCheck=\(stored)")
            guard let available = await viewModel.checkUsernameAvailable(raw) else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                print("[HandleValidationDebug] handleAvailable=\(available)")
                if available {
                    handleStatusMessage = "Available"
                    handleStatusIsPositive = true
                } else {
                    handleStatusMessage = "Already taken"
                    handleStatusIsPositive = false
                    print("[HandleValidationDebug] handleRejected reason=already_taken")
                }
            }
        }
    }

    private func saveIdentity() async {
        guard viewModel.isLoggedIn else {
#if DEBUG
            print("[FanProfileSave] validationPassed=false reason=notSignedIn")
#endif
            await MainActor.run {
                identityMessage = "Please sign in to edit your profile."
                viewModel.showSocialActionToast("Please sign in to edit your profile.", isError: true)
            }
            return
        }
        guard viewModel.hasLoadedUserProfileForPresentation,
              !viewModel.isUserProfileLoadingForPresentation else {
#if DEBUG
            print("[FanProfileSave] validationPassed=false reason=profileStillLoading loaded=\(viewModel.hasLoadedUserProfileForPresentation) loading=\(viewModel.isUserProfileLoadingForPresentation)")
#endif
            await MainActor.run {
                identityMessage = "Your profile is still loading. Please try again in a moment."
                viewModel.showSocialActionToast("Your profile is still loading. Please try again in a moment.", isError: true)
            }
            return
        }

        await MainActor.run { isSavingIdentity = true }
        defer { Task { @MainActor in isSavingIdentity = false } }

        let originalDisplayName = viewModel.currentUserDisplayName
        let trimmed = editedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextName = trimmed.isEmpty ? displayName : trimmed
        let normalizedOriginalDisplayName = ReservedNameValidation.normalizeForComparison(originalDisplayName)
        let normalizedDraftDisplayName = ReservedNameValidation.normalizeForComparison(nextName)
        let displayNameChanged = normalizedOriginalDisplayName != normalizedDraftDisplayName

        let originalHandle = viewModel.currentUserUsername
        let normalizedOriginalHandle = FanGeoHandleRules.normalizeForStorage(originalHandle)
        let normalizedDraftHandle = FanGeoHandleRules.normalizeForStorage(editedUsername)
        let handleChanged = normalizedOriginalHandle != normalizedDraftHandle

        let displayNameReservedError = FanIdentityValidation.validateDisplayNameForEdit(
            nextName,
            original: originalDisplayName
        )
        let handleReservedOrFormatError = handleChanged
            ? FanIdentityValidation.validateHandleForEdit(editedUsername, original: originalHandle)
            : nil

#if DEBUG
        print("[FanProfileValidation] originalDisplayName=\(originalDisplayName)")
        print("[FanProfileValidation] draftDisplayName=\(nextName)")
        print("[FanProfileValidation] normalizedOriginalDisplayName=\(normalizedOriginalDisplayName)")
        print("[FanProfileValidation] normalizedDraftDisplayName=\(normalizedDraftDisplayName)")
        print("[FanProfileValidation] displayNameChanged=\(displayNameChanged)")
        print("[FanProfileValidation] originalHandle=\(originalHandle)")
        print("[FanProfileValidation] draftHandle=\(editedUsername)")
        print("[FanProfileValidation] normalizedOriginalHandle=\(normalizedOriginalHandle)")
        print("[FanProfileValidation] normalizedDraftHandle=\(normalizedDraftHandle)")
        print("[FanProfileValidation] handleChanged=\(handleChanged)")
        print("[FanProfileValidation] reservedDisplayNameResult=\(displayNameReservedError != nil)")
        print("[FanProfileValidation] reservedHandleResult=\(handleReservedOrFormatError == ReservedNameValidation.rejectionMessage)")
#endif

        if ModerationService.containsProfanity(nextName) {
#if DEBUG
            print("[FanProfileSave] validationPassed=false reason=profanity")
            print("[FanProfileValidation] saveAllowed=false")
#endif
            await MainActor.run {
                localAvatarPreviewImage = nil
                identityMessage = ModerationService.profanityRejectionUserMessage()
                viewModel.showSocialActionToast(ModerationService.profanityRejectionUserMessage(), isError: true)
            }
            return
        }
        if let displayNameReservedError {
#if DEBUG
            print("[FanProfileSave] validationPassed=false reason=reservedName")
            print("[FanProfileValidation] saveAllowed=false")
#endif
            await MainActor.run {
                localAvatarPreviewImage = nil
                identityMessage = displayNameReservedError
                viewModel.showSocialActionToast(displayNameReservedError, isError: true)
            }
            return
        }
        if let handleReservedOrFormatError {
#if DEBUG
            print("[FanProfileSave] validationPassed=false reason=handleInvalid")
            print("[FanProfileSave] handleState=\(fanProfileSaveHandleStateDebug)")
            print("[FanProfileValidation] handleAvailabilityState=skipped_invalid")
            print("[FanProfileValidation] saveAllowed=false")
#endif
            await MainActor.run {
                identityMessage = handleReservedOrFormatError
                viewModel.showSocialActionToast(handleReservedOrFormatError, isError: true)
            }
            print("[HandleValidationDebug] handleRejected reason=editValidation")
            return
        }

#if DEBUG
        print("[FanProfileValidation] handleAvailabilityState=\(handleChanged ? "deferredToSaveUserProfile" : "skippedUnchangedOwnHandle")")
        print("[FanProfileValidation] saveAllowed=true")
        print("[FanProfileSave] validationPassed=true")
        print("[FanProfileSave] handleState=\(fanProfileSaveHandleStateDebug)")
        let nextBioPreview = limitedBio(editedBio)
        print("[FanProfileSave] payload=displayNameLen=\(nextName.count) username=\(normalizedDraftHandle) bioLen=\(nextBioPreview.count) homeCity=\(editedHomeCity) region=\(editedHomeRegion) country=\(editedHomeCountry) showHomeCity=\(editedShowHomeCity)")
        print("[FanProfileSave] requestStarted")
#endif

        let nextBio = FanProfileDefaults.bioForStorage(limitedBio(editedBio))
        if let err = await viewModel.saveUserProfile(
            displayName: nextName,
            avatarURL: viewModel.currentUserAvatarURL,
            avatarThumbnailURL: viewModel.currentUserAvatarThumbnailURL,
            username: editedUsername,
            bio: nextBio
        ) {
#if DEBUG
            print("[FanProfileSave] requestFailed=\(err)")
            print("[FanProfileSave] dismissed=false")
            print("[FanProfileSave] profileRefreshed=false")
#endif
            await MainActor.run {
                identityMessage = err
                viewModel.showSocialActionToast(err, isError: true)
            }
            return
        }

#if DEBUG
        print("[FanProfileSave] requestSucceeded identity")
#endif

        if let err = await viewModel.saveUserProfileHomeCity(
            city: editedHomeCity,
            region: editedHomeRegion,
            country: editedHomeCountry,
            displayFallback: editedHomeCityDisplay,
            showOnProfile: editedShowHomeCity
        ) {
#if DEBUG
            print("[FanProfileSave] requestFailed=\(err)")
            print("[FanProfileSave] dismissed=false")
            print("[FanProfileSave] profileRefreshed=partial_identity_saved")
#endif
            await MainActor.run {
                identityMessage = err
                viewModel.showSocialActionToast(err, isError: true)
            }
            return
        }

#if DEBUG
        print("[FanProfileSave] requestSucceeded homeCity")
#endif

        if let err = await viewModel.saveUserProfileBackgroundKey(editedProfileBackgroundKey) {
#if DEBUG
            print("[FanProfileSave] requestFailed=\(err)")
            print("[FanProfileSave] dismissed=false")
            print("[FanProfileSave] profileRefreshed=partial_identity_home_city_saved")
#endif
            await MainActor.run {
                identityMessage = err
                viewModel.showSocialActionToast(err, isError: true)
            }
            return
        }

#if DEBUG
        print("[FanProfileSave] requestSucceeded profileBackground")
#endif

        await MainActor.run {
            identityMessage = ""
            showIdentityEditor = false
            viewModel.showSocialActionToast("Saved.", isError: false)
#if DEBUG
            print("[FanProfileSave] dismissed=true")
            print("[FanProfileSave] profileRefreshed=true")
#endif
        }
    }

    private func replaceAvatar(with item: PhotosPickerItem) async {
        guard viewModel.isLoggedIn else {
            await MainActor.run {
                viewModel.showSocialActionToast("Please sign in to update your avatar.", isError: true)
            }
            return
        }

        await MainActor.run {
            isUploadingAvatar = true
        }
        defer { Task { @MainActor in isUploadingAvatar = false } }

        guard let data = try? await item.loadTransferable(type: Data.self) else {
            await MainActor.run {
                viewModel.showSocialActionToast(profilePhotoPickFailureHint(), isError: true)
            }
            return
        }
        let previewImage = UIImage(data: data)
        await MainActor.run {
            localAvatarPreviewImage = previewImage
        }
        guard let urls = await viewModel.uploadUserAvatar(data: data, fileName: "avatar.jpg") else {
            await MainActor.run {
                localAvatarPreviewImage = nil
                viewModel.showSocialActionToast("Unable to upload avatar.", isError: true)
            }
            return
        }

        if let err = await viewModel.persistUserProfileAvatar(
            fullURL: urls.fullURL,
            thumbnailURL: urls.thumbnailURL,
            replacedFullURL: urls.replacedFullURL,
            replacedThumbnailURL: urls.replacedThumbnailURL
        ) {
            await MainActor.run {
                localAvatarPreviewImage = nil
                viewModel.showSocialActionToast(err, isError: true)
            }
            return
        }
        if let previewImage {
            let refreshToken = await MainActor.run { viewModel.currentUserAvatarDisplayRefreshToken }
            let cacheURLs = ImageDisplayURL.displayURLs(
                thumbnail: urls.thumbnailURL,
                full: urls.fullURL,
                refreshToken: refreshToken
            )
            await DiscoverMapImageCache.shared.store(previewImage, for: cacheURLs)
        }
        await MainActor.run {
            localAvatarPreviewImage = nil
            viewModel.showSocialActionToast("Avatar updated.", isError: false)
        }
    }

    // MARK: - Home Crowd

    private var homeCrowdSection: some View {
        HomeCrowdProfileCardView(
            summary: viewModel.currentUserHomeCrowdVenue,
            isSelfProfile: true,
            onExploreVenue: viewModel.currentUserHomeCrowdVenue != nil
                ? { viewModel.focusDiscoverOnHomeCrowdVenue() }
                : nil,
            onChangeHomeCrowd: viewModel.currentUserHomeCrowdVenue != nil
                ? { viewModel.focusDiscoverOnHomeCrowdVenue() }
                : nil,
            onChooseHomeCrowd: viewModel.currentUserHomeCrowdVenue == nil
                ? { viewModel.openDiscoverToChooseHomeCrowd() }
                : nil
        )
    }

    // MARK: - Open To preview

    private var openToPreviewSection: some View {
        let prefs = viewModel.currentUserFanIdentityPreferences
        let previewItems = FanOpenToCatalog.publicDisplayItems(from: prefs.resolvedOpenToItemIDs)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("open_to", languageCode: appLanguageRaw))
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(FGColor.accentBlue)
                        .textCase(.uppercase)
                        .tracking(0.78)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(
                        previewItems.isEmpty
                            ? L10n.t("Tell fans what you're up for", languageCode: appLanguageRaw)
                            : L10n.t("What you're open to", languageCode: appLanguageRaw)
                    )
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme).opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    showFanIdentityEditor = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9, weight: .bold))
                        Text("Edit Open To")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(FGColor.accentBlue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background {
                        Capsule()
                            .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.14 : 0.10))
                    }
                }
                .buttonStyle(.plain)
            }

            if previewItems.isEmpty {
                SelfProfileOpenToPreviewGrid(items: []) {
                    quickRemoveOpenToItem($0)
                } onAdd: {
                    showFanIdentityEditor = true
                }
            } else {
                SelfProfileOpenToPreviewGrid(items: previewItems) { item in
                    quickRemoveOpenToItem(item)
                } onAdd: {
                    showFanIdentityEditor = true
                }
            }
        }
    }

    private func quickRemoveOpenToItem(_ item: PublicProfileOpenToItem) {
        print("[FanIdentityOpenTo] quickRemove item=\(item.id)")

        let previous = viewModel.currentUserFanIdentityPreferences
        var next = previous
        let previousIDs = next.resolvedOpenToItemIDs
        let nextIDs = previousIDs.filter { $0 != item.id }
        guard nextIDs.count != previousIDs.count else { return }

        next.openToItems = nextIDs
        next.markOpenToSaved()

        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            viewModel.currentUserFanIdentityPreferences = next
        }

        Task {
            if let err = await viewModel.saveFanIdentityPreferences(next) {
                print("[FanIdentityOpenTo] quickRemoveRollback item=\(item.id)")
                await MainActor.run {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        viewModel.currentUserFanIdentityPreferences = previous
                    }
                    viewModel.showSocialActionToast(err, isError: true)
                }
                return
            }
            print("[FanIdentityOpenTo] quickRemoveSaved")
        }
    }

    private func openNationalTeamPicker() {
        showNationalTeamPicker = true
#if DEBUG
        print("[NationalTeamDebug] pickerOpened=true")
#endif
    }

    private func saveNationalTeamIdentity(_ identity: NationalTeamIdentity) async {
        if let err = await viewModel.saveNationalTeamIdentity(identity) {
            await MainActor.run {
                viewModel.showSocialActionToast(err, isError: true)
            }
        }
    }

    // MARK: - Favorite teams

    /// Carousel / empty-state only — header lives in `ProfileIdentityFavoriteTeamsSection`.
    @ViewBuilder
    private var favoriteTeamsCarouselOnly: some View {
        let teams = selectedTeams
        let primaryID = FavoriteTeamsStore.explicitPrimaryTeamID(primaryFavoriteTeamIDRaw, within: teams.map(\.id))
        if teams.isEmpty {
            addTeamSocialCard
                .frame(height: Self.favoriteTeamsCarouselHeight, alignment: .topLeading)
        } else {
            favoriteTeamsCardRow(teams: teams, primaryFavoriteTeamID: primaryID)
        }
    }

    private var favoriteTeamsSection: some View {
        let teams = selectedTeams
        let primaryID = FavoriteTeamsStore.explicitPrimaryTeamID(primaryFavoriteTeamIDRaw, within: teams.map(\.id))

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("favorite_teams", languageCode: appLanguageRaw))
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(FGColor.accentBlue)
                        .textCase(.uppercase)
                        .tracking(0.78)
                    Text(
                        teams.isEmpty
                            ? L10n.t("profile_shape_fan_identity", languageCode: appLanguageRaw)
                            : L10n.t("profile_show_off_fan_colors", languageCode: appLanguageRaw)
                    )
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme).opacity(0.82))
                }
                Spacer(minLength: 0)
                Button {
                    showFavoriteTeamsPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.system(size: 9, weight: .bold))
                        Text(teams.isEmpty ? "Add Teams" : L10n.t("Edit Teams", languageCode: appLanguageRaw))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(FGColor.accentBlue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background {
                        Capsule()
                            .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.14 : 0.10))
                    }
                }
                .buttonStyle(.plain)
            }

            if teams.isEmpty {
                addTeamSocialCard
                    .frame(height: Self.favoriteTeamsCarouselHeight, alignment: .topLeading)
            } else {
                favoriteTeamsCardRow(teams: teams, primaryFavoriteTeamID: primaryID)
            }
        }
        .padding(.bottom, Self.favoriteTeamsHomeCrowdBottomSpacing)
    }

    private func favoriteTeamsCardRow(teams: [FavoriteTeam], primaryFavoriteTeamID: String?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 10) {
                ForEach(teams) { team in
                    favoriteTeamSocialCard(
                        team: team,
                        primaryFavoriteTeamID: primaryFavoriteTeamID
                    )
                }

                addTeamSocialCard
            }
            .padding(.vertical, 1)
        }
        .frame(height: Self.favoriteTeamsCarouselHeight, alignment: .topLeading)
    }

    private func favoriteTeamSocialCard(
        team: FavoriteTeam,
        primaryFavoriteTeamID: String?
    ) -> some View {
        let isPrimary = team.id == primaryFavoriteTeamID
        let isAnimatingSelection = animatedTrophyTeamID == team.id
        let isAnimatingDemotion = demotedTrophyTeamID == team.id && !isPrimary

        return FavoriteTeamRichCard(
            team: team,
            isPrimary: isPrimary,
            style: .ownProfile,
            languageCode: appLanguageRaw,
            isAnimatingSelection: isAnimatingSelection,
            isAnimatingDemotion: isAnimatingDemotion
        ) {
            // Single My Team affordance: gold trophy + MY TEAM (selected) or white trophy (others).
            HStack(alignment: .top, spacing: 8) {
                trophyTeamButton(
                    team: team,
                    isPrimary: isPrimary,
                    isAnimatingSelection: isAnimatingSelection
                )
                removeFavoriteTeamButton(team: team)
            }
        }
        .overlay {
            if isAnimatingSelection && !reduceMotion {
                trophySelectionShimmer(cornerRadius: FavoriteTeamRichCardStyle.ownProfile.cornerRadius)
            }
        }
        .animation(trophyVisualTransitionAnimation, value: isPrimary)
        .animation(trophyVisualTransitionAnimation, value: isAnimatingDemotion)
    }

    private func trophyTeamButton(
        team: FavoriteTeam,
        isPrimary: Bool,
        isAnimatingSelection: Bool
    ) -> some View {
        Button {
            guard !isPrimary else { return }
            promoteTrophyTeam(team)
        } label: {
            VStack(spacing: 2) {
                ZStack {
                    Image(systemName: "trophy")
                        .opacity(isPrimary ? 0 : 1)
                        .foregroundStyle(Color.white.opacity(0.92))
                    Image(systemName: "trophy.fill")
                        .opacity(isPrimary ? 1 : 0)
                        .foregroundStyle(FGColor.accentYellow)
                }
                .font(.system(size: 14, weight: .heavy))
                .frame(width: 30, height: 30)
                .background {
                    Circle()
                        .fill(isPrimary ? FGColor.accentYellow.opacity(0.18) : Color.black.opacity(0.18))
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    isPrimary ? FGColor.accentYellow.opacity(0.64) : Color.white.opacity(0.22),
                                    lineWidth: 1
                                )
                        }
                }
                .shadow(color: isPrimary ? FGColor.accentYellow.opacity(0.45) : .clear, radius: 8, y: 2)
                .scaleEffect(isAnimatingSelection && !reduceMotion ? 1.13 : 1.0)

                if isPrimary {
                    Text(L10n.t("my_team", languageCode: appLanguageRaw))
                        .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                        .textCase(.uppercase)
                        .tracking(0.2)
                        .foregroundStyle(FGColor.accentYellow)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(minWidth: 44, minHeight: 44, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPrimary)
        .animation(trophyVisualTransitionAnimation, value: isPrimary)
        .animation(trophyPulseAnimation, value: isAnimatingSelection)
        .accessibilityLabel(
            isPrimary
                ? MyTeamDisplayModel(team: team).accessibilityLabel(languageCode: appLanguageRaw)
                : "\(L10n.t("make_my_team", languageCode: appLanguageRaw)), \(team.name)"
        )
        .accessibilityHint(
            isPrimary
                ? L10n.t("my_team_only_one_hint", languageCode: appLanguageRaw)
                : L10n.t("make_my_team_hint", languageCode: appLanguageRaw)
        )
    }

    private func removeFavoriteTeamButton(team: FavoriteTeam) -> some View {
        Button {
            removeFavoriteTeam(team)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.88))
                .frame(width: 24, height: 24)
                .background {
                    Circle()
                        .fill(Color.black.opacity(0.22))
                        .overlay {
                            Circle()
                                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75)
                        }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(team.name) from favorite teams")
    }

    private func removeFavoriteTeam(_ team: FavoriteTeam) {
#if DEBUG
        print("[FavoriteTeamsProfile] remove tapped team_id=\(team.id)")
#endif
        let previousIDs = FavoriteTeamsStore.decodeIDs(from: favoriteTeamIDsRaw)
        let previousPrimary = primaryFavoriteTeamID
        let nextIDs = previousIDs.filter { $0 != team.id }
        guard nextIDs.count != previousIDs.count else { return }
        let nextPrimary = FavoriteTeamsStore.normalizedPrimaryTeamID(
            previousPrimary == team.id ? nil : previousPrimary,
            within: nextIDs
        )

        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            favoriteTeamIDsRaw = FavoriteTeamsStore.encodeIDs(nextIDs)
            primaryFavoriteTeamIDRaw = nextPrimary ?? ""
        }

        Task {
            let didSync = await viewModel.syncFavoriteTeamsToSupabase(teamIDs: nextIDs, primaryTeamID: nextPrimary)
            if didSync {
#if DEBUG
                print("[FavoriteTeamsProfile] remove success team_id=\(team.id)")
#endif
                return
            }

            await MainActor.run {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    favoriteTeamIDsRaw = FavoriteTeamsStore.encodeIDs(previousIDs)
                    primaryFavoriteTeamIDRaw = previousPrimary ?? ""
                }
            }
#if DEBUG
            print("[FavoriteTeamsProfile] remove failed team_id=\(team.id) error=sync_failed")
#endif
        }
    }

    private func promoteTrophyTeam(_ team: FavoriteTeam) {
        let ids = FavoriteTeamsStore.decodeIDs(from: favoriteTeamIDsRaw)
        guard ids.contains(team.id) else { return }
        let previousPrimary = primaryFavoriteTeamID
        guard previousPrimary != team.id else { return }

#if DEBUG
        print("[FavoriteTeamsDebug] trophyTeamSelected teamId=\(team.id)")
        print("[FavoriteTeamsDebug] previousTrophyTeamCleared=\(previousPrimary != nil)")
#endif

        startTrophySelectionAnimation(teamID: team.id, previousPrimaryID: previousPrimary)

        withAnimation(trophyVisualTransitionAnimation) {
            primaryFavoriteTeamIDRaw = team.id
        }

        Task {
            let didSync = await viewModel.syncFavoriteTeamsToSupabase(teamIDs: ids, primaryTeamID: team.id)
            guard !didSync else { return }
            await MainActor.run {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    primaryFavoriteTeamIDRaw = previousPrimary ?? ""
                }
            }
        }
    }

    private var trophyVisualTransitionAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.24)
            : .spring(response: 0.34, dampingFraction: 0.82)
    }

    private var trophyPulseAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.20)
            : .spring(response: 0.26, dampingFraction: 0.58)
    }

    private func startTrophySelectionAnimation(teamID: String, previousPrimaryID: String?) {
        trophyAnimationTask?.cancel()
        trophyShimmerProgress = -0.6

#if DEBUG
        print("[FavoriteTeamsDebug] trophyAnimationStarted teamId=\(teamID)")
        if previousPrimaryID != nil {
            print("[FavoriteTeamsDebug] previousTrophyDemotedAnimated=true")
        }
#endif

        withAnimation(trophyPulseAnimation) {
            animatedTrophyTeamID = teamID
            demotedTrophyTeamID = previousPrimaryID
        }

        if !reduceMotion {
            withAnimation(.easeInOut(duration: 0.42)) {
                trophyShimmerProgress = 1.35
            }
        }

        let durationSeconds = reduceMotion ? 0.28 : 0.46
        trophyAnimationTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(durationSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }

            await MainActor.run {
                withAnimation(trophyVisualTransitionAnimation) {
                    animatedTrophyTeamID = nil
                    demotedTrophyTeamID = nil
                }
                trophyShimmerProgress = -0.6
                trophyAnimationTask = nil
#if DEBUG
                print("[FavoriteTeamsDebug] trophyAnimationCompleted teamId=\(teamID)")
#endif
            }
        }
    }

    private func trophySelectionShimmer(cornerRadius: CGFloat) -> some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let shimmerWidth = max(width * 0.36, 46)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.0),
                            FGColor.accentYellow.opacity(0.18),
                            Color.white.opacity(0.24),
                            Color.white.opacity(0.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: shimmerWidth, height: proxy.size.height * 1.45)
                .rotationEffect(.degrees(14))
                .offset(
                    x: -width + trophyShimmerProgress * (width + shimmerWidth),
                    y: -proxy.size.height * 0.18
                )
                .blendMode(.screen)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var addTeamSocialCard: some View {
        let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
        let title = L10n.t("Add a Team", languageCode: languageCode)
        let subtitle = L10n.t("Add a favorite team", languageCode: languageCode)
        let cardWidth = FavoriteTeamRichCardStyle.ownProfile.width

        return Button {
            showFavoriteTeamsPicker = true
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.16 : 0.11))
                        .frame(width: 58, height: 58)
                    Image(systemName: "plus")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(FGColor.accentBlue)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    Text(subtitle)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(width: cardWidth, alignment: .topLeading)
            .frame(minHeight: Self.favoriteTeamCardHeight, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.045 : 0.9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        FGColor.accentBlue.opacity(colorScheme == .dark ? 0.22 : 0.16),
                                        Color.black.opacity(colorScheme == .dark ? 0.0 : 0.05)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(subtitle)")
    }
}

private final class SponsoredPlacementService {
    private let client: SupabaseClient

    init(client: SupabaseClient = supabase) {
        self.client = client
    }

    func fetchProfileRecommendedPlacements(
        country: String?,
        state: String?,
        city: String?,
        sport: String?,
        userLocation: CLLocationCoordinate2D?
    ) async throws -> [SponsoredProfileVenueRecommendation] {
        SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] queryExecuting=true rpc=get_active_sponsored_placement table=public.sponsored_placements placementKey=profile_recommended_near_you country=\(normalizedTarget(country) ?? "nil") state=\(normalizedTarget(state) ?? "nil") city=\(normalizedTarget(city) ?? "nil") sport=\(normalizedTarget(sport) ?? "nil")")
        let rows: [SponsoredPlacementRPCRow] = try await client
            .rpc(
                "get_active_sponsored_placement",
                params: SponsoredPlacementRPCParams(
                    p_placement_key: "profile_recommended_near_you",
                    p_country: normalizedTarget(country),
                    p_state: normalizedTarget(state),
                    p_city: normalizedTarget(city),
                    p_sport: normalizedTarget(sport)
                )
            )
            .execute()
            .value

        SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] activePlacementsFetched=\(rows.count)")
        SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] currentTime=\(Self.debugDateFormatter.string(from: Date()))")
        for row in rows {
            SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] placementId=\(row.id.uuidString.lowercased())")
            SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] venueId=\(row.venue_id.uuidString.lowercased()) venueName=\(row.venue_name ?? "nil")")
            SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] starts_at=\(row.starts_at ?? "nil") ends_at=\(row.ends_at ?? "nil")")
            print("[SponsoredPlacementRotation] placementId=\(row.id.uuidString.lowercased()) venueName=\(row.venue_name ?? "nil") priority_weight=\(row.resolvedPriorityWeight)")
        }

        let recommendations = rows.compactMap { $0.recommendation(userLocation: userLocation) }
        if recommendations.isEmpty {
            SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] exclusionReason=\(rows.isEmpty ? "rpcReturnedNoRows" : "invalidPlacementVenuePayload")")
        }
        return recommendations
    }

    static func distanceLine(from userLocation: CLLocationCoordinate2D?, to venue: BarVenue) -> String {
        guard let userLocation,
              CLLocationCoordinate2DIsValid(userLocation),
              CLLocationCoordinate2DIsValid(venue.coordinate),
              abs(venue.coordinate.latitude) > 0.0001 || abs(venue.coordinate.longitude) > 0.0001 else {
            let distance = venue.distance.trimmingCharacters(in: .whitespacesAndNewlines)
            return distance.isEmpty ? "Near you" : distance
        }

        let origin = CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
        let destination = CLLocation(latitude: venue.coordinate.latitude, longitude: venue.coordinate.longitude)
        let miles = origin.distance(from: destination) / 1609.344
        if miles < 0.1 { return "Nearby" }
        if miles < 10 { return String(format: "%.1f mi", miles) }
        return "\(Int(miles.rounded())) mi"
    }

    static func parseSupabaseTimestamp(_ raw: String?) -> Date? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }

    private static let debugDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func normalizedTarget(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct SponsoredPlacementRPCParams: Encodable {
    let p_placement_key: String
    let p_country: String?
    let p_state: String?
    let p_city: String?
    let p_sport: String?
}

private struct SponsoredPlacementRPCRow: Decodable {
    let id: UUID
    let venue_id: UUID
    let business_id: UUID?
    let title: String
    let subtitle: String?
    let image_url: String?
    let cta_label: String?
    let starts_at: String?
    let ends_at: String?
    let target_lat: Double?
    let target_lng: Double?
    let target_radius_miles: Double?
    let venue_name: String?
    let address: String?
    let city: String?
    let state: String?
    let country: String?
    let phone: String?
    let primary_sport: String?
    let latitude: Double?
    let longitude: Double?
    let cover_photo_url: String?
    let cover_photo_thumbnail_url: String?
    let menu_photo_url: String?
    let menu_photo_thumbnail_url: String?
    let sport_tags: [String]?
    let fans_going_count: Int?
    let priority_weight: SponsoredPlacementPriorityWeight?

    var resolvedPriorityWeight: Int {
        let weight = priority_weight?.value ?? 1
        return weight > 0 ? weight : 1
    }

    func recommendation(userLocation: CLLocationCoordinate2D?) -> SponsoredProfileVenueRecommendation? {
        let venueName = trimmed(venue_name)
        let placementTitle = trimmed(title)
        guard !venueName.isEmpty || !placementTitle.isEmpty else {
            SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] exclusionReason=missingVenue placementId=\(id.uuidString.lowercased()) venueId=\(venue_id.uuidString.lowercased())")
            return nil
        }

        let sport = trimmed(primary_sport)
        let resolvedSport = sport.isEmpty ? "Sports" : sport
        let coordinate = CLLocationCoordinate2D(latitude: latitude ?? 0, longitude: longitude ?? 0)
        if !CLLocationCoordinate2DIsValid(coordinate) || (abs(coordinate.latitude) <= 0.0001 && abs(coordinate.longitude) <= 0.0001) {
            SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] exclusionReason=missingVenueLocation placementId=\(id.uuidString.lowercased()) venueId=\(venue_id.uuidString.lowercased()) venueName=\(venueName.isEmpty ? placementTitle : venueName)")
        }
        let subtitleLine = trimmed(subtitle)
        let bar = BarVenue(
            id: venue_id,
            name: venueName.isEmpty ? placementTitle : venueName,
            address: trimmed(address),
            phone: trimmed(phone),
            primarySport: resolvedSport,
            distance: locationFallback,
            rating: 0,
            tags: [],
            games: subtitleLine.isEmpty ? [] : [subtitleLine],
            coordinate: coordinate,
            goingCounts: [:],
            coverPhotoURL: cover_photo_url,
            menuPhotoURL: menu_photo_url,
            coverPhotoThumbnailURL: cover_photo_thumbnail_url,
            menuPhotoThumbnailURL: menu_photo_thumbnail_url,
            ownerEmail: nil,
            businessId: business_id,
            adminStatus: "active",
            sportTags: sport_tags ?? []
        )

        let count = max(fans_going_count ?? 0, 0)
        let fansText = count > 0 ? "\(count) fans going" : "Fans going tonight"
        let placementImage = trimmed(image_url)
        return SponsoredProfileVenueRecommendation(
            placementID: id,
            title: placementTitle.isEmpty ? bar.name : placementTitle,
            venue: bar,
            gameLine: subtitleLine.isEmpty ? "\(resolvedSport) tonight" : subtitleLine,
            distanceLine: SponsoredPlacementService.distanceLine(from: userLocation, to: bar),
            fansGoingText: fansText,
            ctaLabel: trimmed(cta_label).isEmpty ? "View Venue" : trimmed(cta_label),
            imageURLString: placementImage.isEmpty ? nil : placementImage,
            isSponsored: true,
            startsAtRaw: starts_at,
            endsAtRaw: ends_at,
            targetLatitude: target_lat,
            targetLongitude: target_lng,
            targetRadiusMiles: target_radius_miles,
            priorityWeight: resolvedPriorityWeight
        )
    }

    private var locationFallback: String {
        let city = trimmed(city)
        let state = trimmed(state)
        if !city.isEmpty && !state.isEmpty { return "\(city), \(state)" }
        if !city.isEmpty { return city }
        if !state.isEmpty { return state }
        return "Near you"
    }

    private func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private struct SponsoredPlacementPriorityWeight: Decodable {
    let value: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let doubleValue = try? container.decode(Double.self), doubleValue.isFinite {
            value = Int(doubleValue)
        } else if let stringValue = try? container.decode(String.self) {
            value = Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            value = nil
        }
    }
}

private enum SponsoredProfileSlotContent: Identifiable {
    case venue(SponsoredProfileVenueRecommendation)
    case fallback(SponsoredProfileFallbackPromotion)

    var id: String { stableIdentity }

    var stableIdentity: String {
        switch self {
        case .venue(let recommendation):
            return recommendation.stableIdentity
        case .fallback(let promotion):
            return promotion.stableIdentity
        }
    }
}

private struct SponsoredProfileVenueRecommendation: Identifiable {
    let placementID: UUID
    let title: String
    let venue: BarVenue
    let gameLine: String
    let distanceLine: String
    let fansGoingText: String
    let ctaLabel: String
    let imageURLString: String?
    let isSponsored: Bool
    let startsAtRaw: String?
    let endsAtRaw: String?
    let targetLatitude: Double?
    let targetLongitude: Double?
    let targetRadiusMiles: Double?
    let priorityWeight: Int

    var id: UUID { placementID }
    var sourceDebugLabel: String { isSponsored ? "sponsored" : "organic" }
    var stableIdentity: String {
        "\(sourceDebugLabel).\(placementID.uuidString.lowercased()).\(venue.id.uuidString.lowercased())"
    }
    var sportChipLabels: [String] {
        var labels: [String] = []
        let candidates = [venue.primarySport] + venue.sportTags
        for raw in candidates {
            let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty,
                  !labels.contains(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) else {
                continue
            }
            labels.append(label)
            if labels.count == 3 { break }
        }
        return labels
    }

    var imageURL: URL? {
        let placementImage = imageURLString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let raw = placementImage.isEmpty
            ? ImageDisplayURL.forList(
            thumbnail: venue.coverPhotoThumbnailURL,
            full: venue.coverPhotoURL
        )
            : placementImage
        guard let raw, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    static func hasValidLocation(_ location: CLLocationCoordinate2D?) -> Bool {
        guard let location,
              CLLocationCoordinate2DIsValid(location),
              abs(location.latitude) > 0.0001 || abs(location.longitude) > 0.0001 else {
            return false
        }
        return true
    }

    func isEligibleActiveRegionalSponsor(
        for userLocation: CLLocationCoordinate2D?,
        now: Date
    ) -> Bool {
        regionalEligibility(for: userLocation, now: now).isEligible
    }

    func regionalEligibility(
        for userLocation: CLLocationCoordinate2D?,
        now: Date
    ) -> SponsoredPlacementRegionalEligibility {
        guard isSponsored,
              let userLocation,
              Self.hasValidLocation(userLocation),
              let targetLatitude,
              let targetLongitude,
              let targetRadiusMiles,
              targetRadiusMiles > 0 else {
            if !isSponsored {
                return .blocked(reason: "notSponsoredPlacement")
            }
            if !Self.hasValidLocation(userLocation) {
                return .blocked(reason: "missingUserDeviceLocation")
            }
            if targetLatitude == nil || targetLongitude == nil {
                return .blocked(reason: "missingCampaignCenter")
            }
            return .blocked(reason: "missingCampaignRadius")
        }
        guard let startsAt = SponsoredPlacementService.parseSupabaseTimestamp(startsAtRaw),
              let endsAt = SponsoredPlacementService.parseSupabaseTimestamp(endsAtRaw),
              startsAt <= now,
              endsAt >= now else {
            return .blocked(reason: "outsideActiveDateWindow")
        }

        let campaignCenter = CLLocationCoordinate2D(latitude: targetLatitude, longitude: targetLongitude)
        guard CLLocationCoordinate2DIsValid(campaignCenter) else {
            return .blocked(reason: "invalidCampaignCenter")
        }
        let origin = CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
        let center = CLLocation(latitude: campaignCenter.latitude, longitude: campaignCenter.longitude)
        let miles = origin.distance(from: center) / 1609.344
        return miles <= targetRadiusMiles
            ? .eligible(distanceMiles: miles)
            : .blocked(reason: "outsideCampaignRadius", distanceMiles: miles)
    }

    func withDistanceLine(_ distanceLine: String) -> SponsoredProfileVenueRecommendation {
        SponsoredProfileVenueRecommendation(
            placementID: placementID,
            title: title,
            venue: venue,
            gameLine: gameLine,
            distanceLine: distanceLine,
            fansGoingText: fansGoingText,
            ctaLabel: ctaLabel,
            imageURLString: imageURLString,
            isSponsored: isSponsored,
            startsAtRaw: startsAtRaw,
            endsAtRaw: endsAtRaw,
            targetLatitude: targetLatitude,
            targetLongitude: targetLongitude,
            targetRadiusMiles: targetRadiusMiles,
            priorityWeight: priorityWeight
        )
    }
}

private struct SponsoredPlacementRegionalEligibility {
    let isEligible: Bool
    let reason: String
    let distanceMiles: Double?

    static func eligible(distanceMiles: Double) -> SponsoredPlacementRegionalEligibility {
        SponsoredPlacementRegionalEligibility(isEligible: true, reason: "eligible", distanceMiles: distanceMiles)
    }

    static func blocked(reason: String, distanceMiles: Double? = nil) -> SponsoredPlacementRegionalEligibility {
        SponsoredPlacementRegionalEligibility(isEligible: false, reason: reason, distanceMiles: distanceMiles)
    }
}

private struct SponsoredProfileFallbackPromotion: Identifiable {
    let id: String
    let eyebrow: String
    let title: String
    let subtitle: String
    let ctaLabel: String
    let systemImage: String

    var stableIdentity: String { "fallback.\(id)" }

    static func businessGrowthCard(languageCode: String) -> SponsoredProfileFallbackPromotion {
        SponsoredProfileFallbackPromotion(
            id: "fangeo-house-business-growth",
            eyebrow: L10n.t("profile_venues_promo_eyebrow", languageCode: languageCode),
            title: L10n.t("profile_venues_promo_title", languageCode: languageCode),
            subtitle: L10n.t("profile_venues_promo_subtitle", languageCode: languageCode),
            ctaLabel: L10n.t("profile_venues_promo_cta", languageCode: languageCode),
            systemImage: "megaphone.fill"
        )
    }
}

private struct SponsoredProfileRecommendationCard: View {
    let recommendation: SponsoredProfileVenueRecommendation
    let colorScheme: ColorScheme
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasRevealed = false
    @State private var glowPulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            titleBlock

            HStack(alignment: .top, spacing: 16) {
                venueImage

                metadataPanel
            }

            ctaButton
        }
        .padding(.horizontal, 22)
        .padding(.top, 21)
        .padding(.bottom, 22)
        .frame(minHeight: 320)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.18 : 0.82),
                            sponsorPurple.opacity(colorScheme == .dark ? 0.48 : 0.34),
                            FGColor.accentBlue.opacity(colorScheme == .dark ? 0.20 : 0.16),
                            Color.black.opacity(colorScheme == .dark ? 0.04 : 0.045)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            sponsorPurple.opacity(colorScheme == .dark ? 0.95 : 0.82),
                            FGColor.accentBlue.opacity(colorScheme == .dark ? 0.58 : 0.42)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 5)
                .padding(.vertical, 22)
                .shadow(color: sponsorPurple.opacity(colorScheme == .dark ? 0.36 : 0.22), radius: 10, x: 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .topLeading) {
            if glowPulse && !reduceMotion {
                softSparkle
                    .padding(.top, 38)
                    .padding(.leading, 22)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(
            color: sponsorPurple.opacity(glowPulse && !reduceMotion ? (colorScheme == .dark ? 0.42 : 0.26) : (colorScheme == .dark ? 0.12 : 0.08)),
            radius: glowPulse && !reduceMotion ? 26 : 0,
            y: 0
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.065), radius: 18, y: 10)
        .offset(y: hasRevealed || reduceMotion ? 0 : 34)
        .opacity(hasRevealed || reduceMotion ? 1 : 0)
        .scaleEffect(hasRevealed || reduceMotion ? 1 : 0.985)
        .onAppear {
            runRevealAnimationIfNeeded()
        }
        .accessibilityLabel("\(recommendation.isSponsored ? "Sponsored " : "")recommendation, \(recommendation.venue.name), \(recommendation.gameLine)")
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(recommendation.title)
                .font(.system(size: 23, weight: .heavy, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(recommendation.gameLine)
                .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 4)
    }

    private var metadataPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            metadataRow
            sportChips
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 115, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.045 : 0.44))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.34), lineWidth: 0.8)
        }
    }

    private var metadataRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(recommendation.distanceLine, systemImage: "location.fill")
                .labelStyle(.titleAndIcon)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 10.5, weight: .bold))
                fansGoingRow
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
        .foregroundStyle(FGColor.mutedText(colorScheme))
    }

    private var ctaButton: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Text(recommendation.ctaLabel)
                    .font(.system(size: 14.5, weight: .heavy, design: .rounded))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .heavy))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.17), in: Circle())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: [
                        sponsorPurple.opacity(0.98),
                        FGColor.accentBlue.opacity(0.96),
                        FGColor.accentGreen.opacity(0.90)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.9)
            }
            .shadow(color: sponsorPurple.opacity(colorScheme == .dark ? 0.24 : 0.16), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .accessibilityLabel("\(recommendation.ctaLabel), \(recommendation.venue.name)")
    }

    private func runRevealAnimationIfNeeded() {
        guard !hasRevealed else { return }
        if reduceMotion {
            hasRevealed = true
            logCardShown()
            return
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            hasRevealed = true
            glowPulse = true
        }
        logCardShown()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            withAnimation(.easeOut(duration: 0.28)) {
                glowPulse = false
            }
        }
    }

    private func logCardShown() {
#if DEBUG
        print("[SponsoredProfileDebug] cardShown=true")
        print("[SponsoredProfileDebug] \(recommendation.isSponsored ? "sponsoredVenue" : "organicVenue")=\(recommendation.venue.name)")
        print("[SponsoredProfileDebug] source=\(recommendation.sourceDebugLabel)")
#endif
    }

    private var softSparkle: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkle")
                .font(.system(size: 12, weight: .bold))
            Image(systemName: "sparkle")
                .font(.system(size: 7, weight: .bold))
                .offset(y: -5)
        }
        .foregroundStyle(
            LinearGradient(
                colors: [
                    sponsorPurple.opacity(0.96),
                    FGColor.accentBlue.opacity(0.78)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .opacity(glowPulse ? 1 : 0)
        .scaleEffect(glowPulse ? 1.08 : 0.78)
    }

    private var sportChips: some View {
        let chips = recommendation.sportChipLabels
        return Group {
            if !chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chips, id: \.self) { chip in
                            HStack(spacing: 5) {
                                Image(systemName: sportChipIcon(for: chip))
                                    .font(.system(size: 10, weight: .bold))
                                Text(chip)
                                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5.5)
                            .background(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(colorScheme == .dark ? 0.075 : 0.76),
                                        FGColor.accentBlue.opacity(colorScheme == .dark ? 0.055 : 0.07)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                in: Capsule()
                            )
                            .overlay {
                                Capsule()
                                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.52), lineWidth: 0.75)
                            }
                        }
                    }
                }
            }
        }
    }

    private func sportChipIcon(for chip: String) -> String {
        let lowercased = chip.lowercased()
        if lowercased.contains("basketball") { return "basketball.fill" }
        if lowercased.contains("soccer") || lowercased.contains("football") { return "soccerball" }
        if lowercased.contains("tennis") { return "tennisball.fill" }
        if lowercased.contains("baseball") { return "baseball.fill" }
        if lowercased.contains("hockey") { return "hockey.puck.fill" }
        return "sportscourt.fill"
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Recommended Near You")
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            Spacer(minLength: 8)
            if recommendation.isSponsored {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 8, weight: .heavy))
                    Text("Sponsored")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .textCase(.uppercase)
                        .tracking(0.55)
                }
                    .foregroundStyle(sponsorPurple.opacity(colorScheme == .dark ? 0.95 : 0.88))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4.5)
                    .background(
                        LinearGradient(
                            colors: [
                                sponsorPurple.opacity(colorScheme == .dark ? 0.15 : 0.12),
                                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.10 : 0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: Capsule()
                    )
                    .overlay {
                        Capsule()
                            .strokeBorder(sponsorPurple.opacity(colorScheme == .dark ? 0.30 : 0.20), lineWidth: 0.8)
                    }
            }
        }
    }

    private var venueImage: some View {
        ZStack {
            if let imageURL = recommendation.imageURL {
                DiscoverCachedRemoteImage(url: imageURL, contentMode: .fill) {
                    venueImagePlaceholder
                }
            } else {
                venueImagePlaceholder
            }
            venueImageAtmosphere
        }
        .frame(width: 150, height: 115)
        .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.15 : 0.58), lineWidth: 0.9)
        }
        .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.20 : 0.12), radius: 13, y: 6)
    }

    private var venueImagePlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [
                    FGColor.accentBlue.opacity(colorScheme == .dark ? 0.66 : 0.42),
                    FGColor.accentGreen.opacity(colorScheme == .dark ? 0.50 : 0.32),
                    Color.black.opacity(colorScheme == .dark ? 0.30 : 0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "sportscourt.fill")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(.white.opacity(0.88))
        }
    }

    private var venueImageAtmosphere: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.0),
                    Color.black.opacity(colorScheme == .dark ? 0.34 : 0.18)
                ],
                startPoint: .center,
                endPoint: .bottom
            )
            Circle()
                .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.22 : 0.16))
                .frame(width: 42, height: 42)
                .blur(radius: 16)
                .offset(x: -5, y: 10)
        }
        .allowsHitTesting(false)
    }

    private var fansGoingRow: some View {
        Text(recommendation.fansGoingText)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(cardSurfaceColor.opacity(colorScheme == .dark ? 0.18 : 0.72))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                sponsorPurple.opacity(colorScheme == .dark ? 0.22 : 0.13),
                                Color.clear,
                                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.12 : 0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(sponsorPurple.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    .frame(width: 132, height: 132)
                    .blur(radius: 32)
                    .offset(x: 34, y: -50)
            }
    }

    private var cardSurfaceColor: Color {
        colorScheme == .dark ? Color(red: 0.08, green: 0.10, blue: 0.12) : Color.white
    }

    private var sponsorPurple: Color {
        Color(red: 0.47, green: 0.25, blue: 0.95)
    }
}

private struct SponsoredProfileFallbackPromotionCard: View {
    let promotion: SponsoredProfileFallbackPromotion
    let colorScheme: ColorScheme
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            iconTile

            VStack(alignment: .leading, spacing: 6) {
                Text(promotion.eyebrow)
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.accentGreen.opacity(0.92))
                    .textCase(.uppercase)
                    .tracking(0.78)

                Text(promotion.title)
                    .font(.system(size: 15.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)

                Text(promotion.subtitle)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(2)

                Button(action: onTap) {
                    HStack(spacing: 8) {
                        Text(promotion.ctaLabel)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .heavy))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        LinearGradient(
                            colors: [
                                FGColor.accentGreen.opacity(0.98),
                                FGColor.accentBlue.opacity(0.86)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: Capsule(style: .continuous)
                    )
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(promotion.ctaLabel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.92 : 0.78))
                .frame(width: 5)
                .padding(.vertical, 16)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.16 : 0.76),
                            FGColor.accentGreen.opacity(colorScheme == .dark ? 0.34 : 0.24),
                            Color.black.opacity(colorScheme == .dark ? 0.04 : 0.045)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.14 : 0.045), radius: 10, y: 6)
        .onAppear {
#if DEBUG
            print("[SponsoredProfileDebug] cardShown=true")
            print("[SponsoredProfileDebug] source=fallback")
            print("[SponsoredProfileDebug] fallbackBusinessPromotion=true")
#endif
        }
    }

    private var iconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            FGColor.accentGreen.opacity(colorScheme == .dark ? 0.34 : 0.26),
                            FGColor.accentBlue.opacity(colorScheme == .dark ? 0.22 : 0.16)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: promotion.systemImage)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.95 : 0.88))
        }
        .frame(width: 56, height: 56)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.48), lineWidth: 0.8)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill((colorScheme == .dark ? Color(red: 0.07, green: 0.10, blue: 0.09) : Color.white).opacity(colorScheme == .dark ? 0.24 : 0.72))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                FGColor.accentGreen.opacity(colorScheme == .dark ? 0.13 : 0.08),
                                Color.clear,
                                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.08 : 0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
    }
}

struct SuggestedFanCard: View {
    let suggestion: FriendSuggestionProfile
    let context: String
    let isSending: Bool
    let chipKind: ChatViewModel.FriendshipChipKind
    let onAdd: (FriendSuggestionProfile) -> Void
    let onCancel: (FriendSuggestionProfile) -> Void
    let onDismiss: (FriendSuggestionProfile) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.sizeCategory) private var sizeCategory
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @State private var showCancelRequestConfirmation = false

    /// Shared layout tokens so every Suggested Fan card is identical in size and vertical alignment.
    enum Metrics {
        static let width: CGFloat = 130
        static let avatarSize: CGFloat = 50
        static let avatarChromePadding: CGFloat = 2
        static var avatarOuterSize: CGFloat { avatarSize + (avatarChromePadding * 2) }
        static let buttonHeight: CGFloat = 28
        static let verticalSpacing: CGFloat = 5
        static let nameLineHeight: CGFloat = 15
        static let nameMaxLines: Int = 2
        static var nameHeight: CGFloat { CGFloat(nameMaxLines) * nameLineHeight }
        static let accessibilityNameLineHeight: CGFloat = 18
        static var accessibilityNameHeight: CGFloat { CGFloat(nameMaxLines) * accessibilityNameLineHeight }
        /// Reserved on every card so presence/absence of country never changes outer height.
        static let countryRowHeight: CGFloat = 14
        static let accessibilityCountryRowHeight: CGFloat = 16
        static let whyHeaderHeight: CGFloat = 11
        static let whyRowHeight: CGFloat = 12
        static let accessibilityWhyRowHeight: CGFloat = 14
        static let whyMaxRows: Int = 3
        static let whyRowSpacing: CGFloat = 1
        static let whySectionSpacing: CGFloat = 2
        static let cardTopPadding: CGFloat = 9
        static let cardHorizontalPadding: CGFloat = 9
        static let cardBottomPadding: CGFloat = 8
        /// Derived once for standard Dynamic Type.
        static let height: CGFloat = computedHeight(
            nameHeight: nameHeight,
            countryRowHeight: countryRowHeight,
            whyRowHeight: whyRowHeight
        )
        /// Shared taller height for accessibility text sizes (all cards still equal).
        static let accessibilityHeight: CGFloat = computedHeight(
            nameHeight: accessibilityNameHeight,
            countryRowHeight: accessibilityCountryRowHeight,
            whyRowHeight: accessibilityWhyRowHeight
        )

        static func whyExplanationRowsHeight(rowHeight: CGFloat) -> CGFloat {
            (CGFloat(whyMaxRows) * rowHeight) + (CGFloat(whyMaxRows - 1) * whyRowSpacing)
        }

        static func whyBlockHeight(rowHeight: CGFloat) -> CGFloat {
            whyHeaderHeight + whySectionSpacing + whyExplanationRowsHeight(rowHeight: rowHeight)
        }

        static func computedHeight(
            nameHeight: CGFloat,
            countryRowHeight: CGFloat,
            whyRowHeight: CGFloat
        ) -> CGFloat {
            let whyBlock = whyBlockHeight(rowHeight: whyRowHeight)
            // Outer VStack: [avatar+name+country+why] + spacing + Spacer(0) + spacing + button
            return cardTopPadding
                + avatarOuterSize
                + verticalSpacing
                + nameHeight
                + verticalSpacing
                + countryRowHeight
                + verticalSpacing
                + whyBlock
                + verticalSpacing
                + verticalSpacing
                + buttonHeight
                + cardBottomPadding
        }

        static func height(for sizeCategory: ContentSizeCategory) -> CGFloat {
            sizeCategory.isAccessibilityCategory ? accessibilityHeight : height
        }

        static func nameAreaHeight(for sizeCategory: ContentSizeCategory) -> CGFloat {
            sizeCategory.isAccessibilityCategory ? accessibilityNameHeight : nameHeight
        }

        static func countryRowHeight(for sizeCategory: ContentSizeCategory) -> CGFloat {
            sizeCategory.isAccessibilityCategory ? accessibilityCountryRowHeight : countryRowHeight
        }

        static func whyRowHeight(for sizeCategory: ContentSizeCategory) -> CGFloat {
            sizeCategory.isAccessibilityCategory ? accessibilityWhyRowHeight : whyRowHeight
        }
    }

    private var whyExplanations: [SuggestedFanWhyExplanation] {
        suggestion.whySuggestedExplanations(max: Metrics.whyMaxRows)
    }

    private var cardHeight: CGFloat {
        Metrics.height(for: sizeCategory)
    }

    private var nameAreaHeight: CGFloat {
        Metrics.nameAreaHeight(for: sizeCategory)
    }

    private var countryRowHeight: CGFloat {
        Metrics.countryRowHeight(for: sizeCategory)
    }

    private var whyRowHeight: CGFloat {
        Metrics.whyRowHeight(for: sizeCategory)
    }

    private var whyBlockHeight: CGFloat {
        Metrics.whyBlockHeight(rowHeight: whyRowHeight)
    }

    private var displayCountry: (isoCode: String?, flagEmoji: String?, localizedName: String)? {
        ProfileHomeCityIdentity.displayableHomeCountry(
            storedCountry: suggestion.homeCountry,
            languageCode: appLanguageRaw
        )
    }

    var body: some View {
        VStack(spacing: Metrics.verticalSpacing) {
            PublicProfileAvatarTap(userId: suggestion.userID, context: context) {
                VStack(spacing: Metrics.verticalSpacing) {
                    avatar

                    Text(displayName)
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .multilineTextAlignment(.center)
                        .lineLimit(Metrics.nameMaxLines)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity)
                        .frame(height: nameAreaHeight, alignment: .top)

                    countryRow

                    whySuggestedSection
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .contentShape(Rectangle())
            }

            Spacer(minLength: 0)

            addButton
        }
        .padding(.top, Metrics.cardTopPadding)
        .padding(.horizontal, Metrics.cardHorizontalPadding)
        .padding(.bottom, Metrics.cardBottomPadding)
        .frame(width: Metrics.width, alignment: .top)
        .frame(height: cardHeight, alignment: .top)
        .background(cardBackground)
        .overlay(alignment: .topTrailing) {
            dismissButton
        }
        .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.10 : 0.055), radius: 8, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(cardAccessibilityLabel)
        .confirmationDialog(
            "Cancel friend request?",
            isPresented: $showCancelRequestConfirmation,
            titleVisibility: .visible
        ) {
            Button("Cancel Request", role: .destructive) {
                onCancel(suggestion)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove your pending request.")
        }
    }

    private var avatar: some View {
        UserAvatarView(
            avatarThumbnailURL: suggestion.avatarThumbnailURL,
            avatarURL: suggestion.avatarURL ?? "",
            avatarDisplayRefreshToken: ProfileAvatarRefreshToken.stable(
                userId: suggestion.userID,
                thumbnailURL: suggestion.avatarThumbnailURL,
                avatarURL: suggestion.avatarURL
            ),
            displayName: displayName,
            email: "",
            size: Metrics.avatarSize,
            fallbackStyle: .lightOnWhiteChrome,
            imagePlaceholderTint: FGColor.accentBlue
        )
        .overlay {
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            FGColor.accentBlue.opacity(0.78),
                            FGColor.accentGreen.opacity(0.72)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2
                )
        }
        .padding(Metrics.avatarChromePadding)
        .background(Circle().fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.96)))
    }

    /// Fixed-height country row — empty when no displayable profile country (keeps carousel card sizes equal).
    private var countryRow: some View {
        Group {
            if let displayCountry {
                HStack(spacing: 3) {
                    if let flag = displayCountry.flagEmoji {
                        Text(flag)
                            .font(.system(size: 10))
                            .accessibilityHidden(true)
                    }
                    Text(displayCountry.localizedName)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(displayCountry.localizedName)
            } else {
                Color.clear
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: countryRowHeight, alignment: .center)
    }

    /// Fixed-height why block so headings and Add buttons stay aligned across the carousel.
    /// Unused reason rows stay empty (no placeholder bullets); content is top-aligned.
    private var whySuggestedSection: some View {
        Group {
            if whyExplanations.isEmpty {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: whyBlockHeight)
                    .accessibilityHidden(true)
            } else {
                VStack(alignment: .leading, spacing: Metrics.whySectionSpacing) {
                    Text(L10n.t("suggested_fan_why_title", languageCode: appLanguageRaw))
                        .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .textCase(.uppercase)
                        .tracking(0.2)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: Metrics.whyHeaderHeight, alignment: .center)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: Metrics.whyRowSpacing) {
                        ForEach(Array(whyExplanations.enumerated()), id: \.offset) { _, reason in
                            whySuggestedRow(reason)
                        }
                    }
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .topLeading
                    )
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: whyBlockHeight, alignment: .top)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(whySuggestedAccessibilityLabel)
            }
        }
    }

    private func whySuggestedRow(_ reason: SuggestedFanWhyExplanation) -> some View {
        HStack(alignment: .top, spacing: 3) {
            Image(systemName: reason.systemImage)
                .font(.system(size: 7.5, weight: .semibold))
                .foregroundStyle(FGColor.accentGreen)
                .frame(width: 10, height: whyRowHeight, alignment: .center)
                .accessibilityHidden(true)

            Text(reason.localizedText(languageCode: appLanguageRaw))
                .font(.system(size: 8.4, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: whyRowHeight, alignment: .center)
        }
        .frame(height: whyRowHeight, alignment: .center)
        .accessibilityHidden(true)
    }

    private var whySuggestedAccessibilityLabel: String {
        let title = L10n.t("suggested_fan_why_title_a11y", languageCode: appLanguageRaw)
        let lines = whyExplanations.map { $0.localizedText(languageCode: appLanguageRaw) }
        return ([title] + lines).joined(separator: ". ")
    }

    private var cardAccessibilityLabel: String {
        var parts = [displayName]
        if let countryName = displayCountry?.localizedName {
            parts.append(countryName)
        }
        if !whyExplanations.isEmpty {
            parts.append(whySuggestedAccessibilityLabel)
        }
        parts.append(buttonState.title)
        return parts.joined(separator: ". ")
    }

    private var addButton: some View {
        let state = buttonState
        return Button {
            switch chipKind {
            case .pendingOutgoing:
                showCancelRequestConfirmation = true
            default:
                onAdd(suggestion)
            }
        } label: {
            HStack(spacing: 5) {
                if isSending {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(state.foreground)
                } else if let systemImage = state.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 8.8, weight: .bold))
                }

                Text(state.title)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .foregroundStyle(state.foreground)
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.buttonHeight)
            .background {
                Capsule()
                    .fill(state.fill)
                    .overlay {
                        Capsule()
                            .strokeBorder(state.stroke, lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
        .disabled(!state.isEnabled)
        .opacity(state.isEnabled ? 1 : 0.88)
        .accessibilityLabel(state.title)
    }

    private var dismissButton: some View {
        Button {
            onDismiss(suggestion)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .frame(width: 19, height: 19)
                .background {
                    Circle()
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.14 : 0.92))
                        .overlay {
                            Circle()
                                .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.0 : 0.06), lineWidth: 0.75)
                        }
                }
        }
        .buttonStyle(.plain)
        .padding(4)
        .accessibilityLabel("Remove suggestion")
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.065 : 0.96),
                        FGColor.accentBlue.opacity(colorScheme == .dark ? 0.07 : 0.06),
                        FGColor.accentGreen.opacity(colorScheme == .dark ? 0.045 : 0.055)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.10 : 0.82),
                                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.12 : 0.14)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
            }
    }

    private var displayName: String {
        let trimmed = (suggestion.displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Fan" : trimmed
    }

    private var buttonState: ButtonState {
        let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
        if isSending {
            return ButtonState(
                title: L10n.t("Adding", languageCode: languageCode),
                systemImage: nil,
                isEnabled: false,
                foreground: FGColor.accentBlue,
                fill: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.16 : 0.10),
                stroke: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.24 : 0.28)
            )
        }

        switch chipKind {
        case .addFriend, .declinedOutgoing:
            return ButtonState(
                title: L10n.t("Add", languageCode: languageCode),
                systemImage: "person.badge.plus",
                isEnabled: true,
                foreground: .white,
                fill: FGColor.accentBlue,
                stroke: FGColor.accentBlue.opacity(0.18)
            )
        case .pendingOutgoing:
            return ButtonState(
                title: "Requested",
                systemImage: "clock.fill",
                isEnabled: true,
                foreground: FGColor.secondaryText(colorScheme),
                fill: Color.white.opacity(colorScheme == .dark ? 0.07 : 0.72),
                stroke: Color.black.opacity(colorScheme == .dark ? 0.0 : 0.05)
            )
        case .pendingIncoming:
            return ButtonState(
                title: "In Chat",
                systemImage: "tray.full.fill",
                isEnabled: false,
                foreground: FGColor.secondaryText(colorScheme),
                fill: Color.white.opacity(colorScheme == .dark ? 0.07 : 0.72),
                stroke: Color.black.opacity(colorScheme == .dark ? 0.0 : 0.05)
            )
        case .friends:
            return ButtonState(
                title: "Friends",
                systemImage: "checkmark",
                isEnabled: false,
                foreground: FGColor.accentGreen,
                fill: FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.11),
                stroke: FGColor.accentGreen.opacity(colorScheme == .dark ? 0.20 : 0.18)
            )
        }
    }

    private struct ButtonState {
        let title: String
        let systemImage: String?
        let isEnabled: Bool
        let foreground: Color
        let fill: Color
        let stroke: Color
    }
}

private struct ProfileSuggestedFansSection: View {
    let suggestions: [FriendSuggestionProfile]
    let hasCompletedLoad: Bool
    let isRefreshing: Bool
    let message: String?
    var loadFailed: Bool = false
    let sendingRequestIds: Set<UUID>
    let chipKind: (UUID) -> ChatViewModel.FriendshipChipKind
    let onAdd: (FriendSuggestionProfile) -> Void
    let onCancel: (FriendSuggestionProfile) -> Void
    let onDismiss: (FriendSuggestionProfile) -> Void
    var onRetry: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.sizeCategory) private var sizeCategory
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @State private var showHowItWorksSheet = false

    private enum CardMetrics {
        /// Keep carousel chrome in sync with `SuggestedFanCard.Metrics`.
        static let width: CGFloat = SuggestedFanCard.Metrics.width
        static let cardHeight: CGFloat = SuggestedFanCard.Metrics.height
        static let accessibilityCardHeight: CGFloat = SuggestedFanCard.Metrics.accessibilityHeight
        static let avatarSize: CGFloat = SuggestedFanCard.Metrics.avatarSize
        static let mutualAvatarSize: CGFloat = 15
        static let buttonHeight: CGFloat = SuggestedFanCard.Metrics.buttonHeight
        static let verticalSpacing: CGFloat = SuggestedFanCard.Metrics.verticalSpacing
        static let infoHeight: CGFloat = 36
        static let reasonRowHeight: CGFloat = 20
        static let cardTopPadding: CGFloat = SuggestedFanCard.Metrics.cardTopPadding
        static let cardHorizontalPadding: CGFloat = SuggestedFanCard.Metrics.cardHorizontalPadding
        static let cardBottomPadding: CGFloat = SuggestedFanCard.Metrics.cardBottomPadding
        static let rowTopPadding: CGFloat = 2
        static let rowBottomPadding: CGFloat = 8

        static func rowMinHeight(for sizeCategory: ContentSizeCategory) -> CGFloat {
            SuggestedFanCard.Metrics.height(for: sizeCategory) + rowTopPadding + rowBottomPadding
        }
    }

    private static let allowedReasonLabels: Set<String> = [
        "Same pickup game",
        "Same watch party",
        "Same team",
        "Same venue",
        "Mutual friends",
        "Active fan",
        "High reputation"
    ]

    private var suggestionsAvatarFingerprint: String {
        suggestions.map { suggestion in
            [
                suggestion.userID.uuidString.lowercased(),
                suggestion.avatarThumbnailURL ?? "",
                suggestion.avatarURL ?? ""
            ].joined(separator: ":")
        }
        .joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if !hasCompletedLoad && suggestions.isEmpty {
                initialLoadingPlaceholder
            } else if suggestions.isEmpty {
                if loadFailed {
                    loadFailedState
                } else {
                    emptyState
                }
            } else {
                if isRefreshing {
                    refreshingIndicator
                }
                suggestionsRow
            }
        }
        .padding(.vertical, 2)
        .task(id: suggestionsAvatarFingerprint) {
            await prefetchSuggestedFanAvatars()
        }
        .sheet(isPresented: $showHowItWorksSheet) {
            SuggestedFansHowItWorksSheet()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 4) {
                Text(L10n.t("suggested_fans", languageCode: appLanguageRaw))
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.accentBlue)
                    .textCase(.uppercase)
                    .tracking(0.78)
                    .accessibilityAddTraits(.isHeader)

                Button {
                    showHowItWorksSheet = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.90 : 0.82))
                        .frame(width: 44, height: 44, alignment: .center)
                        .contentShape(Rectangle())
                        .padding(.vertical, -12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("suggested_fans_how_it_works", languageCode: L10n.normalizedLanguageCode(appLanguageRaw)))
                .accessibilityHint(L10n.t("suggested_fans_how_it_works_hint", languageCode: L10n.normalizedLanguageCode(appLanguageRaw)))

                Spacer(minLength: 0)

                if !suggestions.isEmpty {
                    Text("\(suggestions.count)")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .foregroundStyle(FGColor.accentBlue)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.16 : 0.10), in: Capsule())
                        .accessibilityLabel(
                            String(
                                format: L10n.t("suggested_fans_count_format", languageCode: appLanguageRaw),
                                locale: Locale(identifier: L10n.normalizedLanguageCode(appLanguageRaw)),
                                suggestions.count
                            )
                        )
                }
            }

            Text(L10n.t("suggested_fans_subtitle", languageCode: appLanguageRaw))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(FGColor.mutedText(colorScheme).opacity(0.82))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var refreshingIndicator: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("Updating suggestions…")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(FGColor.mutedText(colorScheme).opacity(0.88))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .accessibilityLabel("Updating suggestions")
    }

    private var initialLoadingPlaceholder: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Finding fans near you…")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
        .accessibilityLabel("Finding fans near you")
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(FGColor.accentGreen.opacity(0.78))

            Text(message?.isEmpty == false ? message! : "More fan matches coming soon")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.045 : 0.78))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.0 : 0.04), lineWidth: 0.75)
                }
        }
        .accessibilityLabel("More fan matches coming soon")
    }

    private var loadFailedState: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(FGColor.dangerRed.opacity(0.85))

            Text(message?.isEmpty == false ? message! : "Couldn't load fan suggestions")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))

            Spacer(minLength: 0)

            if let onRetry {
                Button("Retry", action: onRetry)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.accentBlue)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.045 : 0.78))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.0 : 0.04), lineWidth: 0.75)
                }
        }
        .accessibilityLabel(message ?? "Couldn't load fan suggestions")
    }

    private var suggestionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 10) {
                ForEach(suggestions) { suggestion in
                    suggestionCard(suggestion)
                }
            }
            .padding(.horizontal, 2)
            .padding(.top, CardMetrics.rowTopPadding)
            .padding(.bottom, CardMetrics.rowBottomPadding)
            .padding(.trailing, 8)
        }
        .frame(minHeight: CardMetrics.rowMinHeight(for: sizeCategory), alignment: .top)
    }

    private func prefetchSuggestedFanAvatars() async {
        var seen = Set<URL>()
        var urls: [URL] = []

        func appendURL(thumbnail: String?, full: String?, userId: UUID) {
            let token = ProfileAvatarRefreshToken.stable(
                userId: userId,
                thumbnailURL: thumbnail,
                avatarURL: full
            )
            guard let raw = ImageDisplayURL.forListDisplay(
                thumbnail: thumbnail,
                full: full ?? "",
                refreshToken: token
            ),
                  let url = URL(string: raw),
                  seen.insert(url).inserted else { return }
            urls.append(url)
        }

        for suggestion in suggestions.prefix(8) {
            appendURL(
                thumbnail: suggestion.avatarThumbnailURL,
                full: suggestion.avatarURL,
                userId: suggestion.userID
            )
        }

        guard !urls.isEmpty else {
#if DEBUG
            print("[SmoothPerf] operation=suggestedFansAvatarPrefetch skipped=noURLs durationMs=0 coalesced=false avatarCount=0")
#endif
            return
        }

        let startedAt = Date()
        await DiscoverMapImageCache.shared.prefetch(urls: urls, bucket: .avatar)
#if DEBUG
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        print("[SmoothPerf] operation=suggestedFansAvatarPrefetch skipped=none durationMs=\(ms) coalesced=false avatarCount=\(urls.count)")
#endif
    }

    private func suggestionCard(_ suggestion: FriendSuggestionProfile) -> some View {
        SuggestedFanCard(
            suggestion: suggestion,
            context: "profile_suggested_fans",
            isSending: sendingRequestIds.contains(suggestion.userID),
            chipKind: chipKind(suggestion.userID),
            onAdd: onAdd,
            onCancel: onCancel,
            onDismiss: onDismiss
        )
    }

    private func dismissButton(for suggestion: FriendSuggestionProfile) -> some View {
        Button {
            onDismiss(suggestion)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .frame(width: 19, height: 19)
                .background {
                    Circle()
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.14 : 0.92))
                        .overlay {
                            Circle()
                                .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.0 : 0.06), lineWidth: 0.75)
                        }
                }
        }
        .buttonStyle(.plain)
        .padding(4)
        .accessibilityLabel("Remove suggestion")
    }

    private func avatar(for suggestion: FriendSuggestionProfile) -> some View {
        UserAvatarView(
            avatarThumbnailURL: suggestion.avatarThumbnailURL,
            avatarURL: suggestion.avatarURL ?? "",
            avatarDisplayRefreshToken: ProfileAvatarRefreshToken.stable(
                userId: suggestion.userID,
                thumbnailURL: suggestion.avatarThumbnailURL,
                avatarURL: suggestion.avatarURL
            ),
            displayName: displayName(for: suggestion),
            email: "",
            size: CardMetrics.avatarSize,
            fallbackStyle: .lightOnWhiteChrome,
            imagePlaceholderTint: FGColor.accentBlue
        )
        .overlay {
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            FGColor.accentBlue.opacity(0.78),
                            FGColor.accentGreen.opacity(0.72)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2
                )
        }
        .padding(2)
        .background(Circle().fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.96)))
    }

    @ViewBuilder
    private func mutualOrReasonRow(for suggestion: FriendSuggestionProfile) -> some View {
        if suggestion.mutualFriendCount > 0 {
            reasonBadge(mutualFanBadgeLabel(for: suggestion.mutualFriendCount))
                .frame(height: CardMetrics.reasonRowHeight)
        } else {
            reasonPill(for: suggestion)
                .frame(height: CardMetrics.reasonRowHeight)
        }
    }

    private func mutualFansRow(for suggestion: FriendSuggestionProfile) -> some View {
        HStack(spacing: 5) {
            if !suggestion.mutualFriendAvatars.isEmpty {
                ZStack(alignment: .leading) {
                    ForEach(Array(suggestion.mutualFriendAvatars.prefix(3).enumerated()), id: \.element.id) { index, avatar in
                        mutualFanAvatar(avatar)
                            .offset(x: CGFloat(index) * 12)
                            .zIndex(Double(3 - index))
                    }
                }
                .frame(
                    width: CardMetrics.mutualAvatarSize + CGFloat(max(0, min(3, suggestion.mutualFriendAvatars.count) - 1)) * 12,
                    height: CardMetrics.mutualAvatarSize
                )
            }

            Text(mutualFansLabel(for: suggestion.mutualFriendCount))
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity)
        .frame(height: CardMetrics.reasonRowHeight)
        .accessibilityLabel(mutualFansLabel(for: suggestion.mutualFriendCount))
    }

    private func mutualFanAvatar(_ avatar: FriendSuggestionMutualFanAvatar) -> some View {
        UserAvatarView(
            avatarThumbnailURL: avatar.avatarThumbnailURL,
            avatarURL: avatar.avatarURL ?? "",
            avatarDisplayRefreshToken: ProfileAvatarRefreshToken.stable(
                userId: avatar.userID,
                thumbnailURL: avatar.avatarThumbnailURL,
                avatarURL: avatar.avatarURL
            ),
            displayName: avatar.displayName ?? "Fan",
            email: "",
            size: CardMetrics.mutualAvatarSize,
            fallbackStyle: .lightOnWhiteChrome,
            imagePlaceholderTint: FGColor.accentBlue
        )
        .overlay {
            Circle()
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.22 : 0.96), lineWidth: 1.5)
        }
    }

    private func mutualFansLabel(for count: Int) -> String {
        "\(count) mutual \(count == 1 ? "fan" : "fans")"
    }

    private func mutualFanBadgeLabel(for count: Int) -> String {
        count == 1 ? "Mutual fan" : "Mutual fans"
    }

    private func reasonPill(for suggestion: FriendSuggestionProfile) -> some View {
        reasonBadge(localizedReasonLabel(safeReasonLabel(for: suggestion)))
    }

    private func reasonBadge(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 8.8, weight: .bold, design: .rounded))
            .foregroundStyle(FGColor.accentGreen)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                Capsule()
                    .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.11))
            }
    }

    private func addButton(for suggestion: FriendSuggestionProfile) -> some View {
        let kind = chipKind(suggestion.userID)
        let isSending = sendingRequestIds.contains(suggestion.userID)
        let state = buttonState(for: kind, isSending: isSending)

        return Button {
            onAdd(suggestion)
        } label: {
            HStack(spacing: 5) {
                if isSending {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(state.foreground)
                } else if let systemImage = state.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 8.8, weight: .bold))
                }

                Text(state.title)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
            }
            .foregroundStyle(state.foreground)
            .frame(maxWidth: .infinity)
            .frame(height: CardMetrics.buttonHeight)
            .background {
                Capsule()
                    .fill(state.fill)
                    .overlay {
                        Capsule()
                            .strokeBorder(state.stroke, lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
        .disabled(!state.isEnabled)
        .opacity(state.isEnabled ? 1 : 0.88)
        .accessibilityLabel(state.title)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.065 : 0.96),
                        FGColor.accentBlue.opacity(colorScheme == .dark ? 0.07 : 0.06),
                        FGColor.accentGreen.opacity(colorScheme == .dark ? 0.045 : 0.055)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.10 : 0.82),
                                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.12 : 0.14)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
            }
    }

    private func displayName(for suggestion: FriendSuggestionProfile) -> String {
        let trimmed = (suggestion.displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Fan" : trimmed
    }

    private func handleText(for suggestion: FriendSuggestionProfile) -> String? {
        let trimmed = (suggestion.handle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.hasPrefix("@") ? trimmed : "@\(trimmed)"
    }

    private func safeReasonLabel(for suggestion: FriendSuggestionProfile) -> String {
        if let reasonLabel = suggestion.reasonLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           Self.allowedReasonLabels.contains(reasonLabel) {
            return reasonLabel
        }

        let normalizedType = (suggestion.reasonType ?? "")
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        switch normalizedType {
        case "pickup_game", "pickup", "shared_pickup", "pickup_player":
            return "Same pickup game"
        case "venue_event", "watch_party", "shared_event", "event_interest", "event":
            return "Same watch party"
        case "same_team", "shared_team", "team", "favorite_team", "favorite_teams":
            return "Same team"
        case "favorite_venue", "shared_venue", "venue":
            return "Same venue"
        case "mutual_friends", "mutual_friend":
            return "Mutual friends"
        case "recent_activity", "active_fan", "activity":
            return "Active fan"
        case "reputation", "fan_level", "high_reputation":
            return "High reputation"
        default:
            if suggestion.sharedPickupGameCount > 0 { return "Same pickup game" }
            if suggestion.sharedEventInterestCount > 0 { return "Same watch party" }
            if suggestion.sharedFavoriteTeamsCount > 0 { return "Same team" }
            return suggestion.score >= 400 ? "High reputation" : "Active fan"
        }
    }

    private func localizedReasonLabel(_ label: String) -> String {
        switch label {
        case "Same pickup game":
            return L10n.t("same_pickup_game", languageCode: appLanguageRaw)
        case "Same watch party":
            return L10n.t("same_watch_party", languageCode: appLanguageRaw)
        case "Same team":
            return L10n.t("same_team", languageCode: appLanguageRaw)
        case "Same venue":
            return L10n.t("same_venue", languageCode: appLanguageRaw)
        case "Mutual friends":
            return L10n.t("mutual_friends", languageCode: appLanguageRaw)
        case "High reputation":
            return L10n.t("high_reputation", languageCode: appLanguageRaw)
        case "Active fan":
            return L10n.t("active_fan", languageCode: appLanguageRaw)
        default:
            return label
        }
    }

    private func buttonState(
        for kind: ChatViewModel.FriendshipChipKind,
        isSending: Bool
    ) -> SuggestedFanButtonState {
        if isSending {
            return SuggestedFanButtonState(
                title: "Adding",
                systemImage: nil,
                isEnabled: false,
                foreground: FGColor.accentBlue,
                fill: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.16 : 0.10),
                stroke: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.24 : 0.28)
            )
        }

        switch kind {
        case .addFriend, .declinedOutgoing:
            return SuggestedFanButtonState(
                title: "Add",
                systemImage: "person.badge.plus",
                isEnabled: true,
                foreground: .white,
                fill: FGColor.accentBlue,
                stroke: FGColor.accentBlue.opacity(0.18)
            )
        case .pendingOutgoing:
            return SuggestedFanButtonState(
                title: "Requested",
                systemImage: "clock.fill",
                isEnabled: true,
                foreground: FGColor.secondaryText(colorScheme),
                fill: Color.white.opacity(colorScheme == .dark ? 0.07 : 0.72),
                stroke: Color.black.opacity(colorScheme == .dark ? 0.0 : 0.05)
            )
        case .pendingIncoming:
            return SuggestedFanButtonState(
                title: "In Chat",
                systemImage: "tray.full.fill",
                isEnabled: false,
                foreground: FGColor.secondaryText(colorScheme),
                fill: Color.white.opacity(colorScheme == .dark ? 0.07 : 0.72),
                stroke: Color.black.opacity(colorScheme == .dark ? 0.0 : 0.05)
            )
        case .friends:
            return SuggestedFanButtonState(
                title: "Friends",
                systemImage: "checkmark",
                isEnabled: false,
                foreground: FGColor.accentGreen,
                fill: FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.11),
                stroke: FGColor.accentGreen.opacity(colorScheme == .dark ? 0.20 : 0.18)
            )
        }
    }
}

private struct SuggestedFanButtonState {
    let title: String
    let systemImage: String?
    let isEnabled: Bool
    let foreground: Color
    let fill: Color
    let stroke: Color
}

private extension View {
    func profileIdentityInputStyle(colorScheme: ColorScheme) -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.62 : 0.96))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
            }
    }
}

struct PremiumTeamIdentityOrb: View {
    let team: FavoriteTeam
    let diameter: CGFloat

    private var nationalTeamFlag: String? {
        guard team.kind == .nationalTeam,
              let flag = CountryFlagHelper.flag(for: team.name),
              !flag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return flag
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.18))
                .frame(width: diameter, height: diameter)
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.34), lineWidth: 1)
                }

            if let nationalTeamFlag {
                Text(nationalTeamFlag)
                    .font(.system(size: max(24, diameter * 0.54)))
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
                    .shadow(color: Color.black.opacity(0.18), radius: 1.5, y: 1)
            } else {
                Text(team.initials)
                    .font(.system(size: max(10, diameter * 0.34), weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel("\(team.name), \(team.sport.chipTitle)")
    }
}

struct ProfileIdentityOwnPickupOrganizerSection: View {
    @ObservedObject var viewModel: MapViewModel
    let userId: UUID
    let summary: PickupOrganizerSummary
    var usesExternalChrome: Bool = false

    var body: some View {
        PickupOrganizerSummaryCard(
            userId: userId,
            summary: summary,
            compact: true,
            usesExternalChrome: usesExternalChrome
        )
        .task(id: userId) {
            await viewModel.refreshMyPickupOrganizerSummaryOnAppearIfStale()
        }
    }
}

