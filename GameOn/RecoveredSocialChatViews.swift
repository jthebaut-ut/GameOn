import CoreLocation
import SwiftUI

private func friendsDirectoryCardSubtitle(for item: ChatViewModel.FriendDisplay) -> String {
    if item.preview.isBusinessVenueConversation {
        return "Venue chat"
    }
    if item.preview.isBusinessAccount && item.isConversationBacked {
        return "Business chat"
    }
    let handle = item.preview.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !handle.isEmpty {
        return FanGeoHandleRules.displayHandle(stored: handle)
    }
    return "FanGeo friend"
}

private func isFriendsDirectoryEligible(_ item: ChatViewModel.FriendDisplay) -> Bool {
    guard !item.preview.isDeleted else { return false }
    guard !item.preview.isBusinessVenueConversation else { return false }
    if item.preview.isBusinessAccount && item.isConversationBacked { return false }
    return true
}

nonisolated private func chatFansLiveNowCandidate(_ preview: UserPreview) -> Bool {
    guard !preview.isDeleted else { return false }
    guard preview.businessVenueId == nil else { return false }
    guard !preview.isBusinessAccount else { return false }
    guard let lastSeen = chatFansLiveNowParsedLastSeen(preview.lastSeenAtRaw) else { return false }
    return Date().timeIntervalSince(lastSeen) <= PresenceOnlineStatus.onlineWindowSeconds
}

nonisolated private func chatFansLiveNowParsedLastSeen(_ raw: String?) -> Date? {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return nil }

    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: trimmed) { return date }

    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: trimmed)
}

private func friendsDirectoryDedupeKey(for item: ChatViewModel.FriendDisplay) -> String {
    "user:\(item.preview.id.uuidString.lowercased())"
}

private func preferredFriendsDirectoryEntry(
    existing: ChatViewModel.FriendDisplay,
    candidate: ChatViewModel.FriendDisplay
) -> ChatViewModel.FriendDisplay {
    switch (existing.isConversationBacked, candidate.isConversationBacked) {
    case (false, true):
        return existing
    case (true, false):
        return candidate
    default:
        return existing
    }
}

private func deduplicatedFriendsDirectory(
    from friends: [ChatViewModel.FriendDisplay],
    isAcceptedFriend: (UUID) -> Bool
) -> [ChatViewModel.FriendDisplay] {
    var byKey: [String: ChatViewModel.FriendDisplay] = [:]
    for item in friends where isFriendsDirectoryEligible(item) && isAcceptedFriend(item.preview.id) {
        let key = friendsDirectoryDedupeKey(for: item)
        if let existing = byKey[key] {
            byKey[key] = preferredFriendsDirectoryEntry(existing: existing, candidate: item)
        } else {
            byKey[key] = item
        }
    }
    return Array(byKey.values)
        .sorted {
            $0.preview.displayName.localizedCaseInsensitiveCompare($1.preview.displayName) == .orderedAscending
        }
}

// MARK: - Avatar (toolbar / rows / bubbles)

struct ProfileAvatarView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var mapViewModel: MapViewModel
    let preview: UserPreview
    let size: CGFloat
    /// Passed to ``MapViewModel/presentPublicProfile(userId:context:)`` debug logs.
    var profileTapContext: String = "profile_avatar"
    /// Chat inbox fan rows show the compact Facebook-style relative-time pill
    /// (`Online` / `5m` / `2h` / `1d`) instead of the green online dot. Exactly
    /// one indicator renders; the pill self-hides for missing/hidden/stale
    /// `last_seen_at` (UserPreview already nils it for deleted or
    /// activity-hidden users).
    var usesCompactActivityPill: Bool = false

    var body: some View {
        let avatar = SocialAvatarRenderer.socialAvatarView(for: preview, size: size)
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(FGColor.cardBackground(colorScheme))
            )
            .clipShape(Circle())
            .overlay {
                Circle()
                    .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
            }
            .overlay(alignment: .bottomTrailing) {
                if usesCompactActivityPill {
                    if !preview.isBusinessIdentity {
                        ActivityStatusCompactPill(lastSeenAtRaw: preview.lastSeenAtRaw)
                            .fixedSize()
                            .offset(x: 4, y: 3)
                    }
                } else if preview.isOnlineNow {
                    PresenceOnlineBadge(size: max(9, size * 0.22))
                        .offset(x: size * 0.03, y: size * 0.03)
                }
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.08), radius: 8, y: 4)

        if preview.isBusinessIdentity || !preview.canOpenPublicProfile {
            avatar
        } else {
            PublicProfileAvatarTap(userId: preview.id, context: profileTapContext) {
                avatar
            }
        }
    }
}

private struct PresenceOnlineBadge: View {
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(FGColor.accentGreen)
            .frame(width: size, height: size)
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(0.92), lineWidth: max(1.5, size * 0.18))
            }
            .shadow(color: FGColor.accentGreen.opacity(0.32), radius: 4, y: 1)
            .accessibilityLabel("Online now")
    }
}

// MARK: - DM bubble row

struct DirectMessageBubbleView: View {
    @Environment(\.colorScheme) private var colorScheme

    let text: String
    let isFromCurrentUser: Bool
    let showFriendAvatar: Bool
    let friendPreview: UserPreview
    let timestamp: String?

    private static let avatarColumnWidth: CGFloat = 34

    var body: some View {
        HStack(alignment: .bottom, spacing: FGSpacing.sm) {
            if !isFromCurrentUser, showFriendAvatar {
                ProfileAvatarView(preview: friendPreview, size: 30)
                    .frame(width: Self.avatarColumnWidth, alignment: .center)
            } else if !isFromCurrentUser {
                Color.clear
                    .frame(width: Self.avatarColumnWidth, height: 1)
            }

            VStack(alignment: isFromCurrentUser ? .trailing : .leading, spacing: FGSpacing.xs + 1) {
                Text(text)
                    .font(FGTypography.body)
                    .foregroundStyle(
                        isFromCurrentUser
                            ? Color.white.opacity(0.98)
                            : FGColor.primaryText(colorScheme)
                    )
                    .multilineTextAlignment(isFromCurrentUser ? .trailing : .leading)
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.vertical, FGSpacing.sm + 3)
                    .background {
                        RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                            .fill(
                                isFromCurrentUser
                                    ? AnyShapeStyle(
                                        LinearGradient(
                                            colors: [FGColor.gradientMiddle.opacity(0.96), FGColor.gradientEnd.opacity(0.90)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    : AnyShapeStyle(FGColor.cardBackground(colorScheme))
                            )
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                            .strokeBorder(
                                isFromCurrentUser
                                    ? Color.white.opacity(0.12)
                                    : FGColor.divider(colorScheme),
                                lineWidth: 1
                            )
                    }
                    .softCardShadow()

                if let timestamp, !timestamp.isEmpty {
                    Text(timestamp)
                        .font(FGTypography.metadata)
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .padding(.horizontal, FGSpacing.xs)
                        .frame(maxWidth: .infinity, alignment: isFromCurrentUser ? .trailing : .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: isFromCurrentUser ? .trailing : .leading)
            .padding(.leading, isFromCurrentUser ? 52 : 0)
            .padding(.trailing, isFromCurrentUser ? 0 : 52)

            if isFromCurrentUser {
                Color.clear
                    .frame(width: Self.avatarColumnWidth, height: 1)
            }
        }
    }
}

// MARK: - Chat tab root (friends inbox + requests + DM threads)

struct FriendsTabView: View {
    @ObservedObject var mapViewModel: MapViewModel
    @ObservedObject var viewModel: ChatViewModel
    var isTabSelected: Bool

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var selectedSection: ChatSection = .chats
    @State private var showingAddFriendSheet = false
    @State private var showingBlockedUsersSheet = false
    @State private var showingNewMessageSheet = false
    @State private var showingCreateGroupSheet = false
    @State private var showingRecentlyDeleted = false
    @State private var groupNavigationConversationId: UUID?
    @State private var manualFriendLookupDraft: String = ""
    @State private var friendDirectorySearchText = ""
    @State private var chatConversationFriendsSnapshot: [ChatViewModel.FriendDisplay] = []
    @State private var friendsDirectoryItemsSnapshot: [ChatViewModel.FriendDisplay] = []
    @State private var filteredFriendsDirectoryItemsSnapshot: [ChatViewModel.FriendDisplay] = []
    /// Fingerprint of inputs to ``rebuildFriendDisplaySnapshots`` (ordering, unread, last message,
    /// presence lastSeen, friendship chips, group membership/avatar keys, search query).
    @State private var lastFriendDisplaySnapshotFingerprint: ChatFriendDisplaySnapshotFingerprint? = nil
    /// Populated after first paint from cached friend presence (see ``refreshFansLiveNowAfterFirstPaint``).
    @State private var fansLiveNowEntries: [ChatFansLiveNowEntry] = []
    /// Programmatic push (in-app DM banner → Chat tab → ``DirectChatView``).
    @State private var dmBannerNavigationFriend: UserPreview?
    @State private var openSupportChat = false
    @State private var unfriendConfirmationItem: ChatViewModel.FriendDisplay?

    private enum ChatSection: String, CaseIterable, Identifiable {
        case chats = "Chats"
        case friends = "Friends"
        case requests = "Requests"
        var id: String { rawValue }
    }

    private var chatRootBackground: Color {
        colorScheme == .dark ? Color.black : Color(.systemBackground)
    }

    private var chatConversationFriends: [ChatViewModel.FriendDisplay] {
        let authoritative = viewModel.friends.filter(\.isConversationBacked)
        // Prefer authoritative rows when the deferred snapshot has not caught up yet
        // (avoids empty-state / blank Recent Chats flash after account switch).
        if chatConversationFriendsSnapshot.isEmpty, !authoritative.isEmpty {
            return authoritative
        }
        return chatConversationFriendsSnapshot
    }

    private var friendsDirectoryItems: [ChatViewModel.FriendDisplay] {
        friendsDirectoryItemsSnapshot
    }

    private var filteredFriendsDirectoryItems: [ChatViewModel.FriendDisplay] {
        filteredFriendsDirectoryItemsSnapshot
    }

    private var isBusinessChatAccount: Bool {
        mapViewModel.currentUserIsBusinessAccount
            || mapViewModel.isVenueOwnerLoggedIn
            || mapViewModel.hasAuthenticatedVenueOwnerSession
    }

    /// Fan social sections (Friends / Requests / Add Friend). Business accounts are Chats-only.
    private var showsChatSocialSections: Bool {
        !isBusinessChatAccount
    }

    private var shouldShowFansLiveNowStrip: Bool {
        !isBusinessChatAccount && !fansLiveNowEntries.isEmpty
    }

    private var hasChatAuthSession: Bool {
        mapViewModel.canUsePrivateChat || viewModel.currentUserAuthId != nil
    }

    private var hasRegularUserProfileForChatGate: Bool {
        mapViewModel.userProfileExistsForPresentation
            || !mapViewModel.currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !mapViewModel.currentUserUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shouldShowChatSignInRequired: Bool {
        !hasChatAuthSession
    }

    var body: some View {
        let _ = SwiftUIRecompPerf.rootBodyEvaluated(screen: "ChatInbox")
        friendsTabNavigationStack
            .background(chatRootBackground.ignoresSafeArea())
            .sheet(isPresented: $showingAddFriendSheet) {
                addFriendSheetContent
            }
            .sheet(isPresented: $showingBlockedUsersSheet) {
                ChatBlockedUsersSheet(
                    viewModel: viewModel,
                    onContactSupport: {
                        showingBlockedUsersSheet = false
                        openSupportChat = true
                    }
                )
            }
            .sheet(isPresented: $showingNewMessageSheet) {
                NewMessageFriendPickerSheet(chatViewModel: viewModel) { preview in
                    dmBannerNavigationFriend = preview
                }
            }
            .sheet(isPresented: $showingCreateGroupSheet) {
                CreateGroupChatSheet(chatViewModel: viewModel) { conversationId in
                    groupNavigationConversationId = conversationId
                }
            }
            .modifier(FriendsTabLifecycleModifier(
                viewModel: viewModel,
                mapViewModel: mapViewModel,
                isTabSelected: isTabSelected,
                friendDirectorySearchText: $friendDirectorySearchText,
                onTabSelectedChange: handleTabSelectedChange,
                onAppear: handleAppear,
                onFriendsChange: {
                    rebuildFriendDisplaySnapshots(reason: "friendsChanged")
                    logFriendsDirectoryLoadedCount()
                    refreshFansLiveNowAfterFirstPaint(reason: "friendsPresenceChanged")
                },
                onFriendshipChipsChange: {
                    rebuildFriendDisplaySnapshots(reason: "friendshipChipsChanged")
                },
                onSearchChange: { query in
                    rebuildFriendDisplaySnapshots(reason: "searchChanged")
                    logFriendsDirectorySearchQuery(query)
                },
                onPendingDmOpen: consumePendingDmOpenPreviewIfNeeded,
                onRequiresSignInChange: { logChatAuthGate(reason: "requiresSignInChanged") },
                onChatUserAuthIdChange: {
                    logChatAuthGate(reason: "chatUserAuthIdChanged")
                    chatConversationFriendsSnapshot = []
                    friendsDirectoryItemsSnapshot = []
                    filteredFriendsDirectoryItemsSnapshot = []
                    lastFriendDisplaySnapshotFingerprint = nil
                    fansLiveNowEntries = []
                    rebuildFriendDisplaySnapshots(reason: "chatAuthIdChanged")
                },
                onMapUserAuthIdChange: {
                    logChatAuthGate(reason: "mapUserAuthIdChanged")
                    chatConversationFriendsSnapshot = []
                    friendsDirectoryItemsSnapshot = []
                    filteredFriendsDirectoryItemsSnapshot = []
                    lastFriendDisplaySnapshotFingerprint = nil
                    fansLiveNowEntries = []
                    ChatFansLiveNowSessionCache.clear(authId: nil)
                    rebuildFriendDisplaySnapshots(reason: "mapAuthIdChanged")
                },
                onBusinessAccountChange: {
                    logChatAuthGate(reason: "businessAccountChanged")
                    fansLiveNowEntries = []
                    ChatFansLiveNowSessionCache.clear(authId: mapViewModel.currentUserAuthId)
                    normalizeChatSectionForAccountType()
                }
            ))
            .onChange(of: mapViewModel.isVenueOwnerLoggedIn) { _, _ in
                normalizeChatSectionForAccountType()
            }
            .onChange(of: mapViewModel.hasAuthenticatedVenueOwnerSession) { _, _ in
                normalizeChatSectionForAccountType()
            }
            .background {
                Color.clear
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                    .onChange(of: mapViewModel.pendingDiscoverTodayDashboardNav) { _, _ in
                        applyPendingDiscoverTodayDashboardChatNavIfNeeded()
                    }
            }
            .modifier(ChatErrorAlertsModifier(viewModel: viewModel))
            .alert(
                unfriendConfirmationTitle,
                isPresented: unfriendConfirmationAlertBinding
            ) {
                Button("Cancel", role: .cancel) {
                    unfriendConfirmationItem = nil
                }
                Button("Unfriend", role: .destructive) {
                    guard let item = unfriendConfirmationItem else { return }
                    unfriendConfirmationItem = nil
                    Task {
                        await viewModel.unfriend(item)
                    }
                }
            } message: {
                Text("They will be removed from your friends list. You can send a new request later.")
            }
    }

    private var unfriendConfirmationTitle: String {
        guard let name = unfriendConfirmationItem?.preview.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return "Unfriend?"
        }
        return "Unfriend \(name)?"
    }

    private var unfriendConfirmationAlertBinding: Binding<Bool> {
        Binding(
            get: { unfriendConfirmationItem != nil },
            set: { if !$0 { unfriendConfirmationItem = nil } }
        )
    }

    private var friendsTabNavigationStack: some View {
        NavigationStack {
            chatRootContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(chatRootBackground)
                .navigationDestination(item: $dmBannerNavigationFriend) { friend in
                    DirectChatView(friend: friend)
                        .environmentObject(viewModel)
                        .environmentObject(mapViewModel)
                }
                .navigationDestination(isPresented: Binding(
                    get: { groupNavigationConversationId != nil },
                    set: { if !$0 { groupNavigationConversationId = nil } }
                )) {
                    if let groupNavigationConversationId {
                        GroupChatView(
                            conversationId: groupNavigationConversationId,
                            chatViewModel: viewModel
                        )
                        .environmentObject(mapViewModel)
                    }
                }
                .navigationDestination(isPresented: $openSupportChat) {
                    FanGeoSupportHubView(
                        mapViewModel: mapViewModel,
                        chatViewModel: viewModel,
                        embedsInNavigationStack: true,
                        showsCloseButton: false,
                        screenTitle: "Support Center"
                    )
                }
                .navigationDestination(isPresented: $showingRecentlyDeleted) {
                    ChatRecentlyDeletedView(chatViewModel: viewModel)
                        .environmentObject(mapViewModel)
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var addFriendSheetContent: some View {
        AddFriendGlassSheet(
            lookupDraft: $manualFriendLookupDraft,
            viewModel: viewModel,
            onClose: {
                showingAddFriendSheet = false
                manualFriendLookupDraft = ""
                viewModel.clearAddFriendSearch()
            }
        )
    }

    private func handleTabSelectedChange(_ on: Bool) {
        guard on else { return }
        TabTapPerf.shellVisible(tab: "chat")
        AppPerfDebug.screenLoadStart(tab: "chat", source: "tabSelected")
        UIPerformanceDiagnostics.signpost("DM inbox open", "source=tabSelected")
        applyPendingDiscoverTodayDashboardChatNavIfNeeded()
        consumePendingDmOpenPreviewIfNeeded()
        Task { @MainActor in
            await Task.yield()
#if DEBUG
            let started = CFAbsoluteTimeGetCurrent()
#endif
            rebuildFriendDisplaySnapshots(reason: "chatTabSelected")
#if DEBUG
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
            DebugLogGate.tabSwitchPerfVerbose(
                "[TabRenderPerf] tab=chat visible=true renderMs=\(String(format: "%.2f", ms))"
            )
            AppPerfDebug.mainActorBlocked(ms: ms, tab: "chat", source: "rebuildFriendDisplaySnapshots")
#endif
            await viewModel.ensureSignedInSocialRealtimeIfNeeded()
            refreshFansLiveNowAfterFirstPaint(reason: "chatTabSelected")
        }
    }

    private func applyPendingDiscoverTodayDashboardChatNavIfNeeded() {
        guard isTabSelected else { return }
        guard mapViewModel.pendingDiscoverTodayDashboardNav == .chatFansLiveNow else { return }
        selectedSection = .chats
        mapViewModel.clearPendingDiscoverTodayDashboardNav()
#if DEBUG
        print("[DiscoverTodayDashboard] applied chatFansLiveNow")
#endif
    }

    private func handleAppear() {
#if DEBUG
        let started = CFAbsoluteTimeGetCurrent()
        ChatActivationPerf.log("activationStarted cachedContentShown=\(!viewModel.friends.isEmpty) initialLoadDone=\(viewModel.hasCompletedInitialInboxLoad)")
#endif
        TabTapPerf.shellVisible(tab: "chat")
        rebuildFriendDisplaySnapshots(reason: "appear")
#if DEBUG
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        ChatActivationPerf.log(
            "cachedInboxUsable ms=\(String(format: "%.2f", ms)) rows=\(chatConversationFriendsSnapshot.count)"
        )
        DebugLogGate.tabSwitchPerfVerbose(
            "[TabRenderPerf] tab=chat visible=\(isTabSelected) renderMs=\(String(format: "%.2f", ms))"
        )
        // The first Chat mount is the one that can stall the tap→frame path; report it explicitly.
        TabTapPerf.mainActorBusy(ms: ms, source: "chatFirstMountSnapshotRebuild")
#endif
        if isTabSelected {
            UIPerformanceDiagnostics.signpost("DM inbox open", "source=onAppear")
        }
        viewModel.mapViewModel = mapViewModel
        logChatAuthGate(reason: "appear")
        normalizeChatSectionForAccountType()
        applyPendingDiscoverTodayDashboardChatNavIfNeeded()
        consumePendingDmOpenPreviewIfNeeded()
        if chatNeedsInboxBodyLoad {
            viewModel.prepareInboxLoadUIStateIfNeeded()
        }
        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard isTabSelected else { return }
            if shouldSkipInboxRefreshOnAppear {
                AppPerfDebug.refreshSkipped(tab: "chat", source: "inboxSummaries", reason: chatSkipInboxRefreshReason)
                DebugLogGate.tabSwitchPerfVerbose("[TabDeferredRefresh] tab=chat reason=appear skipped=\(chatSkipInboxRefreshReason)")
            } else {
                DebugLogGate.tabSwitchPerfVerbose("[TabDeferredRefresh] tab=chat reason=appear started")
                if viewModel.hasCompletedInitialInboxLoad {
                    await viewModel.refreshInboxSummariesIfNeeded()
                } else {
                    await viewModel.beginInitialInboxLoadIfNeeded(source: "tab")
                }
                if showsChatSocialSections {
                    Task { await viewModel.refreshFriendRequestListsOnly() }
                }
                viewModel.noteChatTabSurfaceRefreshCompleted()
                DebugLogGate.tabSwitchPerfVerbose("[TabDeferredRefresh] tab=chat reason=appear finished")
            }
            TabTapPerf.stableInboxReady(rows: chatConversationFriendsSnapshot.count)
            if isTabSelected {
                await viewModel.ensureSignedInSocialRealtimeIfNeeded()
            }
        }
    }

    private func normalizeChatSectionForAccountType() {
        if isBusinessChatAccount {
            if selectedSection != .chats {
                selectedSection = .chats
            }
            if showingAddFriendSheet {
                showingAddFriendSheet = false
                manualFriendLookupDraft = ""
                viewModel.clearAddFriendSearch()
            }
        }
    }

    private var chatNeedsInboxBodyLoad: Bool {
        !shouldShowChatSignInRequired
            && !viewModel.hasCompletedInitialInboxLoad
            && viewModel.friends.filter(\.isConversationBacked).isEmpty
    }

    private var shouldSkipInboxRefreshOnAppear: Bool {
        if chatNeedsInboxBodyLoad { return false }
        if mapViewModel.didCompleteTabIntentPreloadRecently("chat", within: 25) { return true }
        if viewModel.shouldSkipChatTabSurfaceRefresh() { return true }
        return false
    }

    private var chatSkipInboxRefreshReason: String {
        if mapViewModel.didCompleteTabIntentPreloadRecently("chat", within: 25) {
            return "tabPreloadRecent"
        }
        return "freshCache"
    }

    private func rebuildFriendDisplaySnapshots(reason: String) {
#if DEBUG
        let started = CFAbsoluteTimeGetCurrent()
#endif
        let friends = viewModel.friends
        let query = friendDirectorySearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let fingerprintStartedAt = CFAbsoluteTimeGetCurrent()
        let fingerprint = friendDisplaySnapshotFingerprint(friends: friends, query: query)
        ChatActivationPerf.fingerprintBuildMs(
            (CFAbsoluteTimeGetCurrent() - fingerprintStartedAt) * 1000,
            rows: friends.count
        )
        if fingerprint == lastFriendDisplaySnapshotFingerprint,
           !chatConversationFriendsSnapshot.isEmpty || friends.isEmpty {
            DebugLogGate.tabSwitchPerfVerbose(
                "[ChatLoadPerf] snapshotRebuildSkipped reason=fingerprintUnchanged trigger=\(reason)"
            )
            return
        }
        let conversations = friends.filter(\.isConversationBacked)
        let directory = deduplicatedFriendsDirectory(from: friends) { userId in
            viewModel.chipKind(forOtherUserId: userId) == .friends
        }
        let filtered: [ChatViewModel.FriendDisplay]
        if query.isEmpty {
            filtered = directory
        } else {
            filtered = directory.filter { item in
                item.preview.displayName.lowercased().contains(query)
                    || (item.preview.username?.lowercased().contains(query) == true)
            }
        }
        chatConversationFriendsSnapshot = conversations
        friendsDirectoryItemsSnapshot = directory
        filteredFriendsDirectoryItemsSnapshot = filtered
        lastFriendDisplaySnapshotFingerprint = fingerprint
        prefetchChatInboxAvatars(reason: reason, rows: conversations)
#if DEBUG
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        DebugLogGate.tabSwitchPerfVerbose(
            "[RenderPerf] view=FriendsTabView renderMs=\(String(format: "%.2f", ms)) rebuildReason=\(reason)"
        )
#endif
    }

    /// Inputs: friend id/order, unread, last message time/body, presence lastSeen, conversation/group
    /// flags, group member avatar keys, friendship chip kind, and directory search query.
    ///
    /// Structural equality replaces the previous large interpolated String while encoding
    /// exactly the same fields — any change that altered the old fingerprint alters this value.
    private func friendDisplaySnapshotFingerprint(
        friends: [ChatViewModel.FriendDisplay],
        query: String
    ) -> ChatFriendDisplaySnapshotFingerprint {
        let rows: [ChatFriendDisplaySnapshotFingerprint.Row] = friends.map { item in
            let chip: ChatFriendDisplaySnapshotFingerprint.ChipKind = {
                switch viewModel.chipKind(forOtherUserId: item.preview.id) {
                case .addFriend: return .add
                case .pendingOutgoing: return .out
                case .pendingIncoming: return .in
                case .friends: return .friends
                case .declinedOutgoing: return .declined
                }
            }()
            let groupMembers: [UUID]
            let groupConversationId: UUID?
            if item.isGroupConversation, let conversationId = item.conversationId {
                groupConversationId = conversationId
                groupMembers = viewModel.groupInboxAvatarMemberIdsByConversationId[conversationId] ?? []
            } else {
                groupConversationId = nil
                groupMembers = []
            }
            return ChatFriendDisplaySnapshotFingerprint.Row(
                id: item.id,
                previewId: item.preview.id,
                unreadCount: item.unreadCount,
                lastMessageAtEpoch: item.lastMessageAt?.timeIntervalSince1970 ?? 0,
                subtitle: item.subtitle ?? "",
                lastSeenAtRaw: item.preview.lastSeenAtRaw ?? "",
                isConversationBacked: item.isConversationBacked,
                inboxKind: item.inboxKind.rawValue,
                chip: chip,
                groupConversationId: groupConversationId,
                groupMemberIds: groupMembers,
                groupMemberCount: item.groupMemberCount,
                isGroupMuted: item.isGroupMuted
            )
        }
        return ChatFriendDisplaySnapshotFingerprint(query: query, rows: rows)
    }

    private func prefetchChatInboxAvatars(reason: String, rows: [ChatViewModel.FriendDisplay]) {
        let urls = rows.prefix(12).compactMap { item -> URL? in
            guard let raw = ImageDisplayURL.forList(
                thumbnail: item.preview.avatarThumbnailURL,
                full: item.preview.avatarURL
            ) else { return nil }
            return URL(string: raw)
        }
        guard !urls.isEmpty else {
#if DEBUG
            print("[SmoothPerf] operation=chatInboxAvatarPrefetch skipped=noURLs durationMs=0 coalesced=false avatarCount=0 reason=\(reason)")
#endif
            return
        }

        Task {
            let startedAt = Date()
            await DiscoverMapImageCache.shared.prefetch(urls: urls, bucket: .avatar)
#if DEBUG
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            print("[SmoothPerf] operation=chatInboxAvatarPrefetch skipped=none durationMs=\(ms) coalesced=false avatarCount=\(urls.count) reason=\(reason)")
#endif
        }
    }

    @ViewBuilder
    private var chatRootContent: some View {
        if shouldShowChatSignInRequired {
            chatSignInRequiredView
        } else if viewModel.isLoading && viewModel.friends.isEmpty && viewModel.incomingRequests.isEmpty {
            ProgressView("Loading…")
        } else {
            VStack(spacing: 10) {
                chatHeader
                if showsChatSocialSections {
                    chatSectionPicker
                }
                selectedChatSectionContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.top, 10)
        }
    }

    private var chatSignInRequiredView: some View {
        ContentUnavailableView(
            "Sign in to chat",
            systemImage: "person.crop.circle.badge.questionmark",
            description: Text("Use your account tab to sign in, then open Chat again.")
        )
    }

    private func logChatAuthGate(reason: String) {
#if DEBUG
        let hasSession = hasChatAuthSession
        let reasonBlocked = hasSession ? "none" : "missingSupabaseSession"
        print("[ChatAuthGate] reason=\(reason)")
        print("[ChatAuthGate] hasSession=\(hasSession)")
        print("[ChatAuthGate] userEmail=\(mapViewModel.authenticatedSocialEmailForUI.isEmpty ? "nil" : mapViewModel.authenticatedSocialEmailForUI)")
        print("[ChatAuthGate] isBusinessAccount=\(isBusinessChatAccount)")
        print("[ChatAuthGate] hasUserProfile=\(hasRegularUserProfileForChatGate)")
        print("[ChatAuthGate] reasonBlocked=\(reasonBlocked)")
#endif
    }

    private var chatHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            FanGeoPagePurposeHeader(
                title: L10n.t("Chat", languageCode: appLanguageRaw),
                subtitle: L10n.t("chat_tab_subtitle", languageCode: appLanguageRaw)
            )

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                if showsChatSocialSections, mapViewModel.canUsePrivateChat {
                    chatHeaderButton(systemImage: "person.badge.plus", accessibilityLabel: "Add friend") {
                        showingAddFriendSheet = true
                    }
                }

                chatOptionsMenu
            }
        }
        .padding(.horizontal, 16)
    }

    private var chatOptionsMenu: some View {
        Menu {
            if showsChatSocialSections, mapViewModel.canUsePrivateChat {
                Button {
                    showingNewMessageSheet = true
                } label: {
                    Label(L10n.t("new_message", languageCode: appLanguageRaw), systemImage: "square.and.pencil")
                }

                Button {
                    showingCreateGroupSheet = true
                } label: {
                    Label(L10n.t("create_a_group", languageCode: appLanguageRaw), systemImage: "person.3.fill")
                }

                Divider()
            }

            Button {
                openSupportChat = true
            } label: {
                Text("💬 Support Center")
            }

            Divider()

            Button {
                showingBlockedUsersSheet = true
            } label: {
                Text("🚫 Blocked Users")
            }

            Divider()

            Button {
                showingRecentlyDeleted = true
            } label: {
                Label(
                    L10n.t("chat_recently_deleted_title", languageCode: appLanguageRaw),
                    systemImage: "trash"
                )
            }
            .accessibilityLabel(L10n.t("chat_recently_deleted_menu_a11y", languageCode: appLanguageRaw))
            .accessibilityHint(L10n.t("chat_recently_deleted_menu_a11y_hint", languageCode: appLanguageRaw))
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .frame(width: 38, height: 38)
                .background(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.74 : 0.96), in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(FGColor.divider(colorScheme).opacity(0.55), lineWidth: 1)
                }
                .softCardShadow()
        }
        .accessibilityLabel("Chat options")
    }

    private func chatHeaderButton(systemImage: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .frame(width: 38, height: 38)
                .background(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.74 : 0.96), in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(FGColor.divider(colorScheme).opacity(0.55), lineWidth: 1)
                }
                .softCardShadow()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var chatSectionPicker: some View {
        HStack(spacing: 6) {
            ForEach(ChatSection.allCases) { section in
                chatSectionButton(section)
            }
        }
        .padding(4)
        .padding(.top, totalRequestRowCount > 0 ? 4 : 0)
        .background {
            Capsule(style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground).opacity(colorScheme == .dark ? 0.36 : 0.72))
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.55), lineWidth: 1)
        }
        .softCardShadow()
        .padding(.horizontal, 16)
        .onAppear {
#if DEBUG
            print("[ChatRequestsBadge] pendingCount=\(totalRequestRowCount)")
#endif
        }
        .onChange(of: totalRequestRowCount) { _, count in
#if DEBUG
            print("[ChatRequestsBadge] pendingCount=\(count)")
#endif
        }
    }

    private func chatSectionButton(_ section: ChatSection) -> some View {
        let isSelected = selectedSection == section
        let hasUnreadDMs = viewModel.unreadDirectMessageCount > 0
        let requestsTabBadgeCount = totalRequestRowCount
        return Button {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                selectedSection = section
            }
        } label: {
            HStack(spacing: 6) {
                ChatSectionTabIcon(
                    systemImage: chatSectionIcon(section),
                    showUnreadDot: section == .chats && hasUnreadDMs,
                    pendingRequestCount: section == .requests ? requestsTabBadgeCount : 0,
                    tint: isSelected ? FGColor.primaryText(colorScheme) : FGColor.secondaryText(colorScheme)
                )
                .animation(.spring(response: 0.28, dampingFraction: 0.82), value: hasUnreadDMs)
                .animation(.spring(response: 0.28, dampingFraction: 0.82), value: requestsTabBadgeCount)
                .zIndex(section == .requests && requestsTabBadgeCount > 0 ? 1 : 0)

                Text(section.rawValue)
                    .font(.system(size: 12.5, weight: isSelected ? .bold : .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .foregroundStyle(isSelected ? FGColor.primaryText(colorScheme) : FGColor.secondaryText(colorScheme))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, section == .requests && requestsTabBadgeCount > 0 ? 2 : 0)
            .frame(minHeight: 36)
            .background {
                Capsule(style: .continuous)
                    .fill(isSelected ? FGColor.cardBackground(colorScheme) : Color.clear)
            }
            .overlay(alignment: .bottom) {
                Capsule(style: .continuous)
                    .fill(isSelected ? FGColor.accentGreen : Color.clear)
                    .frame(width: 26, height: 2)
                    .offset(y: -2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            chatSectionAccessibilityLabel(
                section,
                hasUnreadDMs: section == .chats && hasUnreadDMs,
                pendingRequests: section == .requests ? requestsTabBadgeCount : 0
            )
        )
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private func chatSectionAccessibilityLabel(
        _ section: ChatSection,
        hasUnreadDMs: Bool,
        pendingRequests: Int
    ) -> String {
        switch section {
        case .chats:
            return hasUnreadDMs ? "\(section.rawValue), unread messages" : section.rawValue
        case .requests:
            guard pendingRequests > 0 else { return section.rawValue }
            let noun = pendingRequests == 1 ? "pending request" : "pending requests"
            return "\(section.rawValue), \(pendingRequests) \(noun)"
        default:
            return section.rawValue
        }
    }

    private func chatContentSectionHeader(
        title: String,
        count: Int,
        subtitle: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text(title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                if count > 0 {
                    Text(" · \(count)")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textCase(nil)
    }

    private var pendingIncomingRequestCount: Int {
        viewModel.pendingBadgeCount
    }

    private var totalRequestRowCount: Int {
        viewModel.incomingRequests.count
            + viewModel.outgoingRequests.count
            + viewModel.pendingGroupInvitations.count
    }

    private var requestsSectionSubtitle: String? {
        let pending = pendingIncomingRequestCount
        if pending == 1 { return "1 pending request" }
        if pending > 1 { return "\(pending) pending requests" }
        return nil
    }

    private func chatSectionIcon(_ section: ChatSection) -> String {
        switch section {
        case .chats:
            return "bubble.left.and.bubble.right.fill"
        case .friends:
            return "person.2.fill"
        case .requests:
            return "person.badge.plus"
        }
    }

    @ViewBuilder
    private var selectedChatSectionContent: some View {
        if showsChatSocialSections {
            switch selectedSection {
            case .chats:
                chatsList
            case .friends:
                friendsDirectoryList
            case .requests:
                requestsList
            }
        } else {
            chatsList
        }
    }

    /// When switching to Chat from another tab (e.g. Account → Settings pickup), `onChange(pendingDmOpenPreview)` may not run
    /// because the preview is already non-nil when this view appears—drain it here so programmatic DM opens still navigate.
    private func consumePendingDmOpenPreviewIfNeeded() {
        guard !viewModel.requiresSignIn else { return }
        if let groupId = viewModel.pendingGroupOpenConversationId {
            selectedSection = .chats
            groupNavigationConversationId = groupId
            viewModel.pendingGroupOpenConversationId = nil
            return
        }
        guard let preview = viewModel.pendingDmOpenPreview else { return }
        selectedSection = .chats
        dmBannerNavigationFriend = preview
        viewModel.pendingDmOpenPreview = nil
    }

    private func refreshFansLiveNowAfterFirstPaint(reason: String) {
        guard selectedSection == .chats, !shouldShowChatSignInRequired else { return }
        guard !isBusinessChatAccount else {
            fansLiveNowEntries = []
            return
        }
        Task { @MainActor in
            await Task.yield()
            let authId = mapViewModel.currentUserAuthId
            let languageCode = L10n.normalizedLanguageCode(
                UserDefaults.standard.string(forKey: L10n.appLanguageKey) ?? L10n.defaultLanguageCode
            )
            var entries = ChatFansLiveNowSessionCache.resolve(
                authId: authId,
                friends: viewModel.friends,
                languageCode: languageCode
            )
            // Fail closed: clear prior Nearby labels before the authoritative membership refresh.
            entries = ChatFansLiveNowSessionCache.applyingNearbyLabels(
                authId: authId,
                entries: entries,
                nearbyIds: [],
                languageCode: languageCode
            )
            fansLiveNowEntries = entries
#if DEBUG
            print("[FansLiveNow] refresh reason=\(reason) count=\(entries.count)")
            print("[ChatNearbyTest] candidateCount=\(entries.count)")
            if !entries.isEmpty, let ms = ChatLoadPerf.elapsedMsSinceLoadStarted() {
                ChatLoadPerf.liveFansVisibleMs(ms)
            }
#endif
            guard !entries.isEmpty else { return }
            // Candidate IDs must be profile/user IDs (`UserPreview.id`), never conversation/friendship IDs.
            let candidateIds = entries.map(\.preview.id)
#if DEBUG
            print("[ChatNearby] candidates count=\(candidateIds.count) idSource=preview")
#endif
            // Ensure requester center is available for the among-RPC (no new permission prompt).
            if mapViewModel.currentUserLocation == nil {
                _ = await mapViewModel.refreshCurrentUserLocationIfAuthorized(timeoutSeconds: 4)
            }
            if let coordinate = mapViewModel.currentUserLocation {
                PresenceService.shared.updateHeartbeatLocation(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )
#if DEBUG
                print("[ChatNearbyTest] heartbeat requester=success")
#endif
            } else {
#if DEBUG
                print("[ChatNearbyTest] heartbeat requester=missing")
                print("[ChatNearbyTest] excluded reason=missingLocation")
#endif
            }
            let nearbyIds = await FansNearbyService.shared.nearbyIdsAmong(
                authId: authId,
                isBusinessAccount: mapViewModel.currentUserIsBusinessAccount
                    || mapViewModel.isVenueOwnerLoggedIn,
                center: mapViewModel.currentUserLocation,
                candidateIds: candidateIds,
                force: true,
                reason: "fansLiveNow:\(reason)"
            )
            guard !Task.isCancelled, selectedSection == .chats else { return }
            entries = ChatFansLiveNowSessionCache.applyingNearbyLabels(
                authId: authId,
                entries: entries,
                nearbyIds: nearbyIds,
                languageCode: languageCode
            )
            fansLiveNowEntries = entries
#if DEBUG
            let labeled = entries.filter(\.isNearby).count
            print("[ChatNearby] entries rebuilt nearbyCount=\(labeled)")
            print("[ChatNearbyTest] rpc nearbyCount=\(nearbyIds.count)")
            for entry in entries {
                print("[ChatNearby] subtitle nearby=\(entry.isNearby ? "true" : "false")")
                print("[ChatNearbyTest] entry nearby=\(entry.isNearby ? "true" : "false")")
            }
#endif
        }
    }

    /// Conversation fetch in flight (initial or background). Presentation only — does not change fetch lifecycle.
    private var isLoadingConversations: Bool {
        viewModel.isInboxInitialLoadInFlight || viewModel.isInboxBackgroundRefreshInFlight
    }

    /// Authoritative conversation rows from the view model (not the deferred UI snapshot).
    private var authoritativeConversationFriends: [ChatViewModel.FriendDisplay] {
        viewModel.friends.filter(\.isConversationBacked)
    }

    /// Cached/loaded conversation list or a completed initial load (including empty inbox).
    private var hasConversationContent: Bool {
        !authoritativeConversationFriends.isEmpty || !chatConversationFriends.isEmpty
    }

    /// First-load pending for this account — never treat as the true empty state.
    private var isInitialInboxLoadPending: Bool {
        !shouldShowChatSignInRequired
            && !viewModel.hasCompletedInitialInboxLoad
            && authoritativeConversationFriends.isEmpty
    }

    /// Full-screen / section loader only when opening with nothing to show yet.
    private var shouldShowChatInboxLoadingState: Bool {
        if viewModel.initialInboxLoadFailed && !hasConversationContent {
            return false
        }
        if isInitialInboxLoadPending {
            return true
        }
        return isLoadingConversations && !hasConversationContent
    }

    /// Compact inline refresh above Recent Chats when existing content stays on screen.
    private var shouldShowInlineConversationRefresh: Bool {
        isLoadingConversations && hasConversationContent
    }

    private var shouldShowChatInboxEmptyState: Bool {
        viewModel.hasCompletedInitialInboxLoad
            && !viewModel.initialInboxLoadFailed
            && authoritativeConversationFriends.isEmpty
            && chatConversationFriends.isEmpty
            && !shouldShowChatInboxLoadingState
            && !isLoadingConversations
    }

    private var shouldShowChatInboxLoadFailureState: Bool {
        viewModel.initialInboxLoadFailed
            && !viewModel.hasCompletedInitialInboxLoad
            && !hasConversationContent
            && !isLoadingConversations
    }

    private var chatInboxUpdatingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Updating conversations…")
                .font(.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Updating conversations…")
    }

    private var chatInboxLoadingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Loading conversations…")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.96))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.55), lineWidth: 1)
        }
        .softCardShadow()
    }

    private var chatInboxLoadFailureCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Couldn't load conversations")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
            Text("Pull to try again, or reopen Chat.")
                .font(.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
            Button("Try again") {
                Task { await viewModel.beginInitialInboxLoadIfNeeded(source: "tab") }
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.96))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.55), lineWidth: 1)
        }
        .softCardShadow()
    }

    private var chatsList: some View {
        Group {
            if shouldShowChatInboxLoadingState {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        chatInboxLoadingCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 110)
                }
                .background(chatRootBackground)
            } else if shouldShowChatInboxLoadFailureState {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        chatInboxLoadFailureCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 110)
                }
                .background(chatRootBackground)
                .refreshable {
                    await viewModel.beginInitialInboxLoadIfNeeded(source: "tab")
                }
            } else if shouldShowChatInboxEmptyState {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if shouldShowFansLiveNowStrip {
                            fansLiveNowStrip
                        }
                        if shouldShowInlineConversationRefresh {
                            chatInboxUpdatingIndicator
                        }
                        chatEmptyState
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 110)
                }
                .background(chatRootBackground)
            } else {
                GeometryReader { layoutGeo in
                    VStack(spacing: 8) {
                        // Fans Live Now stays mounted during conversation refresh (not displaced by the loader).
                        if shouldShowFansLiveNowStrip {
                            fansLiveNowStrip
                                .padding(.horizontal, 16)
                                .fixedSize(horizontal: false, vertical: true)
                                .layoutPriority(1)
                        }
                        chatsInboxList(layoutWidth: layoutGeo.size.width)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .onAppear {
            logChatInboxAdPlacement()
            refreshFansLiveNowAfterFirstPaint(reason: "chatsListAppear")
        }
        .onChange(of: viewModel.friends) { _, _ in
            refreshFansLiveNowAfterFirstPaint(reason: "friendsUpdated")
        }
    }

    private var fansLiveNowStrip: some View {
        ChatFansLiveNowStripView(
            entries: fansLiveNowEntries,
            onSeeAll: { selectedSection = .friends },
            onOpenProfile: { userId in
                mapViewModel.presentPublicProfile(userId: userId, context: "fans_live_now")
            },
            onOpenChat: { preview in
                dmBannerNavigationFriend = preview
            }
        )
    }

    private func chatsInboxList(layoutWidth: CGFloat) -> some View {
        let inboxItems = ChatInboxAdPlacement.listItems(for: chatConversationFriends)
#if DEBUG
        let _ = logChatAdsInvestigation(
            conversations: chatConversationFriends,
            inboxItems: inboxItems,
            adLoaded: nil,
            phase: "listBuild"
        )
#endif
        return List {
            Section {
                ForEach(inboxItems) { item in
                    chatInboxListRow(item, layoutWidth: layoutWidth)
                }
            } header: {
                VStack(alignment: .leading, spacing: 6) {
                    if shouldShowInlineConversationRefresh {
                        chatInboxUpdatingIndicator
                    }
                    chatListHeader(
                        title: L10n.t("recent_conversations", languageCode: appLanguageRaw),
                        count: chatConversationFriends.count
                    )
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(chatRootBackground)
        .refreshable { await viewModel.refreshInboxSummaries() }
        .onAppear {
            viewModel.clearActiveVisibleConversationId(reason: "chat_list_visible")
            logChatInboxAdPlacement()
#if DEBUG
            logChatAdsInvestigation(
                conversations: chatConversationFriends,
                inboxItems: inboxItems,
                adLoaded: nil,
                phase: "listAppear"
            )
#endif
        }
        .onChange(of: chatConversationFriends.count) { _, _ in
            logChatInboxAdPlacement()
#if DEBUG
            logChatAdsInvestigation(
                conversations: chatConversationFriends,
                inboxItems: ChatInboxAdPlacement.listItems(for: chatConversationFriends),
                adLoaded: nil,
                phase: "conversationCountChanged"
            )
#endif
        }
    }

    private func chatListHeader(title: String, count: Int = 0) -> some View {
        HStack {
            HStack(spacing: 0) {
                Text(title)
                    .font(.headline.weight(.bold))
                    .textCase(nil)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                if count > 0 {
                    Text(" · \(count)")
                        .font(.headline.weight(.semibold))
                        .textCase(nil)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 0)
        .accessibilityElement(children: .combine)
    }

    private var supportInboxCardButton: some View {
        Button {
            openSupportChat = true
        } label: {
            FanGeoSupportInboxCard()
        }
        .buttonStyle(.plain)
    }

    private var supportInboxListRow: some View {
        supportInboxCardButton
            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private var chatEmptyState: some View {
        let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
        return VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(FGColor.accentGreen)
                .frame(width: 52, height: 52)
                .background(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.18 : 0.10), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("chat_empty_title", languageCode: languageCode))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))

                Text(L10n.t("chat_empty_privacy_message", languageCode: languageCode))
                    .font(.subheadline)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }

            HStack(spacing: 10) {
                if showsChatSocialSections {
                    Button {
                        showingAddFriendSheet = true
                    } label: {
                        Label("Find Fans", systemImage: "person.badge.plus")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(FGColor.accentGreen, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Button {
                    mapViewModel.requestDiscoverTabForHomeCrowd = true
                } label: {
                    Label("Explore Venues", systemImage: "map.fill")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .foregroundStyle(FGColor.accentGreen)
                .background(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.96))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.55), lineWidth: 1)
        }
        .softCardShadow()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func chatInboxListRow(_ item: ChatInboxListItem, layoutWidth: CGFloat) -> some View {
        switch item {
        case .conversation(let friend):
            friendRow(friend)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        Task {
                            await viewModel.clearInboxConversation(
                                peerUserId: friend.preview.id,
                                conversationId: friend.conversationId
                            )
                        }
                    } label: {
                        Label(
                            L10n.t("chat_delete_from_chats", languageCode: appLanguageRaw),
                            systemImage: "trash"
                        )
                    }
                }
                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        case .nativeAd(let slot):
            if isTabSelected {
                let _ = logChatNativeAdInserted(slot)
                CompactNativeAdCard(
                    placement: "chat.inboxFeed",
                    hostTabRaw: "chat",
                    slotIndex: slot.slotIndex,
                    layoutWidth: max(280, layoutWidth),
                    onAdLoaded: {
#if DEBUG
                        logChatAdsInvestigation(
                            conversations: chatConversationFriends,
                            inboxItems: ChatInboxAdPlacement.listItems(for: chatConversationFriends),
                            adLoaded: true,
                            phase: "adLoaded slot=\(slot.slotIndex)"
                        )
#endif
                    },
                    onAdFailed: { error in
#if DEBUG
                        logChatAdsInvestigation(
                            conversations: chatConversationFriends,
                            inboxItems: ChatInboxAdPlacement.listItems(for: chatConversationFriends),
                            adLoaded: false,
                            phase: "adFailed slot=\(slot.slotIndex) error=\(error.localizedDescription)"
                        )
#endif
                    }
                )
                .frame(maxWidth: .infinity)
                .frame(height: CompactNativeAdLayout.preferredHeight)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                let _ = logChatNativeAdSkipped(reason: "tabNotSelected")
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: CompactNativeAdLayout.preferredHeight)
                    .allowsHitTesting(false)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
    }

    private func logChatInboxAdPlacement() {
        guard AdDiagnostics.enabled else { return }
        let conversationCount = chatConversationFriends.count
        let insertionIndexes = ChatInboxAdPlacement.insertionPositions(for: conversationCount)
        let renderedInsertionIndexes = insertionIndexes.map(String.init).joined(separator: ",")
        print("[NativeAdDebug] placement=chat.inboxFeed conversationCount=\(conversationCount)")
        print("[NativeAdDebug] placement=chat.inboxFeed insertedAtIndex=\(insertionIndexes.first ?? -1)")
        if let reason = ChatInboxAdPlacement.skippedReason(conversationCount: conversationCount) {
            print("[NativeAdDebug] placement=chat.inboxFeed skippedReason=\(reason)")
        }
        print("[ChatInboxAdDebug] conversationCount=\(conversationCount)")
        print("[ChatInboxAdDebug] insertionIndexes=[\(renderedInsertionIndexes)]")
        print("[ChatInboxAdDebug] adsInsertedCount=\(insertionIndexes.count)")
        print("[ChatInboxAdDebug] debugOverride=\(ChatInboxAdPlacement.debugOverrideEnabled)")
        print("[ChatInboxAdDebug] enabled=true")
        print("[ChatInboxAdDebug] dmThreadAds=false")
    }

#if DEBUG
    /// Temporary investigation logger for Chat inbox sponsored ads. Do not keep permanently.
    private func logChatAdsInvestigation(
        conversations: [ChatViewModel.FriendDisplay],
        inboxItems: [ChatInboxListItem],
        adLoaded: Bool?,
        phase: String
    ) {
        let conversationCount = conversations.count
        let eligible = FanGeoAdPolicy.shouldInsertAdsInFeeds()
            && ChatInboxAdPlacement.shouldInsertNativeAd(conversationCount: conversationCount)
        let insertionIndexes = ChatInboxAdPlacement.insertionPositions(for: conversationCount)
        let insertAttempted = eligible && !insertionIndexes.isEmpty
        let rowTypes = inboxItems.map { item -> String in
            switch item {
            case .conversation: return "Conversation"
            case .nativeAd: return "SponsoredAd"
            }
        }
        let suppression = FanGeoAdPolicy.adsSuppressionReason ?? "none"
        let mount = FanGeoAdPolicy.shouldMountAdViews()
        let tabOffscreen = AdDebugContext.isTabOffscreenPreserved(tabRaw: "chat")
        let adLoadedText: String = {
            if let adLoaded { return "\(adLoaded)" }
            return "pending/unknown"
        }()

        print(
            """
            ===== CHAT ADS =====
            phase: \(phase)
            Conversations loaded: \(conversationCount)
            Eligible for ads: \(eligible) (policyInsert=\(FanGeoAdPolicy.shouldInsertAdsInFeeds()) suppression=\(suppression) mount=\(mount) tabOffscreen=\(tabOffscreen) isTabSelected=\(isTabSelected))
            Ad loaded: \(adLoadedText)
            Insert attempted: \(insertAttempted)
            Insert index: \(insertionIndexes.first.map(String.init) ?? "none")
            Final row count: \(inboxItems.count)
            Final row types: [\(rowTypes.joined(separator: ", "))]
            note: CompactNativeAdCard uses height=0/opacity=0 until load; chat row does not reserve preferredHeight (unlike Live).
            ===================
            """
        )
    }
#endif

    private func logChatNativeAdInserted(_ slot: ChatInboxNativeAdSlot) {
        guard AdDiagnostics.enabled else { return }
        print("[NativeAdDebug] placement=chat.inboxFeed insertedAtIndex=\(slot.insertedAfterConversationPosition)")
    }

    private func logChatNativeAdSkipped(reason: String) {
        guard AdDiagnostics.enabled else { return }
        print("[NativeAdDebug] placement=chat.inboxFeed skippedReason=\(reason)")
    }

    private var friendsDirectoryList: some View {
        Group {
            if friendsDirectoryItems.isEmpty {
                ContentUnavailableView(
                    "No friends yet",
                    systemImage: "person.2",
                    description: Text("Add fans to start building your sports circle.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        chatContentSectionHeader(
                            title: "Friends",
                            count: friendsDirectoryItems.count
                        )

                        friendsDirectorySearchField

                        if filteredFriendsDirectoryItems.isEmpty {
                            Text("No friends match your search.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 28)
                        } else {
                            LazyVGrid(
                                columns: [
                                    GridItem(.adaptive(minimum: 158, maximum: 220), spacing: 12, alignment: .top)
                                ],
                                spacing: 12
                            ) {
                                ForEach(filteredFriendsDirectoryItems) { item in
                                    friendDirectoryCard(item)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 110)
                }
                .background(chatRootBackground)
                .refreshable {
                    await viewModel.refreshFriendRequestListsOnly()
                    await viewModel.refreshInboxSummaries()
                }
                .onAppear {
                    logFriendsDirectoryLoadedCount()
                }
            }
        }
    }

    private var friendsDirectorySearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(FGColor.mutedText(colorScheme))
            TextField("Search friends", text: $friendDirectorySearchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.92))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.45), lineWidth: 1)
        }
        .softCardShadow()
    }

    private var requestsList: some View {
        Group {
            if viewModel.incomingRequests.isEmpty
                && viewModel.outgoingRequests.isEmpty
                && viewModel.pendingGroupInvitations.isEmpty {
                ContentUnavailableView(
                    "No pending requests",
                    systemImage: "person.2",
                    description: Text("When someone adds you, it will show up here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !viewModel.pendingGroupInvitations.isEmpty {
                        Section {
                            ForEach(viewModel.pendingGroupInvitations) { invitation in
                                groupInvitationRow(invitation)
                            }
                        } header: {
                            chatContentSectionHeader(
                                title: L10n.t("group_chat_invitations_section", languageCode: appLanguageRaw),
                                count: viewModel.pendingGroupInvitations.count,
                                subtitle: nil
                            )
                            .padding(.bottom, 4)
                        }
                    }

                    if !viewModel.incomingRequests.isEmpty || !viewModel.outgoingRequests.isEmpty {
                        Section {
                            if !viewModel.incomingRequests.isEmpty {
                                ForEach(viewModel.incomingRequests) { item in
                                    requestRowIncoming(item)
                                }
                            }
                            if !viewModel.outgoingRequests.isEmpty {
                                if !viewModel.incomingRequests.isEmpty {
                                    Text("Sent")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                                        .textCase(nil)
                                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
                                        .listRowSeparator(.hidden)
                                        .listRowBackground(Color.clear)
                                }
                                ForEach(viewModel.outgoingRequests) { item in
                                    requestRowOutgoing(item)
                                }
                            }
                        } header: {
                            chatContentSectionHeader(
                                title: "Requests",
                                count: viewModel.incomingRequests.count + viewModel.outgoingRequests.count,
                                subtitle: requestsSectionSubtitle
                            )
                            .padding(.bottom, 4)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(chatRootBackground)
                .refreshable { await viewModel.refresh() }
            }
        }
    }

    private func friendRow(_ item: ChatViewModel.FriendDisplay) -> some View {
        let conversationKey = item.conversationId ?? item.id
        let memberIds = viewModel.groupInboxAvatarMemberIdsByConversationId[conversationKey] ?? []
        let watchSpotVenueId = item.inboxKind == .business ? item.preview.businessVenueId : nil
        return ChatFriendInboxRow(
            item: item,
            timeLabel: Self.inboxTimeLabel(item.lastMessageAt, languageCode: appLanguageRaw),
            languageCode: appLanguageRaw,
            groupAvatarMemberIds: memberIds,
            groupMemberPreviews: viewModel.groupMemberPreviewByUserId,
            onOpenConversation: {
                openInboxConversation(item)
            },
            onOpenWatchSpotInDiscover: watchSpotVenueId.map { venueId in
                { openWatchSpotInDiscover(from: item, venueId: venueId) }
            }
        )
        .id(
            "inbox-\(item.inboxKind.rawValue)-\(conversationKey.uuidString.lowercased())-\(memberIds.map { $0.uuidString.lowercased() }.joined(separator: "."))"
        )
    }

    private func openInboxConversation(_ friend: ChatViewModel.FriendDisplay) {
#if DEBUG
        print("[DirectChatNav] rowTap conversationPresent=\(friend.conversationId != nil) kind=\(friend.inboxKind.rawValue)")
#endif
        if friend.isGroupConversation {
            groupNavigationConversationId = friend.conversationId ?? friend.id
        } else {
            dmBannerNavigationFriend = friend.preview
        }
    }

    private func openWatchSpotInDiscover(from friend: ChatViewModel.FriendDisplay, venueId: UUID) {
#if DEBUG
        print(
            "[ChatWatchSpotNavigation] kind=\(friend.inboxKind.rawValue) venueId=\(venueId.uuidString.lowercased()) focusRequested=true context=watch+allSpots+allSports"
        )
#endif
        mapViewModel.requestDiscoverFocusForVenueId(venueId)
    }

    private func friendDirectoryCard(_ item: ChatViewModel.FriendDisplay) -> some View {
        FriendDirectoryCard(
            item: item,
            colorScheme: colorScheme,
            onProfile: { openFriendProfile(from: $0) },
            onMessage: { openMessage(from: $0) },
            onUnfriend: { unfriendConfirmationItem = $0 }
        )
        .equatable()
    }

    private var friendDirectoryCardBackground: AnyShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(.ultraThinMaterial)
        }
        return AnyShapeStyle(Color.white.opacity(0.94))
    }

    private func friendDirectorySubtitle(for item: ChatViewModel.FriendDisplay) -> String {
        friendsDirectoryCardSubtitle(for: item)
    }

    private func openMessage(from item: ChatViewModel.FriendDisplay) {
#if DEBUG
        print("[FriendsDirectoryDebug] messageTapped=\(item.id.uuidString.lowercased())")
        print("[DirectChatNav] rowTap conversationPresent=\(item.conversationId != nil)")
#endif
        dmBannerNavigationFriend = item.preview
#if DEBUG
        print(
            "[DirectChatNav] setActive peerPresent=true conversationPresent=\(item.conversationId != nil || item.preview.dmConversationId != nil)"
        )
#endif
    }

    private func openFriendProfile(from item: ChatViewModel.FriendDisplay) {
#if DEBUG
        print("[FriendsDirectoryDebug] cardTapped=\(item.id.uuidString.lowercased())")
#endif
        mapViewModel.presentPublicProfile(userId: item.id, context: "friends_directory_card")
    }

    private func logFriendsDirectoryLoadedCount() {
#if DEBUG
        print("[FriendsDirectoryDebug] loadedCount=\(friendsDirectoryItems.count)")
#endif
    }

    private func logFriendsDirectorySearchQuery(_ query: String) {
#if DEBUG
        print("[FriendsDirectoryDebug] searchQuery=\(query.trimmingCharacters(in: .whitespacesAndNewlines))")
#endif
    }

    private func groupInvitationRow(_ invitation: GroupPendingInvitationRow) -> some View {
        let inviterPreview = viewModel.pendingGroupInvitationPreviews[invitation.inviter_user_id]
            ?? UserPreview(
                id: invitation.inviter_user_id,
                displayName: L10n.t("group_chat_system_member_fallback", languageCode: appLanguageRaw),
                avatarURL: nil,
                avatarThumbnailURL: nil
            )
        let memberCountText: String? = invitation.member_count.map { count in
            groupChatLocalizedMemberCount(count, languageCode: appLanguageRaw)
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProfileAvatarView(preview: inviterPreview, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(invitation.group_title)
                        .font(.subheadline.weight(.semibold))
                    Text(
                        String(
                            format: L10n.t("group_chat_invitation_invited_you", languageCode: appLanguageRaw),
                            inviterPreview.displayName
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let memberCountText {
                        Text(memberCountText)
                            .font(.caption2)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Button(L10n.t("group_chat_invitation_accept", languageCode: appLanguageRaw)) {
                    Task {
                        do {
                            let conversationId = try await viewModel.acceptGroupInvitation(invitation)
                            selectedSection = .chats
                            groupNavigationConversationId = conversationId
                        } catch {
                            // Server authorization failures clear on next inbox refresh.
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                Button(L10n.t("group_chat_invitation_decline", languageCode: appLanguageRaw)) {
                    Task { try? await viewModel.declineGroupInvitation(invitation) }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    private func requestRowIncoming(_ item: ChatViewModel.IncomingRequestDisplay) -> some View {
        let declined = item.friendship.isDeclinedStatus
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProfileAvatarView(preview: item.requester, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.requester.displayName)
                        .font(.subheadline.weight(.semibold))
                    if declined {
                        Text("Declined")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.orange)
                    } else {
                        Text("Wants to connect")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if declined {
                Button("Clear") {
                    Task { await viewModel.clearIncomingDeclinedRequest(item) }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(.orange)
            } else {
                HStack(spacing: 10) {
                    let busy = viewModel.isFriendRequestActionInFlight(item.friendship.id)
                    Button("Accept") { Task { await viewModel.accept(item) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                    Button("Decline") { Task { await viewModel.reject(item) } }
                        .buttonStyle(.bordered)
                        .disabled(busy)
                }
            }
        }
        .padding(.vertical, 4)
        .background {
            if declined {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(colorScheme == .dark ? 0.14 : 0.10))
            }
        }
    }

    private func requestRowOutgoing(_ item: ChatViewModel.OutgoingRequestDisplay) -> some View {
        let declined = item.friendship.isDeclinedStatus
        return HStack(spacing: 10) {
            ProfileAvatarView(preview: item.addressee, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.addressee.displayName)
                    .font(.subheadline.weight(.semibold))
                if declined {
                    Text("Declined")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.orange)
                } else {
                    Text("Pending")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if declined {
                Button("Clear") {
                    Task { await viewModel.clearOutgoingDeclinedRequest(item) }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(.orange)
            } else {
                Button("Cancel") { Task { await viewModel.cancel(item) } }
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(.vertical, 4)
        .background {
            if declined {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(colorScheme == .dark ? 0.14 : 0.10))
            }
        }
    }

    private static func inboxTimeLabel(_ date: Date?, languageCode: String) -> String {
        ChatInboxTimestampFormatting.label(for: date, languageCode: languageCode)
    }
}

private struct ChatSectionTabIcon: View {
    let systemImage: String
    let showUnreadDot: Bool
    let pendingRequestCount: Int
    let tint: Color

    private var showsRequestBadge: Bool { pendingRequestCount > 0 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 16, height: 16, alignment: .center)

            if showUnreadDot {
                ChatSectionDirectMessageUnreadDot()
                    .offset(x: 4, y: -2)
                    .transition(.scale(scale: 0.35).combined(with: .opacity))
            } else if showsRequestBadge {
                ChatSectionPendingRequestBadge(count: pendingRequestCount)
                    .offset(x: 6, y: -5)
                    .zIndex(2)
                    .transition(.scale(scale: 0.35).combined(with: .opacity))
            }
        }
        .frame(width: badgeLayoutWidth, height: 18, alignment: .center)
        .padding(.top, showsRequestBadge ? 4 : 0)
        .padding(.trailing, showsRequestBadge ? 6 : 0)
    }

    private var badgeLayoutWidth: CGFloat {
        showsRequestBadge ? 28 : 16
    }
}

private struct ChatSectionDirectMessageUnreadDot: View {
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption2) private var dotSize: CGFloat = 7

    var body: some View {
        Circle()
            .fill(FGColor.dangerRed)
            .frame(width: dotSize, height: dotSize)
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.30 : 0.92), lineWidth: max(0.5, dotSize * 0.14))
            }
            .shadow(color: FGColor.dangerRed.opacity(0.32), radius: 2, y: 0)
            .accessibilityHidden(true)
    }
}

private struct ChatSectionPendingRequestBadge: View {
    let count: Int
    @ScaledMetric(relativeTo: .caption2) private var minHeight: CGFloat = 14
    @ScaledMetric(relativeTo: .caption2) private var horizontalPadding: CGFloat = 4

    private var label: String {
        count > 99 ? "99+" : "\(count)"
    }

    var body: some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, horizontalPadding)
            .frame(minWidth: minHeight, minHeight: minHeight)
            .background(FGColor.dangerRed, in: Capsule())
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 0.5)
            }
            .shadow(color: FGColor.dangerRed.opacity(0.28), radius: 1.5, y: 0)
            .fixedSize()
            .accessibilityHidden(true)
    }
}

private struct ChatInboxBusinessConversationAvatar: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "building.2.fill")
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(FGColor.accentGreen)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Subtle type chip for Chat inbox title row. Private (`.direct`) has no badge.
private struct ChatInboxConversationTypeBadge: View {
    enum Kind {
        case group
        case watchSpot
    }

    let kind: Kind
    let languageCode: String
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption2) private var fontSize: CGFloat = 10
    @ScaledMetric(relativeTo: .caption2) private var horizontalPadding: CGFloat = 5
    @ScaledMetric(relativeTo: .caption2) private var verticalPadding: CGFloat = 2
    @ScaledMetric(relativeTo: .caption2) private var iconTextSpacing: CGFloat = 3

    var body: some View {
        HStack(spacing: iconTextSpacing) {
            Image(systemName: systemImage)
                .font(.system(size: fontSize, weight: .semibold))
            Text(label)
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .foregroundStyle(foreground)
        .background(background, in: Capsule(style: .continuous))
        .accessibilityHidden(true)
    }

    private var systemImage: String {
        switch kind {
        case .group: return "person.2.fill"
        case .watchSpot: return "building.2.fill"
        }
    }

    private var label: String {
        switch kind {
        case .group:
            return L10n.t("chat_inbox_badge_group", languageCode: languageCode)
        case .watchSpot:
            return L10n.t("chat_inbox_badge_watch_spot", languageCode: languageCode)
        }
    }

    private var foreground: Color {
        switch kind {
        case .group:
            return FGColor.secondaryText(colorScheme)
        case .watchSpot:
            return FGColor.accentGreen
        }
    }

    private var background: Color {
        switch kind {
        case .group:
            return FGColor.secondaryText(colorScheme).opacity(colorScheme == .dark ? 0.18 : 0.12)
        case .watchSpot:
            return FGColor.accentGreen.opacity(colorScheme == .dark ? 0.22 : 0.14)
        }
    }
}

private struct ChatInboxWatchSpotAffordanceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct ChatFriendInboxRow: View {
    let item: ChatViewModel.FriendDisplay
    let timeLabel: String
    var languageCode: String = L10n.defaultLanguageCode
    var groupAvatarMemberIds: [UUID] = []
    var groupMemberPreviews: [UUID: UserPreview] = [:]
    let onOpenConversation: () -> Void
    /// Authoritative Watch Spot venue focus. Nil when not venue-linked or venue id missing.
    var onOpenWatchSpotInDiscover: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption2) private var unreadCapsuleMinSize: CGFloat = 22

    private var isUnread: Bool { item.unreadCount > 0 }

    private var unreadBadgeText: String {
        item.unreadCount > 99 ? "99+" : "\(item.unreadCount)"
    }

    /// Authoritative inbox metadata only — never inferred from title/avatar text.
    private var conversationTypeBadgeKind: ChatInboxConversationTypeBadge.Kind? {
        switch item.inboxKind {
        case .direct:
            return nil
        case .group:
            return .group
        case .business:
            return .watchSpot
        }
    }

    private var conversationTypeAccessibilityPhrase: String {
        switch item.inboxKind {
        case .direct:
            return L10n.t("chat_inbox_a11y_private_conversation", languageCode: languageCode)
        case .group:
            return L10n.t("chat_inbox_a11y_group_conversation", languageCode: languageCode)
        case .business:
            return L10n.t("chat_inbox_a11y_watch_spot_conversation", languageCode: languageCode)
        }
    }

    private var openConversationAccessibilityLabel: String {
        var parts = [
            String(
                format: L10n.t("chat_inbox_a11y_open_conversation_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                item.preview.displayName
            ),
            conversationTypeAccessibilityPhrase
        ]
        if isUnread {
            parts.append(
                String(
                    format: L10n.t("chat_unread_count_a11y", languageCode: languageCode),
                    item.unreadCount
                )
            )
        }
        let preview = chatPreviewLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preview.isEmpty {
            parts.append(preview)
        }
        return parts.joined(separator: ", ")
    }

    private var viewWatchSpotAccessibilityLabel: String {
        String(
            format: L10n.t("chat_inbox_a11y_view_watch_spot_in_discover_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            item.preview.displayName
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            watchSpotOrStaticAvatar

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 6) {
                    Button(action: onOpenConversation) {
                        Text(item.preview.displayName)
                            .font(.subheadline.weight(isUnread ? .bold : .medium))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .layoutPriority(0)
                    .accessibilityLabel(openConversationAccessibilityLabel)

                    if let badgeKind = conversationTypeBadgeKind {
                        watchSpotBadgeOrStatic(badgeKind)
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)
                    }

                    Button(action: onOpenConversation) {
                        HStack(spacing: 8) {
                            Spacer(minLength: 4)

                            if !timeLabel.isEmpty {
                                Text(timeLabel)
                                    .font(.caption2.weight(isUnread ? .bold : .medium))
                                    .foregroundStyle(isUnread ? FGColor.accentGreen : FGColor.secondaryText(colorScheme))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }

                            if isUnread {
                                Text(unreadBadgeText)
                                    .font(.caption2.weight(.black))
                                    .foregroundStyle(Color.white)
                                    .frame(minWidth: unreadCapsuleMinSize, minHeight: unreadCapsuleMinSize)
                                    .padding(.horizontal, item.unreadCount > 99 ? 6 : 0)
                                    .background(FGColor.accentGreen, in: Capsule())
                                    .accessibilityHidden(true)
                            }

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(FGColor.mutedText(colorScheme))
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHidden(true)
                }

                Button(action: onOpenConversation) {
                    VStack(alignment: .leading, spacing: 4) {
                        if item.isPickupGameChat {
                            Text("Pickup game")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(FGColor.accentGreen)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if item.isGroupConversation, item.groupMemberCount > 0 {
                            Text(groupChatLocalizedMemberCount(item.groupMemberCount, languageCode: languageCode))
                                .font(.caption)
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if let businessName = item.preview.businessVenueBusinessName,
                           !businessName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(businessName)
                                .font(.caption)
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if !item.preview.isBusinessIdentity,
                                  !item.preview.publicHandleLine.isEmpty {
                            Text(item.preview.publicHandleLine)
                                .font(.caption)
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Text(chatPreviewLine)
                            .font(.caption.weight(isUnread ? .semibold : .regular))
                            .foregroundStyle(isUnread ? FGColor.primaryText(colorScheme) : FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .leading) {
            if isUnread {
                Capsule()
                    .fill(FGColor.accentGreen)
                    .frame(width: 3.5)
                    .padding(.vertical, 10)
                    .padding(.leading, 3)
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    isUnread
                        ? FGColor.accentGreen.opacity(colorScheme == .dark ? 0.38 : 0.28)
                        : FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.34 : 0.48),
                    lineWidth: 1
                )
        }
        .softCardShadow()
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: isUnread)
        .accessibilityElement(children: .contain)
#if DEBUG
        .onAppear {
            if item.inboxKind == .business, onOpenWatchSpotInDiscover == nil {
                print(
                    "[ChatWatchSpotNavigation] kind=business venueId=nil focusRequested=false reason=missingVenueId conversationId=\(item.conversationId?.uuidString.lowercased() ?? "nil")"
                )
            }
        }
#endif
    }

    @ViewBuilder
    private var watchSpotOrStaticAvatar: some View {
        if let onOpenWatchSpotInDiscover {
            Button(action: onOpenWatchSpotInDiscover) {
                inboxAvatar
            }
            .buttonStyle(ChatInboxWatchSpotAffordanceButtonStyle())
            .accessibilityLabel(viewWatchSpotAccessibilityLabel)
            .accessibilityHint(L10n.t("chat_inbox_a11y_view_watch_spot_hint", languageCode: languageCode))
        } else {
            inboxAvatar
        }
    }

    @ViewBuilder
    private func watchSpotBadgeOrStatic(_ kind: ChatInboxConversationTypeBadge.Kind) -> some View {
        let badge = ChatInboxConversationTypeBadge(kind: kind, languageCode: languageCode)
        if kind == .watchSpot, let onOpenWatchSpotInDiscover {
            // Same action as avatar; hide from VoiceOver to avoid duplicate controls.
            Button(action: onOpenWatchSpotInDiscover) {
                badge
            }
            .buttonStyle(ChatInboxWatchSpotAffordanceButtonStyle())
            .accessibilityHidden(true)
        } else {
            badge
        }
    }

    private var rowBackground: Color {
        if isUnread {
            return FGColor.accentGreen.opacity(colorScheme == .dark ? 0.14 : 0.08)
        }
        return FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.96)
    }

    @ViewBuilder
    private var inboxAvatar: some View {
        let fanAvatarSize: CGFloat = 52
        let businessIconSize: CGFloat = 44

        if item.isGroupConversation {
            GroupInboxMemberAvatarCluster(
                memberIds: groupAvatarMemberIds,
                memberCount: item.groupMemberCount,
                previewsByUserId: groupMemberPreviews,
                size: fanAvatarSize,
                languageCode: languageCode,
                colorScheme: colorScheme
            )
        } else if item.preview.isBusinessVenueConversation || item.preview.isBusinessAccount {
            ChatInboxBusinessConversationAvatar(size: businessIconSize)
                .frame(width: fanAvatarSize, height: fanAvatarSize, alignment: .center)
        } else {
            // Fan counterpart: compact last-active pill replaces the online dot.
            ProfileAvatarView(
                preview: item.preview,
                size: fanAvatarSize,
                usesCompactActivityPill: true
            )
        }
    }

    private var chatPreviewLine: String {
        let raw = item.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty
            ? ChatInboxPreviewFormatting.emptyConversationPlaceholder(languageCode: languageCode)
            : raw
    }
}

/// Compact overlapping member avatars for group conversation rows in Chat Inbox.
private struct GroupInboxMemberAvatarCluster: View {
    let memberIds: [UUID]
    let memberCount: Int
    let previewsByUserId: [UUID: UserPreview]
    let size: CGFloat
    let languageCode: String
    let colorScheme: ColorScheme

    private let maxVisible = 3
    private let avatarSize: CGFloat = 26

    private var visibleIds: [UUID] {
        Array(memberIds.prefix(maxVisible))
    }

    private var placeholderCount: Int {
        min(maxVisible, max(1, memberCount))
    }

    var body: some View {
        let ids = visibleIds
        let count = ids.isEmpty ? placeholderCount : ids.count
        HStack(spacing: -avatarSize * 0.34) {
            if ids.isEmpty {
                ForEach(0..<count, id: \.self) { index in
                    placeholderAvatar(seedIndex: index)
                }
            } else {
                ForEach(ids, id: \.self) { userId in
                    memberAvatar(for: userId)
                }
            }
        }
        .frame(width: size, height: size, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelText)
    }

    @ViewBuilder
    private func memberAvatar(for userId: UUID) -> some View {
        let preview = previewsByUserId[userId] ?? UserPreview(
            id: userId,
            displayName: L10n.t("Fan", languageCode: languageCode),
            avatarURL: nil,
            avatarThumbnailURL: nil
        )
        SocialAvatarRenderer.socialAvatarView(for: preview, size: avatarSize)
            .frame(width: avatarSize, height: avatarSize)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .strokeBorder(
                        colorScheme == .dark ? Color.black.opacity(0.55) : Color.white,
                        lineWidth: 1.2
                    )
            }
            .accessibilityHidden(true)
    }

    private func placeholderAvatar(seedIndex: Int) -> some View {
        let preview = UserPreview(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", seedIndex + 1)) ?? UUID(),
            displayName: L10n.t("Fan", languageCode: languageCode),
            avatarURL: nil,
            avatarThumbnailURL: nil
        )
        return SocialAvatarRenderer.socialAvatarView(for: preview, size: avatarSize)
            .frame(width: avatarSize, height: avatarSize)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .strokeBorder(
                        colorScheme == .dark ? Color.black.opacity(0.55) : Color.white,
                        lineWidth: 1.2
                    )
            }
            .accessibilityHidden(true)
    }

    private var accessibilityLabelText: String {
        let names = visibleIds.map { id in
            let preview = previewsByUserId[id]
            let trimmed = preview?.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
            if let username = preview?.username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty {
                return username
            }
            return L10n.t("Fan", languageCode: languageCode)
        }
        let totalOthersOrMembers = max(memberIds.count, names.count)
        if names.isEmpty {
            return String(
                format: L10n.t("group_chat_inbox_avatars_a11y_count_format", languageCode: languageCode),
                max(1, memberCount)
            )
        }
        if names.count == 1 {
            return String(
                format: L10n.t("group_chat_inbox_avatars_a11y_one_format", languageCode: languageCode),
                names[0]
            )
        }
        if names.count == 2, totalOthersOrMembers <= 2 {
            return String(
                format: L10n.t("group_chat_inbox_avatars_a11y_two_format", languageCode: languageCode),
                names[0],
                names[1]
            )
        }
        let remaining = max(0, memberIds.count - names.count)
        if remaining <= 0 {
            return String(
                format: L10n.t("group_chat_inbox_avatars_a11y_two_format", languageCode: languageCode),
                names[0],
                names[1]
            )
        }
        return String(
            format: L10n.t("group_chat_inbox_avatars_a11y_many_format", languageCode: languageCode),
            names[0],
            names[1],
            remaining
        )
    }
}

private struct FriendDirectoryCard: View, Equatable {
    let item: ChatViewModel.FriendDisplay
    let colorScheme: ColorScheme
    let onProfile: (ChatViewModel.FriendDisplay) -> Void
    let onMessage: (ChatViewModel.FriendDisplay) -> Void
    let onUnfriend: (ChatViewModel.FriendDisplay) -> Void

    static func == (lhs: FriendDirectoryCard, rhs: FriendDirectoryCard) -> Bool {
        lhs.item == rhs.item && lhs.colorScheme == rhs.colorScheme
    }

    var body: some View {
        VStack(spacing: 10) {
            Button {
                onProfile(item)
            } label: {
                VStack(spacing: 10) {
                    ProfileAvatarView(preview: item.preview, size: 74, profileTapContext: "friends_directory_avatar")
                        .padding(.top, 4)

                    VStack(spacing: 3) {
                        Text(item.preview.displayName)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(1)
                            .minimumScaleFactor(0.86)

                        Text(subtitle)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                            .minimumScaleFactor(0.86)
                    }
                    .frame(maxWidth: .infinity, minHeight: 38)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            Button {
                onMessage(item)
            } label: {
                Label("Message", systemImage: "bubble.left.fill")
                    .font(.caption.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(FGColor.accentBlue, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 178)
        .background(cardBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.34 : 0.52), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .softCardShadow()
        .overlay(alignment: .topTrailing) {
            friendOverflowMenu
                .padding(.top, 6)
                .padding(.trailing, 6)
        }
    }

    private var friendOverflowMenu: some View {
        Menu {
            Button {
                onMessage(item)
            } label: {
                Label("Message", systemImage: "bubble.left.fill")
            }

            Button {
                onProfile(item)
            } label: {
                Label("View Profile", systemImage: "person.crop.circle")
            }

            Divider()

            Button(role: .destructive) {
                onUnfriend(item)
            } label: {
                Label("Unfriend", systemImage: "person.fill.xmark")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .frame(width: 28, height: 28)
                .background(
                    FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.78 : 0.94),
                    in: Circle()
                )
                .overlay {
                    Circle()
                        .strokeBorder(FGColor.divider(colorScheme).opacity(0.45), lineWidth: 1)
                }
        }
        .accessibilityLabel("Friend options")
    }

    private var subtitle: String {
        friendsDirectoryCardSubtitle(for: item)
    }

    private var cardBackground: AnyShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(.ultraThinMaterial)
        }
        return AnyShapeStyle(Color.white.opacity(0.94))
    }
}

private struct ChatErrorAlertsModifier: ViewModifier {
    @ObservedObject var viewModel: ChatViewModel
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var friendRequestErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: {
                if !$0 {
                    viewModel.errorMessage = nil
                    viewModel.friendRequestAlertTitle = nil
                }
            }
        )
    }

    private var inboxDeleteErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.inboxDeleteError != nil },
            set: { if !$0 { viewModel.inboxDeleteError = nil } }
        )
    }

    private var unfriendErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.unfriendError != nil },
            set: { if !$0 { viewModel.unfriendError = nil } }
        )
    }

    func body(content: Content) -> some View {
        content
            .alert(
                viewModel.friendRequestAlertTitle
                    ?? L10n.t("friend_request_update_failed_title", languageCode: languageCode),
                isPresented: friendRequestErrorAlertBinding
            ) {
                Button(L10n.t("OK", languageCode: languageCode), role: .cancel) {
                    viewModel.errorMessage = nil
                    viewModel.friendRequestAlertTitle = nil
                }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .alert(
                "Couldn’t delete conversation",
                isPresented: inboxDeleteErrorAlertBinding
            ) {
                Button("OK", role: .cancel) {
                    viewModel.inboxDeleteError = nil
                }
            } message: {
                Text(viewModel.inboxDeleteError ?? "")
            }
            .alert(
                "Couldn’t unfriend",
                isPresented: unfriendErrorAlertBinding
            ) {
                Button("OK", role: .cancel) {
                    viewModel.unfriendError = nil
                }
            } message: {
                Text(viewModel.unfriendError ?? "")
            }
    }
}

// MARK: - Blocked Users

private struct ChatBlockedUsersSheet: View {
    @ObservedObject var viewModel: ChatViewModel
    var onContactSupport: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if blockedItems.isEmpty {
                        Text("No blocked users.")
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    } else {
                        ForEach(blockedItems, id: \.id) { item in
                            blockedUserRow(item)
                        }
                    }
                } header: {
                    Text("Manage people you have blocked.")
                        .font(.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .textCase(nil)
                }

                Section {
                    Text("Need help? Contact FanGeo Support.")
                        .font(.subheadline)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))

                    Button {
                        dismiss()
                        onContactSupport()
                    } label: {
                        Label("Contact FanGeo Support", systemImage: "bubble.left.and.bubble.right.fill")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Blocked Users")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await viewModel.refreshBlockedUsers()
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func blockedUserRow(_ item: BlockedUserDisplay) -> some View {
        HStack(spacing: 12) {
            ProfileAvatarView(preview: item.preview, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button("Unblock") {
                Task { await viewModel.unblockUser(item.id) }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    private var blockedItems: [BlockedUserDisplay] {
        let byId = Dictionary(uniqueKeysWithValues: viewModel.blockedUserPreviews.map { ($0.id, $0) })
        return viewModel.blockedUserIds
            .map { id -> BlockedUserDisplay in
                if let preview = byId[id] {
                    return BlockedUserDisplay(
                        id: id,
                        preview: preview,
                        title: preview.displayName,
                        subtitle: nil
                    )
                }
                let fallback = UserPreview(id: id, displayName: "Blocked user", avatarURL: nil)
                return BlockedUserDisplay(
                    id: id,
                    preview: fallback,
                    title: "Blocked user",
                    subtitle: shortId(id)
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func shortId(_ id: UUID) -> String {
        "\(id.uuidString.prefix(8))…"
    }

    private struct BlockedUserDisplay: Identifiable {
        let id: UUID
        let preview: UserPreview
        let title: String
        let subtitle: String?
    }
}

private struct FriendsTabLifecycleModifier: ViewModifier {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var mapViewModel: MapViewModel

    let isTabSelected: Bool
    @Binding var friendDirectorySearchText: String

    let onTabSelectedChange: (Bool) -> Void
    let onAppear: () -> Void
    let onFriendsChange: () -> Void
    let onFriendshipChipsChange: () -> Void
    let onSearchChange: (String) -> Void
    let onPendingDmOpen: () -> Void
    let onRequiresSignInChange: () -> Void
    let onChatUserAuthIdChange: () -> Void
    let onMapUserAuthIdChange: () -> Void
    let onBusinessAccountChange: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: isTabSelected) { _, on in
                onTabSelectedChange(on)
            }
            .onAppear(perform: onAppear)
            .onChange(of: viewModel.friends) { _, _ in
                onFriendsChange()
            }
            .onChange(of: viewModel.friendshipChipByOtherUserId) { _, _ in
                onFriendshipChipsChange()
            }
            .onChange(of: friendDirectorySearchText) { _, query in
                onSearchChange(query)
            }
            .onChange(of: viewModel.pendingDmOpenPreview) { _, preview in
                guard preview != nil else { return }
                onPendingDmOpen()
            }
            .onChange(of: viewModel.pendingGroupOpenConversationId) { _, groupId in
                guard groupId != nil else { return }
                onPendingDmOpen()
            }
            .onChange(of: viewModel.requiresSignIn) { _, _ in
                onRequiresSignInChange()
            }
            .onChange(of: viewModel.currentUserAuthId) { _, _ in
                onChatUserAuthIdChange()
            }
            .onChange(of: mapViewModel.currentUserAuthId) { _, _ in
                onMapUserAuthIdChange()
            }
            .onChange(of: mapViewModel.currentUserIsBusinessAccount) { _, _ in
                onBusinessAccountChange()
            }
    }
}

// MARK: - Add Friend (Liquid Glass sheet)

private struct AddFriendSearchResultRow: View {
    let target: AddFriendSearchTarget
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                addFriendResultAvatar
                addFriendResultText
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 44, alignment: .center)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.12)
                            : Color(.secondarySystemGroupedBackground).opacity(0.6)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var addFriendResultAvatar: some View {
        if target.entityType == .user {
            PublicProfileAvatarTap(userId: target.entityId, context: "add_friend_search") {
                UserAvatarView(
                    avatarThumbnailURL: target.avatarThumbnailURL,
                    avatarURL: target.avatarURL ?? "",
                    avatarDisplayRefreshToken: UserAvatarView.stableRefreshToken(
                        userId: target.entityId,
                        thumbnailURL: target.avatarThumbnailURL,
                        avatarURL: target.avatarURL
                    ),
                    displayName: target.displayName,
                    email: "",
                    size: 36,
                    fallbackStyle: .lightOnWhiteChrome,
                    imagePlaceholderTint: FGColor.accentBlue
                )
            }
        } else {
            Image(systemName: "building.2.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(FGColor.accentBlue)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(Circle())
        }
    }

    private var addFriendResultText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(target.listTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            if !target.publicHandleLine.isEmpty {
                Text(target.publicHandleLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if target.entityType == .business {
                Text("Business")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct BusinessVenuePickerSheet: View {
    let businessName: String
    let venues: [BusinessVenueMessageTarget]
    let onSelect: (BusinessVenueMessageTarget) -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List(venues) { venue in
                Button {
                    onSelect(venue)
                } label: {
                    HStack(spacing: 12) {
                        BusinessVenuePickerThumbnail(venue: venue)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(venue.venueName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            if !venue.locationLine.isEmpty {
                                Text(venue.locationLine)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Choose a venue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct BusinessVenuePickerThumbnail: View {
    let venue: BusinessVenueMessageTarget

    private let size: CGFloat = 48

    var body: some View {
        Group {
            if let urlString = ImageDisplayURL.forList(
                thumbnail: venue.coverPhotoThumbnailURL,
                full: venue.coverPhotoURL
            ),
               let url = URL(string: urlString) {
                DiscoverCachedRemoteImage(url: url, contentMode: .fill) {
                    fallbackBackground
                }
            } else {
                fallbackBackground
                    .overlay {
                        Image(systemName: "building.2.fill")
                            .font(.system(size: size * 0.4, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var fallbackBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
    }
}

private struct AddFriendGlassSheet: View {
    @Binding var lookupDraft: String
    @ObservedObject var viewModel: ChatViewModel
    let onClose: () -> Void

    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @State private var inlineError: String?
    @State private var inlineWarning: String?
    @State private var successMessage: String?
    @State private var isSending = false
    @State private var selectedTarget: AddFriendSearchTarget?
    @State private var searchTask: Task<Void, Never>?
    @State private var venuePickerTarget: AddFriendSearchTarget?
    @State private var venuePickerOptions: [BusinessVenueMessageTarget] = []
    @State private var selectedDetent: PresentationDetent = .medium

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var normalizedDraft: String {
        FriendshipService.normalizedFriendLookupQuery(lookupDraft)
    }

    private var canPerformPrimaryAction: Bool {
        selectedTarget != nil && !isSending
    }

    private var primaryActionTitle: String {
        // Always resolve through L10n (including disabled/"Send" with no selection).
        // Plain String titles skip SwiftUI LocalizedStringKey lookup.
        guard let target = selectedTarget else {
            return L10n.t("Send", languageCode: languageCode)
        }
        return target.entityType == .business
            ? L10n.t("Message", languageCode: languageCode)
            : L10n.t("Send", languageCode: languageCode)
    }

    var body: some View {
        VStack(spacing: 12) {
            header

            VStack(alignment: .leading, spacing: 8) {
                Text("Search fans or businesses")
                    .font(.subheadline.weight(.semibold))

                TextField(
                    L10n.t("Search by @handle, name, or email", languageCode: languageCode),
                    text: $lookupDraft
                )
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground).opacity(0.7))
                    )

                Text("Send a friend request to fans, or message a business.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if viewModel.addFriendSearchIsLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }

                if let successMessage {
                    Text(successMessage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
                if let inlineWarning {
                    Text(inlineWarning)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
                if let inlineError {
                    Text(inlineError)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                }

                searchResultsList
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.top, 12)
        .onChange(of: lookupDraft) { _, newValue in
            inlineError = nil
            inlineWarning = nil
            successMessage = nil
            selectedTarget = nil
            let normalized = FriendshipService.normalizedFriendLookupQuery(newValue)
            if !normalized.isEmpty, selectedDetent != .large {
                selectedDetent = .large
            }
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 320_000_000)
                guard !Task.isCancelled else { return }
                await viewModel.refreshAddFriendSearch(query: newValue)
            }
        }
        .onChange(of: viewModel.addFriendSearchResults) { _, results in
            if selectedTarget == nil {
                selectedTarget = results.first
            }
        }
        .onChange(of: selectedTarget) { _, newValue in
            inlineError = nil
            successMessage = nil
            if newValue?.entityType == .business {
                inlineWarning = "Businesses can't be added as friends, but you can message one of their venues."
            } else if inlineWarning == "Businesses can't be added as friends, but you can message one of their venues." {
                inlineWarning = nil
            }
        }
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(34)
        .presentationBackground(.ultraThinMaterial)
        .sheet(item: $venuePickerTarget) { target in
            BusinessVenuePickerSheet(
                businessName: target.displayName,
                venues: venuePickerOptions,
                onSelect: { venue in
                    venuePickerTarget = nil
                    Task {
                        isSending = true
                        let outcome = await viewModel.openBusinessVenueConversation(target: target, venue: venue)
                        isSending = false
                        switch outcome {
                        case .openedChat:
                            onClose()
                        case .needsVenuePicker:
                            inlineWarning = "Choose a venue to continue."
                        case .informational(let msg):
                            inlineWarning = msg
                        }
                    }
                },
                onClose: {
                    venuePickerTarget = nil
                }
            )
        }
    }

    @ViewBuilder
    private var searchResultsList: some View {
        if viewModel.addFriendSearchResults.isEmpty {
            if !normalizedDraft.isEmpty, !viewModel.addFriendSearchIsLoading {
                Text("No matches yet. Try another @handle, name, or email.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(viewModel.addFriendSearchResults) { target in
                        AddFriendSearchResultRow(
                            target: target,
                            isSelected: selectedTarget?.id == target.id
                        ) {
                            selectedTarget = target
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .scrollDismissesKeyboard(.never)
        }
    }

    private var header: some View {
        HStack {
            Button(successMessage == nil ? "Close" : "Done", action: onClose)
                .buttonStyle(.plain)
                .font(.headline.weight(.semibold))
                .foregroundStyle(successMessage == nil ? Color.secondary : Color.accentColor)
                .frame(width: 68, alignment: .leading)

            Spacer()

            Text("Find People & Businesses")
                .font(.headline.weight(.semibold))

            Spacer()

            Button(primaryActionTitle) {
                guard let target = selectedTarget else { return }
                Task {
                    isSending = true
                    inlineError = nil
                    inlineWarning = nil
                    successMessage = nil
                    if target.entityType == .user {
                        let outcome = await viewModel.sendFriendRequest(to: target)
                        switch outcome {
                        case .success:
                            successMessage = "Friend request sent."
                        case .informational(let msg):
                            inlineWarning = msg
                        case .error(let msg):
                            inlineError = msg
                        }
                    } else {
                        let outcome = await viewModel.prepareBusinessVenueMessage(from: target)
                        switch outcome {
                        case .openedChat:
                            onClose()
                        case .needsVenuePicker(let venues):
                            venuePickerOptions = venues
                            venuePickerTarget = target
                        case .informational(let msg):
                            inlineWarning = msg
                        }
                    }
                    isSending = false
                }
            }
            .buttonStyle(.plain)
            .font(.headline.weight(.semibold))
            .foregroundStyle(canPerformPrimaryAction ? Color.accentColor : Color.secondary)
            .disabled(!canPerformPrimaryAction)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(minWidth: 68, alignment: .trailing)
        }
        .padding(.horizontal, 18)
    }
}

// MARK: - Fans Live Now (Chat Chats tab)

private enum ChatFansLiveNowMetrics {
    static let avatarSize: CGFloat = 58
    static let ringSize: CGFloat = 66
    static let profileLabelSpacing: CGFloat = 3
    static let nameSubtitleSpacing: CGFloat = 1
    /// Per-line budget; cards may use up to ``nameMaxLines``.
    static let nameLineHeight: CGFloat = 16
    static let nameMaxLines: Int = 2
    /// "Online Fan" status line.
    static let statusLineHeight: CGFloat = 14
    static let statusNearbySpacing: CGFloat = 1
    /// Optional second line (`📍 Nearby`); included in row height so Nearby never clips.
    static let nearbyLineHeight: CGFloat = 14
    static let chatButtonTopSpacing: CGFloat = 3
    static let chatButtonHeight: CGFloat = 30

    static let minCardWidth: CGFloat = ringSize + 8
    static let maxCardWidthCompact: CGFloat = 102
    static let maxCardWidthRegular: CGFloat = 168

    static let rowHeight: CGFloat =
        ringSize
        + profileLabelSpacing
        + (nameLineHeight * CGFloat(nameMaxLines))
        + nameSubtitleSpacing
        + statusLineHeight
        + statusNearbySpacing
        + nearbyLineHeight
        + chatButtonTopSpacing
        + chatButtonHeight

    /// Adaptive card width from strip container size — computed outside cell `body` layouts.
    static func cardWidth(
        containerWidth: CGFloat,
        horizontalSizeClass: UserInterfaceSizeClass?
    ) -> CGFloat {
        let width = max(0, containerWidth)
        if horizontalSizeClass == .regular {
            // iPad / regular width: use available space without becoming a full-width tile.
            let proposed = width * 0.18
            return min(maxCardWidthRegular, max(118, proposed))
        }
        let proposed = max(minCardWidth, min(maxCardWidthCompact, width * 0.22))
        return proposed
    }
}

struct ChatFansLiveNowEntry: Identifiable, Hashable {
    let id: UUID
    let preview: UserPreview
    /// Line 1 under the name — always "Online Fan" (localized).
    let statusLine: String
    /// Line 2 when Nearby — e.g. "📍 Nearby". Nil for non-nearby (no blank gap).
    let nearbyLine: String?
    /// VoiceOver status without decorative pin/emoji.
    let accessibilitySubtitle: String
    let isNearby: Bool
}

enum ChatFansLiveNowSessionCache {
    static let displayLimit = FansNearbyProduct.amongCandidateCap

    private static var entriesByAuthId: [UUID: [ChatFansLiveNowEntry]] = [:]
    private static var presenceSignatureByAuthId: [UUID: String] = [:]

    static func clear(authId: UUID?) {
        guard let authId else {
            entriesByAuthId.removeAll()
            presenceSignatureByAuthId.removeAll()
            return
        }
        entriesByAuthId.removeValue(forKey: authId)
        presenceSignatureByAuthId.removeValue(forKey: authId)
    }

    static func resolve(
        authId: UUID?,
        friends: [ChatViewModel.FriendDisplay],
        languageCode: String
    ) -> [ChatFansLiveNowEntry] {
        guard let authId else { return [] }
        let signature = onlinePresenceSignature(friends) + "|lang:\(languageCode)"
        if let cached = entriesByAuthId[authId], presenceSignatureByAuthId[authId] == signature {
            return cached
        }
        let built = buildEntries(friends: friends, languageCode: languageCode)
        entriesByAuthId[authId] = built
        presenceSignatureByAuthId[authId] = signature
        return built
    }

    /// Applies Nearby membership labels to already-built Live Now entries (outside SwiftUI `body`).
    /// Matches RPC `user_id` against ``UserPreview/id`` (never conversation / friendship IDs).
    static func applyingNearbyLabels(
        authId: UUID?,
        entries: [ChatFansLiveNowEntry],
        nearbyIds: Set<UUID>,
        languageCode: String
    ) -> [ChatFansLiveNowEntry] {
        let updated = entries.map { entry in
            let isNearby = nearbyIds.contains(entry.preview.id)
            let labels = subtitleLabels(isNearby: isNearby, languageCode: languageCode)
            return ChatFansLiveNowEntry(
                id: entry.preview.id,
                preview: entry.preview,
                statusLine: labels.statusLine,
                nearbyLine: labels.nearbyLine,
                accessibilitySubtitle: labels.accessibilitySubtitle,
                isNearby: isNearby
            )
        }
        if let authId, presenceSignatureByAuthId[authId] != nil {
            entriesByAuthId[authId] = updated
        }
        return updated
    }

    private static func onlinePresenceSignature(_ friends: [ChatViewModel.FriendDisplay]) -> String {
        friends
            .filter { chatFansLiveNowCandidate($0.preview) }
            .map { "\($0.preview.id.uuidString.lowercased()):\($0.preview.lastSeenAtRaw ?? "")" }
            .sorted()
            .joined(separator: "|")
    }

    private static func buildEntries(
        friends: [ChatViewModel.FriendDisplay],
        languageCode: String
    ) -> [ChatFansLiveNowEntry] {
        var seen = Set<UUID>()

        let onlineFriends = friends
            .filter { chatFansLiveNowCandidate($0.preview) }
            .sorted { lhs, rhs in
                let left = PresenceOnlineStatus.parse(lhs.preview.lastSeenAtRaw) ?? .distantPast
                let right = PresenceOnlineStatus.parse(rhs.preview.lastSeenAtRaw) ?? .distantPast
                if left != right { return left > right }
                return lhs.preview.displayName.localizedCaseInsensitiveCompare(rhs.preview.displayName) == .orderedAscending
            }

        var entries: [ChatFansLiveNowEntry] = []
        entries.reserveCapacity(min(displayLimit, onlineFriends.count))
        let onlineLabels = subtitleLabels(isNearby: false, languageCode: languageCode)

        for friend in onlineFriends {
            // `FriendDisplay.id` is often a conversation/friendship id; RPC expects profile/user id.
            let profileId = friend.preview.id
            guard seen.insert(profileId).inserted else { continue }
            entries.append(
                ChatFansLiveNowEntry(
                    id: profileId,
                    preview: friend.preview,
                    statusLine: onlineLabels.statusLine,
                    nearbyLine: onlineLabels.nearbyLine,
                    accessibilitySubtitle: onlineLabels.accessibilitySubtitle,
                    isNearby: false
                )
            )
            if entries.count >= displayLimit { break }
        }
        return entries
    }

    private static func subtitleLabels(
        isNearby: Bool,
        languageCode: String
    ) -> (statusLine: String, nearbyLine: String?, accessibilitySubtitle: String) {
        let status = L10n.t("chat_fans_live_now_online_fan", languageCode: languageCode)
        if isNearby {
            return (
                status,
                L10n.t("chat_fans_live_now_nearby_line", languageCode: languageCode),
                L10n.t("chat_fans_live_now_online_fan_nearby_a11y", languageCode: languageCode)
            )
        }
        return (
            status,
            nil,
            L10n.t("chat_fans_live_now_online_fan_a11y", languageCode: languageCode)
        )
    }
}

private struct ChatFansLiveNowStripView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @State private var showNearbyInfo = false

    let entries: [ChatFansLiveNowEntry]
    let onSeeAll: () -> Void
    let onOpenProfile: (UUID) -> Void
    let onOpenChat: (UserPreview) -> Void

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Fans Live Now")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Button {
                    showNearbyInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("chat_fans_live_now_nearby_info_a11y", languageCode: languageCode))
                Spacer()
                Button("See all", action: onSeeAll)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.accentGreen)
            }

            GeometryReader { geo in
                let cardWidth = ChatFansLiveNowMetrics.cardWidth(
                    containerWidth: geo.size.width,
                    horizontalSizeClass: horizontalSizeClass
                )
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(entries) { entry in
                            ChatFansLiveNowCell(
                                entry: entry,
                                cardWidth: cardWidth,
                                onOpenProfile: onOpenProfile,
                                onOpenChat: onOpenChat
                            )
                        }
                    }
                }
            }
            .frame(height: ChatFansLiveNowMetrics.rowHeight)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Fans live now")
        .sheet(isPresented: $showNearbyInfo) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.t("chat_fans_live_now_nearby_info_title", languageCode: languageCode))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text(L10n.t("chat_fans_live_now_nearby_info_body", languageCode: languageCode))
                        .font(.body)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(FGColor.background(colorScheme).ignoresSafeArea())
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L10n.t("chat_fans_live_now_nearby_info_done", languageCode: languageCode)) {
                            showNearbyInfo = false
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }
}

private struct ChatFansLiveNowCompactChatButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption2) private var buttonHeight: CGFloat = ChatFansLiveNowMetrics.chatButtonHeight
    @ScaledMetric(relativeTo: .caption2) private var horizontalPadding: CGFloat = 12

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.caption2.weight(.bold))
                Text("Chat")
                    .font(.caption2.weight(.bold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: buttonHeight)
            .background(FGColor.accentBlue, in: Capsule(style: .continuous))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.10), radius: 6, y: 3)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.96))
        .accessibilityLabel("Chat with fan")
    }
}

private struct ChatFansLiveNowCell: View {
    @Environment(\.colorScheme) private var colorScheme

    let entry: ChatFansLiveNowEntry
    let cardWidth: CGFloat
    let onOpenProfile: (UUID) -> Void
    let onOpenChat: (UserPreview) -> Void

    private var avatarSize: CGFloat { ChatFansLiveNowMetrics.avatarSize }
    private var ringSize: CGFloat { ChatFansLiveNowMetrics.ringSize }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                onOpenProfile(entry.id)
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(FGColor.accentGreen.opacity(0.92), lineWidth: 2.5)
                        .frame(width: ringSize, height: ringSize)

                    SocialAvatarRenderer.socialAvatarView(for: entry.preview, size: avatarSize)
                        .frame(width: avatarSize, height: avatarSize)
                        .clipShape(Circle())
                        .overlay(alignment: .bottomTrailing) {
                            PresenceOnlineBadge(size: max(9, avatarSize * 0.22))
                                .offset(x: avatarSize * 0.03, y: avatarSize * 0.03)
                        }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.preview.displayName) profile")
            .accessibilityHint("Opens profile")
            .padding(.bottom, ChatFansLiveNowMetrics.profileLabelSpacing)

            Text(entry.preview.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)
                .lineLimit(ChatFansLiveNowMetrics.nameMaxLines)
                .minimumScaleFactor(0.88)
                .truncationMode(.tail)
                .frame(width: cardWidth, alignment: .top)
                .frame(minHeight: ChatFansLiveNowMetrics.nameLineHeight, alignment: .top)
                .padding(.bottom, ChatFansLiveNowMetrics.nameSubtitleSpacing)
                .accessibilityLabel(entry.preview.displayName)

            VStack(spacing: ChatFansLiveNowMetrics.statusNearbySpacing) {
                Text(entry.statusLine)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let nearbyLine = entry.nearbyLine {
                    Text(nearbyLine)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(FGColor.accentGreen)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: cardWidth)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.accessibilitySubtitle)

            ChatFansLiveNowCompactChatButton {
                onOpenChat(entry.preview)
            }
            .frame(maxWidth: cardWidth, alignment: .center)
            .padding(.top, ChatFansLiveNowMetrics.chatButtonTopSpacing)
        }
        .frame(width: cardWidth)
        .accessibilityElement(children: .contain)
    }
}
