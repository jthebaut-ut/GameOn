import Combine
import Foundation
import Supabase
import SwiftUI

/// Owns friends / friend-request state for the Chat tab. Independent of ``MapViewModel``.
@MainActor
final class ChatViewModel: ObservableObject {
    /// Narrow projection consumed by `MainTabView`. Chat remains the sole source of truth;
    /// this object mirrors only root routing/chrome primitives synchronously on MainActor.
    let mainTabState = ChatMainTabState()
    /// Badge-only projection observed by the floating Chat button leaf.
    let tabBadgeState = ChatTabBadgeState()

    private var instanceDebugID: String {
        "\(ObjectIdentifier(self))"
    }

    init() {
#if DEBUG
        print("[ChatViewModelInstanceDebug] init id=\(instanceDebugID)")
        print("[MainActorDebug] ChatViewModel.init actor=MainActor")
#endif
        fanProfileAvatarChangeObserver = NotificationCenter.default.addObserver(
            forName: FanProfileChangeCenter.avatarDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let change = FanProfileChangeCenter.avatarChange(from: notification) else { return }
            Task { @MainActor [weak self] in
                self?.applyFanProfileAvatarChange(change)
            }
        }
    }

    deinit {
        if let fanProfileAvatarChangeObserver {
            NotificationCenter.default.removeObserver(fanProfileAvatarChangeObserver)
        }
#if DEBUG
        print("[ChatViewModelInstanceDebug] deinit id=\(ObjectIdentifier(self))")
#endif
    }

    /// Used to refresh internal reputation state after friend accept (set from ``FriendsTabView``).
    weak var mapViewModel: MapViewModel?

    /// Compact friendship state for comment rows (and similar surfaces). Absence in ``friendshipChipByOtherUserId`` means treat as stranger → Add Friend.
    enum FriendshipChipKind: Equatable {
        case addFriend
        /// Viewer sent a request to this user (show “Requested”).
        case pendingOutgoing
        /// This user sent the viewer a request (show inbox-style hint; not “Requested”).
        case pendingIncoming
        case friends
        /// Viewer’s outgoing request was declined; still visible in Sent until cleared.
        case declinedOutgoing
    }

    struct FriendDisplay: Identifiable, Hashable {
        let id: UUID
        let preview: UserPreview
        let subtitle: String?
        let lastMessageAt: Date?
        let unreadCount: Int
        let isConversationBacked: Bool
        /// Stable server thread id when inbox row is venue-scoped or otherwise conversation-specific.
        let conversationId: UUID?
        let inboxKind: ChatInboxConversationKind
        let groupMemberCount: Int
        let isGroupMuted: Bool
        /// When set, this group inbox row is a pickup-game private chat.
        let pickupGameId: UUID?
        /// When set, this group inbox row is an official Fan Team chat (`fan_teams.group_conversation_id`).
        /// Sourced from already-loaded Team membership snapshots — no extra inbox RPC.
        let fanTeamId: UUID?

        init(
            id: UUID,
            preview: UserPreview,
            subtitle: String?,
            lastMessageAt: Date?,
            unreadCount: Int,
            isConversationBacked: Bool,
            conversationId: UUID?,
            inboxKind: ChatInboxConversationKind = .direct,
            groupMemberCount: Int = 0,
            isGroupMuted: Bool = false,
            pickupGameId: UUID? = nil,
            fanTeamId: UUID? = nil
        ) {
            self.id = id
            self.preview = preview
            self.subtitle = subtitle
            self.lastMessageAt = lastMessageAt
            self.unreadCount = unreadCount
            self.isConversationBacked = isConversationBacked
            self.conversationId = conversationId
            self.inboxKind = inboxKind
            self.groupMemberCount = groupMemberCount
            self.isGroupMuted = isGroupMuted
            self.pickupGameId = pickupGameId
            self.fanTeamId = fanTeamId
        }

        var isGroupConversation: Bool { inboxKind == .group }
        var isPickupGameChat: Bool { pickupGameId != nil }
        var isFanTeamChat: Bool { fanTeamId != nil && !isPickupGameChat }
    }

    struct IncomingRequestDisplay: Identifiable, Hashable {
        let friendship: FriendshipRow
        let requester: UserPreview
        var id: UUID { friendship.id }
    }

    struct OutgoingRequestDisplay: Identifiable, Hashable {
        let friendship: FriendshipRow
        let addressee: UserPreview
        var id: UUID { friendship.id }
    }

    @Published private(set) var friends: [FriendDisplay] = [] {
        didSet {
            MainTabObservationPerf.chatPublished(category: "conversationsOrPresence")
        }
    }
    @Published private(set) var incomingRequests: [IncomingRequestDisplay] = [] {
        didSet {
            MainTabObservationPerf.chatPublished(category: "friendRequests")
        }
    }
    @Published private(set) var outgoingRequests: [OutgoingRequestDisplay] = [] {
        didSet {
            MainTabObservationPerf.chatPublished(category: "friendRequests")
        }
    }
    @Published private(set) var pendingBadgeCount: Int = 0 {
        didSet {
            MainTabObservationPerf.chatPublished(category: "requestBadge")
            tabBadgeState.setPendingBadgeCount(pendingBadgeCount)
        }
    }
    /// Root Teams tab badge: pending Team invitations addressed to **me**
    /// (`list_my_pending_fan_team_invitations`). Distinct from manager Team-card
    /// `pendingInvitationCount` (invites I sent).
    @Published private(set) var pendingFanTeamInvitationCount: Int = 0 {
        didSet {
            MainTabObservationPerf.chatPublished(category: "myTeamsInvitationBadge")
            tabBadgeState.setPendingFanTeamInvitationCount(pendingFanTeamInvitationCount)
        }
    }
    /// Cached invitee invitation rows for Action Center enrichment (same RPC as badge count).
    @Published private(set) var pendingFanTeamInvitations: [FanTeamInvitation] = []
    /// Unread peer DMs for the signed-in user (MainTabView private chat tab badge + ``AppIconBadgeSync``). Server source: inbox RPC unread totals / `get_dm_unread_total`; not friend-request counts.
    @Published private(set) var unreadDirectMessageCount: Int = 0 {
        didSet {
            MainTabObservationPerf.chatPublished(category: "unreadBadge")
            tabBadgeState.setUnreadDirectMessageCount(unreadDirectMessageCount)
        }
    }
    /// When non-nil, ``MainTabView`` switches to Chat and ``FriendsTabView`` pushes ``DirectChatView`` for this peer.
    @Published var pendingDmOpenPreview: UserPreview? {
        didSet {
            MainTabObservationPerf.chatPublished(category: "deepLink")
            mainTabState.setPendingDmOpenPreview(pendingDmOpenPreview)
        }
    }
    /// Cold-start / background APNs DM tap waiting for auth + Chat shell readiness.
    @Published private(set) var pendingDirectMessageNotificationDeepLink: DirectMessageNotificationDeepLinkRequest?
    /// Cold-start / background APNs friend-request tap waiting for auth + Chat shell readiness.
    @Published private(set) var pendingFriendRequestNotificationDeepLink: FriendRequestNotificationDeepLinkRequest?
    /// Cold-start / background APNs Fan Team invitation tap waiting for auth + Chat shell readiness.
    @Published private(set) var pendingFanTeamInvitationNotificationDeepLink: FanTeamInvitationNotificationDeepLinkRequest?
    /// Cold-start / background APNs unified chat_message tap waiting for auth + Chat shell readiness.
    @Published private(set) var pendingChatMessageNotificationDeepLink: ChatMessageNotificationDeepLinkRequest?
    /// When true, ``MainTabView`` selects Chat and ``FriendsTabView`` selects Requests.
    @Published var pendingOpenFriendRequestsSection: Bool = false {
        didSet {
            MainTabObservationPerf.chatPublished(category: "deepLink")
            mainTabState.setPendingOpenFriendRequestsSection(pendingOpenFriendRequestsSection)
        }
    }
    /// When true, ``MainTabView`` selects the root Teams tab (invitations / management).
    @Published var pendingOpenMyTeamsInvitations: Bool = false {
        didSet {
            MainTabObservationPerf.chatPublished(category: "deepLink")
            mainTabState.setPendingOpenMyTeamsInvitations(pendingOpenMyTeamsInvitations)
        }
    }
    /// Optional invitation id to highlight after opening Teams from a Team invitation push.
    @Published var pendingHighlightFanTeamInvitationId: UUID?
    /// Open Teams → Team Detail → Roster after a `member_left_team` push tap.
    @Published var pendingOpenFanTeamRosterTeamId: UUID?
    /// Optional message id to scroll/highlight after opening a DM or group from global search.
    @Published var pendingOpenHighlightMessageId: UUID?
    /// Newly created venue-scoped DM threads that should show the one-time intro banner.
    @Published private(set) var pendingVenueChatIntroConversationIds: Set<UUID> = []
    /// Lightweight in-app banner for an incoming DM while the thread is not open (local only).
    @Published private(set) var dmInAppNotification: DmInAppNotificationPayload? {
        didSet {
            MainTabObservationPerf.chatPublished(category: "inAppNotification")
            mainTabState.setDmInAppNotification(dmInAppNotification)
        }
    }
    @Published var errorMessage: String?
    /// Localized title for the friend-request error alert (accept / decline / clear).
    @Published var friendRequestAlertTitle: String?
    /// Debounce Accept/Decline while a mutation for that friendship id is in flight.
    @Published private(set) var friendRequestActionInFlightIds: Set<UUID> = []
    /// Shown when swipe-delete (inbox clear) fails; kept separate from ``errorMessage`` so friend-request errors don’t clash.
    @Published var inboxDeleteError: String?
    /// Shown when Friends directory unfriend fails; kept separate from ``errorMessage``.
    @Published var unfriendError: String?
    @Published private(set) var requiresSignIn: Bool = false {
        didSet {
            MainTabObservationPerf.chatPublished(category: "authGate")
            tabBadgeState.setRequiresSignIn(requiresSignIn)
        }
    }
    @Published var isLoading: Bool = false {
        didSet { MainTabObservationPerf.chatPublished(category: "chatLoading") }
    }
    /// True while the first inbox load is in flight and there is no cached inbox to show.
    @Published private(set) var isInboxInitialLoadInFlight: Bool = false {
        didSet { MainTabObservationPerf.chatPublished(category: "chatLoading") }
    }
    /// True while refreshing inbox when cached rows are already visible (stale-while-revalidate).
    @Published private(set) var isInboxBackgroundRefreshInFlight: Bool = false {
        didSet { MainTabObservationPerf.chatPublished(category: "chatLoading") }
    }
    /// Set after the first inbox load attempt finishes successfully so empty state can appear safely.
    @Published private(set) var hasCompletedInitialInboxLoad: Bool = false {
        didSet { MainTabObservationPerf.chatPublished(category: "chatLoading") }
    }
    /// True when the first inbox load failed before any successful result (show retry, not empty).
    @Published private(set) var initialInboxLoadFailed: Bool = false {
        didSet { MainTabObservationPerf.chatPublished(category: "chatLoading") }
    }

    /// Other user id → chip state. Keys only for users with an active friendship row; missing key ⇒ ``FriendshipChipKind.addFriend``.
    @Published private(set) var friendshipChipByOtherUserId: [UUID: FriendshipChipKind] = [:]
    @Published private(set) var currentUserAuthId: UUID?

    // MARK: - Moderation (blocked users)

    @Published private(set) var blockedUserIds: Set<UUID> = []
    /// Users who have blocked the current user (reverse of ``blockedUserIds``).
    @Published private(set) var usersWhoBlockedMeIds: Set<UUID> = []
    @Published private(set) var blockedUserPreviews: [UserPreview] = []
    private let moderation = ModerationService()

    /// When true, Chat has a DM/group conversation route. ``MainTabView`` hides the floating
    /// tab bar only while Chat is also the selected tab (`hidesFloatingTabBarForActiveChatConversation`).
    /// Source of truth lives in ``ChatMainTabState``; destinations must not write this.
    /// Kept as a non-publishing mirror for call sites that still read the name.
    var hidesFloatingTabBarForDirectChat: Bool {
        get { mainTabState.hidesFloatingTabBarForDirectChat }
        set { mainTabState.setHidesFloatingTabBarForDirectChat(newValue) }
    }
    @Published private(set) var activeVisibleConversationId: UUID?
    /// Typed foreground chat identity (`direct` / `group`) — UUIDs can overlap across tables.
    @Published private(set) var activeVisibleChatKind: String?
    @Published private(set) var directChatReadVisibilityVersion: Int = 0

    @Published private(set) var addFriendSearchResults: [AddFriendSearchTarget] = []
    @Published private(set) var addFriendSearchIsLoading: Bool = false

    private let service = FriendshipService()
    private let directChatService = DirectChatService()
    private let groupChatService = GroupChatService()
    private let socialIdentityService = SocialIdentityService()
    private let recentlyDeletedService = ChatRecentlyDeletedService()

    /// Server-backed soft/permanent inbox exclusions (`direct` / `group` conversation ids).
    private var serverExcludedInboxConversationIds: Set<UUID> = []
    /// True when `get_my_chat_inbox_exclusions` is available and last fetch succeeded.
    private var serverInboxExclusionsAvailable = false

    /// When set, Chat tab opens ``GroupChatView`` for this conversation id.
    @Published var pendingGroupOpenConversationId: UUID? {
        didSet {
            mainTabState.setPendingGroupOpenConversationId(pendingGroupOpenConversationId)
        }
    }
    /// Pending group invitations for the signed-in user (not active membership).
    @Published private(set) var pendingGroupInvitations: [GroupPendingInvitationRow] = []
    @Published private(set) var pendingGroupInvitationPreviews: [UUID: UserPreview] = [:]
    /// Active group member IDs for Chat Inbox avatar clusters, keyed by conversation id (display-ordered).
    @Published private(set) var groupInboxAvatarMemberIdsByConversationId: [UUID: [UUID]] = [:]
    /// Shared identity cache for group inbox member avatars.
    @Published private(set) var groupMemberPreviewByUserId: [UUID: UserPreview] = [:]

    private var groupInboxAvatarHydrationGeneration: UInt64 = 0
    private var groupInboxAvatarHydrationTask: Task<Void, Never>?
    /// Identity of the in-flight / last-completed avatar hydration within the current refresh cycle.
    private var groupInboxAvatarHydrationKey: String?
    /// Bumped at the start of each inbox refresh so identical group-ID sets still rehydrate across refreshes.
    private var groupInboxAvatarHydrationRefreshToken: UInt64 = 0
    private var lastCompletedGroupInboxAvatarHydrationKey: String?
    private var lastLoadAt: Date?
    private let minRefreshInterval: TimeInterval = 12
    private var lastInboxLoadAt: Date?
    private let minInboxRefreshInterval: TimeInterval = 2
    private var startupLightweightPrefetchTask: Task<StartupChatPrefetchResult, Never>?
    private var lastStartupLightweightPrefetchAt: Date?
    private let startupLightweightPrefetchTTL: TimeInterval = 90
    /// Coalesces duplicate unread RPCs during launch (critical → warm → post-auth badge).
    private var unreadDirectMessageRefreshTask: Task<Void, Never>?
    private var lastUnreadDirectMessageRefreshAt: Date?
    private let unreadDirectMessageRefreshFreshness: TimeInterval = 12
    private var lastChatTabIntentPreloadAt: Date?
    private var lastChatTabSurfaceRefreshAt: Date?
    private static let chatTabRefreshCoalesceInterval: TimeInterval = 25
    private var inboxEnrichmentTask: Task<Void, Never>?
    /// Shared in-flight inbox summaries refresh (login bootstrap + Chat tab coalesce).
    private var inboxSummariesRefreshTask: Task<Void, Never>?
    private var inboxSummariesRefreshAuthId: UUID?

    private var chatTabVisibleForDirectReadState = false
    private var privateChatUnlockedForDirectReadState = false

    /// Payload for the top-of-app DM toast/banner.
    struct DmInAppNotificationPayload: Identifiable, Equatable {
        let id: UUID
        let conversationId: UUID?
        let senderPreview: UserPreview
        let bodyPreview: String
    }

    struct StartupChatPrefetchResult {
        let dmBadgePrefetched: Bool
        let inboxSummariesPrefetched: Bool
        let skippedReason: String?
    }

    // MARK: - Realtime (in-app inbox)

    /// In-app realtime listener for `public.direct_messages` INSERTs while signed in (singleton per user).
    /// Lifecycle: ``ensureSignedInSocialRealtimeIfNeeded()`` / ``scheduleEnsureSocialRealtimeAfterForeground()``; stopped on logout.
    /// This does **not** work when the app is backgrounded/killed; that requires APNs/push later.
    ///
    /// **Scope:** When ``inboxRealtimeUsesConversationFilter`` is false (no filter or list too large), the client listens without
    /// a `postgres` filter; **RLS on `direct_messages`** restricts which rows each JWT receives at scale.
    ///
    /// **TODO (ideal at scale):** user-scoped Realtime channel or Edge Function broadcast delivering inbox summary deltas only,
    /// avoiding per-row fan-out and large conversation-id filter lists.
    private var inboxChannel: RealtimeChannelV2?
    private var inboxListenTask: Task<Void, Never>?
    /// Debounced server unread total (`get_dm_unread_total` / equivalent) after local inbox row tweaks from Realtime.
    private var inboxUnreadDebounceTask: Task<Void, Never>?
    /// Coalesces rare “peer not in inbox list yet” cases into a single full ``refreshInboxSummaries()`` (not per INSERT).
    private var inboxMissingPeerReconcileTask: Task<Void, Never>?
    /// Coalesces explicit badge recount requests from foreground, tab switches, and read-state changes.
    private var badgeRecalculationTask: Task<Void, Never>?
    private var badgeRecalculationNeedsInboxSummaries = false
    private var dmLatencyInboxEventStartByConversationID: [UUID: CFAbsoluteTime] = [:]
    /// User id the active inbox channel was bound to (debug + duplicate-guard).
    private var inboxRealtimeBoundUserId: UUID?
    /// True when the inbox listener uses a client-side `conversation_id IN (...)` filter (see run loop).
    private var inboxRealtimeUsesConversationFilter: Bool = false
    private var chatPresenceChannel: RealtimeChannelV2?
    private var chatPresenceListenTask: Task<Void, Never>?
    private var chatPresenceTrackedUserIds: Set<UUID> = []
    private var chatPresenceExpiryTask: Task<Void, Never>?
    /// Peers hidden from Recent Chats via swipe delete (persisted per auth user; restored on new inbound DM).
    private var hiddenInboxPeerUserIds: Set<UUID> = []
    private var hiddenInboxConversationIds: Set<UUID> = []

    /// Supabase Realtime `IN` filters should stay small; above this we omit the client filter and rely on RLS.
    private let kMaxConversationIdsForInboxRealtimeClientFilter = 48
    private let kMaxUserProfileIdsForPresenceRealtimeClientFilter = 64

    struct DMRealtimeIdentitySnapshot {
        let accountType: String
        let authUserId: UUID?
        let businessId: UUID?
        let listeningIdentityIds: [UUID]

        var authUserIdLogValue: String {
            authUserId?.uuidString.lowercased() ?? "nil"
        }

        var businessIdLogValue: String {
            businessId?.uuidString.lowercased() ?? "nil"
        }

        var listeningLogValue: String {
            guard !listeningIdentityIds.isEmpty else { return "none" }
            return listeningIdentityIds
                .map { $0.uuidString.lowercased() }
                .joined(separator: ",")
        }
    }

    // MARK: - Realtime (friend requests)

    private var friendshipsChannel: RealtimeChannelV2?
    private var friendshipsListenTask: Task<Void, Never>?
    private var friendshipsRealtimeBoundUserId: UUID?
    private var friendRequestRealtimeDebounceTask: Task<Void, Never>?
    /// Debounces ``ensureSignedInSocialRealtimeIfNeeded()`` after app foreground to avoid reconnect storms.
    private var socialRealtimeForegroundTask: Task<Void, Never>?
    private var fanProfileAvatarChangeObserver: NSObjectProtocol?
    private var fanTeamIdentityInboxObserver: NSObjectProtocol?
    private var fanTeamMembershipInboxObserver: NSObjectProtocol?
    private var fanTeamInvitationBadgeObserver: NSObjectProtocol?
    private var fanTeamDeletedBadgeObserver: NSObjectProtocol?
    private var pendingFanTeamInvitationCountRefreshTask: Task<Void, Never>?
    private var lastPendingFanTeamInvitationCountRefreshAt: Date?
    private var ensureSocialRealtimeInFlightTask: Task<Void, Never>?
    private var fullRefreshInFlightTask: Task<Void, Never>?
    private var lastSocialRealtimeEnsureAt: Date?
    private static let socialRealtimeForegroundSkipInterval: TimeInterval = 4
    /// Skip redundant full chat refreshes when enriched inbox + realtime are already warm.
    private static let fullRefreshFreshnessInterval: TimeInterval = 25

    func dmRealtimeIdentitySnapshot(fallbackAuthUserId: UUID? = nil) -> DMRealtimeIdentitySnapshot {
        let authUserId = currentUserAuthId ?? fallbackAuthUserId
        let businessId = currentBusinessIdentityIdForDMRealtime()
        let accountType = businessId == nil ? "user" : "business"
        let ids = [authUserId, businessId]
            .compactMap { $0 }
            .reduce(into: [UUID]()) { result, id in
                if !result.contains(id) { result.append(id) }
            }
        return DMRealtimeIdentitySnapshot(
            accountType: accountType,
            authUserId: authUserId,
            businessId: businessId,
            listeningIdentityIds: ids
        )
    }

    func isCurrentDMRealtimeIdentity(_ id: UUID, fallbackAuthUserId: UUID? = nil) -> Bool {
        dmRealtimeIdentitySnapshot(fallbackAuthUserId: fallbackAuthUserId)
            .listeningIdentityIds
            .contains(id)
    }

    private func currentBusinessIdentityIdForDMRealtime() -> UUID? {
        guard let mapViewModel else { return nil }
        let isBusinessContext = mapViewModel.currentUserIsBusinessAccount
            || mapViewModel.isVenueOwnerLoggedIn
            || mapViewModel.hasAuthenticatedVenueOwnerSession
        guard isBusinessContext else { return nil }
        return mapViewModel.currentBusinessIdForAddLocation()
            ?? mapViewModel.ownedBusinesses.first?.id
    }

    func currentUserIdIfSignedIn() async -> UUID? {
        try? await service.currentUserId()
    }

    private func noteAuthenticatedChatSession(userId: UUID, source: String) {
        currentUserAuthId = userId
        hiddenInboxPeerUserIds = DmInboxHiddenConversationsStore.hiddenPeerUserIds(authId: userId)
        hiddenInboxConversationIds = DmInboxHiddenConversationsStore.hiddenConversationIds(authId: userId)
        requiresSignIn = false
#if DEBUG
        let email = mapViewModel?.authenticatedSocialEmailForUI ?? ""
        let isBusiness = mapViewModel?.currentUserIsBusinessAccount == true
            || mapViewModel?.isVenueOwnerLoggedIn == true
            || mapViewModel?.hasAuthenticatedVenueOwnerSession == true
        let hasUserProfile = mapViewModel?.userProfileExistsForPresentation == true
            || mapViewModel?.currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || mapViewModel?.currentUserUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        print("[ChatAuthGate] chatViewModelAuthenticated source=\(source)")
        print("[ChatAuthGate] hasSession=true")
        print("[ChatAuthGate] userEmail=\(email.isEmpty ? "nil" : email)")
        print("[ChatAuthGate] isBusinessAccount=\(isBusiness)")
        print("[ChatAuthGate] hasUserProfile=\(hasUserProfile)")
        print("[ChatAuthGate] reasonBlocked=none")
#endif
        deliverPendingDirectMessageNotificationDeepLinkIfReady(reason: "auth:\(source)")
        deliverPendingFriendRequestNotificationDeepLinkIfReady(reason: "auth:\(source)")
        deliverPendingFanTeamInvitationNotificationDeepLinkIfReady(reason: "auth:\(source)")
        deliverPendingChatMessageNotificationDeepLinkIfReady(reason: "auth:\(source)")
    }

    private func ignoreCancellationIfNeeded(_ error: Error, context: String) -> Bool {
        guard error is CancellationError else { return false }
        #if DEBUG
        print("[CancellationHandlingDebug] ignoredCancellation context=\(context)")
        #endif
        return true
    }

    /// Clears social UI state when the session ends (no network).
    func clearForSignOut() {
        resetPrivateChatState(reason: "signedOut", nextAuthId: nil, requiresSignIn: true)
    }

    /// Account switch / login handoff: drop prior account private Chat state without flashing it.
    func resetForAccountChange(newAuthId: UUID?, reason: String) {
#if DEBUG
        print("[ChatBootstrap] accountChanged")
        print("[ChatBootstrap] resetPreviousAccount")
#endif
        resetPrivateChatState(
            reason: reason,
            nextAuthId: newAuthId,
            requiresSignIn: newAuthId == nil
        )
        if newAuthId != nil {
            deliverPendingDirectMessageNotificationDeepLinkIfReady(reason: "accountChange:\(reason)")
            deliverPendingFriendRequestNotificationDeepLinkIfReady(reason: "accountChange:\(reason)")
            deliverPendingFanTeamInvitationNotificationDeepLinkIfReady(reason: "accountChange:\(reason)")
            deliverPendingChatMessageNotificationDeepLinkIfReady(reason: "accountChange:\(reason)")
        }
    }

    private func resetPrivateChatState(reason: String, nextAuthId: UUID?, requiresSignIn signInRequired: Bool) {
        friends = []
        incomingRequests = []
        outgoingRequests = []
        pendingBadgeCount = 0
        pendingFanTeamInvitationCount = 0
        pendingFanTeamInvitations = []
        unreadDirectMessageCount = 0
        pendingGroupInvitations = []
        pendingGroupInvitationPreviews = [:]
        groupInboxAvatarMemberIdsByConversationId = [:]
        groupMemberPreviewByUserId = [:]
        groupInboxAvatarHydrationTask?.cancel()
        groupInboxAvatarHydrationTask = nil
        groupInboxAvatarHydrationGeneration &+= 1
        groupInboxAvatarHydrationKey = nil
        lastCompletedGroupInboxAvatarHydrationKey = nil
        groupInboxAvatarHydrationRefreshToken &+= 1
        errorMessage = nil
        friendRequestAlertTitle = nil
        inboxDeleteError = nil
        requiresSignIn = signInRequired
        isInboxInitialLoadInFlight = false
        isInboxBackgroundRefreshInFlight = false
        hasCompletedInitialInboxLoad = false
        initialInboxLoadFailed = false
        lastLoadAt = nil
        lastInboxLoadAt = nil
        inboxEnrichmentTask?.cancel()
        inboxEnrichmentTask = nil
        inboxSummariesRefreshTask?.cancel()
        inboxSummariesRefreshTask = nil
        inboxSummariesRefreshAuthId = nil
        friendshipChipByOtherUserId = [:]
        ChatFriendsStability.resetForAccountChange()
        currentUserAuthId = nextAuthId
        if let nextAuthId {
            hiddenInboxPeerUserIds = DmInboxHiddenConversationsStore.hiddenPeerUserIds(authId: nextAuthId)
            hiddenInboxConversationIds = DmInboxHiddenConversationsStore.hiddenConversationIds(authId: nextAuthId)
        } else {
            hiddenInboxPeerUserIds = []
            hiddenInboxConversationIds = []
        }
        serverExcludedInboxConversationIds = []
        serverInboxExclusionsAvailable = false
        mainTabState.setHidesFloatingTabBarForDirectChat(false)
        blockedUserIds = []
        usersWhoBlockedMeIds = []
        blockedUserPreviews = []
        addFriendSearchResults = []
        addFriendSearchIsLoading = false
        pendingDmOpenPreview = nil
        pendingGroupOpenConversationId = nil
        pendingOpenHighlightMessageId = nil
        // Preserve APNs deep-links across login restore; clear only on sign-out.
        if nextAuthId == nil {
            pendingDirectMessageNotificationDeepLink = nil
            pendingFriendRequestNotificationDeepLink = nil
            pendingFanTeamInvitationNotificationDeepLink = nil
            pendingChatMessageNotificationDeepLink = nil
            pendingOpenFriendRequestsSection = false
            pendingOpenMyTeamsInvitations = false
            pendingHighlightFanTeamInvitationId = nil
        }
        dmInAppNotification = nil
        activeVisibleConversationId = nil
        activeVisibleChatKind = nil
        chatTabVisibleForDirectReadState = false
        privateChatUnlockedForDirectReadState = false
        inboxUnreadDebounceTask?.cancel()
        inboxUnreadDebounceTask = nil
        inboxMissingPeerReconcileTask?.cancel()
        inboxMissingPeerReconcileTask = nil
        badgeRecalculationTask?.cancel()
        badgeRecalculationTask = nil
        badgeRecalculationNeedsInboxSummaries = false
        startupLightweightPrefetchTask?.cancel()
        startupLightweightPrefetchTask = nil
        lastStartupLightweightPrefetchAt = nil
        unreadDirectMessageRefreshTask?.cancel()
        unreadDirectMessageRefreshTask = nil
        lastUnreadDirectMessageRefreshAt = nil
        lastChatTabIntentPreloadAt = nil
        lastChatTabSurfaceRefreshAt = nil
        friendRequestRealtimeDebounceTask?.cancel()
        friendRequestRealtimeDebounceTask = nil
        socialRealtimeForegroundTask?.cancel()
        socialRealtimeForegroundTask = nil
        ensureSocialRealtimeInFlightTask?.cancel()
        ensureSocialRealtimeInFlightTask = nil
        fullRefreshInFlightTask?.cancel()
        fullRefreshInFlightTask = nil
        lastSocialRealtimeEnsureAt = nil
        dmLatencyInboxEventStartByConversationID.removeAll(keepingCapacity: false)

        // Cancel listen tasks synchronously so teardown cannot race a remount before async stop finishes.
        // Detach channel removal — never await websocket unsubscribe on the logout path.
        let inboxChannel = inboxChannel
        let friendshipsChannel = friendshipsChannel
        let presenceChannel = chatPresenceChannel
        inboxListenTask?.cancel()
        inboxListenTask = nil
        friendshipsListenTask?.cancel()
        friendshipsListenTask = nil
        chatPresenceListenTask?.cancel()
        chatPresenceListenTask = nil
        chatPresenceExpiryTask?.cancel()
        chatPresenceExpiryTask = nil
        chatPresenceTrackedUserIds = []
        self.inboxChannel = nil
        self.friendshipsChannel = nil
        friendshipsRealtimeBoundUserId = nil
        chatPresenceChannel = nil

        if let fanTeamIdentityInboxObserver {
            NotificationCenter.default.removeObserver(fanTeamIdentityInboxObserver)
            self.fanTeamIdentityInboxObserver = nil
        }
        if let fanTeamMembershipInboxObserver {
            NotificationCenter.default.removeObserver(fanTeamMembershipInboxObserver)
            self.fanTeamMembershipInboxObserver = nil
        }
        if let fanTeamInvitationBadgeObserver {
            NotificationCenter.default.removeObserver(fanTeamInvitationBadgeObserver)
            self.fanTeamInvitationBadgeObserver = nil
        }
        if let fanTeamDeletedBadgeObserver {
            NotificationCenter.default.removeObserver(fanTeamDeletedBadgeObserver)
            self.fanTeamDeletedBadgeObserver = nil
        }
        pendingFanTeamInvitationCountRefreshTask?.cancel()
        pendingFanTeamInvitationCountRefreshTask = nil
        lastPendingFanTeamInvitationCountRefreshAt = nil
        Task {
            if let inboxChannel {
                await supabase.removeChannel(inboxChannel)
            }
            if let friendshipsChannel {
                await supabase.removeChannel(friendshipsChannel)
            }
            if let presenceChannel {
                await supabase.removeChannel(presenceChannel)
            }
            await FanTeamIdentityRealtimeCoordinator.shared.stop()
            await AppIconBadgeSync.apply(count: 0)
        }
#if DEBUG
        print("[ChatBootstrap] resetPreviousAccount reason=\(reason)")
#endif
    }

    func clearForLogout() async {
        clearForSignOut()
    }

    /// Starts the authoritative inbox load for the current account (login bootstrap or Chat tab).
    /// Coalesces with any in-flight ``refreshInboxSummaries`` request.
    func beginInitialInboxLoadIfNeeded(source: String) async {
        if hasCompletedInitialInboxLoad {
            return
        }
        prepareInboxLoadUIStateIfNeeded()
#if DEBUG
        if inboxSummariesRefreshTask != nil {
            print("[ChatBootstrap] joinedExistingRequest")
        } else {
            print("[ChatBootstrap] initialLoadStarted source=\(source)")
        }
#endif
        await refreshInboxSummaries()
    }

    /// True if either party has blocked the other (client-side UX guard).
    func isEitherDirectionBlocked(with peerId: UUID) -> Bool {
        blockedUserIds.contains(peerId) || usersWhoBlockedMeIds.contains(peerId)
    }

    /// Reloads block sets from Supabase; ignores failures (keeps prior state).
    private func reloadModerationBlockSets() async {
        do {
            blockedUserIds = try await moderation.fetchBlockedUserIds()
            usersWhoBlockedMeIds = try await moderation.fetchUsersWhoBlockedMeIds()
        } catch {
            // TODO: Non-fatal telemetry; server-side enforcement still required.
        }
    }

    /// Ensures DM inbox + friend-request Realtime listeners are running while signed in.
    /// Tab switches, DM navigation, and sheets do **not** stop these listeners (see ``setChatTabRealtimeEnabled``).
    func ensureSignedInSocialRealtimeIfNeeded() async {
        guard requiresSignIn == false else { return }
        if let inFlight = ensureSocialRealtimeInFlightTask {
            DebugLogGate.debug("[PresenceDebug] ensureCoalesced=true reason=inFlight")
            await inFlight.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performEnsureSignedInSocialRealtime()
        }
        ensureSocialRealtimeInFlightTask = task
        await task.value
        if ensureSocialRealtimeInFlightTask == task {
            ensureSocialRealtimeInFlightTask = nil
        }
    }

    private func performEnsureSignedInSocialRealtime() async {
        guard requiresSignIn == false else { return }
        // Explicit logout must never restart presence / inbox / friendship realtime mid-pipeline.
        guard FanGeoExplicitLogoutGuard.isInProgress == false else {
#if DEBUG
            print("[PresenceDebug] ensureSkipped reason=logoutInProgress")
#endif
            return
        }
        // Fail closed: no presence heartbeat, DM inbox, or friendship realtime until the
        // authoritative age record confirmed this exact UUID for the current policy.
        guard AgeAccessGateService.shared.allowsSocialSubsystemsForActiveUser() else {
            AgeAccessRuntimeLog.socialSubsystemBlocked(
                userId: AgeAccessGateService.shared.activeUserId,
                subsystem: "chat_presence_realtime"
            )
            return
        }
#if DEBUG
        print("[BadgeArchitectureDebug] ensureRealtime vm=\(instanceDebugID)")
        print("[MainActorDebug] ensureRealtime actor=MainActor")
#endif
        await repairInconsistentSocialRealtimeChannelsIfNeeded()
        startInboxRealtimeListenerIfNeeded()
        startFriendshipsRealtimeListenerIfNeeded()
        syncChatPresenceRealtimeIfNeeded(reason: "ensureSignedInSocialRealtime")
        let teamIdentityUserId: UUID?
        if let existing = currentUserAuthId {
            teamIdentityUserId = existing
        } else {
            teamIdentityUserId = try? await service.currentUserId()
        }
        if let teamIdentityUserId {
            currentUserAuthId = teamIdentityUserId
            await FanTeamIdentityRealtimeCoordinator.shared.startIfNeeded(userId: teamIdentityUserId)
            installFanTeamIdentityInboxObserverIfNeeded()
            installFanTeamMembershipInboxObserverIfNeeded()
            syncFanTeamClassificationOnGroupInbox()
            installFanTeamInvitationBadgeObserversIfNeeded()
            await refreshPendingFanTeamInvitationCount(force: true)
        }
        lastSocialRealtimeEnsureAt = Date()
    }

    /// Debounced re-attach after foreground (avoids stacked reconnects with scene churn).
    func scheduleEnsureSocialRealtimeAfterForeground() {
        socialRealtimeForegroundTask?.cancel()
        socialRealtimeForegroundTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
#if DEBUG
            print("[RealtimeLifecycle] foreground debounced ensure")
#endif
            FanTeamIdentityRealtimeCoordinator.shared.handleSceneBecameActive()
            await self.refreshPendingFanTeamInvitationCount(force: true)
            if let last = self.lastSocialRealtimeEnsureAt,
               Date().timeIntervalSince(last) < Self.socialRealtimeForegroundSkipInterval {
                AppPerfDebug.realtimeRestarted(false, source: "foregroundSkippedRecentEnsure")
                await self.refreshChatPresenceSnapshots(reason: "foregroundReconnectSkipped")
                self.requestForegroundBadgeRefresh()
                return
            }
            let identity = self.dmRealtimeIdentitySnapshot()
            DMRealtimeDiagnostics.debug(
                "reconnectOnForeground=true accountType=\(identity.accountType) authUserId=\(identity.authUserIdLogValue) businessId=\(identity.businessIdLogValue)"
            )
            DMRealtimeDiagnostics.debug(
                "foregroundReconnectCheck=true accountType=\(identity.accountType) authUserId=\(identity.authUserIdLogValue) businessId=\(identity.businessIdLogValue)"
            )
#if DEBUG
            RealtimeHealthDiagnostics.log("appForegroundReconnect=chat_social")
#endif
            await self.restartSocialRealtimeAfterForeground()
            await self.refreshChatPresenceSnapshots(reason: "foregroundReconnect")
            self.requestForegroundBadgeRefresh()
        }
    }

    private func restartSocialRealtimeAfterForeground() async {
        guard requiresSignIn == false else { return }
#if DEBUG
        RealtimeHealthDiagnostics.log("reconnectDetected=chat_social_foreground_resubscribe")
#endif
        DebugLogGate.debug("[PresenceDebug] foregroundReconnect=true")
        AppPerfDebug.realtimeRestarted(true, source: "foregroundResubscribe")
        await stopInboxRealtimeListener()
        await stopFriendshipsRealtimeListener()
        await stopChatPresenceRealtimeListener()
        await ensureSignedInSocialRealtimeIfNeeded()
    }

    func forceRestartChatRealtimeAfterGlobalRetryExhausted(reason: String) async {
        guard requiresSignIn == false else { return }
        DMRealtimeDiagnostics.debug("globalRealtimeRestart=true reason=\(reason)")
#if DEBUG
        RealtimeHealthDiagnostics.log("reconnectDetected=chat_social_global_retry_exhausted reason=\(reason)")
#endif
        await stopInboxRealtimeListener()
        await stopFriendshipsRealtimeListener()
        await stopChatPresenceRealtimeListener()
        await ensureSignedInSocialRealtimeIfNeeded()
    }

    private func realtimeErrorIndicatesGlobalRetryExhausted(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("maximum retry attempts")
            || message.contains("max retry")
            || message.contains("retry attempts reached")
    }

    private func repairInconsistentSocialRealtimeChannelsIfNeeded() async {
        if (inboxListenTask == nil) != (inboxChannel == nil) {
#if DEBUG
            RealtimeHealthDiagnostics.log("reconnectDetected=dm_inbox_inconsistent_state")
#endif
            await stopInboxRealtimeListener()
        }
        if (friendshipsListenTask == nil) != (friendshipsChannel == nil) {
#if DEBUG
            RealtimeHealthDiagnostics.log("reconnectDetected=friendships_inconsistent_state")
#endif
            await stopFriendshipsRealtimeListener()
        }
        if (chatPresenceListenTask == nil) != (chatPresenceChannel == nil) {
#if DEBUG
            RealtimeHealthDiagnostics.log("reconnectDetected=chat_presence_inconsistent_state")
#endif
            await stopChatPresenceRealtimeListener()
        }
    }

    private func syncChatPresenceRealtimeIfNeeded(reason: String) {
        guard requiresSignIn == false else {
            Task { await stopChatPresenceRealtimeListener() }
            return
        }
        // Track fan peer *user* ids — `FriendDisplay.id` is the conversation id for
        // conversation-backed rows and would never match `user_profiles.id`.
        let ids = Set(
            friends
                .filter { !$0.isGroupConversation && !$0.preview.isDeleted && !$0.preview.isBusinessIdentity }
                .map(\.preview.id)
        )
        guard !ids.isEmpty else {
            Task { await stopChatPresenceRealtimeListener() }
            return
        }

        if ids == chatPresenceTrackedUserIds,
           chatPresenceListenTask != nil,
           chatPresenceChannel != nil {
            startChatPresenceExpiryTickerIfNeeded()
            ChatActivationPerf.presencePeerSet(changed: false, count: ids.count)
            DebugLogGate.debug("[PresenceDebug] subscribeStarted=false reason=alreadyActive onlineUsersCount=\(chatPresenceOnlineCount())")
            return
        }

        ChatActivationPerf.presencePeerSet(changed: true, count: ids.count)
        chatPresenceTrackedUserIds = ids
        chatPresenceListenTask?.cancel()
        chatPresenceListenTask = nil
        if let channel = chatPresenceChannel {
            chatPresenceChannel = nil
            Task { await supabase.removeChannel(channel) }
        }

        let sortedIds = ids.sorted { $0.uuidString < $1.uuidString }
        startChatPresenceExpiryTickerIfNeeded()
        chatPresenceListenTask = Task { @MainActor [weak self] in
            await self?.runChatPresenceRealtimeLoop(userIds: sortedIds, reason: reason)
        }
    }

    private func runChatPresenceRealtimeLoop(userIds: [UUID], reason: String) async {
        guard !userIds.isEmpty else { return }
        let authKey = (currentUserAuthId ?? userIds.first)?.uuidString.lowercased() ?? "anon"
        let channelName = "chat-presence-\(authKey)"
        let channel = supabase.channel(channelName)
        chatPresenceChannel = channel
        let identity = dmRealtimeIdentitySnapshot()
        DebugLogGate.debug("[PresenceDebug] subscribeStarted=true reason=\(reason) channelName=\(channelName)")
        DebugLogGate.debug("[PresenceDebug] userId=\(identity.authUserIdLogValue)")
        DebugLogGate.debug("[PresenceDebug] businessId=\(identity.businessIdLogValue)")

        let streams = Self.chunked(userIds, size: kMaxUserProfileIdsForPresenceRealtimeClientFilter).map { chunk in
            channel.postgresChange(
                UpdateAction.self,
                schema: "public",
                table: "user_profiles",
                filter: RealtimePostgresFilter.in("id", values: chunk)
            )
        }

        var shouldRestartChatRealtime = false
        do {
            try await channel.subscribeWithError()
            DebugLogGate.debug("[PresenceDebug] onlineUsersCount=\(chatPresenceOnlineCount())")
            await withTaskGroup(of: Void.self) { group in
                for stream in streams {
                    group.addTask { [weak self] in
                        await self?.consumeChatPresenceUpdates(stream)
                    }
                }
            }
        } catch is CancellationError {
        } catch {
#if DEBUG
            DebugLogGate.debug("[PresenceDebug] subscribeError=\(error.localizedDescription) channelName=\(channelName)")
#endif
            shouldRestartChatRealtime = realtimeErrorIndicatesGlobalRetryExhausted(error)
        }

        if chatPresenceChannel === channel {
            chatPresenceChannel = nil
        }
        if chatPresenceListenTask != nil, !Task.isCancelled {
            await supabase.removeChannel(channel)
        }
        if shouldRestartChatRealtime {
            Task { @MainActor [weak self] in
                await Task.yield()
                await self?.forceRestartChatRealtimeAfterGlobalRetryExhausted(reason: "presenceMaxRetry")
            }
        }
    }

    private func consumeChatPresenceUpdates(_ stream: AsyncStream<UpdateAction>) async {
        let decoder = JSONDecoder()
        for await update in stream {
            if Task.isCancelled { break }
            let row: UserProfileRow
            do {
                row = try update.decodeRecord(as: UserProfileRow.self, decoder: decoder)
            } catch {
                continue
            }
            guard let userId = row.id else { continue }
            applyChatPresenceUpdate(userId: userId, lastSeenAtRaw: row.last_seen_at, source: "realtime")
            let full = ImageDisplayURL.canonicalStorageURLString(row.avatar_url)
            let thumb = ImageDisplayURL.canonicalStorageURLString(row.avatar_thumbnail_url)
            if !full.isEmpty || !thumb.isEmpty {
                applyFanProfileAvatarChange(
                    FanProfileAvatarChange(
                        userId: userId,
                        avatarURL: full.isEmpty ? (thumb) : full,
                        avatarThumbnailURL: thumb.isEmpty ? nil : thumb
                    )
                )
            }
        }
    }

    /// Merges a peer (or self) avatar URL change into inbox / requests / group member caches.
    func applyFanProfileAvatarChange(_ change: FanProfileAvatarChange) {
        let userId = change.userId
        let nextFull = change.avatarURL.isEmpty ? nil : change.avatarURL
        let nextThumb = change.avatarThumbnailURL

        func previewNeedsUpdate(_ preview: UserPreview) -> Bool {
            guard preview.id == userId else { return false }
            let currentFull = ImageDisplayURL.canonicalStorageURLString(preview.avatarURL)
            let currentThumb = ImageDisplayURL.canonicalStorageURLString(preview.avatarThumbnailURL)
            let desiredFull = ImageDisplayURL.canonicalStorageURLString(nextFull)
            let desiredThumb = ImageDisplayURL.canonicalStorageURLString(nextThumb)
            return currentFull != desiredFull || currentThumb != desiredThumb
        }

        func updatedPreview(_ preview: UserPreview) -> UserPreview {
            preview.replacingAvatars(
                avatarURL: nextFull ?? preview.avatarURL,
                avatarThumbnailURL: nextThumb ?? preview.avatarThumbnailURL
            )
        }

        // Invalidate superseded decoded images before publishing new URLs (versioned paths).
        if let existing = friends.first(where: { !$0.isGroupConversation && $0.preview.id == userId })?.preview
            ?? incomingRequests.first(where: { $0.requester.id == userId })?.requester
            ?? outgoingRequests.first(where: { $0.addressee.id == userId })?.addressee
            ?? groupMemberPreviewByUserId[userId],
           previewNeedsUpdate(existing) {
            FanProfileChangeCenter.invalidateCachedAvatarImages(
                previousAvatarURL: existing.avatarURL,
                previousThumbnailURL: existing.avatarThumbnailURL,
                nextAvatarURL: change.avatarURL,
                nextThumbnailURL: change.avatarThumbnailURL
            )
        }

        var friendsChanged = false
        let nextFriends = friends.map { display -> FriendDisplay in
            if display.isGroupConversation {
                return display
            }
            guard previewNeedsUpdate(display.preview) else { return display }
            friendsChanged = true
            return FriendDisplay(
                id: display.id,
                preview: updatedPreview(display.preview),
                subtitle: display.subtitle,
                lastMessageAt: display.lastMessageAt,
                unreadCount: display.unreadCount,
                isConversationBacked: display.isConversationBacked,
                conversationId: display.conversationId,
                inboxKind: display.inboxKind,
                groupMemberCount: display.groupMemberCount,
                isGroupMuted: display.isGroupMuted,
                pickupGameId: display.pickupGameId,
                fanTeamId: display.fanTeamId
            )
        }
        if friendsChanged {
            friends = nextFriends
        }

        var incomingChanged = false
        let nextIncoming = incomingRequests.map { item -> IncomingRequestDisplay in
            guard previewNeedsUpdate(item.requester) else { return item }
            incomingChanged = true
            return IncomingRequestDisplay(friendship: item.friendship, requester: updatedPreview(item.requester))
        }
        if incomingChanged {
            incomingRequests = nextIncoming
        }

        var outgoingChanged = false
        let nextOutgoing = outgoingRequests.map { item -> OutgoingRequestDisplay in
            guard previewNeedsUpdate(item.addressee) else { return item }
            outgoingChanged = true
            return OutgoingRequestDisplay(friendship: item.friendship, addressee: updatedPreview(item.addressee))
        }
        if outgoingChanged {
            outgoingRequests = nextOutgoing
        }

        if let existing = groupMemberPreviewByUserId[userId], previewNeedsUpdate(existing) {
            groupMemberPreviewByUserId[userId] = updatedPreview(existing)
        }
    }

    private func applyChatPresenceUpdate(userId: UUID, lastSeenAtRaw: String?, source: String) {
        let userLow = userId.uuidString.lowercased()
        let existingVisible = friends.first(where: { $0.preview.id == userId })?.preview.activityStatusVisible
            ?? incomingRequests.first(where: { $0.requester.id == userId })?.requester.activityStatusVisible
            ?? outgoingRequests.first(where: { $0.addressee.id == userId })?.addressee.activityStatusVisible
            ?? true
        guard existingVisible else {
            ActivityStatusDebug.lifecycle("activity visibility disabled", details: "source=\(source)")
            return
        }
        let isOnline = PresenceOnlineStatus.parse(lastSeenAtRaw).map {
            Date().timeIntervalSince($0) <= PresenceOnlineStatus.onlineWindowSeconds
        } ?? false
        ActivityStatusDebug.lifecycle("presence record received", details: "source=\(source) online=\(isOnline)")
        DebugLogGate.debug("[PresenceDebug] userOnline=\(isOnline) userId=\(userLow) source=\(source)")
        DebugLogGate.debug("[PresenceDebug] lastSeen=\(lastSeenAtRaw ?? "nil") userId=\(userLow)")

        var changed = false
        let nextFriends = friends.map { display -> FriendDisplay in
            guard !display.isGroupConversation else { return display }
            guard display.id == userId || display.preview.id == userId else { return display }
            guard display.preview.lastSeenAtRaw != lastSeenAtRaw else { return display }
            changed = true
            return FriendDisplay(
                id: display.id,
                preview: Self.preview(display.preview, replacingLastSeenAtRawWith: lastSeenAtRaw),
                subtitle: display.subtitle,
                lastMessageAt: display.lastMessageAt,
                unreadCount: display.unreadCount,
                isConversationBacked: display.isConversationBacked,
                conversationId: display.conversationId,
                inboxKind: display.inboxKind,
                groupMemberCount: display.groupMemberCount,
                isGroupMuted: display.isGroupMuted,
                pickupGameId: display.pickupGameId,
                fanTeamId: display.fanTeamId
            )
        }
        if changed {
            friends = nextFriends
            DebugLogGate.debug("[PresenceDebug] onlineUsersCount=\(chatPresenceOnlineCount(in: nextFriends))")
#if DEBUG
            if let updated = nextFriends.first(where: { !$0.isGroupConversation && $0.preview.id == userId }) {
                ChatActivityBadgeDebug.log(
                    isRegularFan: !updated.preview.isBusinessIdentity && !updated.preview.isDeleted,
                    lastSeenPresent: updated.preview.lastSeenAtRaw != nil,
                    visibilityAllowed: updated.preview.activityStatusVisible,
                    kind: ActivityStatus.resolve(lastSeenAtRaw: updated.preview.lastSeenAtRaw),
                    source: source == "realtime" ? "realtimeUpdate" : source
                )
            }
#endif
        }

        var incomingChanged = false
        let nextIncoming = incomingRequests.map { item -> IncomingRequestDisplay in
            guard item.requester.id == userId else { return item }
            guard item.requester.lastSeenAtRaw != lastSeenAtRaw else { return item }
            incomingChanged = true
            return IncomingRequestDisplay(
                friendship: item.friendship,
                requester: Self.preview(item.requester, replacingLastSeenAtRawWith: lastSeenAtRaw)
            )
        }
        if incomingChanged {
            incomingRequests = nextIncoming
        }

        var outgoingChanged = false
        let nextOutgoing = outgoingRequests.map { item -> OutgoingRequestDisplay in
            guard item.addressee.id == userId else { return item }
            guard item.addressee.lastSeenAtRaw != lastSeenAtRaw else { return item }
            outgoingChanged = true
            return OutgoingRequestDisplay(
                friendship: item.friendship,
                addressee: Self.preview(item.addressee, replacingLastSeenAtRawWith: lastSeenAtRaw)
            )
        }
        if outgoingChanged {
            outgoingRequests = nextOutgoing
        }
    }

    private func refreshChatPresenceSnapshots(reason: String) async {
        // Key by fan peer user id, not `FriendDisplay.id` (conversation id for
        // conversation-backed rows) — a conversation-id lookup always misses and
        // used to overwrite valid `lastSeenAtRaw` values with nil.
        let ids = Array(
            Set(
                friends
                    .filter { !$0.isGroupConversation && !$0.preview.isDeleted && !$0.preview.isBusinessIdentity }
                    .map(\.preview.id)
            )
        )
        guard !ids.isEmpty else { return }
        do {
            let previews = try await socialIdentityService.fetchUserPreviews(for: ids)
            for id in ids {
                // Skip lookup misses instead of nulling a previously valid timestamp.
                guard let refreshed = previews[id] else { continue }
                applyChatPresenceUpdate(
                    userId: id,
                    lastSeenAtRaw: refreshed.lastSeenAtRaw,
                    source: reason
                )
            }
        } catch {
#if DEBUG
            DebugLogGate.debug("[PresenceDebug] refreshFailed reason=\(reason) error=\(error.localizedDescription)")
#endif
        }
    }

    private func startChatPresenceExpiryTickerIfNeeded() {
        guard chatPresenceExpiryTask == nil else { return }
        chatPresenceExpiryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    return
                }
                self?.expireStaleChatPresence()
            }
        }
    }

    private func expireStaleChatPresence() {
        let now = Date()
        // Re-publish when a row's 2-minute online window just lapsed so green dots /
        // `Online` pills downgrade to a relative label. Never null `lastSeenAtRaw`:
        // the compact pill needs the timestamp to render `5m` / `2h` / `1d`.
        let tickerSlack: TimeInterval = 45 // ticker period (30s) + margin
        let justExpired = friends.contains { display in
            guard !display.isGroupConversation,
                  let lastSeen = PresenceOnlineStatus.parse(display.preview.lastSeenAtRaw) else {
                return false
            }
            let elapsed = now.timeIntervalSince(lastSeen)
            return elapsed > PresenceOnlineStatus.onlineWindowSeconds
                && elapsed <= PresenceOnlineStatus.onlineWindowSeconds + tickerSlack
        }
        guard justExpired else { return }
        ActivityStatusDebug.lifecycle("online window lapsed", details: "source=expiry")
        friends = friends
    }

    private func stopChatPresenceRealtimeListener() async {
        chatPresenceListenTask?.cancel()
        chatPresenceListenTask = nil
        chatPresenceTrackedUserIds = []
        chatPresenceExpiryTask?.cancel()
        chatPresenceExpiryTask = nil
        guard let channel = chatPresenceChannel else { return }
        chatPresenceChannel = nil
        await supabase.removeChannel(channel)
    }

    private func chatPresenceOnlineCount(in displays: [FriendDisplay]? = nil) -> Int {
        (displays ?? friends).filter { $0.preview.isOnlineNow }.count
    }

    private static func preview(
        _ preview: UserPreview,
        replacingLastSeenAtRawWith lastSeenAtRaw: String?
    ) -> UserPreview {
        UserPreview(
            id: preview.id,
            displayName: preview.displayName,
            username: preview.username,
            email: preview.email,
            avatarURL: preview.avatarURL,
            avatarThumbnailURL: preview.avatarThumbnailURL,
            isBusinessAccount: preview.isBusinessAccount,
            isDeleted: preview.isDeleted,
            lastSeenAtRaw: preview.activityStatusVisible ? lastSeenAtRaw : nil,
            activityStatusVisible: preview.activityStatusVisible,
            dmConversationId: preview.dmConversationId,
            businessVenueId: preview.businessVenueId,
            businessVenueBusinessId: preview.businessVenueBusinessId,
            businessVenueBusinessName: preview.businessVenueBusinessName,
            venueScopedThread: preview.venueScopedThread
        )
    }

    private static func chunked<T>(_ values: [T], size: Int) -> [[T]] {
        guard size > 0, !values.isEmpty else { return [] }
        var result: [[T]] = []
        var index = values.startIndex
        while index < values.endIndex {
            let end = values.index(index, offsetBy: size, limitedBy: values.endIndex) ?? values.endIndex
            result.append(Array(values[index..<end]))
            index = end
        }
        return result
    }

    func setDirectChatReadStateVisibility(chatTabVisible: Bool, privateChatUnlocked: Bool) {
        let wasAllowed = chatTabVisibleForDirectReadState && privateChatUnlockedForDirectReadState
        chatTabVisibleForDirectReadState = chatTabVisible
        privateChatUnlockedForDirectReadState = privateChatUnlocked
        let isAllowed = chatTabVisible && privateChatUnlocked
        if !isAllowed {
            clearActiveVisibleConversationId(reason: chatTabVisible ? "private_chat_locked" : "chat_tab_hidden")
        } else if !wasAllowed {
            directChatReadVisibilityVersion += 1
        }
#if DEBUG
        print("[DMReadStateDebug] chatTabVisible=\(chatTabVisible)")
        print("[DMReadStateDebug] privateChatUnlocked=\(privateChatUnlocked)")
#endif
    }

    @discardableResult
    func setActiveVisibleConversationIdIfAllowed(_ conversationId: UUID?, reason: String) -> Bool {
        guard let conversationId else {
#if DEBUG
            DirectChatInvestigation.trace(
                source: "setActiveVisibleConversationIdIfAllowed",
                property: "activeVisibleConversationId"
            )
#endif
            clearActiveVisibleConversationId(reason: "\(reason):missing_conversation")
            return false
        }
        guard chatTabVisibleForDirectReadState && privateChatUnlockedForDirectReadState else {
#if DEBUG
            DirectChatInvestigation.trace(
                source: "setActiveVisibleConversationIdIfAllowed",
                property: "activeVisibleConversationId"
            )
#endif
            clearActiveVisibleConversationId(reason: reason)
            return false
        }
#if DEBUG
        DirectChatInvestigation.trace(
            source: "setActiveVisibleConversationIdIfAllowed",
            property: "activeVisibleConversationId"
        )
#endif
        activeVisibleConversationId = conversationId
        activeVisibleChatKind = "direct"
#if DEBUG
        print("[DMActiveVisibilityDebug] setActiveVisibleConversationId reason=\(reason)")
#endif
        return true
    }

    func clearActiveVisibleConversationId(reason: String) {
        guard activeVisibleConversationId != nil || activeVisibleChatKind != nil else {
#if DEBUG
            if !DirectChatInvestigation.quietConsole {
                print("[DMActiveVisibilityDebug] clearActiveVisibleConversationId reason=\(reason) noop")
            }
#endif
            return
        }
#if DEBUG
        DirectChatInvestigation.trace(
            source: "clearActiveVisibleConversationId",
            property: "activeVisibleConversationId"
        )
        print("[DMActiveVisibilityDebug] clearActiveVisibleConversationId reason=\(reason)")
#endif
        activeVisibleConversationId = nil
        activeVisibleChatKind = nil
    }

    /// Group / pickup thread visibility for foreground push suppression.
    func setActiveVisibleGroupConversationId(_ conversationId: UUID?, reason: String) {
        guard let conversationId else {
            if activeVisibleChatKind == "group" {
                activeVisibleConversationId = nil
                activeVisibleChatKind = nil
            }
            return
        }
        guard chatTabVisibleForDirectReadState && privateChatUnlockedForDirectReadState else {
            if activeVisibleChatKind == "group" {
                activeVisibleConversationId = nil
                activeVisibleChatKind = nil
            }
            return
        }
        activeVisibleConversationId = conversationId
        activeVisibleChatKind = "group"
#if DEBUG
        print("[ChatActiveVisibilityDebug] setActiveVisibleGroupConversationId reason=\(reason)")
#endif
    }

    func clearActiveVisibleGroupConversationId(reason: String) {
        guard activeVisibleChatKind == "group" else { return }
        activeVisibleConversationId = nil
        activeVisibleChatKind = nil
#if DEBUG
        print("[ChatActiveVisibilityDebug] clearActiveVisibleGroupConversationId reason=\(reason)")
#endif
    }

    func isUserViewingChatConversation(chatType: String, conversationId: UUID) -> Bool {
        guard activeVisibleConversationId == conversationId else { return false }
        let normalized = chatType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "group", "pickup":
            return activeVisibleChatKind == "group"
        case "direct", "venue":
            return activeVisibleChatKind == "direct" || activeVisibleChatKind == nil
        default:
            return activeVisibleChatKind == normalized
        }
    }

    func canMarkActiveDirectThreadRead(conversationId: UUID?, reason: String) -> Bool {
#if DEBUG
        print("[DMReadStateDebug] activeVisibleConversationId=\(activeVisibleConversationId?.uuidString.lowercased() ?? "nil")")
#endif
        guard let conversationId, activeVisibleConversationId == conversationId else {
#if DEBUG
            print("[DMReadStateDebug] markReadSuppressed reason=notActiveVisibleThread")
#endif
            return false
        }
#if DEBUG
        print("[DMReadStateDebug] markReadAllowed reason=\(reason)")
#endif
        return true
    }

    func dismissDmInAppNotification() {
        dmInAppNotification = nil
    }

    /// User tapped the in-app DM banner: navigate to Chat + open thread.
    func openConversationFromDmBanner() {
        guard let note = dmInAppNotification else { return }
        dmInAppNotification = nil
        pendingDmOpenPreview = note.senderPreview
    }

    /// True when any chat push deep-link is waiting for Chat tab / subsection / conversation open.
    var hasPendingChatPushDeepLinkRoute: Bool {
        pendingDirectMessageNotificationDeepLink != nil
            || pendingChatMessageNotificationDeepLink != nil
            || pendingFriendRequestNotificationDeepLink != nil
            || pendingFanTeamInvitationNotificationDeepLink != nil
            || pendingDmOpenPreview != nil
            || pendingGroupOpenConversationId != nil
            || pendingOpenFriendRequestsSection
            || pendingOpenMyTeamsInvitations
    }

    /// Remote APNs DM tap: open Chat tab + exact conversation (waits for auth when needed).
    func enqueueDirectMessageNotificationDeepLink(_ request: DirectMessageNotificationDeepLinkRequest) {
#if DEBUG
        PushDeepLinkLog.received(type: "direct", conversation: request.conversationID)
        print(
            "[DMPushRoute] enqueue conversationId=\(request.conversationID.uuidString.lowercased()) " +
            "senderId=\(request.senderID.uuidString.lowercased())"
        )
#endif
        // Newer tap wins; supersede group/friend-request/team-invite UI pending so DM is not starved.
        pendingChatMessageNotificationDeepLink = nil
        pendingFriendRequestNotificationDeepLink = nil
        pendingFanTeamInvitationNotificationDeepLink = nil
        pendingGroupOpenConversationId = nil
        pendingOpenFriendRequestsSection = false
        pendingOpenMyTeamsInvitations = false
        pendingHighlightFanTeamInvitationId = nil
        pendingDirectMessageNotificationDeepLink = request
        deliverPendingDirectMessageNotificationDeepLinkIfReady(reason: "enqueue")
    }

    func deliverPendingDirectMessageNotificationDeepLinkIfReady(reason: String) {
        guard let request = pendingDirectMessageNotificationDeepLink else { return }
        guard currentUserAuthId != nil else {
#if DEBUG
            PushDeepLinkLog.waiting(reason: "auth")
            print("[DMPushRoute] defer until auth reason=\(reason)")
#endif
            return
        }
        // Never open a DM as the sender's own identity on the recipient device.
        if currentUserAuthId == request.senderID {
#if DEBUG
            print("[DMPushRoute] ignore: current user is sender")
#endif
            pendingDirectMessageNotificationDeepLink = nil
            return
        }

        // Validate membership before surfacing UI route (wrong-account / stale token safety).
        let requestID = request.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.pendingDirectMessageNotificationDeepLink?.id == requestID else { return }
            let allowed = await self.currentUserParticipatesInDirectConversation(request.conversationID)
            guard self.pendingDirectMessageNotificationDeepLink?.id == requestID else { return }
            guard allowed else {
#if DEBUG
                PushDeepLinkLog.failed(reason: "not_dm_participant")
                print("[DMPushRoute] reject not participant conversationId=\(request.conversationID.uuidString.lowercased())")
#endif
                self.pendingDirectMessageNotificationDeepLink = nil
                self.pendingDmOpenPreview = nil
                self.pendingOpenHighlightMessageId = nil
                return
            }

            if let messageId = request.messageID {
                self.pendingOpenHighlightMessageId = messageId
            }

            let preview = UserPreview(
                id: request.senderID,
                displayName: request.senderDisplayName,
                avatarURL: nil,
                dmConversationId: request.conversationID,
                businessVenueId: request.venueID,
                businessVenueBusinessId: request.businessID,
                venueScopedThread: request.venueID != nil
            )
            if self.pendingDmOpenPreview?.dmConversationId != request.conversationID
                || self.pendingDmOpenPreview?.id != request.senderID {
#if DEBUG
                PushDeepLinkLog.queued(type: "direct", conversation: request.conversationID)
                print(
                    "[DMPushRoute] deliver pendingDmOpenPreview conversationId=\(request.conversationID.uuidString.lowercased()) reason=\(reason)"
                )
#endif
                self.pendingDmOpenPreview = preview
            }
        }
    }

    /// Call only after Chat UI has accepted the DM navigation route (or determined it is invalid).
    func acknowledgeDirectMessagePushDeepLinkOpened(conversationId: UUID) {
        if pendingDirectMessageNotificationDeepLink?.conversationID == conversationId {
            pendingDirectMessageNotificationDeepLink = nil
        }
        if pendingDmOpenPreview?.dmConversationId == conversationId {
            pendingDmOpenPreview = nil
        }
#if DEBUG
        PushDeepLinkLog.completed(conversation: conversationId, kind: "direct")
#endif
    }

    /// Remote APNs friend-request tap: open Chat → Requests after auth is ready.
    func enqueueFriendRequestNotificationDeepLink(_ request: FriendRequestNotificationDeepLinkRequest) {
#if DEBUG
        PushDeepLinkLog.received(type: "friend_request", conversation: nil)
        print(
            "[FriendRequestPushRoute] enqueue requestId=\(request.requestID?.uuidString.lowercased() ?? "nil") " +
            "requesterId=\(request.requesterID?.uuidString.lowercased() ?? "nil")"
        )
#endif
        // Friend-request taps must not be overridden by a stale DM/group open.
        pendingDirectMessageNotificationDeepLink = nil
        pendingChatMessageNotificationDeepLink = nil
        pendingFanTeamInvitationNotificationDeepLink = nil
        pendingDmOpenPreview = nil
        pendingGroupOpenConversationId = nil
        pendingOpenMyTeamsInvitations = false
        pendingHighlightFanTeamInvitationId = nil
        pendingFriendRequestNotificationDeepLink = request
        deliverPendingFriendRequestNotificationDeepLinkIfReady(reason: "enqueue")
    }

    func deliverPendingFriendRequestNotificationDeepLinkIfReady(reason: String) {
        guard let request = pendingFriendRequestNotificationDeepLink else { return }
        guard currentUserAuthId != nil else {
#if DEBUG
            PushDeepLinkLog.waiting(reason: "auth")
            print("[FriendRequestPushRoute] defer until auth reason=\(reason)")
#endif
            return
        }
        // Never open Requests as the requester on their own device.
        if let requesterID = request.requesterID, currentUserAuthId == requesterID {
#if DEBUG
            print("[FriendRequestPushRoute] ignore: current user is requester")
#endif
            pendingFriendRequestNotificationDeepLink = nil
            return
        }

        // Keep APNs request until FriendsTab selects Requests.
        if !pendingOpenFriendRequestsSection {
#if DEBUG
            PushDeepLinkLog.queued(type: "friend_request", conversation: nil)
            print("[FriendRequestPushRoute] deliver pendingOpenFriendRequestsSection reason=\(reason)")
#endif
            pendingOpenFriendRequestsSection = true
        }
        requestBadgeRecalculation(reason: "friendRequestPushDeepLink", includeInboxSummaries: false)
        Task { [weak self] in
            await self?.refreshFriendRequestListsOnly()
        }
    }

    func acknowledgeFriendRequestPushDeepLinkOpened() {
        pendingFriendRequestNotificationDeepLink = nil
        pendingOpenFriendRequestsSection = false
#if DEBUG
        PushDeepLinkLog.completed(conversation: nil, kind: "friend_request")
#endif
    }

    /// Remote APNs Fan Team invitation tap: open Teams tab after auth is ready.
    func enqueueFanTeamInvitationNotificationDeepLink(_ request: FanTeamInvitationNotificationDeepLinkRequest) {
#if DEBUG
        PushDeepLinkLog.received(type: "team_invitation", conversation: nil)
        print(
            "[FanTeamInvitationPushRoute] enqueue invitationId=\(request.invitationID?.uuidString.lowercased() ?? "nil") " +
            "teamId=\(request.teamID?.uuidString.lowercased() ?? "nil") " +
            "invitedBy=\(request.invitedByUserID?.uuidString.lowercased() ?? "nil")"
        )
#endif
        pendingDirectMessageNotificationDeepLink = nil
        pendingChatMessageNotificationDeepLink = nil
        pendingFriendRequestNotificationDeepLink = nil
        pendingDmOpenPreview = nil
        pendingGroupOpenConversationId = nil
        pendingOpenFriendRequestsSection = false
        pendingFanTeamInvitationNotificationDeepLink = request
        deliverPendingFanTeamInvitationNotificationDeepLinkIfReady(reason: "enqueue")
    }

    func deliverPendingFanTeamInvitationNotificationDeepLinkIfReady(reason: String) {
        guard let request = pendingFanTeamInvitationNotificationDeepLink else { return }
        guard currentUserAuthId != nil else {
#if DEBUG
            PushDeepLinkLog.waiting(reason: "auth")
            print("[FanTeamInvitationPushRoute] defer until auth reason=\(reason)")
#endif
            return
        }
        // Never open My Teams invitations as the inviter on their own device.
        if let invitedBy = request.invitedByUserID, currentUserAuthId == invitedBy {
#if DEBUG
            print("[FanTeamInvitationPushRoute] ignore: current user is inviter")
#endif
            pendingFanTeamInvitationNotificationDeepLink = nil
            pendingHighlightFanTeamInvitationId = nil
            return
        }

        if let invitationID = request.invitationID {
            pendingHighlightFanTeamInvitationId = invitationID
        }

        if !pendingOpenMyTeamsInvitations {
#if DEBUG
            PushDeepLinkLog.queued(type: "team_invitation", conversation: nil)
            print("[FanTeamInvitationPushRoute] deliver pendingOpenMyTeamsInvitations reason=\(reason)")
#endif
            pendingOpenMyTeamsInvitations = true
        }
        Task { await refreshPendingFanTeamInvitationCount(force: true) }
    }

    func acknowledgeFanTeamInvitationPushDeepLinkOpened() {
        pendingFanTeamInvitationNotificationDeepLink = nil
        pendingOpenMyTeamsInvitations = false
        // Keep `pendingHighlightFanTeamInvitationId` until My Teams consumes it.
#if DEBUG
        PushDeepLinkLog.completed(conversation: nil, kind: "team_invitation")
#endif
    }

    /// Returns and clears the invitation id to highlight in My Teams (fail-soft if already gone).
    func consumePendingHighlightFanTeamInvitationId() -> UUID? {
        let id = pendingHighlightFanTeamInvitationId
        pendingHighlightFanTeamInvitationId = nil
        return id
    }

    /// Remote APNs Team-deleted tap: open Teams tab (never a dead Team Detail).
    func enqueueFanTeamDeletedNotificationDeepLink(_ request: FanTeamDeletedNotificationDeepLinkRequest) {
#if DEBUG
        PushDeepLinkLog.received(type: "team_deleted", conversation: nil)
        print(
            "[FanTeamDeletedPushRoute] enqueue teamId=\(request.teamID?.uuidString.lowercased() ?? "nil") " +
            "eventId=\(request.eventID?.uuidString.lowercased() ?? "nil")"
        )
#endif
        pendingDirectMessageNotificationDeepLink = nil
        pendingChatMessageNotificationDeepLink = nil
        pendingFriendRequestNotificationDeepLink = nil
        pendingFanTeamInvitationNotificationDeepLink = nil
        pendingDmOpenPreview = nil
        pendingGroupOpenConversationId = nil
        pendingOpenFriendRequestsSection = false
        pendingHighlightFanTeamInvitationId = nil
        pendingOpenFanTeamRosterTeamId = nil
        // Reuse My Teams section open (no invitation highlight).
        if !pendingOpenMyTeamsInvitations {
            pendingOpenMyTeamsInvitations = true
        }
#if DEBUG
        PushDeepLinkLog.queued(type: "team_deleted", conversation: nil)
#endif
        _ = request
    }

    /// Remote APNs member_left_team tap: open Teams → Team Detail → Roster.
    func enqueueFanTeamMemberLeftNotificationDeepLink(_ request: FanTeamMemberLeftNotificationDeepLinkRequest) {
#if DEBUG
        PushDeepLinkLog.received(type: "member_left_team", conversation: nil)
        print(
            "[FanTeamMemberLeaveDebug] enqueue teamId=\(request.teamID?.uuidString.lowercased() ?? "nil") " +
            "eventId=\(request.eventID?.uuidString.lowercased() ?? "nil") " +
            "leftUserId=\(request.leftUserID?.uuidString.lowercased() ?? "nil")"
        )
#endif
        pendingDirectMessageNotificationDeepLink = nil
        pendingChatMessageNotificationDeepLink = nil
        pendingFriendRequestNotificationDeepLink = nil
        pendingFanTeamInvitationNotificationDeepLink = nil
        pendingDmOpenPreview = nil
        pendingGroupOpenConversationId = nil
        pendingOpenFriendRequestsSection = false
        pendingHighlightFanTeamInvitationId = nil
        pendingOpenFanTeamRosterTeamId = request.teamID
        if !pendingOpenMyTeamsInvitations {
            pendingOpenMyTeamsInvitations = true
        }
#if DEBUG
        PushDeepLinkLog.queued(type: "member_left_team", conversation: nil)
#endif
    }

    func consumePendingOpenFanTeamRosterTeamId() -> UUID? {
        let id = pendingOpenFanTeamRosterTeamId
        pendingOpenFanTeamRosterTeamId = nil
        return id
    }

    /// Remote APNs member_change tap: Team Detail/Roster, or My Teams fallback after removal.
    func enqueueFanTeamMemberChangeNotificationDeepLink(
        _ request: FanTeamMemberChangeNotificationDeepLinkRequest
    ) {
#if DEBUG
        PushDeepLinkLog.received(type: "member_change", conversation: nil)
        print(
            "[FanTeamMemberChangeDebug] enqueue kind=\(request.kind ?? "nil") " +
            "teamId=\(request.teamID?.uuidString.lowercased() ?? "nil") " +
            "pickupGameId=\(request.pickupGameID?.uuidString.lowercased() ?? "nil")"
        )
#endif
        pendingDirectMessageNotificationDeepLink = nil
        pendingChatMessageNotificationDeepLink = nil
        pendingFriendRequestNotificationDeepLink = nil
        pendingFanTeamInvitationNotificationDeepLink = nil
        pendingDmOpenPreview = nil
        pendingGroupOpenConversationId = nil
        pendingOpenFriendRequestsSection = false
        pendingHighlightFanTeamInvitationId = nil

        let kind = (request.kind ?? "").lowercased()
        if kind == "removed_from_team" || kind == "team_admin_removed" {
            // Safe fallback — Team Detail may no longer be accessible.
            pendingOpenFanTeamRosterTeamId = nil
            pendingHighlightFanTeamInvitationId = nil
            if !pendingOpenMyTeamsInvitations {
                pendingOpenMyTeamsInvitations = true
            }
        } else {
            pendingOpenFanTeamRosterTeamId = request.teamID
            if !pendingOpenMyTeamsInvitations {
                pendingOpenMyTeamsInvitations = true
            }
        }
#if DEBUG
        PushDeepLinkLog.queued(type: "member_change", conversation: nil)
#endif
    }

    /// Remote APNs unified chat_message tap: open Chat → exact DM or group/pickup conversation.
    func enqueueChatMessageNotificationDeepLink(_ request: ChatMessageNotificationDeepLinkRequest) {
#if DEBUG
        PushDeepLinkLog.received(type: request.chatType, conversation: request.conversationID)
        print(
            "[ChatPushRoute] enqueue chatType=\(request.chatType) " +
            "conversationId=\(request.conversationID.uuidString.lowercased())"
        )
#endif
        pendingDirectMessageNotificationDeepLink = nil
        pendingFriendRequestNotificationDeepLink = nil
        pendingFanTeamInvitationNotificationDeepLink = nil
        pendingOpenFriendRequestsSection = false
        pendingOpenMyTeamsInvitations = false
        pendingHighlightFanTeamInvitationId = nil
        pendingChatMessageNotificationDeepLink = request
        deliverPendingChatMessageNotificationDeepLinkIfReady(reason: "enqueue")
    }

    func deliverPendingChatMessageNotificationDeepLinkIfReady(reason: String) {
        guard let request = pendingChatMessageNotificationDeepLink else { return }
        guard currentUserAuthId != nil else {
#if DEBUG
            PushDeepLinkLog.waiting(reason: "auth")
            print("[ChatPushRoute] defer until auth reason=\(reason)")
#endif
            return
        }
        if let senderID = request.senderID, currentUserAuthId == senderID {
#if DEBUG
            print("[ChatPushRoute] ignore: current user is sender")
#endif
            pendingChatMessageNotificationDeepLink = nil
            return
        }

        let requestID = request.id
        let chatType = request.chatType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.pendingChatMessageNotificationDeepLink?.id == requestID else { return }

            let allowed: Bool
            switch chatType {
            case "group", "pickup":
                allowed = await self.currentUserParticipatesInGroupConversation(request.conversationID)
            default:
                allowed = await self.currentUserParticipatesInDirectConversation(request.conversationID)
            }
            guard self.pendingChatMessageNotificationDeepLink?.id == requestID else { return }
            guard allowed else {
#if DEBUG
                PushDeepLinkLog.failed(reason: "not_chat_participant")
                print(
                    "[ChatPushRoute] reject not participant chatType=\(chatType) " +
                    "conversationId=\(request.conversationID.uuidString.lowercased())"
                )
#endif
                self.pendingChatMessageNotificationDeepLink = nil
                self.pendingGroupOpenConversationId = nil
                self.pendingDmOpenPreview = nil
                self.pendingOpenHighlightMessageId = nil
                return
            }

            if let messageId = request.messageID {
                self.pendingOpenHighlightMessageId = messageId
            }

            switch chatType {
            case "group", "pickup":
                if self.pendingGroupOpenConversationId != request.conversationID {
#if DEBUG
                    PushDeepLinkLog.queued(type: chatType, conversation: request.conversationID)
                    print(
                        "[ChatPushRoute] deliver pendingGroupOpenConversationId " +
                        "conversationId=\(request.conversationID.uuidString.lowercased()) reason=\(reason)"
                    )
#endif
                    self.pendingDmOpenPreview = nil
                    self.pendingGroupOpenConversationId = request.conversationID
                }
            default:
                let senderID = request.senderID ?? UUID()
                let isVenue = chatType == "venue" || request.venueID != nil || request.businessID != nil
                let preview = UserPreview(
                    id: senderID,
                    displayName: request.senderDisplayName,
                    avatarURL: nil,
                    dmConversationId: request.conversationID,
                    businessVenueId: request.venueID,
                    businessVenueBusinessId: request.businessID,
                    businessVenueBusinessName: isVenue ? request.conversationTitle : nil,
                    venueScopedThread: isVenue
                )
                if self.pendingDmOpenPreview?.dmConversationId != request.conversationID {
#if DEBUG
                    PushDeepLinkLog.queued(type: isVenue ? "venue" : "direct", conversation: request.conversationID)
                    print(
                        "[ChatPushRoute] deliver pendingDmOpenPreview " +
                        "conversationId=\(request.conversationID.uuidString.lowercased()) reason=\(reason)"
                    )
#endif
                    self.pendingGroupOpenConversationId = nil
                    self.pendingDmOpenPreview = preview
                }
            }
        }
    }

    /// RLS-backed membership check: row visible ⇒ current user is a DM participant.
    func currentUserParticipatesInDirectConversation(_ conversationId: UUID) async -> Bool {
        struct Row: Decodable { let id: UUID }
        do {
            let rows: [Row] = try await supabase
                .from("direct_conversations")
                .select("id")
                .eq("id", value: conversationId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value
            return !rows.isEmpty
        } catch {
#if DEBUG
            print("[PushDeepLink] dm_participant_check_failed error=\(error.localizedDescription)")
#endif
            return false
        }
    }

    /// Active group/pickup membership for the signed-in user.
    func currentUserParticipatesInGroupConversation(_ conversationId: UUID) async -> Bool {
        guard let me = currentUserAuthId else { return false }
        struct Row: Decodable { let conversation_id: UUID }
        do {
            let rows: [Row] = try await supabase
                .from("group_conversation_members")
                .select("conversation_id")
                .eq("conversation_id", value: conversationId.uuidString.lowercased())
                .eq("user_id", value: me.uuidString.lowercased())
                .is("left_at", value: nil)
                .limit(1)
                .execute()
                .value
            return !rows.isEmpty
        } catch {
#if DEBUG
            print("[PushDeepLink] group_participant_check_failed error=\(error.localizedDescription)")
#endif
            return false
        }
    }

    func acknowledgeGroupPushDeepLinkOpened(conversationId: UUID) {
        if pendingChatMessageNotificationDeepLink?.conversationID == conversationId {
            pendingChatMessageNotificationDeepLink = nil
        }
        if pendingGroupOpenConversationId == conversationId {
            pendingGroupOpenConversationId = nil
        }
#if DEBUG
        PushDeepLinkLog.completed(conversation: conversationId, kind: "group")
#endif
    }

    func acknowledgeChatMessageDirectPushDeepLinkOpened(conversationId: UUID) {
        if pendingChatMessageNotificationDeepLink?.conversationID == conversationId {
            pendingChatMessageNotificationDeepLink = nil
        }
        acknowledgeDirectMessagePushDeepLinkOpened(conversationId: conversationId)
    }

    func requestBadgeRecalculation(
        reason: String,
        includeInboxSummaries: Bool = false,
        delayNanoseconds: UInt64 = 120_000_000
    ) {
#if DEBUG
        print("[BadgeSyncDebug] recalculation requested reason=\(reason)")
        print("[BadgeSyncDebug] includeInboxSummaries=\(includeInboxSummaries)")
#endif
        if badgeRecalculationTask != nil {
            if includeInboxSummaries && !badgeRecalculationNeedsInboxSummaries {
                badgeRecalculationNeedsInboxSummaries = true
#if DEBUG
                print("[BadgeSyncDebug] upgraded pending refresh reason=\(reason)")
                print("[BadgeSyncDebug] includeInboxSummaries=true")
#endif
            }
#if DEBUG
            print("[BadgeSyncDebug] skipped duplicate refresh")
#endif
            return
        }

        badgeRecalculationNeedsInboxSummaries = includeInboxSummaries
        badgeRecalculationTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                await MainActor.run {
                    if self?.badgeRecalculationTask != nil {
                        self?.badgeRecalculationTask = nil
                        self?.badgeRecalculationNeedsInboxSummaries = false
                    }
                }
                return
            }

            guard let self, !Task.isCancelled else { return }
            let shouldRefreshInbox = self.badgeRecalculationNeedsInboxSummaries
            self.badgeRecalculationNeedsInboxSummaries = false
            if shouldRefreshInbox {
                await self.refreshInboxSummaries()
            } else {
                await self.refreshUnreadDirectMessageCount(force: true)
            }
            self.badgeRecalculationTask = nil
        }
    }

    func requestForegroundBadgeRefresh() {
#if DEBUG
        print("[BadgeSyncDebug] foreground refresh")
#endif
        requestBadgeRecalculation(reason: "foreground", includeInboxSummaries: true)
    }

    /// Legacy hook from the Chat tab: **only starts** listeners when enabled; disabling is a no-op so
    /// friend requests + inbox badges keep updating while on other tabs or inside a DM thread.
    func setChatTabRealtimeEnabled(_ enabled: Bool) {
        guard enabled else { return }
        Task { await ensureSignedInSocialRealtimeIfNeeded() }
    }

    /// Starts/stops a lightweight in-app inbox listener for unread badge refresh.
    /// Call this from the Chat tab view layer when the Chat tab becomes visible or hidden.
    func setInboxRealtimeEnabled(_ enabled: Bool) {
        guard enabled else { return }
        Task { await ensureSignedInSocialRealtimeIfNeeded() }
    }

    private func startInboxRealtimeListenerIfNeeded() {
        guard requiresSignIn == false else { return }
        guard inboxListenTask == nil, inboxChannel == nil else {
            AppPerfDebug.realtimeRestarted(false, source: "inboxListenerAlreadyActive")
#if DEBUG
            print("[RealtimeLifecycle] duplicate prevented (inbox listener already active)")
#endif
#if DEBUG
            print("[RealtimeSubscriptionDebug] duplicatePrevented vm=\(instanceDebugID) taskActive=\(inboxListenTask != nil) channelActive=\(inboxChannel != nil)")
#endif
            return
        }
#if DEBUG
        print("[RealtimeLifecycle] starting inbox listener")
#endif
#if DEBUG
        print("[RealtimeSubscriptionDebug] startingInbox vm=\(instanceDebugID)")
        print("[MainActorDebug] startInboxRealtimeListenerIfNeeded actor=MainActor")
#endif
        inboxListenTask = Task { [weak self] in
            guard let self else { return }
            await self.runInboxRealtimeListenerLoop()
        }
    }

    private func removeInboxRealtimeChannelOnly() async {
        if let ch = inboxChannel {
            await supabase.removeChannel(ch)
        }
        inboxChannel = nil
        inboxRealtimeBoundUserId = nil
        inboxRealtimeUsesConversationFilter = false
    }

    private func runInboxRealtimeListenerLoop() async {
        // Ensure we have a current user id; ignore if not signed in.
        let me: UUID
        if let cached = currentUserAuthId {
            me = cached
        } else if let fetched = try? await directChatService.currentUserId() {
            me = fetched
        } else {
            return
        }

        defer {
            inboxUnreadDebounceTask?.cancel()
            inboxUnreadDebounceTask = nil
            inboxMissingPeerReconcileTask?.cancel()
            inboxMissingPeerReconcileTask = nil
            inboxListenTask = nil
        }

        let identity = dmRealtimeIdentitySnapshot(fallbackAuthUserId: me)
        let channelName = "dm-inbox-\(me.uuidString.lowercased())"
        let channel = supabase.channel(channelName)
        inboxChannel = channel
        let subscribeStartedAt = CFAbsoluteTimeGetCurrent()

        let readStateChanges = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "conversation_read_state"
        )

        let inserts = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "direct_messages"
        )
        inboxRealtimeUsesConversationFilter = false
#if DEBUG
        print("[ChatRealtime] inbox scope: postgresChange unfiltered; user-visible events rely on RLS.")
        print("[RealtimeSubscriptionDebug] inboxFilter=none reason=avoid_stale_conversation_snapshot vm=\(instanceDebugID)")
        print("[RealtimePublicationVerify] expected table=conversation_read_state publication=supabase_realtime migration=20260731_0030")
        print("[RealtimeChainDebug] subscribeRequested table=conversation_read_state channel=\(channel.topic) filter=none")
        RealtimeHealthDiagnostics.log("channelName=\(channel.topic)")
        RealtimeHealthDiagnostics.log("subscribeStart=true channelName=\(channel.topic)")
#endif
        DMRealtimeDiagnostics.debug("subscribeStarted=true accountType=\(identity.accountType)")
        DMRealtimeDiagnostics.debug("authUserId=\(identity.authUserIdLogValue)")
        DMRealtimeDiagnostics.debug("businessId=\(identity.businessIdLogValue)")
        DMRealtimeDiagnostics.debug("channelName=\(channel.topic)")
        DMRealtimeDiagnostics.debug("listeningForSender=\(identity.listeningLogValue)")
        DMRealtimeDiagnostics.debug("listeningForRecipient=\(identity.listeningLogValue)")

        var shouldRestartChatRealtime = false
        do {
            try await channel.subscribeWithError()
            inboxRealtimeBoundUserId = me
            DMRealtimeDiagnostics.debug("channelStatus=\(String(describing: channel.status)) channelName=\(channel.topic)")
#if DEBUG
            print("[DMRealtime] inbox subscribed channel=dm-inbox-\(me.uuidString.lowercased())")
#endif
#if DEBUG
            print("[RealtimeSubscriptionDebug] inboxSubscribed vm=\(instanceDebugID) user=\(me.uuidString.lowercased()) filtered=\(inboxRealtimeUsesConversationFilter)")
            print("[DMRealtimeLatencyDebug] realtimeSubscribed conversationId=inbox channel=\(channel.topic)")
            print("[RealtimeChainDebug] subscribeReady table=conversation_read_state channel=\(channel.topic)")
            RealtimeHealthDiagnostics.log("subscribeReady elapsedMs=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - subscribeStartedAt) * 1000)) channelName=\(channel.topic)")
#endif
#if DEBUG
            DMRealtimeDiagnostics.log(
                "phase=inbox_realtime_subscribe_ready channel=dm-inbox-\(me.uuidString.lowercased()) filtered=\(inboxRealtimeUsesConversationFilter)"
            )
#endif

            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    await self?.consumeConversationReadStateRealtime(readStateChanges)
                }
                group.addTask { [weak self] in
                    await self?.consumeInboxDirectMessageInserts(inserts, me: me)
                }
            }
        } catch is CancellationError {
#if DEBUG
            print("[DMRealtime] inbox listener cancelled")
#endif
        } catch {
            DMRealtimeDiagnostics.debug("channelError=\(error.localizedDescription) channelName=\(channel.topic)")
#if DEBUG
            print("[DMRealtime] inbox listener error: \(error)")
#endif
#if DEBUG
            print("[RealtimeChainDebug] subscribeFailed table=conversation_read_state error=\(error.localizedDescription)")
            RealtimeHealthDiagnostics.log("subscribeError=\(error.localizedDescription) channelName=\(channel.topic)")
#endif
            shouldRestartChatRealtime = realtimeErrorIndicatesGlobalRetryExhausted(error)
        }

        await removeInboxRealtimeChannelOnly()
        if shouldRestartChatRealtime {
            Task { @MainActor [weak self] in
                await Task.yield()
                await self?.forceRestartChatRealtimeAfterGlobalRetryExhausted(reason: "inboxMaxRetry")
            }
        }
        // Allow ``startInboxRealtimeListenerIfNeeded()`` after disconnect; do not call ``stopInboxRealtimeListener()`` here
        // (that would deadlock while awaiting this same task).
    }

    /// Read cursor changes (mark-read) do not emit `direct_messages` rows; listen for lightweight RPC recount instead of reloading the inbox.
    private func consumeConversationReadStateRealtime(_ stream: AsyncStream<AnyAction>) async {
        for await action in stream {
            if Task.isCancelled { break }
            switch action {
            case .insert, .update, .delete:
                #if DEBUG
                let eventType: String
                switch action {
                case .insert: eventType = "insert"
                case .update: eventType = "update"
                case .delete: eventType = "delete"
                }
                print("[RealtimeChainDebug] eventReceived table=conversation_read_state eventType=\(eventType) rowId=unknown")
                print("[RealtimeChainDebug] eventMatchedCurrentView table=conversation_read_state matched=unknown reason=unfilteredBadgeListenerReliesOnRLS")
                #endif
                scheduleDebouncedUnreadDirectMessageRPCRefresh()
            }
        }
    }

    private func consumeInboxDirectMessageInserts(_ inserts: AsyncStream<InsertAction>, me: UUID) async {
        for await insertion in inserts {
            if Task.isCancelled { break }
            do {
                try Task.checkCancellation()
            } catch {
                break
            }
            let row: DirectMessageRow
            do {
                row = try insertion.decodeRecord(as: DirectMessageRow.self, decoder: JSONDecoder())
            } catch {
                continue
            }

            if row.deleted_at != nil {
                DMRealtimeDiagnostics.debug("ignoredReason=deleted messageId=\(row.id.uuidString.lowercased())")
                continue
            }
            if row.is_deleted == true {
                DMRealtimeDiagnostics.debug("ignoredReason=deleted messageId=\(row.id.uuidString.lowercased())")
                continue
            }
            let identity = dmRealtimeIdentitySnapshot(fallbackAuthUserId: me)
            DMRealtimeDiagnostics.debug(
                "insertReceived messageId=\(row.id.uuidString.lowercased()) senderId=\(row.sender_id.uuidString.lowercased()) conversationId=\(row.conversation_id?.uuidString.lowercased() ?? "nil")"
            )
            if isCurrentDMRealtimeIdentity(row.sender_id, fallbackAuthUserId: me) {
                DMRealtimeDiagnostics.debug(
                    "ignoredReason=selfEcho messageId=\(row.id.uuidString.lowercased()) accountType=\(identity.accountType)"
                )
#if DEBUG
                print("[ChatReappear] ignored reason=selfSend")
#endif
                continue
            }
#if DEBUG
            if let cid = row.conversation_id {
                dmLatencyInboxEventStartByConversationID[cid] = CFAbsoluteTimeGetCurrent()
            }
            print("[DMRealtimeLatencyDebug] realtimeInsertReceived conversationId=\(row.conversation_id?.uuidString.lowercased() ?? "nil") messageId=\(row.id.uuidString.lowercased()) elapsedSinceSendMs=nil")
            RealtimeHealthDiagnostics.log("eventReceived table=direct_messages id=\(row.id.uuidString.lowercased()) elapsedSinceInsertMs=nil")
            DMRealtimeDiagnostics.log(
                "phase=receiver_inbox_realtime_callback_fired messageId=\(row.id.uuidString.lowercased()) sender=\(row.sender_id.uuidString.lowercased()) conversation=\(row.conversation_id?.uuidString.lowercased() ?? "nil")"
            )
#endif
            if isEitherDirectionBlocked(with: row.sender_id) {
                DMRealtimeDiagnostics.debug("ignoredReason=blocked messageId=\(row.id.uuidString.lowercased())")
                #if DEBUG
                print("[ChatRealtime] inbox INSERT id=\(row.id) sender=\(row.sender_id) → skip(blocked)")
                print("[ChatReappear] ignored reason=blocked")
                #endif
                continue
            }

            #if DEBUG
            print("[ChatRealtime] inbox INSERT id=\(row.id) conv=\(row.conversation_id?.uuidString ?? "nil") sender=\(row.sender_id)")
            #endif

            let patched = await applyRealtimeIncomingPeerMessage(row)
            DMRealtimeDiagnostics.debug(
                "insertMatchedThread=\(patched) messageId=\(row.id.uuidString.lowercased()) conversationId=\(row.conversation_id?.uuidString.lowercased() ?? "nil")"
            )
            maybeEmitDmInAppNotification(row: row, me: me)
            if patched {
                DMRealtimeDiagnostics.debug("ignoredReason=none messageId=\(row.id.uuidString.lowercased())")
#if DEBUG
                print("[UnreadStateDebug] incomingInsert source=localRealtimePatch action=keptLocalUnread")
#endif
            } else {
#if DEBUG
                print("[UnreadStateDebug] incomingInsert source=missingLocalRow action=serverRecountAndInboxReconcile")
#endif
                scheduleDebouncedUnreadDirectMessageRPCRefresh()
            }
        }
    }

    /// Called from ``DirectChatPresenter`` after flushes read cursor for an incoming peer message (no full inbox fetch).
    func notifyIncomingDmHandledInActiveThread() {
        requestBadgeRecalculation(reason: "active_thread_incoming_handled")
    }

    /// Coalesces server unread recount RPC after local patches (low latency).
    private func scheduleDebouncedUnreadDirectMessageRPCRefresh() {
        #if DEBUG
        print("[RealtimeChainDebug] refreshQueued table=conversation_read_state reason=debounced_unread_rpc")
        #endif
        requestBadgeRecalculation(reason: "debounced_unread_rpc", delayNanoseconds: 110_000_000)
    }

    private func isUserViewingThisDmThread(conversationId: UUID?, peerSenderId _: UUID) -> Bool {
        guard let conversationId else { return false }
        return activeVisibleConversationId == conversationId
    }

    private func maybeEmitDmInAppNotification(row: DirectMessageRow, me: UUID) {
        guard !isCurrentDMRealtimeIdentity(row.sender_id, fallbackAuthUserId: me) else { return }
        guard !isUserViewingThisDmThread(conversationId: row.conversation_id, peerSenderId: row.sender_id) else {
#if DEBUG
            print("[DMInAppNotificationDebug] conversationId=\(row.conversation_id?.uuidString ?? "nil")")
            print("[DMInAppNotificationDebug] sender=\(row.sender_id.uuidString)")
            print("[DMInAppNotificationDebug] shouldShow=false")
            print("[DMInAppNotificationDebug] reason=thread_already_open")
#endif
            return
        }
        let previewFromFriendRow = friends.first(where: {
            if let cid = row.conversation_id {
                return $0.conversationId == cid || $0.id == cid
            }
            return $0.id == row.sender_id || $0.preview.id == row.sender_id
        })?.preview
        let senderPreview = previewFromFriendRow
            ?? deletedUserPreview(userId: row.sender_id)
        let trimmed = row.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let previewSource = FanProfileShareMessage.inboxPreview(from: trimmed)
            ?? PickupGameShareMessage.inboxPreview(from: trimmed)
            ?? ProGameShareMessage.inboxPreview(from: trimmed)
            ?? VenueShareMessage.inboxPreview(from: trimmed)
            ?? ChatLocationShareMessage.inboxPreview(from: trimmed)
            ?? ChatLiveLocationShareMessage.inboxPreview(from: trimmed)
            ?? ChatOnMyWayMessage.inboxPreview(from: trimmed)
            ?? PickupGamePollMessage.inboxPreview(from: trimmed)
            ?? trimmed
        let snippet = previewSource.isEmpty ? "New message" : String(previewSource.prefix(120))
        dmInAppNotification = DmInAppNotificationPayload(
            id: row.id,
            conversationId: row.conversation_id,
            senderPreview: senderPreview,
            bodyPreview: snippet
        )
#if DEBUG
        print("[DMInAppNotificationDebug] conversationId=\(row.conversation_id?.uuidString ?? "nil")")
        print("[DMInAppNotificationDebug] sender=\(senderPreview.displayName)")
        print("[DMInAppNotificationDebug] shouldShow=true")
        print("[DMInAppNotificationDebug] reason=incoming_peer_dm_background")
#endif
    }

    /// Zeros this peer’s row in the local inbox immediately after opening a thread / mark-read so the tab badge drops before summaries refetch.
    func markDirectInboxReadLocally(
        peerUserId: UUID,
        conversationId: UUID? = nil,
        scheduleBadgeRecalculation: Bool = true
    ) {
#if DEBUG
        print("[BadgeSyncDebug] marked read conversationId=\(conversationId?.uuidString.lowercased() ?? "nil")")
#endif
        guard let idx = friends.firstIndex(where: { display in
            if let conversationId {
                return display.conversationId == conversationId || display.id == conversationId
            }
            return display.id == peerUserId || display.preview.id == peerUserId
        }) else {
            if scheduleBadgeRecalculation {
                requestBadgeRecalculation(reason: "marked_read_missing_row", includeInboxSummaries: true)
            }
            return
        }
        let old = friends[idx]
        guard old.unreadCount > 0 else {
            if scheduleBadgeRecalculation {
                // Unread already zero locally — badge-only refresh, not a full inbox rebuild.
                requestBadgeRecalculation(reason: "marked_read_no_local_unread", includeInboxSummaries: true)
            }
            return
        }
#if DEBUG
        print("[UnreadBadgeDebug] conversationId=local_mark_read")
        print("[UnreadBadgeDebug] oldUnread=\(old.unreadCount)")
        print("[UnreadBadgeDebug] newUnread=0")
#endif
        let updated = FriendDisplay(
            id: old.id,
            preview: old.preview,
            subtitle: old.subtitle,
            lastMessageAt: old.lastMessageAt,
            unreadCount: 0,
            isConversationBacked: old.isConversationBacked,
            conversationId: old.conversationId,
            inboxKind: old.inboxKind,
            groupMemberCount: old.groupMemberCount,
            isGroupMuted: old.isGroupMuted,
            pickupGameId: old.pickupGameId,
            fanTeamId: old.fanTeamId
        )
        var next = friends
        next[idx] = updated
        friends = next
#if DEBUG
        print("[BadgeSyncDebug] chat list updated")
#endif
        let totalUnread = next.reduce(0) { $0 + $1.unreadCount }
#if DEBUG
        print("[UnreadBadgeDebug] totalBadge=\(totalUnread)")
#endif
        Task { await setUnreadDirectMessageCountAndSyncAppIcon(totalUnread, source: "local_mark_read") }
        if scheduleBadgeRecalculation {
            // Prefer badge-only; missing-row path above still requests full summaries.
            requestBadgeRecalculation(reason: "marked_read", includeInboxSummaries: true)
        }
    }

    /// Persists read cursor, clears local inbox unread, and reconciles tab/list badges.
    @discardableResult
    func markDirectThreadRead(
        conversationId: UUID,
        peerUserId: UUID,
        reason: String,
        requireActiveVisibleThread: Bool = true
    ) async -> Bool {
#if DEBUG
        print("[DMUnread] opening thread reason=\(reason) conversationId=\(conversationId.uuidString.lowercased())")
#endif
        if requireActiveVisibleThread {
            guard canMarkActiveDirectThreadRead(conversationId: conversationId, reason: reason) else {
                return false
            }
        }
        guard let me = try? await directChatService.currentUserId() else { return false }
        do {
            try await directChatService.markConversationRead(
                conversationId: conversationId,
                userId: me,
                lastReadAt: Date()
            )
#if DEBUG
            print("[DMUnread] mark read success conversationId=\(conversationId.uuidString.lowercased()) reason=\(reason)")
#endif
        } catch {
#if DEBUG
            print(
                "[DMUnread] mark read error conversationId=\(conversationId.uuidString.lowercased()) " +
                "reason=\(reason) error=\(error.localizedDescription)"
            )
#endif
            return false
        }
        markDirectInboxReadLocally(
            peerUserId: peerUserId,
            conversationId: conversationId,
            scheduleBadgeRecalculation: false
        )
        // Pre–Phase 1: refresh inbox summaries after mark-read.
        await refreshInboxSummaries()
#if DEBUG
        print("[DMUnread] unread counts refreshed reason=\(reason)")
#endif
        return true
    }

    /// Applies a lightweight inbox row update for an incoming peer DM (1:1). Returns false if a full inbox reconcile should run.
    private func applyRealtimeIncomingPeerMessage(_ row: DirectMessageRow) async -> Bool {
        let peerId = row.sender_id
        if isEitherDirectionBlocked(with: peerId) {
#if DEBUG
            print("[ChatReappear] ignored reason=blocked")
#endif
            return true
        }

        let conversationVisibleBefore = friends.contains { inboxDisplayMatchesInboundMessage($0, row: row) }
        let hiddenByConversation = row.conversation_id.map { hiddenInboxConversationIds.contains($0) } ?? false
        let hiddenByPeer = hiddenInboxPeerUserIds.contains(peerId)
#if DEBUG
        print(
            "[ChatReappear] inbound conversationVisibleBefore=\(conversationVisibleBefore) " +
            "hiddenState=conversation:\(hiddenByConversation),peer:\(hiddenByPeer)"
        )
#endif

        // Swipe-delete hides by conversationId (preferred) and/or peer id. Unhide both so
        // refreshInboxSummaries / applyHiddenInboxPeerFilter can show the thread again.
        if let conversationId = row.conversation_id {
            if hiddenByConversation || hiddenByPeer {
#if DEBUG
                print("[ChatReappear] resetVisibility reason=newInboundMessage")
#endif
            }
            revealInboxConversationIfHidden(
                conversationId: conversationId,
                peerUserId: peerId,
                reason: "newInboundMessage"
            )
        } else if hiddenByPeer {
#if DEBUG
            print("[ChatReappear] resetVisibility reason=newInboundMessage")
#endif
            revealInboxConversationIfHidden(peerUserId: peerId, reason: "newInboundMessage")
        }

        let viewing = isUserViewingThisDmThread(conversationId: row.conversation_id, peerSenderId: peerId)
        let badgeBefore = unreadDirectMessageCount
#if DEBUG
        let applyStartedAt = CFAbsoluteTimeGetCurrent()
        RealtimeHealthDiagnostics.log("mainActorApplyStart=direct_messages_inbox id=\(row.id.uuidString.lowercased())")
        print("[BadgeReceiveDebug] incomingDM conversationId=\(row.conversation_id?.uuidString.lowercased() ?? "nil")")
        print("[BadgeReceiveDebug] activeVisibleConversationId=\(activeVisibleConversationId?.uuidString.lowercased() ?? "nil")")
        print("[BadgeReceiveDebug] isExactVisibleThread=\(viewing)")
        print("[BadgeReceiveDebug] shouldCountUnread=\(!viewing)")
        print("[BadgeReceiveDebug] badgeBefore=\(badgeBefore)")
        print("[BadgeReceiveDebug] actor=MainActor")
#endif

        let rawPreview = ChatInboxPreviewFormatting.previewLine(
            body: row.body,
            isFromCurrentUser: false
        )
        let lastAt = Self.parseISO8601(row.created_at) ?? Date()

        if let idx = friends.firstIndex(where: { inboxDisplayMatchesInboundMessage($0, row: row) }) {
            let old = friends[idx]
            let newUnread: Int
            if viewing {
                newUnread = 0
            } else {
                newUnread = old.unreadCount + 1
            }
#if DEBUG
            print("[UnreadBadgeDebug] conversationId=\(row.conversation_id?.uuidString ?? "nil")")
            print("[UnreadBadgeDebug] oldUnread=\(old.unreadCount)")
            print("[UnreadBadgeDebug] newUnread=\(newUnread)")
            print("[ChatReappear] inboxUpsert conversationFound=true")
#endif
            let updated = FriendDisplay(
                id: old.id,
                preview: old.preview,
                subtitle: rawPreview,
                lastMessageAt: lastAt,
                unreadCount: newUnread,
                isConversationBacked: true,
                conversationId: old.conversationId ?? row.conversation_id,
                inboxKind: old.inboxKind,
                groupMemberCount: old.groupMemberCount,
                isGroupMuted: old.isGroupMuted,
                pickupGameId: old.pickupGameId,
                fanTeamId: old.fanTeamId
            )
            var next = friends
            next[idx] = updated
            next.sort(by: Self.isInboxRowOrderedBefore)
            friends = next
            syncChatPresenceRealtimeIfNeeded(reason: "incomingDmPatchedInbox")
#if DEBUG
            print("[BadgeSyncDebug] chat list updated")
            let inboxElapsedStart = row.conversation_id.flatMap { dmLatencyInboxEventStartByConversationID[$0] }
            let inboxElapsed = inboxElapsedStart.map { String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - $0) * 1000) } ?? "nil"
            print("[DMRealtimeLatencyDebug] inboxUpdated conversationId=\(row.conversation_id?.uuidString.lowercased() ?? "nil") elapsedMs=\(inboxElapsed)")
#endif
            let totalUnread = next.reduce(0) { $0 + $1.unreadCount }
#if DEBUG
            print("[UnreadBadgeDebug] totalBadge=\(totalUnread)")
#endif
            await setUnreadDirectMessageCountAndSyncAppIcon(totalUnread, source: viewing ? "incoming_visible_thread" : "incoming_realtime_local_increment")
#if DEBUG
            print("[BadgeReceiveDebug] badgeAfter=\(totalUnread)")
            RealtimeHealthDiagnostics.log("mainActorApplyEnd elapsedMs=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - applyStartedAt) * 1000)) table=direct_messages_inbox id=\(row.id.uuidString.lowercased())")
#endif
            requestBadgeRecalculation(reason: "incoming_message")
            return true
        }

        // Hidden swipe-delete removed the local row; re-insert immediately after unhide.
        let upserted = await upsertInboxDisplayFromInboundPeerMessage(
            row,
            previewText: rawPreview,
            lastMessageAt: lastAt,
            viewing: viewing
        )
#if DEBUG
        print("[ChatReappear] inboxUpsert conversationFound=\(upserted)")
        DMRealtimeDiagnostics.debug(
            "ignoredReason=missingInboxRow messageId=\(row.id.uuidString.lowercased()) senderId=\(peerId.uuidString.lowercased()) activeThread=\(viewing)"
        )
        print("[BadgeReceiveDebug] skipped reason=missing_inbox_row upserted=\(upserted)")
#endif
        if upserted {
            requestBadgeRecalculation(reason: "incoming_message_reappear")
            return true
        }
        return false
    }

    /// Matches inbox rows by conversation id (preferred) or fan peer id (legacy / non-venue).
    private func inboxDisplayMatchesInboundMessage(_ display: FriendDisplay, row: DirectMessageRow) -> Bool {
        if display.isGroupConversation { return false }
        if let conversationId = row.conversation_id {
            if display.conversationId == conversationId || display.id == conversationId {
                return true
            }
        }
        if display.preview.isBusinessVenueConversation {
            return false
        }
        return display.preview.id == row.sender_id || display.id == row.sender_id
    }

    /// Rebuilds a Recent Chats row after swipe-delete hide when an inbound DM arrives.
    @MainActor
    private func upsertInboxDisplayFromInboundPeerMessage(
        _ row: DirectMessageRow,
        previewText: String,
        lastMessageAt: Date,
        viewing: Bool
    ) async -> Bool {
        guard !isEitherDirectionBlocked(with: row.sender_id) else {
#if DEBUG
            print("[ChatReappear] ignored reason=blocked")
#endif
            return false
        }

        var preview = previewForLoadedDmParticipant(
            userId: row.sender_id,
            conversationId: row.conversation_id
        )
        if preview == nil {
            preview = try? await socialIdentityService.fetchUserPreviews(for: [row.sender_id])[row.sender_id]
        }
        let resolved = preview ?? UserPreview(
            id: row.sender_id,
            displayName: "Player",
            username: nil,
            email: nil,
            avatarURL: nil,
            avatarThumbnailURL: nil,
            dmConversationId: row.conversation_id
        )
        let displayId = row.conversation_id ?? row.sender_id
        let display = FriendDisplay(
            id: displayId,
            preview: resolved,
            subtitle: previewText,
            lastMessageAt: lastMessageAt,
            unreadCount: viewing ? 0 : 1,
            isConversationBacked: true,
            conversationId: row.conversation_id
        )

        var next = friends.filter { !inboxDisplayMatchesInboundMessage($0, row: row) }
        next.insert(display, at: 0)
        next.sort(by: Self.isInboxRowOrderedBefore)
        friends = next
        syncChatPresenceRealtimeIfNeeded(reason: "incomingDmReappearedInbox")
        let totalUnread = next.reduce(0) { $0 + $1.unreadCount }
        await setUnreadDirectMessageCountAndSyncAppIcon(
            totalUnread,
            source: viewing ? "incoming_reappear_visible_thread" : "incoming_reappear_local_increment"
        )
#if DEBUG
        print("[BadgeSyncDebug] chat list updated (reappear upsert)")
#endif
        // Enrich names/avatars without blocking the visible restore.
        return true
    }

    private func stopInboxRealtimeListener() async {
#if DEBUG
        print("[RealtimeLifecycle] stopping inbox listener")
#endif
        inboxUnreadDebounceTask?.cancel()
        inboxUnreadDebounceTask = nil
        inboxMissingPeerReconcileTask?.cancel()
        inboxMissingPeerReconcileTask = nil

        let task = inboxListenTask
        inboxListenTask = nil
        task?.cancel()
        // removeChannel first so postgresChange AsyncStreams finish; awaiting task.result
        // before channel removal hangs logout / sign-out cleanup forever.
        await removeInboxRealtimeChannelOnly()
        if let task {
            _ = await task.result
        }
    }

    private func removeFriendshipsChannelOnly() async {
        if let ch = friendshipsChannel {
            await supabase.removeChannel(ch)
        }
        friendshipsChannel = nil
        friendshipsRealtimeBoundUserId = nil
    }

    private func startFriendshipsRealtimeListenerIfNeeded() {
        guard friendshipsListenTask == nil, friendshipsChannel == nil else {
#if DEBUG
            print("[RealtimeLifecycle] duplicate prevented (friendship listener already active)")
#endif
            return
        }
        guard requiresSignIn == false else { return }
#if DEBUG
        print("[RealtimeLifecycle] starting friendship listener")
#endif
        friendshipsListenTask = Task { [weak self] in
            guard let self else { return }
            await self.runFriendshipsRealtimeListenerLoop()
        }
    }

    private func runFriendshipsRealtimeListenerLoop() async {
        defer {
            friendshipsListenTask = nil
        }

        let me: UUID
        if let cached = currentUserAuthId {
            me = cached
        } else if let fetched = try? await service.currentUserId() {
            me = fetched
        } else {
            return
        }

#if DEBUG
        print("[FriendRequestRealtime] friendship channel bound user=\(me.uuidString.lowercased())")
#endif

        let channel = supabase.channel("friendships-\(me.uuidString.lowercased())")
        friendshipsChannel = channel

        let changes = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "friendships"
        )

        defer {
            friendRequestRealtimeDebounceTask?.cancel()
            friendRequestRealtimeDebounceTask = nil
        }

        var shouldRestartChatRealtime = false
        do {
            try await channel.subscribeWithError()
            friendshipsRealtimeBoundUserId = me

            for await action in changes {
                if Task.isCancelled { break }
                try Task.checkCancellation()
                switch action {
                case .insert, .update, .delete:
                    logFriendRequestRealtimeCancelledIfNeeded(action)
#if DEBUG
                    print("[FriendRequestRealtime] event received")
#endif
                    scheduleFriendRequestRealtimeRefresh()
                }
            }
        } catch {
            if !(error is CancellationError) {
#if DEBUG
                print("[FriendRequestRealtime] subscribe/stream error: \(error)")
                print("[RealtimeLifecycle] friendship listener ended with error")
#endif
                shouldRestartChatRealtime = realtimeErrorIndicatesGlobalRetryExhausted(error)
            }
        }

        await removeFriendshipsChannelOnly()
        if shouldRestartChatRealtime {
            Task { @MainActor [weak self] in
                await Task.yield()
                await self?.forceRestartChatRealtimeAfterGlobalRetryExhausted(reason: "friendshipsMaxRetry")
            }
        }
    }

    private func logFriendRequestRealtimeCancelledIfNeeded(_ action: AnyAction) {
        guard case let .update(u) = action else { return }
        guard let raw = u.record["status"] else { return }
        let lowered: String?
        switch raw {
        case let .string(s):
            lowered = s.lowercased()
        default:
            lowered = nil
        }
        if lowered == "cancelled" {
#if DEBUG
            print("[FriendRequestRealtime] cancelled request received")
#endif
        }
    }

    private func scheduleFriendRequestRealtimeRefresh() {
        friendRequestRealtimeDebounceTask?.cancel()
        friendRequestRealtimeDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
#if DEBUG
            print("[FriendRequestRealtime] refreshing requests")
#endif
            await self.refreshFriendRequestListsOnly()
#if DEBUG
            print("[FriendRequestRealtime] badge updated pending=\(self.pendingBadgeCount)")
#endif
        }
    }

    private func stopFriendshipsRealtimeListener() async {
        friendRequestRealtimeDebounceTask?.cancel()
        friendRequestRealtimeDebounceTask = nil

        let task = friendshipsListenTask
        friendshipsListenTask = nil
        friendshipsRealtimeBoundUserId = nil
        task?.cancel()
        await removeFriendshipsChannelOnly()
        if let task {
            _ = await task.result
        }
#if DEBUG
        print("[RealtimeLifecycle] stopping friendship listener")
#endif
    }

    private func installFanTeamIdentityInboxObserverIfNeeded() {
        guard fanTeamIdentityInboxObserver == nil else { return }
        fanTeamIdentityInboxObserver = NotificationCenter.default.addObserver(
            forName: FanTeamIdentityChangeCenter.identityDidChangeNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let change = FanTeamIdentityChangeCenter.identityChange(from: note) else { return }
            Task { @MainActor [weak self] in
                self?.applyFanTeamIdentityChangeToGroupInbox(change)
            }
        }
    }

    private func installFanTeamMembershipInboxObserverIfNeeded() {
        guard fanTeamMembershipInboxObserver == nil else { return }
        fanTeamMembershipInboxObserver = NotificationCenter.default.addObserver(
            forName: FanTeamIdentityRealtimeCoordinator.membershipSnapshotsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncFanTeamClassificationOnGroupInbox()
            }
        }
    }

    /// Re-tags group inbox rows as Fan Team chats using already-loaded Team membership snapshots.
    func syncFanTeamClassificationOnGroupInbox() {
        var changed = false
        let next = friends.map { row -> FriendDisplay in
            guard row.inboxKind == .group, !row.isPickupGameChat else { return row }
            let conversationId = row.conversationId ?? row.id
            let teamId = FanTeamIdentityRealtimeCoordinator.shared.teamId(forConversationId: conversationId)
            let teamTitle = Self.fanTeamInboxTitle(
                teamId: teamId,
                conversationId: conversationId,
                fallback: row.preview.displayName
            )
            let titleChanged = teamId != nil && row.preview.displayName != teamTitle
            guard row.fanTeamId != teamId || titleChanged else { return row }
            changed = true
            let preview: UserPreview = {
                guard titleChanged else { return row.preview }
                return row.preview.replacingDisplayName(teamTitle)
            }()
            return FriendDisplay(
                id: row.id,
                preview: preview,
                subtitle: row.subtitle,
                lastMessageAt: row.lastMessageAt,
                unreadCount: row.unreadCount,
                isConversationBacked: row.isConversationBacked,
                conversationId: row.conversationId,
                inboxKind: row.inboxKind,
                groupMemberCount: row.groupMemberCount,
                isGroupMuted: row.isGroupMuted,
                pickupGameId: row.pickupGameId,
                fanTeamId: teamId
            )
        }
        if changed {
            friends = next
        }
    }

    /// Authoritative Team name for inbox rows (never inferred from title strings).
    private static func fanTeamInboxTitle(
        teamId: UUID?,
        conversationId: UUID,
        fallback: String
    ) -> String {
        let teamName = FanTeamIdentityRealtimeCoordinator.shared.markSnapshot(
            teamId: teamId,
            conversationId: conversationId
        )?.name
        return ChatInboxFanTeamRowIdentity.preferredTitle(
            teamName: teamName,
            fallbackConversationTitle: fallback
        )
    }

    private func installFanTeamInvitationBadgeObserversIfNeeded() {
        if fanTeamInvitationBadgeObserver == nil {
            fanTeamInvitationBadgeObserver = NotificationCenter.default.addObserver(
                forName: .fanTeamInvitationPushArrivedInForeground,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor [weak self] in
                    await self?.refreshPendingFanTeamInvitationCount(force: true)
                }
            }
        }
        if fanTeamDeletedBadgeObserver == nil {
            fanTeamDeletedBadgeObserver = NotificationCenter.default.addObserver(
                forName: .fanTeamDeletedPushArrivedInForeground,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor [weak self] in
                    await self?.refreshPendingFanTeamInvitationCount(force: true)
                }
            }
        }
    }

    /// Updates group inbox Team identity (name + classification). Does not touch unread/history.
    func applyFanTeamIdentityChangeToGroupInbox(_ change: FanTeamIdentityChange) {
        guard let idx = friends.firstIndex(where: {
            $0.isGroupConversation
                && ($0.conversationId == change.conversationId || $0.id == change.conversationId)
        }) else { return }
        let existing = friends[idx]
        let trimmed = change.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextTitle = ChatInboxFanTeamRowIdentity.preferredTitle(
            teamName: trimmed.isEmpty ? nil : trimmed,
            fallbackConversationTitle: existing.preview.displayName
        )
        let preview = existing.preview.replacingDisplayName(nextTitle)
        friends[idx] = FriendDisplay(
            id: existing.id,
            preview: preview,
            subtitle: existing.subtitle,
            lastMessageAt: existing.lastMessageAt,
            unreadCount: existing.unreadCount,
            isConversationBacked: existing.isConversationBacked,
            conversationId: existing.conversationId,
            inboxKind: existing.inboxKind,
            groupMemberCount: existing.groupMemberCount,
            isGroupMuted: existing.isGroupMuted,
            pickupGameId: existing.pickupGameId,
            fanTeamId: existing.fanTeamId ?? change.teamId
        )
    }

    /// Lightweight tab-intent preload: unread DM badge + pending request counts only (no inbox body reload).
    func prefetchTabIntentChatBadgeData() async {
        guard (try? await directChatService.currentUserId()) != nil else {
            clearForSignOut()
            return
        }
        await refreshUnreadDirectMessageCount(force: true)
        await refreshFriendRequestListsOnly()
        await refreshPendingFanTeamInvitationCount(force: true)
        noteChatTabIntentPreloadCompleted()
    }

    /// Apply in-memory My Teams invitation list length (accept/decline/local refresh).
    func applyPendingFanTeamInvitationCount(_ count: Int) {
        let next = max(0, count)
        guard pendingFanTeamInvitationCount != next else { return }
        pendingFanTeamInvitationCount = next
#if DEBUG
        print("[ChatMyTeamsBadge] apply count=\(next)")
#endif
    }

    func applyPendingFanTeamInvitations(_ invitations: [FanTeamInvitation]) {
        pendingFanTeamInvitations = invitations
        applyPendingFanTeamInvitationCount(invitations.count)
    }

    /// Authoritative refresh from `list_my_pending_fan_team_invitations` (invitee-only pending).
    func refreshPendingFanTeamInvitationCount(force: Bool = false) async {
        guard currentUserAuthId != nil, !requiresSignIn else {
            applyPendingFanTeamInvitations([])
            return
        }
        if let inFlight = pendingFanTeamInvitationCountRefreshTask {
            await inFlight.value
            if !force { return }
        }
        if !force,
           let last = lastPendingFanTeamInvitationCountRefreshAt,
           Date().timeIntervalSince(last) < 2 {
            return
        }
        let expectedAuthId = currentUserAuthId
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let invitations = try await FanTeamsService().listMyPendingInvitations()
                guard self.currentUserAuthId == expectedAuthId, !self.requiresSignIn else { return }
                self.applyPendingFanTeamInvitations(invitations)
                self.lastPendingFanTeamInvitationCountRefreshAt = Date()
            } catch {
                if FanTeamsLoadErrorPresentation.isMissingAuthSession(error) {
                    guard self.currentUserAuthId == expectedAuthId else { return }
                    self.applyPendingFanTeamInvitations([])
                    return
                }
#if DEBUG
                print("[ChatMyTeamsBadge] refresh failed error=\(error.localizedDescription)")
#endif
            }
        }
        pendingFanTeamInvitationCountRefreshTask = task
        await task.value
        if pendingFanTeamInvitationCountRefreshTask == task {
            pendingFanTeamInvitationCountRefreshTask = nil
        }
    }

    func shouldSkipChatTabIntentPreload() -> Bool {
        guard let last = lastChatTabIntentPreloadAt else { return false }
        return Date().timeIntervalSince(last) < Self.chatTabRefreshCoalesceInterval
    }

    func shouldSkipChatTabSurfaceRefresh() -> Bool {
        let recentIntent = lastChatTabIntentPreloadAt.map {
            Date().timeIntervalSince($0) < Self.chatTabRefreshCoalesceInterval
        } ?? false
        let recentSurface = lastChatTabSurfaceRefreshAt.map {
            Date().timeIntervalSince($0) < Self.chatTabRefreshCoalesceInterval
        } ?? false
        return recentIntent || recentSurface
    }

    func noteChatTabIntentPreloadCompleted() {
        lastChatTabIntentPreloadAt = Date()
    }

    func noteChatTabSurfaceRefreshCompleted() {
        lastChatTabSurfaceRefreshAt = Date()
    }

    /// Refreshes friend request rows + chip map + pending badge without reloading DM inbox.
    func refreshFriendRequestListsOnly() async {
        let startedAt = Date()
        guard let me = try? await service.currentUserId() else {
            clearForSignOut()
            DebugLogGate.debug("[NotificationPerf] chatFriendRequestsSkipped reason=missingSession")
            return
        }
        noteAuthenticatedChatSession(userId: me, source: "friendRequests")
        await reloadModerationBlockSets()
        do {
            async let accepted = service.fetchAcceptedFriendships(for: me)
            async let incomingRows = service.fetchIncomingFriendRequestsVisible(for: me)
            async let outgoingRows = service.fetchOutgoingFriendRequestsVisible(for: me)
            let (accRows, inRows, outRows) = try await (accepted, incomingRows, outgoingRows)

            let previewIds = Set(
                inRows.map(\.requester_id)
                    + outRows.map(\.addressee_id)
            )
            let previewsById = try await socialIdentityService.fetchUserPreviews(for: Array(previewIds))

            incomingRequests = inRows
                .filter { !isEitherDirectionBlocked(with: $0.requester_id) }
                .map { row in
                    let preview = previewsById[row.requester_id] ?? deletedUserPreview(userId: row.requester_id)
                    return IncomingRequestDisplay(friendship: row, requester: preview)
                }

            outgoingRequests = outRows
                .filter { !isEitherDirectionBlocked(with: $0.addressee_id) }
                .map { row in
                    let preview = previewsById[row.addressee_id] ?? deletedUserPreview(userId: row.addressee_id)
                    return OutgoingRequestDisplay(friendship: row, addressee: preview)
                }

            pendingBadgeCount = incomingRequests.filter { $0.friendship.isPendingStatus }.count
            DebugLogGate.debug("[NotificationPerf] chatFriendRequestsFinished durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) pending=\(pendingBadgeCount)")
            DebugLogGate.debug("[BadgeSyncDebug] tab badge updated")
            noteAuthenticatedChatSession(userId: me, source: "friendRequestsLoaded")
            applyFriendshipChipStates(me: me, accepted: accRows, incoming: inRows, outgoing: outRows)
        } catch {
            // Keep existing lists; next refresh or realtime will retry.
            DebugLogGate.debug("[NotificationPerf] chatFriendRequestsFailed durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) error=\(error.localizedDescription)")
        }
    }

    /// Refreshes the Chat tab badge for unread peer DMs (no friendship / request counts).
    /// - Parameter force: When true, bypasses launch freshness coalesce (realtime, tab intent, auth change).
    ///   Still waits for any in-flight refresh before starting a new one to avoid racing publishers.
    func refreshUnreadDirectMessageCount(force: Bool = false) async {
        if let inFlight = unreadDirectMessageRefreshTask {
            StartupPerf.taskCoalesced(name: "unreadDirectMessageCount")
            DebugLogGate.debug("[NotificationPerf] chatUnreadCoalesced reason=inFlight force=\(force)")
            await inFlight.value
            if !force { return }
        } else if !force,
                  let last = lastUnreadDirectMessageRefreshAt,
                  Date().timeIntervalSince(last) < unreadDirectMessageRefreshFreshness {
            StartupPerf.duplicateSkipped(reason: "unreadDirectMessageFresh")
            DebugLogGate.debug("[NotificationPerf] chatUnreadSkipped reason=freshCache")
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performUnreadDirectMessageCountRefresh()
        }
        unreadDirectMessageRefreshTask = task
        await task.value
        if unreadDirectMessageRefreshTask == task {
            unreadDirectMessageRefreshTask = nil
        }
    }

    private func performUnreadDirectMessageCountRefresh() async {
        let startedAt = Date()
        guard let me = try? await directChatService.currentUserId() else {
            clearForSignOut()
            DebugLogGate.debug("[NotificationPerf] chatUnreadSkipped reason=missingSession")
            return
        }
        noteAuthenticatedChatSession(userId: me, source: "unreadDirectMessageCount")
        let prior = unreadDirectMessageCount
        DebugLogGate.debug("[RealtimeChainDebug] refreshStarted table=conversation_read_state key=unreadDirectMessageCount")
        guard let n = try? await directChatService.fetchUnreadDirectMessageCount(currentUserId: me) else {
            DebugLogGate.debug("[NotificationPerf] chatUnreadFailed durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
            return
        }
        await setUnreadDirectMessageCountAndSyncAppIcon(n, source: "rpc_total_refresh")
        lastUnreadDirectMessageRefreshAt = Date()
        DebugLogGate.debug("[NotificationPerf] chatUnreadFinished durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) unread=\(n)")
        DebugLogGate.debug("[RealtimeChainDebug] refreshSucceeded table=conversation_read_state key=unreadDirectMessageCount")
        DebugLogGate.debug("[UnreadBadgeDebug] conversationId=rpc_total_refresh")
        DebugLogGate.debug("[UnreadBadgeDebug] oldUnread=\(prior)")
        DebugLogGate.debug("[UnreadBadgeDebug] newUnread=\(n)")
        DebugLogGate.debug("[UnreadBadgeDebug] totalBadge=\(n)")
    }

    /// Launch warm path: refreshes only the DM unread badge and inbox summaries, never message bodies.
    func prefetchLightweightStartupChatData() async -> StartupChatPrefetchResult {
        // No DM/badge prefetch until the authoritative age record confirmed this UUID.
        if !AgeAccessGateService.shared.allowsSocialSubsystemsForActiveUser() {
            AgeAccessRuntimeLog.socialSubsystemBlocked(
                userId: AgeAccessGateService.shared.activeUserId,
                subsystem: "chat_startup_prefetch"
            )
            return StartupChatPrefetchResult(
                dmBadgePrefetched: false,
                inboxSummariesPrefetched: false,
                skippedReason: "ageAccessUnresolved"
            )
        }
        if let inFlight = startupLightweightPrefetchTask {
            DebugLogGate.debug("[NotificationPerf] chatStartupPrefetchCoalesced=true")
            DebugLogGate.debug("[StartupPrefetchDebug] skippedReason=chatInFlight")
            return await inFlight.value
        }
        if let lastStartupLightweightPrefetchAt,
           Date().timeIntervalSince(lastStartupLightweightPrefetchAt) < startupLightweightPrefetchTTL {
            DebugLogGate.debug("[NotificationPerf] chatStartupPrefetchSkipped reason=freshCache")
            DebugLogGate.debug("[StartupPrefetchDebug] skippedReason=chatFreshCache")
            return StartupChatPrefetchResult(
                dmBadgePrefetched: true,
                inboxSummariesPrefetched: true,
                skippedReason: "chatFreshCache"
            )
        }

        let task = Task<StartupChatPrefetchResult, Never> { [weak self] in
            guard let self else {
                return StartupChatPrefetchResult(
                    dmBadgePrefetched: false,
                    inboxSummariesPrefetched: false,
                    skippedReason: "chatViewModelReleased"
                )
            }
            return await self.runLightweightStartupChatPrefetch()
        }
        startupLightweightPrefetchTask = task
        let startedAt = Date()
        let result = await task.value
        startupLightweightPrefetchTask = nil
        if result.skippedReason == nil {
            lastStartupLightweightPrefetchAt = Date()
        }
        DebugLogGate.debug("[NotificationPerf] chatStartupPrefetchFinished durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) skippedReason=\(result.skippedReason ?? "none")")
        return result
    }

    private func runLightweightStartupChatPrefetch() async -> StartupChatPrefetchResult {
        guard (try? await directChatService.currentUserId()) != nil else {
            clearForSignOut()
            return StartupChatPrefetchResult(
                dmBadgePrefetched: false,
                inboxSummariesPrefetched: false,
                skippedReason: "chatMissingSession"
            )
        }

        await refreshUnreadDirectMessageCount()
        await beginInitialInboxLoadIfNeeded(source: "login")
        return StartupChatPrefetchResult(
            dmBadgePrefetched: true,
            inboxSummariesPrefetched: true,
            skippedReason: nil
        )
    }

    /// Loads friends and requests; coalesces rapid repeats.
    func loadIfNeeded() async {
        if isLoading { return }
        if let inFlight = fullRefreshInFlightTask {
            await inFlight.value
            return
        }
        if shouldSkipFullRefreshBecauseInboxFresh() {
            DebugLogGate.tabSwitchPerfVerbose(
                "[ChatLoadPerf] fullRefreshSkipped reason=enrichedInboxFresh realtimeActive=true"
            )
            return
        }
        if let last = lastLoadAt, Date().timeIntervalSince(last) < minRefreshInterval {
            return
        }
        await refresh()
    }

    /// True when enriched/fast inbox data is recent and DM inbox realtime is already attached.
    private func shouldSkipFullRefreshBecauseInboxFresh() -> Bool {
        guard hasCompletedInitialInboxLoad else { return false }
        guard inboxListenTask != nil, inboxChannel != nil else { return false }
        guard let last = lastInboxLoadAt else { return false }
        return Date().timeIntervalSince(last) < Self.fullRefreshFreshnessInterval
    }

    /// Refreshes Chat → Friends inbox summaries (preview/time/unread + sorted order) without reloading requests.
    func refreshInboxSummariesIfNeeded() async {
        if isLoading { return }
        if friends.isEmpty && !hasCompletedInitialInboxLoad {
            await refreshInboxSummaries()
            return
        }
        if let last = lastInboxLoadAt, Date().timeIntervalSince(last) < minInboxRefreshInterval {
            return
        }
        await refreshInboxSummaries()
    }

    /// Marks inbox loading UI before a deferred fetch begins (Chat tab appear path).
    func prepareInboxLoadUIStateIfNeeded() {
        guard !hasCompletedInitialInboxLoad else { return }
        initialInboxLoadFailed = false
        if friends.filter(\.isConversationBacked).isEmpty {
            isInboxInitialLoadInFlight = true
        } else {
            isInboxBackgroundRefreshInFlight = true
        }
    }

    func refreshInboxSummaries() async {
        if let inFlight = inboxSummariesRefreshTask {
            ChatActivationPerf.inboxRefreshCoalesced(source: "inboxSummaries")
#if DEBUG
            print("[ChatBootstrap] joinedExistingRequest")
#endif
            await inFlight.value
            return
        }

        ChatActivationPerf.inboxRefreshRequested(source: "inboxSummaries")
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefreshInboxSummaries()
        }
        inboxSummariesRefreshTask = task
        await task.value
        if inboxSummariesRefreshTask == task {
            inboxSummariesRefreshTask = nil
            inboxSummariesRefreshAuthId = nil
        }
    }

    /// Accepts a pending group invitation; returns the conversation id on success.
    @MainActor
    func acceptGroupInvitation(_ invitation: GroupPendingInvitationRow) async throws -> UUID {
        let conversationId = try await groupChatService.acceptInvitation(invitationId: invitation.invitation_id)
        pendingGroupInvitations.removeAll { $0.invitation_id == invitation.invitation_id }
        await refreshInboxSummaries()
        return conversationId
    }

    /// Declines a pending group invitation.
    @MainActor
    func declineGroupInvitation(_ invitation: GroupPendingInvitationRow) async throws {
        try await groupChatService.declineInvitation(invitationId: invitation.invitation_id)
        pendingGroupInvitations.removeAll { $0.invitation_id == invitation.invitation_id }
    }

    /// Patches cached group inbox mute without a full inbox reload (Group Info mute toggle).
    @MainActor
    func patchGroupInboxMuted(conversationId: UUID, isMuted: Bool) {
        guard let index = friends.firstIndex(where: {
            $0.isGroupConversation && $0.conversationId == conversationId
        }) else { return }
        let existing = friends[index]
        guard existing.isGroupMuted != isMuted else { return }
        friends[index] = FriendDisplay(
            id: existing.id,
            preview: existing.preview,
            subtitle: existing.subtitle,
            lastMessageAt: existing.lastMessageAt,
            unreadCount: existing.unreadCount,
            isConversationBacked: existing.isConversationBacked,
            conversationId: existing.conversationId,
            inboxKind: existing.inboxKind,
            groupMemberCount: existing.groupMemberCount,
            isGroupMuted: isMuted,
            pickupGameId: existing.pickupGameId,
            fanTeamId: existing.fanTeamId
        )
    }

    private func performRefreshInboxSummaries() async {
        let refreshStartedAt = CFAbsoluteTimeGetCurrent()
#if DEBUG
        ChatLoadPerf.loadStarted()
        if !friends.isEmpty {
            ChatLoadPerf.cachedRowsShown(count: friends.count)
        }
#endif
        guard let me = try? await directChatService.currentUserId() else {
            clearForSignOut()
            return
        }
        inboxSummariesRefreshAuthId = me
        noteAuthenticatedChatSession(userId: me, source: "inboxSummaries")
        groupInboxAvatarHydrationRefreshToken &+= 1
        lastCompletedGroupInboxAvatarHydrationKey = nil

        let hadCachedRows = !friends.filter(\.isConversationBacked).isEmpty
        if hadCachedRows {
            isInboxBackgroundRefreshInFlight = true
        } else if !hasCompletedInitialInboxLoad {
            isInboxInitialLoadInFlight = true
            initialInboxLoadFailed = false
        }

        await reloadModerationBlockSets()
        guard stillCurrentChatAccount(me, context: "inboxSummariesAfterModeration") else { return }

        do {
            let inboxFetchStartedAt = CFAbsoluteTimeGetCurrent()
            async let dmRowsTask = directChatService.fetchInboxSummaries()
            ChatActivationPerf.groupInboxRPCStarted()
            async let groupRowsTask = groupChatService.fetchInboxSummaries()
            async let pendingGroupInvitesTask = groupChatService.fetchPendingInvitationsForMe()
            async let exclusionsTask: Void = refreshServerInboxExclusionsIfAvailable()
            async let clearsHydrateTask: Void = directChatService.hydrateHistoryClearsFromServer()
            let rows = try await dmRowsTask
            let groupRows = (try? await groupRowsTask) ?? []
            let pendingGroupInvites = (try? await pendingGroupInvitesTask) ?? []
            _ = await exclusionsTask
            _ = await clearsHydrateTask
            ChatActivationPerf.inboxRPC(
                ms: Int((CFAbsoluteTimeGetCurrent() - inboxFetchStartedAt) * 1000),
                dmRows: rows.count,
                groupRows: groupRows.count
            )
#if DEBUG
            ChatLoadPerf.inboxFetchMs(Int((CFAbsoluteTimeGetCurrent() - inboxFetchStartedAt) * 1000))
#endif
            guard stillCurrentChatAccount(me, context: "inboxSummariesAfterFetch") else { return }

            let teamLinkedPickupIds = await groupChatService.teamLinkedPickupGameIds(
                among: groupRows.compactMap(\.pickup_game_id)
            )
            let fastBuildStartedAt = CFAbsoluteTimeGetCurrent()
            let dmVisible = buildInboxFriendDisplays(from: rows, me: me, participantPreviews: [:], profileLookupAttempted: false)
            let groupVisible = buildGroupInboxDisplays(
                from: groupRows,
                me: me,
                teamLinkedPickupGameIds: teamLinkedPickupIds
            )
            // Fast path is conversation-only. Preserve previously published accepted friends that
            // do not yet have a DM thread so the Friends tab does not flicker 4 → 3 → 4 while
            // enrichment re-merges them (see ``preservingAcceptedFriendsDirectoryRows``).
            let dmWithAcceptedDirectory = preservingAcceptedFriendsDirectoryRows(
                over: dmVisible,
                source: "fastPath"
            )
            let visible = mergeInboxDisplays(direct: dmWithAcceptedDirectory, groups: groupVisible)
            ChatActivationPerf.snapshotBuildMs(
                (CFAbsoluteTimeGetCurrent() - fastBuildStartedAt) * 1000,
                source: "fastPath"
            )
            applyInboxFriendsSnapshot(visible, source: "fastPath")
            pendingGroupInvitations = pendingGroupInvites
            await hydratePendingGroupInvitationPreviews(for: pendingGroupInvites)
            scheduleGroupInboxAvatarHydration(groupConversationIds: groupRows.map(\.conversation_id), me: me)
            let totalUnread = visible.reduce(0) { $0 + $1.unreadCount }
            await setUnreadDirectMessageCountAndSyncAppIcon(totalUnread, source: "refresh_inbox_summaries_fast")
            guard stillCurrentChatAccount(me, context: "inboxSummariesAfterApply") else { return }

            lastInboxLoadAt = Date()
            noteAuthenticatedChatSession(userId: me, source: "inboxSummariesLoaded")
            initialInboxLoadFailed = false
#if DEBUG
            print("[BadgeSyncDebug] chat list updated (fast path)")
            let recentMs = Int((CFAbsoluteTimeGetCurrent() - refreshStartedAt) * 1000)
            ChatLoadPerf.recentChatsVisibleMs(recentMs)
            ChatLoadPerf.presenceFetchDeferred(deferred: true)
            print("[ChatBootstrap] initialLoadFinished conversations=\(visible.filter(\.isConversationBacked).count)")
#endif

            // Authoritative first-load completion (including zero conversations).
            isInboxInitialLoadInFlight = false
            hasCompletedInitialInboxLoad = true
#if DEBUG
            ChatLoadPerf.totalInitialLoadMs(Int((CFAbsoluteTimeGetCurrent() - refreshStartedAt) * 1000))
            print("[ChatBootstrap] emptyStateAllowed=\(visible.filter(\.isConversationBacked).isEmpty)")
#endif

            inboxEnrichmentTask?.cancel()
            inboxEnrichmentTask = Task { [weak self] in
                await self?.enrichInboxSummariesAfterFirstPaint(
                    me: me,
                    rows: rows,
                    fallbackGroupRows: groupRows,
                    refreshStartedAt: refreshStartedAt,
                    finishInitialLoadIfStillPending: false
                )
                await MainActor.run {
                    self?.isInboxBackgroundRefreshInFlight = false
                }
            }
        } catch {
            guard stillCurrentChatAccount(me, context: "inboxSummariesCatch") else { return }
            isInboxInitialLoadInFlight = false
            isInboxBackgroundRefreshInFlight = false
            if hadCachedRows {
                // Preserve last valid rows after a prior successful load.
                hasCompletedInitialInboxLoad = true
                initialInboxLoadFailed = false
            } else {
                // Failure before any successful load: never flash the true empty state.
                hasCompletedInitialInboxLoad = false
                initialInboxLoadFailed = true
#if DEBUG
                print("[ChatBootstrap] emptyStateAllowed=false")
#endif
            }
        }
    }

    private func stillCurrentChatAccount(_ requestAuthId: UUID, context: String) -> Bool {
        if requiresSignIn {
#if DEBUG
            print("[ChatBootstrap] staleResultIgnored")
#endif
            return false
        }
        if let bound = inboxSummariesRefreshAuthId, bound != requestAuthId {
#if DEBUG
            print("[ChatBootstrap] staleResultIgnored")
#endif
            return false
        }
        if let current = currentUserAuthId, current != requestAuthId {
#if DEBUG
            print("[ChatBootstrap] staleResultIgnored")
#endif
            ChatCounterpartDebug.log("stale session result ignored context=\(context)")
            return false
        }
        return true
    }

    /// Publishes a rebuilt inbox snapshot only when it differs from the current list.
    /// A refresh recomputes an identical array in the common "nothing changed" case; skipping the
    /// assignment avoids a redundant `objectWillChange` that would invalidate the whole tab shell
    /// (`MainTabView` observes this view model). Row identity and order come from the caller.
    @discardableResult
    private func applyInboxFriendsSnapshot(_ next: [FriendDisplay], source: String) -> Bool {
        let token = ChatFriendsStability.beginRefresh(source: source)
        let nextDirectoryIds = friendsDirectoryMembershipIds(in: next)
        ChatFriendsStability.stage("afterMerge", refreshToken: token, ids: nextDirectoryIds)
        ChatFriendsStability.publishedDirectory(refreshToken: token, ids: nextDirectoryIds)

        guard friends != next else {
            ChatActivationPerf.snapshotReused(source: source)
            ChatActivationPerf.noteReused()
            return false
        }
        let publishStartedAt = CFAbsoluteTimeGetCurrent()
        friends = next
        ChatActivationPerf.publishMs(
            (CFAbsoluteTimeGetCurrent() - publishStartedAt) * 1000,
            rows: next.count,
            source: source
        )
        ChatActivationPerf.snapshotPublished(rows: next.count, source: source)
        ChatActivationPerf.notePublished()
        return true
    }

    /// Peer user ids that the Friends tab would show for this snapshot (accepted + directory-eligible).
    private func friendsDirectoryMembershipIds(in displays: [FriendDisplay]) -> Set<UUID> {
        Set(
            displays.compactMap { display -> UUID? in
                guard !display.isGroupConversation else { return nil }
                guard !display.preview.isDeleted else { return nil }
                guard !display.preview.isBusinessVenueConversation else { return nil }
                if display.preview.isBusinessAccount && display.isConversationBacked { return nil }
                guard friendshipChipByOtherUserId[display.preview.id] == .friends else { return nil }
                return display.preview.id
            }
        )
    }

    private func buildInboxFriendDisplays(
        from rows: [DmInboxSummaryRow],
        me: UUID,
        participantPreviews: [UUID: UserPreview],
        profileLookupAttempted: Bool
    ) -> [FriendDisplay] {
        var seenConversationIds = Set<UUID>()
        let displays: [FriendDisplay] = rows.compactMap { row -> FriendDisplay? in
            if let conversationId = row.conversation_id {
                if seenConversationIds.contains(conversationId) {
                    ChatCounterpartDebug.log("duplicate conversation row detected")
                    return nil
                }
                seenConversationIds.insert(conversationId)
            }

            let preview = inboxPreview(
                for: row,
                resolvedPreview: participantPreviews[row.friend_user_id],
                profileLookupAttempted: profileLookupAttempted
            )
            if DebugLogGate.verboseChatInboxRowLogging {
                logChatRowDebug(preview: preview)
                logDeletedUserRenderDebug(surface: "dm_inbox", preview: preview)
                logCounterpartMapping(row: row, preview: preview)
#if DEBUG
                ChatActivityBadgeDebug.log(
                    isRegularFan: !preview.isBusinessIdentity && !preview.isDeleted,
                    lastSeenPresent: preview.lastSeenAtRaw != nil,
                    visibilityAllowed: profileLookupAttempted ? preview.activityStatusVisible : nil,
                    kind: ActivityStatus.resolve(lastSeenAtRaw: preview.lastSeenAtRaw),
                    source: profileLookupAttempted ? "previewEnrichment" : "inboxRPC"
                )
#endif
            }

            let rawPreview = ChatInboxPreviewFormatting.previewLine(
                body: row.last_message_body,
                isFromCurrentUser: row.last_message_sender_id == me
            )

            let lastAt = Self.parseISO8601(row.last_message_created_at)
            let unread = max(0, row.unread_count ?? 0)
            let kind: ChatInboxConversationKind = {
                if preview.isBusinessVenueConversation || preview.isBusinessAccount { return .business }
                return .direct
            }()
            return FriendDisplay(
                id: row.conversation_id ?? preview.id,
                preview: preview,
                subtitle: rawPreview,
                lastMessageAt: lastAt,
                unreadCount: unread,
                isConversationBacked: true,
                conversationId: row.conversation_id,
                inboxKind: kind
            )
        }

        var visible = displays.filter { !isEitherDirectionBlocked(with: $0.preview.id) }
        visible = applyHiddenInboxPeerFilter(visible)
        return visible
    }

    private func buildGroupInboxDisplays(
        from rows: [GroupInboxSummaryRow],
        me: UUID,
        teamLinkedPickupGameIds: Set<UUID> = []
    ) -> [FriendDisplay] {
        let displays = rows.compactMap { row -> FriendDisplay? in
            guard TeamEventChatConsolidation.shouldShowInGroupInbox(
                pickupGameId: row.pickup_game_id,
                teamLinkedPickupGameIds: teamLinkedPickupGameIds
            ) else {
                return nil
            }
            let fallbackTitle = row.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? L10n.t("group_chat_default_title")
                : row.title
            let fanTeamId: UUID? = {
                guard row.pickup_game_id == nil else { return nil }
                return FanTeamIdentityRealtimeCoordinator.shared.teamId(
                    forConversationId: row.conversation_id
                )
            }()
            let displayName = fanTeamId == nil
                ? fallbackTitle
                : Self.fanTeamInboxTitle(
                    teamId: fanTeamId,
                    conversationId: row.conversation_id,
                    fallback: fallbackTitle
                )
            let preview = UserPreview(
                id: row.conversation_id,
                displayName: displayName,
                username: nil,
                email: nil,
                avatarURL: nil,
                avatarThumbnailURL: nil
            )
            let isSystem = GroupSystemEventFormatting.isSystemMessage(messageType: row.last_message_type)
            let systemBody = isSystem
                ? GroupSystemEventFormatting.displayText(
                    systemEvent: row.last_system_event,
                    payload: row.last_system_payload,
                    fallbackBody: row.last_message_body ?? ""
                )
                : row.last_message_body
            let subtitle = ChatInboxPreviewFormatting.previewLine(
                body: systemBody,
                isFromCurrentUser: row.last_message_sender_id == me,
                isSystemEvent: isSystem
            )
            return FriendDisplay(
                id: row.conversation_id,
                preview: preview,
                subtitle: subtitle,
                lastMessageAt: Self.parseISO8601(row.last_message_created_at),
                unreadCount: max(0, row.unread_count ?? 0),
                isConversationBacked: true,
                conversationId: row.conversation_id,
                inboxKind: .group,
                groupMemberCount: max(0, row.member_count),
                isGroupMuted: row.is_muted == true,
                pickupGameId: row.pickup_game_id,
                fanTeamId: fanTeamId
            )
        }
        return applyHiddenInboxPeerFilter(displays)
    }

    private func hydratePendingGroupInvitationPreviews(for invitations: [GroupPendingInvitationRow]) async {
        let inviterIds = Array(Set(invitations.map(\.inviter_user_id)))
        guard !inviterIds.isEmpty else {
            await MainActor.run { pendingGroupInvitationPreviews = [:] }
            return
        }
        if let fetched = try? await socialIdentityService.fetchUserPreviews(for: inviterIds) {
            await MainActor.run { pendingGroupInvitationPreviews = fetched }
        }
    }

    /// Stable key for equivalent avatar hydration work within one refresh cycle.
    private func groupInboxAvatarHydrationIdentityKey(
        groupConversationIds: [UUID],
        me: UUID,
        refreshToken: UInt64
    ) -> String {
        let sortedIds = groupConversationIds
            .map { $0.uuidString.lowercased() }
            .sorted()
            .joined(separator: ",")
        return "t\(refreshToken)|u\(me.uuidString.lowercased())|g\(sortedIds)"
    }

    private func scheduleGroupInboxAvatarHydration(groupConversationIds: [UUID], me: UUID) {
        let ids = Array(Set(groupConversationIds)).sorted { $0.uuidString < $1.uuidString }
        let active = Set(ids)
        groupInboxAvatarMemberIdsByConversationId = groupInboxAvatarMemberIdsByConversationId.filter {
            active.contains($0.key)
        }

        let refreshToken = groupInboxAvatarHydrationRefreshToken
        let key = groupInboxAvatarHydrationIdentityKey(
            groupConversationIds: ids,
            me: me,
            refreshToken: refreshToken
        )

        // Same group/member context already in flight → join; do not cancel/restart.
        if groupInboxAvatarHydrationTask != nil,
           groupInboxAvatarHydrationKey == key {
            ChatActivationPerf.avatarHydrationJoined(groupCount: ids.count)
            return
        }

        // Same context already completed for this refresh cycle → skip duplicate.
        if groupInboxAvatarHydrationTask == nil,
           lastCompletedGroupInboxAvatarHydrationKey == key {
            ChatActivationPerf.avatarHydrationSkippedIdentical(groupCount: ids.count)
            return
        }

        groupInboxAvatarHydrationGeneration &+= 1
        let generation = groupInboxAvatarHydrationGeneration
        groupInboxAvatarHydrationKey = key
        groupInboxAvatarHydrationTask?.cancel()
        ChatActivationPerf.avatarHydrationStarted(groupCount: ids.count)
        groupInboxAvatarHydrationTask = Task { [weak self] in
            guard let self else { return }
            await self.hydrateGroupInboxAvatars(
                groupConversationIds: ids,
                me: me,
                generation: generation
            )
            await MainActor.run {
                guard self.groupInboxAvatarHydrationGeneration == generation else { return }
                self.lastCompletedGroupInboxAvatarHydrationKey = key
                if self.groupInboxAvatarHydrationTask != nil {
                    self.groupInboxAvatarHydrationTask = nil
                }
            }
        }
    }

    private func hydrateGroupInboxAvatars(
        groupConversationIds: [UUID],
        me: UUID,
        generation: UInt64
    ) async {
        guard !groupConversationIds.isEmpty else {
            await MainActor.run {
                guard generation == groupInboxAvatarHydrationGeneration else { return }
                groupInboxAvatarMemberIdsByConversationId = [:]
            }
            return
        }

        do {
            let memberRows = try await groupChatService.fetchActiveMembers(forConversationIds: groupConversationIds)
            guard !Task.isCancelled else { return }
            guard generation == groupInboxAvatarHydrationGeneration else { return }
            guard stillCurrentChatAccount(me, context: "groupInboxAvatarMembers") else { return }

            // Membership grouping/ordering is pure and scales with members, so keep it off the MainActor.
            let membershipStartedAt = CFAbsoluteTimeGetCurrent()
            let membership = await Task.detached(priority: .userInitiated) {
                ChatInboxSnapshotBuilder.groupAvatarMembership(
                    memberRows: memberRows,
                    conversationIds: groupConversationIds,
                    currentUserId: me
                )
            }.value
            ChatActivationPerf.offMainWorkMs(
                (CFAbsoluteTimeGetCurrent() - membershipStartedAt) * 1000,
                name: "groupAvatarMembership"
            )
            guard !Task.isCancelled else { return }
            guard generation == groupInboxAvatarHydrationGeneration else { return }
            let nextIdsByConversation = membership.memberIdsByConversationId
            let allMemberIds = membership.referencedMemberIds

            // Seed from friends / existing cache before network.
            var seededPreviews = groupMemberPreviewByUserId
            for friend in friends where !friend.isGroupConversation {
                seededPreviews[friend.preview.id] = friend.preview
            }

            let missingIds = allMemberIds.filter { seededPreviews[$0] == nil }
            var fetched: [UUID: UserPreview] = [:]
            if !missingIds.isEmpty {
                fetched = (try? await socialIdentityService.fetchUserPreviews(for: Array(missingIds))) ?? [:]
            }
            guard !Task.isCancelled else { return }
            guard generation == groupInboxAvatarHydrationGeneration else { return }
            guard stillCurrentChatAccount(me, context: "groupInboxAvatarPreviews") else { return }

            // Keep only members referenced by current inbox groups (plus any still-needed cache hits).
            let mergeStartedAt = CFAbsoluteTimeGetCurrent()
            let seeded = seededPreviews
            let fetchedPreviews = fetched
            let referenced = allMemberIds
            let mergedPreviews = await Task.detached(priority: .userInitiated) {
                ChatInboxSnapshotBuilder.mergedGroupMemberPreviews(
                    seeded: seeded,
                    fetched: fetchedPreviews,
                    referenced: referenced
                )
            }.value
            ChatActivationPerf.offMainWorkMs(
                (CFAbsoluteTimeGetCurrent() - mergeStartedAt) * 1000,
                name: "groupMemberPreviewMerge"
            )

            await MainActor.run {
                guard generation == groupInboxAvatarHydrationGeneration else { return }
                groupInboxAvatarMemberIdsByConversationId = nextIdsByConversation
                groupMemberPreviewByUserId = mergedPreviews
            }
        } catch {
#if DEBUG
            print("[GroupInboxAvatar] hydrate failed error=\(error)")
#endif
            // Keep any prior cluster state; placeholders still render from member_count.
        }
    }

    private func mergeInboxDisplays(direct: [FriendDisplay], groups: [FriendDisplay]) -> [FriendDisplay] {
        var byKey: [String: FriendDisplay] = [:]
        for row in direct {
            byKey["\(row.inboxKind.rawValue):\(row.id.uuidString.lowercased())"] = row
        }
        for row in groups {
            byKey["group:\(row.id.uuidString.lowercased())"] = row
        }
        return byKey.values.sorted(by: Self.isInboxRowOrderedBefore)
    }

    /// Shared inbox comparator (recency first, deterministic tie-break) so refresh merges and
    /// Realtime patches can never disagree about the position of equal-timestamp rows.
    private static func isInboxRowOrderedBefore(_ lhs: FriendDisplay, _ rhs: FriendDisplay) -> Bool {
        ChatInboxSnapshotBuilder.isOrderedBefore(
            lhsLastMessageAt: lhs.lastMessageAt,
            lhsId: lhs.id,
            rhsLastMessageAt: rhs.lastMessageAt,
            rhsId: rhs.id
        )
    }

    /// Second (and final) pass of a refresh: resolves DM profiles, folds in accepted friends without
    /// a thread, and reuses the fast-path group summaries. Everything is merged into one snapshot
    /// before publishing so group rows never momentarily vanish while DM enrichment is applied.
    private func enrichInboxSummariesAfterFirstPaint(
        me: UUID,
        rows: [DmInboxSummaryRow],
        fallbackGroupRows: [GroupInboxSummaryRow],
        refreshStartedAt: CFAbsoluteTime,
        finishInitialLoadIfStillPending: Bool
    ) async {
        defer {
            if finishInitialLoadIfStillPending {
                isInboxInitialLoadInFlight = false
                hasCompletedInitialInboxLoad = true
                initialInboxLoadFailed = false
#if DEBUG
                ChatLoadPerf.totalInitialLoadMs(Int((CFAbsoluteTimeGetCurrent() - refreshStartedAt) * 1000))
#endif
            }
        }
        guard !Task.isCancelled else { return }
        guard stillCurrentChatAccount(me, context: "inboxEnrichmentStart") else { return }
        ChatActivationPerf.enrichmentStarted()
        let enrichmentStartedAt = CFAbsoluteTimeGetCurrent()
        do {
            // Group inbox already fetched on the fast path with the same RPC/session/filters.
            // Reuse that immutable snapshot — a second get_group_inbox_summaries within the same
            // refresh cycle is redundant; Realtime + the next refresh cover intervening changes.
            ChatActivationPerf.groupInboxRPCReused()
            let groupRows = fallbackGroupRows
            let participantPreviews = try await fetchDmParticipantPreviews(for: rows)
            guard !Task.isCancelled else { return }
            guard stillCurrentChatAccount(me, context: "inboxEnrichmentAfterProfiles") else { return }

            var direct = buildInboxFriendDisplays(
                from: rows,
                me: me,
                participantPreviews: participantPreviews,
                profileLookupAttempted: true
            )
            direct = try await mergeAcceptedFriendsMissingFromInbox(me: me, inboxDisplays: direct)
            guard !Task.isCancelled else { return }
            guard stillCurrentChatAccount(me, context: "inboxEnrichmentBeforeApply") else { return }

            let buildStartedAt = CFAbsoluteTimeGetCurrent()
            let teamLinkedPickupIds = await groupChatService.teamLinkedPickupGameIds(
                among: groupRows.compactMap(\.pickup_game_id)
            )
            let groups = buildGroupInboxDisplays(
                from: groupRows,
                me: me,
                teamLinkedPickupGameIds: teamLinkedPickupIds
            )
            let visible = mergeInboxDisplays(direct: direct, groups: groups)
            ChatActivationPerf.snapshotBuildMs(
                (CFAbsoluteTimeGetCurrent() - buildStartedAt) * 1000,
                source: "enrichment"
            )

            applyInboxFriendsSnapshot(visible, source: "enrichment")
            scheduleGroupInboxAvatarHydration(
                groupConversationIds: groupRows.map(\.conversation_id),
                me: me
            )
            syncChatPresenceRealtimeIfNeeded(reason: "inboxSummariesEnriched")
#if DEBUG
            print("[BadgeSyncDebug] chat list updated (enriched)")
            let elapsed = String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - refreshStartedAt) * 1000)
            print("[DMRealtimeLatencyDebug] inboxUpdated conversationId=refresh_inbox_summaries_enriched elapsedMs=\(elapsed)")
#endif
            let totalUnread = visible.reduce(0) { $0 + $1.unreadCount }
            await setUnreadDirectMessageCountAndSyncAppIcon(totalUnread, source: "refresh_inbox_summaries_enriched")
            guard stillCurrentChatAccount(me, context: "inboxEnrichmentAfterUnread") else { return }

            lastInboxLoadAt = Date()
            noteAuthenticatedChatSession(userId: me, source: "inboxSummariesEnriched")
            ChatActivationPerf.enrichmentFinished(
                ms: Int((CFAbsoluteTimeGetCurrent() - enrichmentStartedAt) * 1000),
                applied: true
            )
            ChatActivationPerf.stableInboxReady(
                ms: Int((CFAbsoluteTimeGetCurrent() - refreshStartedAt) * 1000),
                rows: visible.count
            )
        } catch {
            ChatActivationPerf.enrichmentFinished(
                ms: Int((CFAbsoluteTimeGetCurrent() - enrichmentStartedAt) * 1000),
                applied: false
            )
            if ignoreCancellationIfNeeded(error, context: "inbox_summaries_enrichment") { return }
            // Keep fast-path rows; enrichment retries on next refresh.
        }
    }

    // MARK: - Blocked Users management

    func refreshBlockedUsers() async {
        do {
            blockedUserIds = try await moderation.fetchBlockedUserIds()
            usersWhoBlockedMeIds = try await moderation.fetchUsersWhoBlockedMeIds()
            let previews = await moderation.fetchUserPreviews(for: Array(blockedUserIds))
            // Keep stable order.
            let byId = Dictionary(uniqueKeysWithValues: previews.map { ($0.id, $0) })
            blockedUserPreviews = Array(blockedUserIds).compactMap { byId[$0] }.sorted { $0.displayName < $1.displayName }
        } catch {
            blockedUserIds = []
            usersWhoBlockedMeIds = []
            blockedUserPreviews = []
        }
    }

    func unblockUser(_ userId: UUID) async {
        do {
            try await moderation.unblock(userId: userId)
            await refreshBlockedUsers()
            await refreshInboxSummaries()
        } catch {
            // Keep UI lightweight; surface errors only if needed later.
        }
    }

    /// After ``clear_direct_conversation``: mirror server soft-hide locally so inbox updates immediately
    /// for this auth user only (peer history unchanged).
    @MainActor
    func noteDirectConversationClearedForCurrentUser(conversationId: UUID, peerUserId: UUID) async {
        hideInboxConversationLocally(peerUserId: peerUserId, conversationId: conversationId)
        serverExcludedInboxConversationIds.insert(conversationId)
        serverInboxExclusionsAvailable = true
        await refreshServerInboxExclusionsIfAvailable()
    }

    /// Swipe-delete from inbox: per-user soft-delete (Recently Deleted). Does not leave groups.
    /// Does not remove friendships. Shared history remains for other participants.
    func clearInboxConversation(peerUserId: UUID, conversationId: UUID? = nil) async {
#if DEBUG
        print("[DMDelete] delete tapped friendUserId=\(peerUserId.uuidString.lowercased()) conversationId=\(conversationId?.uuidString.lowercased() ?? "nil")")
#endif
        inboxDeleteError = nil

        let inboxRow = friends.first(where: {
            if let conversationId { return $0.conversationId == conversationId }
            return $0.preview.id == peerUserId && $0.isConversationBacked
        })
        let isGroup = inboxRow?.isGroupConversation == true
        let serverKind = isGroup ? "group" : "direct"

        let cid: UUID
        if let conversationId {
            cid = conversationId
        } else if isGroup {
            inboxDeleteError = L10n.t("chat_recently_deleted_delete_failed")
            return
        } else {
            do {
                cid = try await directChatService.startDirectConversation(friendUserId: peerUserId)
            } catch {
                inboxDeleteError = error.localizedDescription
                return
            }
        }

        // Optimistic local hide — rolled back if server soft-delete fails.
        hideInboxConversationLocally(peerUserId: peerUserId, conversationId: cid)
#if DEBUG
        print("[DMDelete] local remove friendUserId=\(peerUserId.uuidString.lowercased())")
#endif

        do {
            try await recentlyDeletedService.softDelete(kind: serverKind, conversationId: cid)
            serverExcludedInboxConversationIds.insert(cid)
            serverInboxExclusionsAvailable = true
#if DEBUG
            print("[DMDelete] server soft-delete success conversationId=\(cid.uuidString.lowercased()) kind=\(serverKind)")
#endif
        } catch {
#if DEBUG
            print(
                "[DMDelete] server soft-delete error friendUserId=\(peerUserId.uuidString.lowercased()) " +
                "error=\(error.localizedDescription)"
            )
#endif
            // Keep optimistic hide only when the RPC is missing (migration not applied yet)
            // so the known group-hide client filter still works offline of the new backend.
            if Self.isMissingRPCError(error) {
                // Client-only fallback: UserDefaults hide + group filter (pre-migration).
#if DEBUG
                print("[DMDelete] soft-delete RPC missing; keeping local hide fallback")
#endif
            } else {
                revealInboxConversationIfHidden(conversationId: cid, peerUserId: peerUserId, reason: "softDeleteFailed")
                inboxDeleteError = error.localizedDescription
                await refreshInboxSummaries()
                return
            }
        }

        await refreshInboxSummaries()
#if DEBUG
        print("[DMDelete] inbox refreshed friendUserId=\(peerUserId.uuidString.lowercased())")
#endif
    }

    func fetchRecentlyDeletedConversations() async throws -> [RecentlyDeletedChatConversationRow] {
        try await recentlyDeletedService.fetchRecentlyDeleted()
    }

    func restoreRecentlyDeletedConversation(_ row: RecentlyDeletedChatConversationRow) async throws {
        try await recentlyDeletedService.restore(kind: row.serverKindParam, conversationId: row.conversation_id)
        serverExcludedInboxConversationIds.remove(row.conversation_id)
        revealInboxConversationIfHidden(
            conversationId: row.conversation_id,
            peerUserId: row.peer_user_id,
            reason: "recentlyDeletedRestore"
        )
    }

    /// Outbound send (share or composer) must make the conversation visible to the sender again.
    /// Server auto-restore only clears soft-delete for the *recipient* of inbound messages.
    func restoreInboxVisibilityAfterOutboundSend(
        serverKind: String,
        conversationId: UUID,
        peerUserId: UUID?,
        reason: String
    ) async {
        do {
            try await recentlyDeletedService.restore(kind: serverKind, conversationId: conversationId)
#if DEBUG
            print(
                "[ChatOutboundRestore] restoreRPC ok kind=\(serverKind) " +
                "conversationId=\(conversationId.uuidString.lowercased()) reason=\(reason)"
            )
#endif
        } catch {
#if DEBUG
            print(
                "[ChatOutboundRestore] restoreRPC error kind=\(serverKind) " +
                "conversationId=\(conversationId.uuidString.lowercased()) " +
                "reason=\(reason) error=\(error.localizedDescription)"
            )
#endif
            // Missing RPC / already-visible: still clear local hide so Recent can show the row.
            if !Self.isMissingRPCError(error) {
                // Non-missing failures still proceed to local reveal; refresh reconciles.
            }
        }

        await MainActor.run {
            serverExcludedInboxConversationIds.remove(conversationId)
            revealInboxConversationIfHidden(
                conversationId: conversationId,
                peerUserId: peerUserId,
                reason: reason
            )
        }
    }

    /// Immediately surfaces an outbound share in Recent conversations (before refresh/realtime).
    @MainActor
    func upsertInboxDisplayAfterOutboundShare(
        conversationId: UUID,
        peerUserId: UUID?,
        body: String,
        inboxKind: ChatInboxConversationKind
    ) {
        let subtitle = ChatInboxPreviewFormatting.previewLine(
            body: body,
            isFromCurrentUser: true
        )
        let lastAt = Date()

        if let idx = friends.firstIndex(where: { $0.conversationId == conversationId }) {
            let old = friends[idx]
            let updated = FriendDisplay(
                id: old.id,
                preview: old.preview,
                subtitle: subtitle,
                lastMessageAt: lastAt,
                unreadCount: 0,
                isConversationBacked: true,
                conversationId: conversationId,
                inboxKind: old.inboxKind,
                groupMemberCount: old.groupMemberCount,
                isGroupMuted: old.isGroupMuted,
                pickupGameId: old.pickupGameId,
                fanTeamId: old.fanTeamId
            )
            var next = friends
            next[idx] = updated
            next.sort(by: Self.isInboxRowOrderedBefore)
            friends = next
            syncChatPresenceRealtimeIfNeeded(reason: "outboundSharePatchedInbox")
#if DEBUG
            print(
                "[ChatOutboundRestore] inboxUpsert existing conversationId=\(conversationId.uuidString.lowercased())"
            )
#endif
            return
        }

        guard inboxKind != .group else {
            // Group rows should already exist when shareable; refresh will reconcile if missing.
            return
        }

        let peer = peerUserId
        let preview: UserPreview = {
            if let peer,
               let existing = friends.first(where: { $0.preview.id == peer })?.preview {
                return existing
            }
            return UserPreview(
                id: peer ?? conversationId,
                displayName: "Fan",
                username: nil,
                email: nil,
                avatarURL: nil,
                avatarThumbnailURL: nil,
                dmConversationId: conversationId
            )
        }()

        let display = FriendDisplay(
            id: conversationId,
            preview: preview,
            subtitle: subtitle,
            lastMessageAt: lastAt,
            unreadCount: 0,
            isConversationBacked: true,
            conversationId: conversationId,
            inboxKind: inboxKind
        )

        var next = friends.filter { row in
            if row.conversationId == conversationId { return false }
            if let peer, !row.isConversationBacked, row.preview.id == peer { return false }
            return true
        }
        next.insert(display, at: 0)
        next.sort(by: Self.isInboxRowOrderedBefore)
        friends = next
        syncChatPresenceRealtimeIfNeeded(reason: "outboundShareReappearedInbox")
#if DEBUG
        print(
            "[ChatOutboundRestore] inboxUpsert new conversationId=\(conversationId.uuidString.lowercased()) " +
            "peer=\(peer?.uuidString.lowercased() ?? "nil")"
        )
#endif
    }

    func permanentlyDeleteRecentlyDeletedConversation(_ row: RecentlyDeletedChatConversationRow) async throws {
        try await recentlyDeletedService.permanentlyDelete(kind: row.serverKindParam, conversationId: row.conversation_id)
        serverExcludedInboxConversationIds.insert(row.conversation_id)
        hideInboxConversationLocally(
            peerUserId: row.peer_user_id ?? row.conversation_id,
            conversationId: row.conversation_id
        )
    }

    private static func isMissingRPCError(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("could not find the function")
            || text.contains("pgrst202")
            || text.contains("404")
            || text.contains("does not exist")
    }

    func previewForLoadedDmParticipant(userId: UUID, conversationId: UUID? = nil) -> UserPreview? {
        if let conversationId,
           let match = friends.first(where: { $0.conversationId == conversationId }) {
            return match.preview
        }
        if let conversationId,
           let match = friends.first(where: { $0.preview.dmConversationId == conversationId }) {
            return match.preview
        }
        if conversationId != nil {
            // Venue threads share the owner auth id with fan DMs — never reuse a peer row by user id alone.
            return nil
        }
        if let match = friends.first(where: { $0.preview.id == userId && $0.preview.isBusinessVenueConversation }) {
            return match.preview
        }
        return friends.first(where: { $0.preview.id == userId && $0.conversationId == nil })?.preview
            ?? friends.first(where: { $0.preview.id == userId && !$0.preview.isBusinessVenueConversation })?.preview
    }

    func resolveDmParticipantPreview(
        userId: UUID,
        fallback: UserPreview,
        surface: String,
        conversationId: UUID? = nil
    ) async -> UserPreview {
        let sessionAuthId = currentUserAuthId
        // Fan viewers keep venue/business peer identity locked.
        // Business viewers must resolve the fan counterpart even when a stale venue preview was seeded.
        if fallback.isBusinessVenueConversation,
           !ChatDMCounterpartResolution.isBusinessSession(mapViewModel: mapViewModel) {
            ChatCounterpartDebug.log("counterpart type=business surface=\(surface) venuePeerPreserved=true")
            return fallback
        }
        if fallback.isDeleted {
            logDeletedUserRenderDebug(surface: surface, preview: fallback)
            return fallback
        }

        do {
            if let resolved = try await socialIdentityService.fetchUserPreviews(for: [userId])[userId] {
                if let sessionAuthId, currentUserAuthId != sessionAuthId {
                    ChatCounterpartDebug.log("stale session result ignored surface=\(surface)")
                    return fallback
                }
                let merged = UserPreview(
                    id: resolved.id,
                    displayName: resolved.displayName,
                    username: resolved.username,
                    email: resolved.email,
                    avatarURL: resolved.avatarURL,
                    avatarThumbnailURL: resolved.avatarThumbnailURL,
                    isBusinessAccount: false,
                    isDeleted: resolved.isDeleted,
                    lastSeenAtRaw: resolved.lastSeenAtRaw,
                    dmConversationId: conversationId ?? fallback.dmConversationId ?? resolved.dmConversationId,
                    businessVenueId: nil,
                    businessVenueBusinessId: nil,
                    businessVenueBusinessName: nil,
                    venueScopedThread: fallback.venueScopedThread || fallback.isVenueScopedDirectMessage
                )
                logDeletedUserRenderDebug(surface: surface, preview: merged)
                ChatCounterpartDebug.log(
                    "fan identity resolved surface=\(surface) hasHandle=\(!merged.publicHandleLine.isEmpty) hasAvatar=\(!(merged.avatarURL ?? "").isEmpty || !(merged.avatarThumbnailURL ?? "").isEmpty)"
                )
                patchLoadedDmParticipantPreview(merged, conversationId: conversationId ?? fallback.dmConversationId)
                return merged
            }
        } catch {
            // Treat unresolved fan identities as deleted for DM presentation; the messages remain intact.
        }

        if let sessionAuthId, currentUserAuthId != sessionAuthId {
            ChatCounterpartDebug.log("stale session result ignored surface=\(surface) phase=deletedFallback")
            return fallback
        }

        let deleted = deletedUserPreview(userId: userId, email: fallback.email)
        logDeletedUserRenderDebug(surface: surface, preview: deleted)
        ChatCounterpartDebug.log("fallback identity used surface=\(surface) reason=profileMissing")
        patchLoadedDmParticipantPreview(deleted, conversationId: conversationId ?? fallback.dmConversationId)
        return deleted
    }

    func refreshDirectChatPresencePreview(
        userId: UUID,
        fallback: UserPreview,
        source: String
    ) async -> UserPreview? {
        if fallback.isBusinessVenueConversation {
            return nil
        }
        do {
            guard let resolved = try await socialIdentityService.fetchUserPreviews(for: [userId])[userId] else {
                return nil
            }
            patchLoadedDmParticipantPreview(resolved, conversationId: fallback.dmConversationId)
            return resolved
        } catch {
#if DEBUG
            DebugLogGate.debug("[PresenceDebug] directChatPresenceRefreshFailed=true friendId=\(userId.uuidString.lowercased()) presenceSource=\(source) error=\(error.localizedDescription)")
#endif
            return nil
        }
    }

    /// Same RPC path as ``DirectChatView`` / inbox rows: returns an existing peer DM conversation id or creates one (no duplicate threads).
    func startDirectConversationWithFriend(friendUserId: UUID) async throws -> UUID {
        try await directChatService.startDirectConversation(friendUserId: friendUserId)
    }

    /// Sends an encoded profile-share message to one or more chat destinations.
    /// Uses peer user IDs for friend DMs, existing conversation IDs for inbox threads, and group send for groups.
    func shareFanProfileMessage(
        body: String,
        toRecipients: [FriendDisplay]
    ) async -> String? {
        guard !toRecipients.isEmpty else {
            return L10n.t("share_profile_choose_recipient")
        }
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else {
            return L10n.t("share_profile_unavailable")
        }

        do {
            let me = try await directChatService.currentUserId()
            var sentCount = 0
            var lastFailure: String?

            for recipient in toRecipients {
                do {
                    switch recipient.inboxKind {
                    case .group:
                        guard let conversationId = recipient.conversationId else {
#if DEBUG
                            print("[ProfileShareDebug] skip group missingConversationId displayId=\(recipient.id.uuidString.lowercased())")
#endif
                            lastFailure = L10n.t("share_profile_failed")
                            continue
                        }
#if DEBUG
                        print("[ProfileShareDebug] send group conversationId=\(conversationId.uuidString.lowercased())")
#endif
                        _ = try await groupChatService.sendMessage(
                            conversationId: conversationId,
                            body: trimmedBody
                        )
                        // Group share path unchanged except sender visibility restore if swipe-hidden.
                        await restoreInboxVisibilityAfterOutboundSend(
                            serverKind: "group",
                            conversationId: conversationId,
                            peerUserId: nil,
                            reason: "profileShareSent"
                        )
                        await MainActor.run {
                            upsertInboxDisplayAfterOutboundShare(
                                conversationId: conversationId,
                                peerUserId: nil,
                                body: trimmedBody,
                                inboxKind: .group
                            )
                        }
                        sentCount += 1

                    case .direct, .business:
                        let peerUserId = recipient.preview.id
                        if recipient.inboxKind == .direct, isEitherDirectionBlocked(with: peerUserId) {
#if DEBUG
                            print("[ProfileShareDebug] skip blocked peer=\(peerUserId.uuidString.lowercased())")
#endif
                            continue
                        }

                        let conversationId: UUID
                        if let existing = recipient.conversationId {
                            conversationId = existing
#if DEBUG
                            print("[ProfileShareDebug] send \(recipient.inboxKind.rawValue) existingConversationId=\(conversationId.uuidString.lowercased()) peer=\(peerUserId.uuidString.lowercased())")
#endif
                        } else {
                            // Friend row without a thread yet — open/create via peer user id (never FriendDisplay.id).
#if DEBUG
                            print("[ProfileShareDebug] startDirectConversation peer=\(peerUserId.uuidString.lowercased()) displayId=\(recipient.id.uuidString.lowercased())")
#endif
                            conversationId = try await directChatService.startDirectConversation(friendUserId: peerUserId)
                        }

                        if let limited = RateLimitService.checkDirectChatSend(conversationId: conversationId, body: trimmedBody) {
                            if sentCount == 0 { return limited }
                            lastFailure = limited
                            continue
                        }

                        _ = try await directChatService.sendMessage(
                            conversationId: conversationId,
                            senderId: me,
                            body: trimmedBody
                        )
                        RateLimitService.recordDirectChatSend(conversationId: conversationId, body: trimmedBody)
                        FanGeoAnalyticsService.recordDMSent(conversationId: conversationId)

                        // Soft-delete is inbound-only on the server; restore sender visibility here.
                        await restoreInboxVisibilityAfterOutboundSend(
                            serverKind: "direct",
                            conversationId: conversationId,
                            peerUserId: peerUserId,
                            reason: "profileShareSent"
                        )
                        await MainActor.run {
                            upsertInboxDisplayAfterOutboundShare(
                                conversationId: conversationId,
                                peerUserId: peerUserId,
                                body: trimmedBody,
                                inboxKind: recipient.inboxKind
                            )
                        }
                        sentCount += 1
                    }
                } catch {
#if DEBUG
                    print(
                        "[ProfileShareDebug] failed kind=\(recipient.inboxKind.rawValue) displayId=\(recipient.id.uuidString.lowercased()) peer=\(recipient.preview.id.uuidString.lowercased()) conversationId=\(recipient.conversationId?.uuidString.lowercased() ?? "nil") error=\(error)"
                    )
#endif
                    if AgeAccessBackendDenial.handle(error, requestUserId: nil) {
                        return L10n.t("share_profile_failed")
                    }
                    lastFailure = L10n.t("share_profile_failed")
                }
            }

            guard sentCount > 0 else {
                return lastFailure ?? L10n.t("share_profile_failed")
            }
            await refreshInboxSummaries()
            requestBadgeRecalculation(reason: "profileShareSent", includeInboxSummaries: true)
            return nil
        } catch {
#if DEBUG
            print("[ProfileShareDebug] outerFailure error=\(error)")
#endif
            AgeAccessBackendDenial.handle(error, requestUserId: nil)
            return L10n.t("share_profile_failed")
        }
    }

    /// Legacy helper kept for call sites that only have peer user IDs (friends without inbox rows).
    func shareFanProfileMessage(body: String, toRecipientUserIds friendUserIds: [UUID]) async -> String? {
        let recipients: [FriendDisplay] = friendUserIds.map { userId in
            if let existing = friends.first(where: { !$0.isGroupConversation && $0.preview.id == userId }) {
                return existing
            }
            return FriendDisplay(
                id: userId,
                preview: UserPreview(id: userId, displayName: "Fan", avatarURL: nil),
                subtitle: nil,
                lastMessageAt: nil,
                unreadCount: 0,
                isConversationBacked: false,
                conversationId: nil,
                inboxKind: .direct
            )
        }
        return await shareFanProfileMessage(body: body, toRecipients: recipients)
    }

    func refresh() async {
        if let inFlight = fullRefreshInFlightTask {
            ChatActivationPerf.inboxRefreshCoalesced(source: "fullRefresh")
            await inFlight.value
            return
        }
        ChatActivationPerf.inboxRefreshRequested(source: "fullRefresh")
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performFullRefresh()
        }
        fullRefreshInFlightTask = task
        await task.value
        if fullRefreshInFlightTask == task {
            fullRefreshInFlightTask = nil
        }
    }

    private func performFullRefresh() async {
        let fullRefreshStartedAt = CFAbsoluteTimeGetCurrent()
        isLoading = true
        errorMessage = nil
        friendRequestAlertTitle = nil
        defer { isLoading = false }

        do {
            let me = try await service.currentUserId()
            if let priorMe = currentUserAuthId, priorMe != me {
                await stopInboxRealtimeListener()
                await stopFriendshipsRealtimeListener()
            }
            noteAuthenticatedChatSession(userId: me, source: "fullRefresh")
            groupInboxAvatarHydrationRefreshToken &+= 1
            lastCompletedGroupInboxAvatarHydrationKey = nil
            await reloadModerationBlockSets()
            async let accepted = service.fetchAcceptedFriendships(for: me)
            async let incoming = service.fetchIncomingFriendRequestsVisible(for: me)
            async let outgoing = service.fetchOutgoingFriendRequestsVisible(for: me)
            async let inbox = directChatService.fetchInboxSummaries()
            async let exclusionsTask: Void = refreshServerInboxExclusionsIfAvailable()
            let (accRows, inRows, outRows, inboxRows) = try await (accepted, incoming, outgoing, inbox)
            _ = await exclusionsTask
            let participantPreviews = try await fetchDmParticipantPreviews(for: inboxRows)

            let previewIds = Set(
                inRows.map(\.requester_id)
                    + outRows.map(\.addressee_id)
            )
            let previewsById = try await socialIdentityService.fetchUserPreviews(for: Array(previewIds))

            let inboxFiltered = inboxRows.filter { !isEitherDirectionBlocked(with: $0.friend_user_id) }
            var friendDisplays = buildInboxFriendDisplays(
                from: inboxFiltered,
                me: me,
                participantPreviews: participantPreviews,
                profileLookupAttempted: true
            )
            friendDisplays = try await mergeAcceptedFriendsMissingFromInbox(me: me, inboxDisplays: friendDisplays)
            friendDisplays = applyHiddenInboxPeerFilter(friendDisplays)
            ChatActivationPerf.groupInboxRPCStarted()
            let groupRows = (try? await groupChatService.fetchInboxSummaries()) ?? []
            let teamLinkedPickupIds = await groupChatService.teamLinkedPickupGameIds(
                among: groupRows.compactMap(\.pickup_game_id)
            )
            let groupDisplays = buildGroupInboxDisplays(
                from: groupRows,
                me: me,
                teamLinkedPickupGameIds: teamLinkedPickupIds
            )
            let fullRefreshVisible = mergeInboxDisplays(direct: friendDisplays, groups: groupDisplays)
            applyInboxFriendsSnapshot(fullRefreshVisible, source: "fullRefresh")
            ChatActivationPerf.stableInboxReady(
                ms: Int((CFAbsoluteTimeGetCurrent() - fullRefreshStartedAt) * 1000),
                rows: fullRefreshVisible.count
            )
            scheduleGroupInboxAvatarHydration(groupConversationIds: groupRows.map(\.conversation_id), me: me)
            syncChatPresenceRealtimeIfNeeded(reason: "fullRefreshLoaded")
#if DEBUG
            print("[BadgeSyncDebug] chat list updated")
            let fullRefreshElapsed = String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - fullRefreshStartedAt) * 1000)
            print("[DMRealtimeLatencyDebug] inboxUpdated conversationId=full_refresh elapsedMs=\(fullRefreshElapsed)")
#endif

            incomingRequests = inRows
                .filter { !isEitherDirectionBlocked(with: $0.requester_id) }
                .map { row in
                let preview = previewsById[row.requester_id] ?? deletedUserPreview(userId: row.requester_id)
                return IncomingRequestDisplay(friendship: row, requester: preview)
            }

            outgoingRequests = outRows
                .filter { !isEitherDirectionBlocked(with: $0.addressee_id) }
                .map { row in
                let preview = previewsById[row.addressee_id] ?? deletedUserPreview(userId: row.addressee_id)
                return OutgoingRequestDisplay(friendship: row, addressee: preview)
            }

            pendingBadgeCount = incomingRequests.filter { $0.friendship.isPendingStatus }.count
#if DEBUG
            print("[BadgeSyncDebug] tab badge updated")
#endif
            requiresSignIn = false
            lastLoadAt = Date()
            lastInboxLoadAt = Date()
            noteAuthenticatedChatSession(userId: me, source: "fullRefreshLoaded")
            applyFriendshipChipStates(
                me: me,
                accepted: accRows,
                incoming: inRows,
                outgoing: outRows
            )
            let totalUnread = friends.reduce(0) { $0 + $1.unreadCount }
            await setUnreadDirectMessageCountAndSyncAppIcon(totalUnread, source: "full_refresh")
            await ensureSignedInSocialRealtimeIfNeeded()
        } catch {
            if ignoreCancellationIfNeeded(error, context: "chat_full_refresh") { return }
            friends = []
            incomingRequests = []
            outgoingRequests = []
            pendingBadgeCount = 0
            groupInboxAvatarMemberIdsByConversationId = [:]
            groupMemberPreviewByUserId = [:]
            friendshipChipByOtherUserId = [:]
            currentUserAuthId = nil
            let msg = error.localizedDescription
            if msg.localizedCaseInsensitiveContains("session")
                || msg.localizedCaseInsensitiveContains("jwt")
                || msg.localizedCaseInsensitiveContains("not authenticated") {
                clearForSignOut()
            } else {
                requiresSignIn = false
                errorMessage = msg
                lastLoadAt = Date()
            }
        }
    }

    private static func parseISO8601(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: raw) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: raw)
    }

    func accept(_ item: IncomingRequestDisplay) async {
        let requestId = item.friendship.id
        guard !friendRequestActionInFlightIds.contains(requestId) else { return }
        friendRequestActionInFlightIds.insert(requestId)
        defer { friendRequestActionInFlightIds.remove(requestId) }

        let responded = ISO8601DateFormatter().string(from: Date())
        let acceptedFriendship = item.friendship.withAcceptedNow(respondedAt: responded)
        let snapshot = incomingRequests
        let chipSnapshot = friendshipChipByOtherUserId

        // Optimistic: drop pending request immediately; authoritative refresh follows.
        incomingRequests.removeAll { $0.id == item.id }
        pendingBadgeCount = incomingRequests.filter { $0.friendship.isPendingStatus }.count
        let rid = item.requester.id
        var chips = friendshipChipByOtherUserId
        chips[rid] = .friends
        friendshipChipByOtherUserId = chips

        do {
            try await service.acceptFriendRequest(requestId: requestId)
            await refresh()
            await awardFriendConnectedXP(friendship: acceptedFriendship)
        } catch {
            if ignoreCancellationIfNeeded(error, context: "friend_request_accept") {
                incomingRequests = snapshot
                pendingBadgeCount = incomingRequests.filter { $0.friendship.isPendingStatus }.count
                friendshipChipByOtherUserId = chipSnapshot
                return
            }
            incomingRequests = snapshot
            pendingBadgeCount = incomingRequests.filter { $0.friendship.isPendingStatus }.count
            friendshipChipByOtherUserId = chipSnapshot
            if AgeAccessBackendDenial.handle(error, requestUserId: nil) { return }
#if DEBUG
            print("[FriendRequest] accept failed id=\(requestId) error=\(error)")
#endif
            presentFriendRequestError(
                titleKey: "friend_request_accept_failed_title",
                messageKey: "friend_request_accept_failed_message",
                underlying: error
            )
            await refreshFriendRequestListsOnly()
        }
    }

    func isFriendRequestActionInFlight(_ friendshipId: UUID) -> Bool {
        friendRequestActionInFlightIds.contains(friendshipId)
    }

    private func presentFriendRequestError(
        titleKey: String,
        messageKey: String,
        underlying: Error
    ) {
        let languageCode = L10n.normalizedLanguageCode(
            UserDefaults.standard.string(forKey: L10n.appLanguageKey)
        )
        friendRequestAlertTitle = L10n.t(titleKey, languageCode: languageCode)
        errorMessage = L10n.t(messageKey, languageCode: languageCode)
#if DEBUG
        print("[FriendRequest] userAlert titleKey=\(titleKey) underlying=\(underlying.localizedDescription)")
#endif
    }

    private func awardFriendConnectedXP(friendship: FriendshipRow) async {
        guard let map = mapViewModel else { return }
        // `claim_fan_xp` awards both accepted friendship participants server-side.
        await map.awardFanXP(
            source: FanXPSource.friendConnected,
            sourceId: friendship.id
        )
    }

    func reject(_ item: IncomingRequestDisplay) async {
        let requestId = item.friendship.id
        guard !friendRequestActionInFlightIds.contains(requestId) else { return }
        friendRequestActionInFlightIds.insert(requestId)
        defer { friendRequestActionInFlightIds.remove(requestId) }

        let responded = ISO8601DateFormatter().string(from: Date())
        let optimistic = item.friendship.withDeclinedNow(respondedAt: responded)
        let snapshot = incomingRequests
        if let idx = incomingRequests.firstIndex(where: { $0.id == item.id }) {
            var next = incomingRequests
            next[idx] = IncomingRequestDisplay(friendship: optimistic, requester: item.requester)
            incomingRequests = next
        }
        pendingBadgeCount = incomingRequests.filter { $0.friendship.isPendingStatus }.count
        let rid = item.requester.id
        if friendshipChipByOtherUserId[rid] == .pendingIncoming {
            var m = friendshipChipByOtherUserId
            m.removeValue(forKey: rid)
            friendshipChipByOtherUserId = m
        }
        do {
            try await service.rejectFriendRequest(requestId: requestId)
            await refreshFriendRequestListsOnly()
        } catch {
            if ignoreCancellationIfNeeded(error, context: "friend_request_reject") {
                incomingRequests = snapshot
                pendingBadgeCount = incomingRequests.filter { $0.friendship.isPendingStatus }.count
                return
            }
            incomingRequests = snapshot
            pendingBadgeCount = incomingRequests.filter { $0.friendship.isPendingStatus }.count
            if AgeAccessBackendDenial.handle(error, requestUserId: nil) { return }
#if DEBUG
            print("[FriendRequest] decline failed id=\(requestId) error=\(error)")
#endif
            presentFriendRequestError(
                titleKey: "friend_request_decline_failed_title",
                messageKey: "friend_request_decline_failed_message",
                underlying: error
            )
            await refreshFriendRequestListsOnly()
        }
    }

    /// Clears a **declined** incoming request from the receiver’s list (soft-dismiss on server).
    func clearIncomingDeclinedRequest(_ item: IncomingRequestDisplay) async {
        guard item.friendship.isDeclinedStatus else { return }
        DebugLogGate.debug("[FriendRequest] clear requested id=\(item.id)")
        let snapshot = incomingRequests
        incomingRequests.removeAll { $0.id == item.id }
        pendingBadgeCount = incomingRequests.filter { $0.friendship.isPendingStatus }.count
        do {
            try await service.clearFriendRequestView(requestId: item.id)
            DebugLogGate.debug("[FriendRequest] clear completed id=\(item.id)")
            await refreshFriendRequestListsOnly()
        } catch {
            if ignoreCancellationIfNeeded(error, context: "friend_request_clear_incoming") {
                incomingRequests = snapshot
                pendingBadgeCount = incomingRequests.filter { $0.friendship.isPendingStatus }.count
                return
            }
            DebugLogGate.debug("[FriendRequest] clear failed id=\(item.id) error=\(error)")
            incomingRequests = snapshot
            pendingBadgeCount = incomingRequests.filter { $0.friendship.isPendingStatus }.count
            presentFriendRequestError(
                titleKey: "friend_request_update_failed_title",
                messageKey: "friend_request_update_failed_message",
                underlying: error
            )
        }
    }

    /// Clears a **declined** outgoing request from the sender’s list (soft-dismiss on server).
    func clearOutgoingDeclinedRequest(_ item: OutgoingRequestDisplay) async {
        guard item.friendship.isDeclinedStatus else { return }
        DebugLogGate.debug("[FriendRequest] clear requested id=\(item.id)")
        let snapshot = outgoingRequests
        outgoingRequests.removeAll { $0.id == item.id }
        do {
            try await service.clearFriendRequestView(requestId: item.id)
            DebugLogGate.debug("[FriendRequest] clear completed id=\(item.id)")
            await refreshFriendRequestListsOnly()
        } catch {
            if ignoreCancellationIfNeeded(error, context: "friend_request_clear_outgoing") {
                outgoingRequests = snapshot
                return
            }
            DebugLogGate.debug("[FriendRequest] clear failed id=\(item.id) error=\(error)")
            outgoingRequests = snapshot
            presentFriendRequestError(
                titleKey: "friend_request_update_failed_title",
                messageKey: "friend_request_update_failed_message",
                underlying: error
            )
        }
    }

    func cancel(_ item: OutgoingRequestDisplay) async {
        guard item.friendship.isPendingStatus else { return }
        let peerId = item.addressee.id
#if DEBUG
        print("[FriendRequestDebug] cancelStarted peer=\(peerId.uuidString.lowercased())")
#endif
        DebugLogGate.debug("[FriendRequest] outgoing cancel requested id=\(item.id)")
        let snapshotOut = outgoingRequests
        let snapshotChips = friendshipChipByOtherUserId

        outgoingRequests.removeAll { $0.id == item.id }
        if friendshipChipByOtherUserId[peerId] == .pendingOutgoing {
            var m = friendshipChipByOtherUserId
            m.removeValue(forKey: peerId)
            friendshipChipByOtherUserId = m
        }

        do {
            try await service.cancelFriendRequest(requestId: item.friendship.id)
#if DEBUG
            print("[FriendRequestDebug] cancelSucceeded peer=\(peerId.uuidString.lowercased())")
#endif
            DebugLogGate.debug("[FriendRequest] outgoing cancel completed id=\(item.id)")
            await refreshFriendRequestListsOnly()
        } catch {
            if ignoreCancellationIfNeeded(error, context: "friend_request_cancel") {
                outgoingRequests = snapshotOut
                friendshipChipByOtherUserId = snapshotChips
                return
            }
#if DEBUG
            print("[FriendRequestDebug] cancelFailed peer=\(peerId.uuidString.lowercased()) error=\(error.localizedDescription)")
#endif
            DebugLogGate.debug("[FriendRequest] outgoing cancel failed id=\(item.id) error=\(error)")
            outgoingRequests = snapshotOut
            friendshipChipByOtherUserId = snapshotChips
            presentFriendRequestError(
                titleKey: "friend_request_update_failed_title",
                messageKey: "friend_request_update_failed_message",
                underlying: error
            )
            await refreshFriendRequestListsOnly()
        }
    }

    /// Cancels the viewer's outgoing pending request to a fan (Suggested Fans / public profile).
    func cancelOutgoingFriendRequest(to peerId: UUID) async {
        guard chipKind(forOtherUserId: peerId) == .pendingOutgoing else { return }

        if let item = outgoingRequests.first(where: {
            $0.addressee.id == peerId || $0.friendship.addressee_id == peerId
        }) {
            await cancel(item)
            return
        }

#if DEBUG
        print("[FriendRequestDebug] cancelStarted peer=\(peerId.uuidString.lowercased())")
#endif
        let snapshotChips = friendshipChipByOtherUserId
        if friendshipChipByOtherUserId[peerId] == .pendingOutgoing {
            var m = friendshipChipByOtherUserId
            m.removeValue(forKey: peerId)
            friendshipChipByOtherUserId = m
        }

        do {
            let me = try await service.currentUserId()
            let rows = try await service.fetchFriendshipsBetween(me: me, other: peerId)
            guard let row = rows.first(where: { $0.isPendingStatus && $0.requester_id == me }) else {
#if DEBUG
                print("[FriendRequestDebug] cancelFailed peer=\(peerId.uuidString.lowercased()) error=no_pending_row")
#endif
                friendshipChipByOtherUserId = snapshotChips
                await refreshFriendRequestListsOnly()
                return
            }
            try await service.cancelFriendRequest(requestId: row.id)
#if DEBUG
            print("[FriendRequestDebug] cancelSucceeded peer=\(peerId.uuidString.lowercased())")
#endif
            await refreshFriendRequestListsOnly()
        } catch {
            if ignoreCancellationIfNeeded(error, context: "friend_request_cancel_peer") {
                friendshipChipByOtherUserId = snapshotChips
                return
            }
#if DEBUG
            print("[FriendRequestDebug] cancelFailed peer=\(peerId.uuidString.lowercased()) error=\(error.localizedDescription)")
#endif
            friendshipChipByOtherUserId = snapshotChips
            presentFriendRequestError(
                titleKey: "friend_request_update_failed_title",
                messageKey: "friend_request_update_failed_message",
                underlying: error
            )
            await refreshFriendRequestListsOnly()
        }
    }

    /// Removes an accepted friendship from the Friends directory (`remove_friend` only — DM history is preserved).
    func unfriend(_ item: FriendDisplay) async {
        unfriendError = nil
        let peerUserId = item.preview.id
        let snapshotFriends = friends
        let snapshotChips = friendshipChipByOtherUserId

        friends.removeAll { $0.preview.id == peerUserId && !$0.isConversationBacked }
        var chips = friendshipChipByOtherUserId
        chips.removeValue(forKey: peerUserId)
        friendshipChipByOtherUserId = chips

        do {
            try await service.removeFriend(friendUserId: peerUserId)
            await refreshInboxSummaries()
            await refreshFriendRequestListsOnly()
        } catch {
            if ignoreCancellationIfNeeded(error, context: "unfriend") {
                friends = snapshotFriends
                friendshipChipByOtherUserId = snapshotChips
                return
            }
            friends = snapshotFriends
            friendshipChipByOtherUserId = snapshotChips
            unfriendError = error.localizedDescription
        }
    }

    /// Public-profile entry point — delegates to ``unfriend(_:)`` (same `remove_friend` path).
    func unfriend(peerUserId: UUID, displayPreview: UserPreview? = nil) async {
        if let existing = friends.first(where: { $0.preview.id == peerUserId }) {
            await unfriend(existing)
            return
        }
        let preview = displayPreview ?? UserPreview(
            id: peerUserId,
            displayName: "",
            avatarURL: nil
        )
        await unfriend(
            FriendDisplay(
                id: peerUserId,
                preview: preview,
                subtitle: nil,
                lastMessageAt: nil,
                unreadCount: 0,
                isConversationBacked: false,
                conversationId: nil
            )
        )
    }

    func sendFriendRequest(to addresseeId: UUID) async {
        if isEitherDirectionBlocked(with: addresseeId) {
            errorMessage = "You can’t send a friend request to this user."
            return
        }
        do {
            let me = try await service.currentUserId()
            try await service.sendFriendRequest(requesterId: me, addresseeId: addresseeId)
            await refreshFriendRequestListsOnly()
        } catch {
            if ignoreCancellationIfNeeded(error, context: "friend_request_send") { return }
            if AgeAccessBackendDenial.handle(error, requestUserId: nil) { return }
            errorMessage = error.localizedDescription
        }
    }

    func refreshAddFriendSearch(query raw: String) async {
        let normalized = FriendshipService.normalizedFriendLookupQuery(raw)
        guard !normalized.isEmpty else {
            addFriendSearchResults = []
            return
        }
        addFriendSearchIsLoading = true
        defer { addFriendSearchIsLoading = false }
        do {
            let me = try await service.currentUserId()
            addFriendSearchResults = try await service.searchAddFriendTargets(
                normalizedQuery: normalized,
                excludingUserId: me
            )
        } catch {
            addFriendSearchResults = []
        }
    }

    func clearAddFriendSearch() {
        addFriendSearchResults = []
        addFriendSearchIsLoading = false
    }

    /// Add friend to a selected search hit (fan user only; businesses are discovery-only).
    func sendFriendRequest(to target: AddFriendSearchTarget) async -> AddFriendLookupOutcome {
#if DEBUG
        print("[FriendSearchDebug] send entity_type=\(target.entityType.rawValue) entity_id=\(target.entityId.uuidString)")
#endif
        guard target.entityType == .user else {
            return .informational("Businesses can't be added as friends, but you can message one of their venues.")
        }
        do {
            let me = try await service.currentUserId()
            if target.entityType == .user, me == target.entityId {
                return .informational("Cannot add yourself. Use another fan or business.")
            }

            let rows = try await service.fetchFriendships(for: target, me: me)
            let relation = FriendshipService.classifyExistingRelation(me: me, rows: rows)
            if let message = FriendshipService.userFacingMessageForExistingRelation(relation) {
                return .informational(message)
            }

            let requesterEntity = (try? await service.fetchSocialEntity(userId: me))
                ?? FriendSocialEntity(id: me, kind: .fanUser)
            let targetEntity = FriendSocialEntity(id: target.entityId, kind: target.socialEntityKind)
#if DEBUG
            FriendshipService.logPendingRelationshipDebug(
                requester: requesterEntity,
                target: targetEntity,
                matchedPending: false,
                friendshipId: nil
            )
#endif

            try await service.sendFriendRequest(requesterId: me, addresseeId: target.entityId)
            await refreshAfterFriendLookupAttempt()
            logFriendRequestVisibilityDebug(
                lookupResult: "created",
                targetUserId: target.entityId,
                me: me
            )
            return .success
        } catch {
            await refreshAfterFriendLookupAttempt()
            if AgeAccessBackendDenial.handle(error, requestUserId: nil) {
                return .informational(L10n.t("share_profile_failed"))
            }
            return await resolveAddFriendLookupOutcomeAfterError(error, target: target)
        }
    }

    /// Legacy path: normalized query only (fan RPC). Prefer ``sendFriendRequest(to:)`` after search.
    func sendFriendRequestByLookup(_ raw: String) async -> AddFriendLookupOutcome {
        let normalized = FriendshipService.normalizedFriendLookupQuery(raw)
        guard !normalized.isEmpty else {
            return .informational("Enter an email or display name.")
        }
        await refreshAddFriendSearch(query: raw)
        if let first = addFriendSearchResults.first {
            return await sendFriendRequest(to: first)
        }
        return .informational("No FanGeo account found with that email or display name.")
    }

    /// Lists active venues for a business before opening a venue-scoped DM.
    func prepareBusinessVenueMessage(from target: AddFriendSearchTarget) async -> AddFriendBusinessMessageOutcome {
        guard target.entityType == .business else {
            return .informational("Only businesses can be messaged from here.")
        }

        do {
            let venues = try await service.fetchActiveVenuesForBusinessMessaging(businessId: target.entityId)
            if venues.isEmpty {
                return .informational("No active venues available for this business.")
            }
            if venues.count == 1, let venue = venues.first {
                return await openBusinessVenueConversation(target: target, venue: venue)
            }
            return .needsVenuePicker(venues)
        } catch {
            return .informational("No active venues available for this business.")
        }
    }

    /// Opens or creates a fan-initiated venue-scoped business DM.
    func openBusinessVenueConversation(
        target: AddFriendSearchTarget,
        venue: BusinessVenueMessageTarget
    ) async -> AddFriendBusinessMessageOutcome {
        guard target.entityType == .business else {
            return .informational("Only businesses can be messaged from here.")
        }

        return await openBusinessVenueConversation(
            businessId: target.entityId,
            businessDisplayName: target.displayName,
            venue: venue,
            ownerUserId: target.ownerUserId,
            businessUsername: target.username,
            businessEmail: target.matchedEmail
        )
    }

    /// Opens or creates a venue-scoped DM from Venue Detail (no venue picker).
    func openBusinessVenueConversationFromVenueDetail(bar: BarVenue) async -> AddFriendBusinessMessageOutcome {
        guard let businessId = bar.businessId else {
            return .informational("This venue isn't available for messaging yet.")
        }

        let context = await service.fetchBusinessMessagingContext(businessId: businessId)
        let venue = BusinessVenueMessageTarget(
            id: bar.id,
            venueName: bar.name,
            locationLine: bar.address,
            coverPhotoURL: bar.coverPhotoURL,
            coverPhotoThumbnailURL: bar.coverPhotoThumbnailURL
        )
        return await openBusinessVenueConversation(
            businessId: businessId,
            businessDisplayName: context.displayName,
            venue: venue,
            ownerUserId: context.ownerUserId,
            businessUsername: nil,
            businessEmail: bar.ownerEmail
        )
    }

    func shouldShowVenueChatIntroBanner(conversationId: UUID) -> Bool {
        guard let authId = currentUserAuthId else { return false }
        guard pendingVenueChatIntroConversationIds.contains(conversationId) else { return false }
        return !Self.hasConsumedVenueChatIntroBanner(authId: authId, conversationId: conversationId)
    }

    @MainActor
    func markVenueChatIntroBannerConsumed(conversationId: UUID) {
        pendingVenueChatIntroConversationIds.remove(conversationId)
        guard let authId = currentUserAuthId else { return }
        Self.setVenueChatIntroBannerConsumed(authId: authId, conversationId: conversationId)
    }

    private static func venueChatIntroBannerDefaultsKey(authId: UUID, conversationId: UUID) -> String {
        "venueChatIntroShown.\(authId.uuidString.lowercased()).\(conversationId.uuidString.lowercased())"
    }

    private static func hasConsumedVenueChatIntroBanner(authId: UUID, conversationId: UUID) -> Bool {
        UserDefaults.standard.bool(
            forKey: venueChatIntroBannerDefaultsKey(authId: authId, conversationId: conversationId)
        )
    }

    private static func setVenueChatIntroBannerConsumed(authId: UUID, conversationId: UUID) {
        UserDefaults.standard.set(
            true,
            forKey: venueChatIntroBannerDefaultsKey(authId: authId, conversationId: conversationId)
        )
    }

    @MainActor
    private func noteNewVenueChatIntroIfNeeded(conversationId: UUID, isNewConversation: Bool) {
        guard isNewConversation else { return }
        guard let authId = currentUserAuthId else { return }
        guard !Self.hasConsumedVenueChatIntroBanner(authId: authId, conversationId: conversationId) else { return }
        pendingVenueChatIntroConversationIds.insert(conversationId)
    }

    private func openBusinessVenueConversation(
        businessId: UUID,
        businessDisplayName: String,
        venue: BusinessVenueMessageTarget,
        ownerUserId: UUID?,
        businessUsername: String?,
        businessEmail: String?
    ) async -> AddFriendBusinessMessageOutcome {
        guard currentUserAuthId != nil else {
            return .informational("Sign in to message this venue.")
        }

        if let ownerId = ownerUserId, isEitherDirectionBlocked(with: ownerId) {
            return .informational("You can't message this business right now.")
        }

        let preview = userPreviewForBusinessVenueChat(
            businessId: businessId,
            businessDisplayName: businessDisplayName,
            venue: venue,
            ownerUserId: ownerUserId,
            businessUsername: businessUsername,
            businessEmail: businessEmail
        )

        do {
            guard let me = currentUserAuthId else {
                return .informational("Sign in to message this venue.")
            }

            let conversationId: UUID
            let isNewConversation: Bool
            guard let ownerId = ownerUserId else {
                return .informational("This venue isn't available for messaging yet.")
            }

            if let existing = try await directChatService.fetchExistingBusinessVenueConversationId(
                businessId: businessId,
                venueId: venue.id,
                ownerUserId: ownerId,
                userId: me
            ) {
                conversationId = existing
                isNewConversation = false
            } else {
                conversationId = try await directChatService.startBusinessVenueConversation(
                    businessId: businessId,
                    venueId: venue.id
                )
                isNewConversation = true
            }

            let threadPreview = UserPreview(
                id: preview.id,
                displayName: preview.displayName,
                username: preview.username,
                email: preview.email,
                avatarURL: preview.avatarURL,
                avatarThumbnailURL: preview.avatarThumbnailURL,
                isBusinessAccount: preview.isBusinessAccount,
                lastSeenAtRaw: preview.lastSeenAtRaw,
                dmConversationId: conversationId,
                businessVenueId: venue.id,
                businessVenueBusinessId: businessId,
                businessVenueBusinessName: preview.businessVenueBusinessName
            )
            await MainActor.run {
                upsertBusinessVenueInboxDisplay(preview: threadPreview, conversationId: conversationId)
                noteNewVenueChatIntroIfNeeded(conversationId: conversationId, isNewConversation: isNewConversation)
            }
            await refreshInboxSummaries()
            await ensureSignedInSocialRealtimeIfNeeded()
            await MainActor.run {
                pendingDmOpenPreview = threadPreview
            }
            return .openedChat
        } catch {
            return .informational("Couldn't open chat. Try again.")
        }
    }

    private func userPreviewForBusinessVenueChat(
        target: AddFriendSearchTarget,
        venue: BusinessVenueMessageTarget
    ) -> UserPreview {
        userPreviewForBusinessVenueChat(
            businessId: target.entityId,
            businessDisplayName: target.displayName,
            venue: venue,
            ownerUserId: target.ownerUserId,
            businessUsername: target.username,
            businessEmail: target.matchedEmail
        )
    }

    private func userPreviewForBusinessVenueChat(
        businessId: UUID,
        businessDisplayName: String,
        venue: BusinessVenueMessageTarget,
        ownerUserId: UUID?,
        businessUsername: String?,
        businessEmail: String?
    ) -> UserPreview {
        let peerId = ownerUserId ?? businessId
        return UserPreview(
            id: peerId,
            displayName: venue.venueName,
            username: businessUsername,
            email: businessEmail,
            avatarURL: nil,
            avatarThumbnailURL: nil,
            isBusinessAccount: true,
            businessVenueId: venue.id,
            businessVenueBusinessId: businessId,
            businessVenueBusinessName: businessDisplayName
        )
    }

    /// Refreshes Chat lists so pending/accepted rows appear immediately after Add Friend (including duplicate path).
    private func refreshAfterFriendLookupAttempt() async {
        await refreshFriendRequestListsOnly()
        await refreshInboxSummaries()
    }

    /// Accepted friends without a DM thread yet still appear in the Friends directory (presentation only; inbox RPC unchanged).
    private func applyHiddenInboxPeerFilter(_ displays: [FriendDisplay]) -> [FriendDisplay] {
        guard !hiddenInboxPeerUserIds.isEmpty
                || !hiddenInboxConversationIds.isEmpty
                || !serverExcludedInboxConversationIds.isEmpty else {
            return displays
        }
        return displays.filter { display in
            guard display.isConversationBacked else { return true }
            if let conversationId = display.conversationId {
                if hiddenInboxConversationIds.contains(conversationId) { return false }
                if serverExcludedInboxConversationIds.contains(conversationId) { return false }
            }
            if display.isGroupConversation {
                return true
            }
            if display.conversationId == nil,
               hiddenInboxPeerUserIds.contains(display.preview.id) {
                return false
            }
            return true
        }
    }

    private func refreshServerInboxExclusionsIfAvailable() async {
        do {
            let keys = try await recentlyDeletedService.fetchExclusions()
            let nextExcluded = Set(keys.map(\.conversation_id))
            let previouslyExcluded = serverExcludedInboxConversationIds
            serverExcludedInboxConversationIds = nextExcluded
            serverInboxExclusionsAvailable = true
            if let authId = currentUserAuthId {
                for id in nextExcluded {
                    DmInboxHiddenConversationsStore.hide(conversationId: id, authId: authId)
                    hiddenInboxConversationIds.insert(id)
                }
                // Auto-restore / manual restore: clear local hide for ids no longer excluded.
                for id in previouslyExcluded.subtracting(nextExcluded) {
                    DmInboxHiddenConversationsStore.unhide(conversationId: id, authId: authId)
                    hiddenInboxConversationIds.remove(id)
                }
            }
        } catch {
            if Self.isMissingRPCError(error) {
                serverInboxExclusionsAvailable = false
            }
#if DEBUG
            print("[DMDelete] exclusions fetch failed error=\(error.localizedDescription)")
#endif
        }
    }

    @MainActor
    private func hideInboxConversationLocally(peerUserId: UUID, conversationId: UUID? = nil) {
        if let authId = currentUserAuthId {
            if let conversationId {
                DmInboxHiddenConversationsStore.hide(conversationId: conversationId, authId: authId)
                hiddenInboxConversationIds.insert(conversationId)
            } else {
                DmInboxHiddenConversationsStore.hide(peerUserId: peerUserId, authId: authId)
                hiddenInboxPeerUserIds.insert(peerUserId)
            }
        }
        let removedConversationRows = friends.filter {
            guard $0.isConversationBacked else { return false }
            if let conversationId {
                return $0.conversationId == conversationId
            }
            return $0.preview.id == peerUserId && $0.conversationId == nil
        }
        friends.removeAll {
            guard $0.isConversationBacked else { return false }
            if let conversationId {
                return $0.conversationId == conversationId
            }
            return $0.preview.id == peerUserId && $0.conversationId == nil
        }
        // Soft-delete hides the Chats row only. Accepted friends must remain in the Friends
        // directory — promote the removed conversation row into a directory-only entry when needed.
        let stillAccepted = friendshipChipByOtherUserId[peerUserId] == .friends
            || friendshipChipByOtherUserId.isEmpty
        let alreadyInDirectory = friends.contains {
            !$0.isConversationBacked && $0.preview.id == peerUserId
        }
        if stillAccepted, !alreadyInDirectory,
           let preview = removedConversationRows.first(where: { $0.preview.id == peerUserId })?.preview {
            friends.append(
                FriendDisplay(
                    id: peerUserId,
                    preview: preview,
                    subtitle: ChatInboxPreviewFormatting.previewLine(body: nil, isFromCurrentUser: false),
                    lastMessageAt: nil,
                    unreadCount: 0,
                    isConversationBacked: false,
                    conversationId: nil
                )
            )
            ChatFriendsStability.preserved(
                refreshToken: ChatFriendsStability.beginRefresh(source: "softDeletePromoteDirectory"),
                ids: [peerUserId]
            )
        }
        let totalUnread = friends.reduce(0) { $0 + $1.unreadCount }
        Task { await setUnreadDirectMessageCountAndSyncAppIcon(totalUnread, source: "clear_inbox_conversation_local") }
    }

    @MainActor
    private func revealInboxConversationIfHidden(peerUserId: UUID, reason: String) {
        guard hiddenInboxPeerUserIds.contains(peerUserId) else { return }
        hiddenInboxPeerUserIds.remove(peerUserId)
        if let authId = currentUserAuthId {
            DmInboxHiddenConversationsStore.unhide(peerUserId: peerUserId, authId: authId)
        }
#if DEBUG
        print("[DMDelete] revealed friendUserId=\(peerUserId.uuidString.lowercased()) reason=\(reason)")
        print("[ChatReappear] resetVisibility reason=\(reason)")
#endif
    }

    @MainActor
    private func revealInboxConversationIfHidden(conversationId: UUID, peerUserId: UUID? = nil, reason: String) {
        if hiddenInboxConversationIds.contains(conversationId) {
            hiddenInboxConversationIds.remove(conversationId)
            if let authId = currentUserAuthId {
                DmInboxHiddenConversationsStore.unhide(conversationId: conversationId, authId: authId)
            }
#if DEBUG
            print("[DMDelete] revealed conversationId=\(conversationId.uuidString.lowercased()) reason=\(reason)")
            print("[ChatReappear] resetVisibility reason=\(reason)")
#endif
        }
        if let peerUserId {
            revealInboxConversationIfHidden(peerUserId: peerUserId, reason: reason)
        }
    }

    @MainActor
    private func upsertBusinessVenueInboxDisplay(preview: UserPreview, conversationId: UUID) {
        let display = FriendDisplay(
            id: conversationId,
            preview: preview,
            subtitle: ChatInboxPreviewFormatting.previewLine(body: nil, isFromCurrentUser: false),
            lastMessageAt: nil,
            unreadCount: 0,
            isConversationBacked: true,
            conversationId: conversationId
        )
        if let index = friends.firstIndex(where: { $0.conversationId == conversationId }) {
            let existing = friends[index]
            friends[index] = FriendDisplay(
                id: conversationId,
                preview: preview,
                subtitle: existing.subtitle,
                lastMessageAt: existing.lastMessageAt,
                unreadCount: existing.unreadCount,
                isConversationBacked: true,
                conversationId: conversationId
            )
        } else {
            friends.insert(display, at: 0)
        }
        revealInboxConversationIfHidden(
            conversationId: conversationId,
            peerUserId: preview.id,
            reason: "business_venue_dm_opened"
        )
    }

    private func mergeAcceptedFriendsMissingFromInbox(
        me: UUID,
        inboxDisplays: [FriendDisplay]
    ) async throws -> [FriendDisplay] {
        let accepted = try await service.fetchAcceptedFriendships(for: me)
        let token = ChatFriendsStability.beginRefresh(source: "mergeAcceptedFriends")
        let acceptedIds = Set(accepted.compactMap { row -> UUID? in
            guard (row.requester_entity_type ?? "user").lowercased() == "user",
                  (row.addressee_entity_type ?? "user").lowercased() == "user" else {
                return nil
            }
            return row.requester_id == me ? row.addressee_id : row.requester_id
        })
        ChatFriendsStability.stage("sourceAcceptedFriendIds", refreshToken: token, ids: acceptedIds)

        let inboxPeerUserIds = Set(inboxDisplays.map(\.preview.id))
        let missingIds: [UUID] = accepted.compactMap { row in
            guard (row.requester_entity_type ?? "user").lowercased() == "user",
                  (row.addressee_entity_type ?? "user").lowercased() == "user" else {
                return nil
            }
            let other = row.requester_id == me ? row.addressee_id : row.requester_id
            guard !inboxPeerUserIds.contains(other) else { return nil }
            if isEitherDirectionBlocked(with: other) {
                ChatFriendsStability.drop(reason: "blocked", refreshToken: token, id: other)
                return nil
            }
            return other
        }
        ChatFriendsStability.stage(
            "afterBlockFilterMissingFromInbox",
            refreshToken: token,
            ids: Set(missingIds)
        )
        guard !missingIds.isEmpty else { return inboxDisplays }

        let previews = try await socialIdentityService.fetchUserPreviews(for: missingIds)
        var merged = inboxDisplays
        for pid in missingIds {
            let preview = previews[pid] ?? deletedUserPreview(userId: pid)
            if previews[pid] == nil {
                ChatFriendsStability.drop(reason: "missingPreviewUsedFallback", refreshToken: token, id: pid)
            }
            logDeletedUserRenderDebug(surface: "dm_inbox", preview: preview)
            merged.append(
                FriendDisplay(
                    id: pid,
                    preview: preview,
                    subtitle: ChatInboxPreviewFormatting.previewLine(body: nil, isFromCurrentUser: false),
                    lastMessageAt: nil,
                    unreadCount: 0,
                    isConversationBacked: false,
                    conversationId: nil
                )
            )
        }
        return merged
    }

    /// Keeps previously published accepted-friend directory rows across a conversation-only
    /// fast-path publish. Enrichment still re-fetches accepted friendships authoritatively;
    /// this only prevents a valid friend from vanishing between publish 1 and publish 2.
    ///
    /// A row is preserved only when:
    /// - it is not conversation-backed (Friends-directory-only entry)
    /// - its peer is not already represented by an inbox row
    /// - it is not blocked either direction
    /// - chip state still says `.friends`, or chips have not loaded yet (cold gap)
    private func preservingAcceptedFriendsDirectoryRows(
        over inboxSnapshot: [FriendDisplay],
        source: String
    ) -> [FriendDisplay] {
        let token = ChatFriendsStability.beginRefresh(source: "preserveDirectory:\(source)")
        let inboxPeerIds = Set(inboxSnapshot.map(\.preview.id))
        var preservedIds = Set<UUID>()
        var keep: [FriendDisplay] = []

        for display in friends {
            guard !display.isConversationBacked else { continue }
            guard !display.isGroupConversation else { continue }
            let peerId = display.preview.id
            if inboxPeerIds.contains(peerId) {
                ChatFriendsStability.drop(
                    reason: "supersededByInboxRow",
                    refreshToken: token,
                    id: peerId
                )
                continue
            }
            if isEitherDirectionBlocked(with: peerId) {
                ChatFriendsStability.drop(reason: "blocked", refreshToken: token, id: peerId)
                continue
            }
            if display.preview.isDeleted {
                ChatFriendsStability.drop(reason: "deletedPreview", refreshToken: token, id: peerId)
                continue
            }
            if !friendshipChipByOtherUserId.isEmpty,
               friendshipChipByOtherUserId[peerId] != .friends {
                ChatFriendsStability.drop(
                    reason: "notAcceptedFriendChip",
                    refreshToken: token,
                    id: peerId
                )
                continue
            }
            keep.append(display)
            preservedIds.insert(peerId)
        }

        ChatFriendsStability.preserved(refreshToken: token, ids: preservedIds)
        guard !keep.isEmpty else { return inboxSnapshot }
        return inboxSnapshot + keep
    }

    private func resolveAddFriendLookupOutcomeAfterError(
        _ error: Error,
        target: AddFriendSearchTarget
    ) async -> AddFriendLookupOutcome {
#if DEBUG
        print("[ChatIdentityDebug] query entity_type=\(target.entityType.rawValue) entity_id=\(target.entityId.uuidString)")
        if let email = target.matchedEmail {
            print("[ChatIdentityDebug] matchedEmail=\(email)")
        }
        print("[ChatIdentityDebug] matchedEntityId=\(target.entityId.uuidString)")
#endif

        var verifiedRelation: FriendLookupExistingRelation = .none

        if let me = try? await service.currentUserId() {
            let requesterEntity = (try? await service.fetchSocialEntity(userId: me))
                ?? FriendSocialEntity(id: me, kind: .fanUser)
            let targetEntity = FriendSocialEntity(id: target.entityId, kind: target.socialEntityKind)

            let exactPending = try? await service.findPendingFriendship(requesterId: me, target: target)
            let rows = (try? await service.fetchFriendships(for: target, me: me)) ?? []
            verifiedRelation = FriendshipService.classifyExistingRelation(me: me, rows: rows)

#if DEBUG
            FriendshipService.logPendingRelationshipDebug(
                requester: requesterEntity,
                target: targetEntity,
                matchedPending: exactPending != nil,
                friendshipId: exactPending?.id
            )
#endif

            if FriendshipService.isDuplicateFriendLookupError(error) {
                logFriendRequestVisibilityDebug(
                    lookupResult: "duplicate",
                    targetUserId: target.entityId,
                    me: me,
                    existingRelation: verifiedRelation
                )

                if let message = FriendshipService.userFacingMessageForExistingRelation(verifiedRelation),
                   FriendshipService.isPendingLikeRelation(verifiedRelation) || verifiedRelation == .accepted {
                    return .informational(message)
                }

                if target.entityType == .user,
                   let email = target.matchedEmail, !email.isEmpty,
                   let sibling = try? await service.findPendingFriendshipWithOtherProfileSharingEmail(
                    requesterId: me,
                    excludePeerUserId: target.entityId,
                    normalizedEmail: email
                   ) {
#if DEBUG
                    print("[PendingRelationshipDebug] duplicateEmailButDifferentEntity=true otherEntityId=\(sibling.other.id.uuidString)")
                    print("[ChatIdentityDebug] duplicateEmailButDifferentEntity=true matchedEntityId=\(target.entityId.uuidString)")
#endif
                    return .error("Couldn't send friend request. Please try again.")
                }

#if DEBUG
                print("[PendingRelationshipDebug] duplicateEmailButDifferentEntity=true")
#endif
                return .error("Couldn't send friend request. Please try again.")
            }

            logFriendRequestVisibilityDebug(
                lookupResult: "error",
                targetUserId: target.entityId,
                me: me,
                existingRelation: verifiedRelation
            )
        }

        return FriendshipService.addFriendLookupOutcome(
            for: error,
            verifiedRelationForTarget: verifiedRelation
        )
    }

    private func logFriendRequestVisibilityDebug(
        lookupResult: String,
        targetUserId: UUID,
        me: UUID,
        existingRelation: FriendLookupExistingRelation = .none
    ) {
#if DEBUG
        let status: String
        switch existingRelation {
        case .none: status = "none"
        case .accepted: status = "accepted"
        case .pendingOutgoing: status = "pending_outgoing"
        case .pendingIncoming: status = "pending_incoming"
        case .declinedVisible: status = "declined_visible"
        }
        let inFriends = friends.contains { $0.id == targetUserId }
        let inIncoming = incomingRequests.contains {
            $0.requester.id == targetUserId || $0.friendship.requester_id == targetUserId
        }
        let inOutgoing = outgoingRequests.contains {
            $0.addressee.id == targetUserId || $0.friendship.addressee_id == targetUserId
        }
        DebugLogGate.debug("[FriendRequestVisibilityDebug] lookupResult=\(lookupResult)")
        DebugLogGate.debug("[FriendRequestVisibilityDebug] existingStatus=\(status) target=\(targetUserId.uuidString) me=\(me.uuidString)")
        DebugLogGate.debug("[FriendRequestVisibilityDebug] appearsInFriends=\(inFriends)")
        DebugLogGate.debug("[FriendRequestVisibilityDebug] appearsInRequests=\(inIncoming || inOutgoing) incoming=\(inIncoming) outgoing=\(inOutgoing)")
#endif
    }

    func chipKind(forOtherUserId userId: UUID) -> FriendshipChipKind {
        friendshipChipByOtherUserId[userId] ?? .addFriend
    }

    /// One batched refresh for all visible comment authors (no per-row queries).
    func refreshFriendshipStateForCommentAuthors(userIds: [UUID]) async {
        let unique = Array(Set(userIds))
        guard !unique.isEmpty else { return }
        if Task.isCancelled {
            #if DEBUG
            print("[CancellationHandlingDebug] ignoredCancellation context=comment_author_friendship_refresh")
            #endif
            return
        }
        guard (try? await service.currentUserId()) != nil else { return }
        await refresh()
    }

    /// Sends a friend request from a comment row; optimistic Pending, then lightweight list refresh.
    func sendFriendRequestFromComments(to addresseeId: UUID) async {
        if isEitherDirectionBlocked(with: addresseeId) {
            errorMessage = "You can’t send a friend request to this user."
            return
        }
        let previous = friendshipChipByOtherUserId[addresseeId]
        friendshipChipByOtherUserId[addresseeId] = .pendingOutgoing
        do {
            let me = try await service.currentUserId()
            try await service.sendFriendRequest(requesterId: me, addresseeId: addresseeId)
            await refreshFriendRequestListsOnly()
        } catch {
            if let previous {
                friendshipChipByOtherUserId[addresseeId] = previous
            } else {
                friendshipChipByOtherUserId.removeValue(forKey: addresseeId)
            }
            if ignoreCancellationIfNeeded(error, context: "friend_request_send_from_comments") { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Updates DM unread state for the Chat tab **and** mirrors it to the app icon badge (foreground / local only until APNs). See ``AppIconBadgeSync``.
    private func setUnreadDirectMessageCountAndSyncAppIcon(_ newValue: Int, source: String = "unspecified") async {
        let updateStartedAt = CFAbsoluteTimeGetCurrent()
        let clamped = max(0, newValue)
        let oldValue = unreadDirectMessageCount
        // Skip no-op republishes so Chat leaves and the badge projection stay quiet when
        // a refresh recomputes the same unread total.
        guard oldValue != clamped else { return }
        unreadDirectMessageCount = clamped
#if DEBUG
        print("[RealtimeChainDebug] uiStateUpdated table=conversation_read_state key=unreadDirectMessageCount oldValue=\(oldValue) newValue=\(clamped)")
        print("[UnreadStateDebug] source=\(source) oldTotal=\(oldValue) newTotal=\(clamped) vm=\(instanceDebugID)")
        print("[BadgeSyncDebug] unread total=\(clamped)")
        print("[BadgeSyncDebug] tab badge updated")
        print("[MainActorDebug] setUnreadDirectMessageCount actor=MainActor")
        let elapsed = String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - updateStartedAt) * 1000)
        print("[DMRealtimeLatencyDebug] unreadBadgeUpdated count=\(clamped) elapsedMs=\(elapsed)")
#endif
        await AppIconBadgeSync.apply(count: unreadDirectMessageCount)
    }

    private func applyFriendshipChipStates(
        me: UUID,
        accepted: [FriendshipRow],
        incoming: [FriendshipRow],
        outgoing: [FriendshipRow]
    ) {
        var next: [UUID: FriendshipChipKind] = [:]
        for row in accepted {
            let other = row.requester_id == me ? row.addressee_id : row.requester_id
            next[other] = .friends
        }
        for row in outgoing where row.isPendingStatus {
            let other = row.addressee_id
            if next[other] != .friends {
                next[other] = .pendingOutgoing
            }
        }
        for row in incoming where row.isPendingStatus {
            let other = row.requester_id
            if next[other] != .friends, next[other] != .pendingOutgoing {
                next[other] = .pendingIncoming
            }
        }
        for row in outgoing where row.isDeclinedStatus && row.requester_cleared_at == nil {
            let other = row.addressee_id
            if next[other] != .friends, next[other] != .pendingOutgoing, next[other] != .pendingIncoming {
                next[other] = .declinedOutgoing
            }
        }
        friendshipChipByOtherUserId = next

        // Drop Friends-directory-only rows that are no longer accepted. Conversation-backed
        // inbox rows stay (DM history / Chats list); the Friends tab filters them via chips.
        let before = friends
        let pruned = before.filter { display in
            if display.isConversationBacked || display.isGroupConversation { return true }
            return next[display.preview.id] == .friends
        }
        if pruned.count != before.count {
            let removed = Set(before.map(\.preview.id)).subtracting(pruned.map(\.preview.id))
            let token = ChatFriendsStability.beginRefresh(source: "chipStatePrune")
            for id in removed {
                ChatFriendsStability.drop(
                    reason: "authoritativeChipNoLongerFriends",
                    refreshToken: token,
                    id: id
                )
            }
            friends = pruned
        }
    }

    private func fetchDmParticipantPreviews(for rows: [DmInboxSummaryRow]) async throws -> [UUID: UserPreview] {
        let ids = Array(Set(rows.map(\.friend_user_id)))
        guard !ids.isEmpty else { return [:] }
        return try await socialIdentityService.fetchUserPreviews(for: ids)
    }

    private func deletedUserPreview(userId: UUID, email: String? = nil) -> UserPreview {
        UserPreview(
            id: userId,
            displayName: "Deleted User",
            email: email,
            avatarURL: nil,
            avatarThumbnailURL: nil,
            isDeleted: true
        )
    }

    private func patchLoadedDmParticipantPreview(_ preview: UserPreview, conversationId: UUID? = nil) {
        if preview.isBusinessVenueConversation {
            return
        }
        if let conversationId,
           let index = friends.firstIndex(where: { $0.conversationId == conversationId && !$0.isGroupConversation }) {
            let existing = friends[index]
            guard !existing.preview.isBusinessVenueConversation else { return }
            friends[index] = FriendDisplay(
                id: existing.id,
                preview: preview,
                subtitle: existing.subtitle,
                lastMessageAt: existing.lastMessageAt,
                unreadCount: existing.unreadCount,
                isConversationBacked: existing.isConversationBacked,
                conversationId: existing.conversationId,
                inboxKind: existing.inboxKind,
                groupMemberCount: existing.groupMemberCount,
                isGroupMuted: existing.isGroupMuted,
                pickupGameId: existing.pickupGameId,
                fanTeamId: existing.fanTeamId
            )
            return
        }
        guard let index = friends.firstIndex(where: { $0.preview.id == preview.id && !$0.preview.isBusinessVenueConversation && !$0.isGroupConversation }) else { return }
        let existing = friends[index]
        friends[index] = FriendDisplay(
            id: existing.id,
            preview: preview,
            subtitle: existing.subtitle,
            lastMessageAt: existing.lastMessageAt,
            unreadCount: existing.unreadCount,
            isConversationBacked: existing.isConversationBacked,
            conversationId: existing.conversationId,
            inboxKind: existing.inboxKind,
            groupMemberCount: existing.groupMemberCount,
            isGroupMuted: existing.isGroupMuted,
            pickupGameId: existing.pickupGameId,
            fanTeamId: existing.fanTeamId
        )
    }

    private func fallbackPreview(
        userId: UUID,
        displayName: String? = nil,
        email: String? = nil,
        avatarURL: String? = nil,
        avatarThumbnailURL: String? = nil,
        isDeleted: Bool = false
    ) -> UserPreview {
        if isDeleted {
            return UserPreview(
                id: userId,
                displayName: "Deleted User",
                email: email,
                avatarURL: nil,
                avatarThumbnailURL: nil,
                isDeleted: true
            )
        }
        let trimmed = displayName?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
        let resolved = trimmed.isEmpty ? "Player" : trimmed
        return UserPreview(
            id: userId,
            displayName: resolved,
            email: email,
            avatarURL: avatarURL,
            avatarThumbnailURL: avatarThumbnailURL
        )
    }

    private func inboxPreview(
        for row: DmInboxSummaryRow,
        resolvedPreview: UserPreview? = nil,
        profileLookupAttempted: Bool = false
    ) -> UserPreview {
        let presentAsBusinessVenue = ChatDMCounterpartResolution.shouldPresentAsBusinessVenuePeer(
            row: row,
            mapViewModel: mapViewModel
        )

        if presentAsBusinessVenue {
            let venueName = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let businessName = row.friend_business_display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let fallbackName = row.friend_display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let resolvedVenue = !venueName.isEmpty ? venueName : (!fallbackName.isEmpty ? fallbackName : "Venue")
            let resolvedBusiness = !businessName.isEmpty ? businessName : "Business"
            return UserPreview(
                id: row.friend_user_id,
                displayName: resolvedVenue,
                email: row.friend_email,
                avatarURL: nil,
                avatarThumbnailURL: nil,
                isBusinessAccount: true,
                lastSeenAtRaw: resolvedPreview?.lastSeenAtRaw,
                dmConversationId: row.conversation_id,
                businessVenueId: row.venue_id,
                businessVenueBusinessName: resolvedBusiness
            )
        }

        // Business session viewing a venue-scoped thread: counterpart is the fan (`friend_user_id`).
        // Never attach venue/business peer metadata so Watch Spot chrome cannot appear.

        let isDeleted = row.friend_is_deleted == true
            || OwnerBusinessEmail.normalized(row.friend_email ?? "").hasSuffix("@deleted.fangeo.local")
            || row.friend_display_name?.trimmingCharacters(in: .whitespacesAndNewlines) == "Deleted User"
            || resolvedPreview?.isDeleted == true
        if isDeleted {
            return deletedUserPreview(userId: row.friend_user_id, email: row.friend_email)
        }

        if row.friend_is_business == true,
           !ChatDMCounterpartResolution.isBusinessSession(mapViewModel: mapViewModel) {
            let businessName = row.friend_business_display_name?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
            let fallbackName = row.friend_display_name?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
            let email = row.friend_email?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let resolved = !businessName.isEmpty
                ? businessName
                : (!fallbackName.isEmpty ? fallbackName : (email?.isEmpty == false ? email! : "Business"))
            return UserPreview(
                id: row.friend_user_id,
                displayName: resolved,
                email: email,
                avatarURL: nil,
                avatarThumbnailURL: nil,
                isBusinessAccount: true,
                lastSeenAtRaw: resolvedPreview?.lastSeenAtRaw,
                dmConversationId: row.conversation_id
            )
        }

        if let resolvedPreview {
            let venueScoped = row.venue_id != nil
            return UserPreview(
                id: resolvedPreview.id,
                displayName: resolvedPreview.displayName,
                username: resolvedPreview.username,
                email: resolvedPreview.email,
                avatarURL: resolvedPreview.avatarURL,
                avatarThumbnailURL: resolvedPreview.avatarThumbnailURL,
                isBusinessAccount: false,
                isDeleted: resolvedPreview.isDeleted,
                lastSeenAtRaw: resolvedPreview.lastSeenAtRaw,
                dmConversationId: row.conversation_id ?? resolvedPreview.dmConversationId,
                businessVenueId: nil,
                businessVenueBusinessId: nil,
                businessVenueBusinessName: nil,
                venueScopedThread: venueScoped
            )
        }

        if profileLookupAttempted {
            return deletedUserPreview(userId: row.friend_user_id, email: row.friend_email)
        }

        // Neutral placeholder when a business session still has venue-labeled RPC fields
        // and fan profile enrichment has not returned yet.
        let rpcName = row.friend_display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let looksLikeSelfVenueLabel = ChatDMCounterpartResolution.isBusinessSession(mapViewModel: mapViewModel)
            && row.venue_id != nil
            && (row.friend_is_business == true || !(row.venue_name?.isEmpty ?? true))
        let displayName: String = {
            if looksLikeSelfVenueLabel {
                ChatCounterpartDebug.log("fallback identity used reason=neutralPendingFanEnrichment")
                return "FanGeo User"
            }
            return rpcName.isEmpty ? "FanGeo User" : rpcName
        }()

        return UserPreview(
            id: row.friend_user_id,
            displayName: displayName,
            email: row.friend_email,
            avatarURL: looksLikeSelfVenueLabel ? nil : row.friend_avatar_url,
            avatarThumbnailURL: looksLikeSelfVenueLabel ? nil : row.friend_avatar_thumbnail_url,
            venueScopedThread: row.venue_id != nil
        )
    }

    private func logCounterpartMapping(row: DmInboxSummaryRow, preview: UserPreview) {
        let context = ChatDMCounterpartResolution.sessionContext(mapViewModel: mapViewModel)
        let counterpart: ChatDMCounterpartResolution.CounterpartType = {
            if preview.isBusinessVenueConversation || preview.isBusinessAccount { return .business }
            if preview.isDeleted { return .unknown }
            return .fan
        }()
        ChatCounterpartDebug.log("conversation mapped")
        ChatCounterpartDebug.log("current session context=\(context.rawValue)")
        ChatCounterpartDebug.log("current participant matched=true")
        ChatCounterpartDebug.log("counterpart participant selected=true")
        ChatCounterpartDebug.log("counterpart type=\(counterpart.rawValue)")
        ChatCounterpartDebug.log(
            "fan identity resolved=\(counterpart == .fan) hasHandle=\(!preview.publicHandleLine.isEmpty) hasAvatar=\(!(preview.avatarURL ?? "").isEmpty || !(preview.avatarThumbnailURL ?? "").isEmpty)"
        )
        _ = row
    }

    private func logDeletedUserRenderDebug(surface: String, preview: UserPreview) {
#if DEBUG
        print("[DeletedUserRenderDebug] surface=\(surface)")
        print("[DeletedUserRenderDebug] userID=\(preview.id.uuidString.lowercased())")
        print("[DeletedUserRenderDebug] isDeleted=\(preview.isDeleted)")
        print("[DeletedUserRenderDebug] displayNameUsed=\(preview.displayName)")
#endif
    }

    private func logChatRowDebug(preview: UserPreview) {
#if DEBUG
        let avatarSource: String
        if preview.isBusinessIdentity {
            avatarSource = "business_building_icon"
        } else if !(preview.avatarThumbnailURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    || !(preview.avatarURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            avatarSource = "user_photo"
        } else {
            avatarSource = "generic_person_fallback"
        }
        DebugLogGate.debug(
            "[ChatRowDebug] displayName=\(preview.displayName) email=\(preview.email ?? "nil") isBusinessIdentity=\(preview.isBusinessIdentity) avatarSource=\(avatarSource)"
        )
#endif
    }

    private func formattedFriendshipSubtitle(row: FriendshipRow) -> String? {
        if let responded = row.responded_at, !responded.isEmpty {
            return "Friends since \(shortDate(from: responded))"
        }
        return nil
    }

    private func shortDate(from iso: String) -> String {
        let trimmed = String(iso.prefix(10))
        return trimmed.isEmpty ? iso : trimmed
    }
}

/// Root-shell projection observed by ``MainTabView``.
/// Conversation chrome (`hidesFloatingTabBarForDirectChat`) is owned here and updated from
/// parent route presence in ``FriendsTabView`` — never mirrored from a destination `onAppear`.
/// ``MainTabView`` applies this only while `selectedTab == .chat` so an inactive Chat stack
/// (preserved DM/group route) cannot suppress the floating tab bar on other tabs.
@MainActor
final class ChatMainTabState: ObservableObject {
    @Published private(set) var pendingDmOpenPreview: UserPreview?
    @Published private(set) var pendingGroupOpenConversationId: UUID?
    @Published private(set) var pendingOpenFriendRequestsSection = false
    @Published private(set) var pendingOpenMyTeamsInvitations = false
    @Published private(set) var dmInAppNotification: ChatViewModel.DmInAppNotificationPayload?
    /// True while FriendsTab has a DM or group conversation route. Shell hide is gated by active Chat tab.
    @Published private(set) var hidesFloatingTabBarForDirectChat = false

    func setPendingDmOpenPreview(_ value: UserPreview?) {
        guard pendingDmOpenPreview != value else { return }
        pendingDmOpenPreview = value
        MainTabObservationPerf.projectionPublished(scope: "routing", category: "deepLink")
    }

    func setPendingGroupOpenConversationId(_ value: UUID?) {
        guard pendingGroupOpenConversationId != value else { return }
        pendingGroupOpenConversationId = value
        MainTabObservationPerf.projectionPublished(scope: "routing", category: "deepLink")
    }

    func setPendingOpenFriendRequestsSection(_ value: Bool) {
        guard pendingOpenFriendRequestsSection != value else { return }
        pendingOpenFriendRequestsSection = value
        MainTabObservationPerf.projectionPublished(scope: "routing", category: "deepLink")
    }

    func setPendingOpenMyTeamsInvitations(_ value: Bool) {
        guard pendingOpenMyTeamsInvitations != value else { return }
        pendingOpenMyTeamsInvitations = value
        MainTabObservationPerf.projectionPublished(scope: "routing", category: "deepLink")
    }

    func setDmInAppNotification(_ value: ChatViewModel.DmInAppNotificationPayload?) {
        guard dmInAppNotification != value else { return }
        dmInAppNotification = value
        MainTabObservationPerf.projectionPublished(scope: "routing", category: "inAppNotification")
    }

    func setHidesFloatingTabBarForDirectChat(_ value: Bool) {
        guard hidesFloatingTabBarForDirectChat != value else { return }
#if DEBUG
        print("[ChatNav] mainTab.directChatChrome \(hidesFloatingTabBarForDirectChat)→\(value)")
#endif
        hidesFloatingTabBarForDirectChat = value
        MainTabObservationPerf.projectionPublished(scope: "routing", category: "navigationChrome")
    }

}

/// Badge-only projection observed below the root shell.
@MainActor
final class ChatTabBadgeState: ObservableObject {
    @Published private(set) var unreadDirectMessageCount = 0
    @Published private(set) var pendingBadgeCount = 0
    @Published private(set) var pendingFanTeamInvitationCount = 0
    @Published private(set) var requiresSignIn = false

    func setUnreadDirectMessageCount(_ value: Int) {
        guard unreadDirectMessageCount != value else { return }
        unreadDirectMessageCount = value
        MainTabObservationPerf.projectionPublished(scope: "badgeLeaf", category: "unreadBadge")
    }

    func setPendingBadgeCount(_ value: Int) {
        guard pendingBadgeCount != value else { return }
        pendingBadgeCount = value
        MainTabObservationPerf.projectionPublished(scope: "badgeLeaf", category: "requestBadge")
    }

    func setPendingFanTeamInvitationCount(_ value: Int) {
        guard pendingFanTeamInvitationCount != value else { return }
        pendingFanTeamInvitationCount = value
        MainTabObservationPerf.projectionPublished(scope: "badgeLeaf", category: "myTeamsInvitationBadge")
    }

    func setRequiresSignIn(_ value: Bool) {
        guard requiresSignIn != value else { return }
        requiresSignIn = value
        MainTabObservationPerf.projectionPublished(scope: "badgeLeaf", category: "authGate")
    }
}
