import SwiftUI
import Supabase
import UIKit

/// Neutral copy for invite eligibility / authorization failures (never disclose blocks).
/// Also routes backend age-access denials into the shared age gate (single system).
@MainActor
private func groupChatNeutralInviteErrorText(_ error: Error, languageCode: String) -> String {
    if AgeAccessBackendDenial.handle(error, requestUserId: nil) {
        return L10n.t("group_chat_invite_unavailable", languageCode: languageCode)
    }
    let raw = error.localizedDescription.lowercased()
    if raw.contains("not eligible")
        || raw.contains("not authorized")
        || raw.contains("42501") {
        return L10n.t("group_chat_invite_unavailable", languageCode: languageCode)
    }
    return error.localizedDescription
}

// MARK: - Create group

struct CreateGroupChatSheet: View {
    @ObservedObject var chatViewModel: ChatViewModel
    var onCreated: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var title: String = ""
    @State private var selectedIds: Set<UUID> = []
    @State private var isSubmitting = false
    @State private var errorText: String?

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var candidates: [ChatViewModel.FriendDisplay] {
        chatViewModel.friends.filter {
            !$0.isGroupConversation
                && !$0.preview.isBusinessAccount
                && !$0.preview.isBusinessVenueConversation
                && !$0.preview.isDeleted
                && chatViewModel.chipKind(forOtherUserId: $0.preview.id) == .friends
                && !chatViewModel.isEitherDirectionBlocked(with: $0.preview.id)
        }
    }

    private var canCreate: Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !isSubmitting
            && trimmed.count >= 1
            && trimmed.count <= 60
            && selectedIds.count >= 2
            && selectedIds.count <= 24
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField(L10n.t("group_chat_title_placeholder", languageCode: appLanguageRaw), text: $title)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text(L10n.t("group_chat_name_section", languageCode: appLanguageRaw))
                } footer: {
                    Text(L10n.t("group_chat_create_invite_footer", languageCode: appLanguageRaw))
                }

                Section {
                    ForEach(candidates) { friend in
                        Button {
                            toggle(friend.preview.id)
                        } label: {
                            HStack(spacing: 12) {
                                ProfileAvatarView(preview: friend.preview, size: 36)
                                Text(friend.preview.displayName)
                                    .foregroundStyle(FGColor.primaryText(colorScheme))
                                Spacer()
                                Image(systemName: selectedIds.contains(friend.preview.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedIds.contains(friend.preview.id) ? FGColor.accentGreen : FGColor.mutedText(colorScheme))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(L10n.t("group_chat_members_section", languageCode: appLanguageRaw))
                }
            }
            .navigationTitle(L10n.t("create_a_group", languageCode: appLanguageRaw))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel", languageCode: appLanguageRaw)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("group_chat_create_action", languageCode: appLanguageRaw)) {
                        Task { await create() }
                    }
                    .disabled(!canCreate)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding()
                }
            }
        }
    }

    private func toggle(_ id: UUID) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else if selectedIds.count < 24 {
            selectedIds.insert(id)
        }
    }

    @MainActor
    private func create() async {
        guard canCreate else { return }
        isSubmitting = true
        errorText = nil
        do {
            let id = try await GroupChatService().createGroup(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                memberIds: Array(selectedIds)
            )
            await chatViewModel.refreshInboxSummaries()
            onCreated(id)
            dismiss()
        } catch {
            errorText = groupChatNeutralInviteErrorText(error, languageCode: languageCode)
        }
        isSubmitting = false
    }
}

// MARK: - New message (friend picker)

struct NewMessageFriendPickerSheet: View {
    @ObservedObject var chatViewModel: ChatViewModel
    var onSelect: (UserPreview) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var friends: [ChatViewModel.FriendDisplay] {
        chatViewModel.friends.filter {
            !$0.isGroupConversation
                && !$0.preview.isDeleted
                && chatViewModel.chipKind(forOtherUserId: $0.preview.id) == .friends
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(friends) { friend in
                    Button {
                        onSelect(friend.preview)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            ProfileAvatarView(preview: friend.preview, size: 40)
                            Text(friend.preview.displayName)
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(L10n.t("new_message", languageCode: appLanguageRaw))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel", languageCode: appLanguageRaw)) { dismiss() }
                }
            }
            .overlay {
                if friends.isEmpty {
                    Text(L10n.t("group_chat_no_friends_to_message", languageCode: appLanguageRaw))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .padding()
                }
            }
        }
    }
}

// MARK: - Group conversation

struct GroupChatView: View {
    let conversationId: UUID
    @ObservedObject var chatViewModel: ChatViewModel
    /// When set, this thread is presented as a pickup-game chat (header + info gating).
    var pickupContext: PickupGameChatContext? = nil
    @EnvironmentObject private var mapViewModel: MapViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    init(
        conversationId: UUID,
        chatViewModel: ChatViewModel,
        pickupContext: PickupGameChatContext? = nil
    ) {
#if DEBUG
        ChatNavDebugCounters.log("destination.init", detail: "kind=group")
#endif
        self.conversationId = conversationId
        self.chatViewModel = chatViewModel
        self.pickupContext = pickupContext
    }

    @State private var title: String = L10n.t("group_chat_default_title")
    @State private var messages: [GroupMessageRow] = []
    @State private var draft: String = ""
    @State private var isLoading = true
    @State private var isSending = false
    @State private var isLoadingOlder = false
    @State private var canLoadOlder = true
    @State private var errorText: String?
    @State private var showInfo = false
    @State private var details: [GroupConversationDetailRow] = []
    @State private var memberPreviews: [UUID: UserPreview] = [:]
    @State private var realtimeChannel: RealtimeChannelV2?
    @State private var realtimeListenTask: Task<Void, Never>?
    /// Owns subscribe/retry so SwiftUI `.task` cancellation cannot abandon a healthy channel at `.connecting`.
    @State private var groupRealtimeSubscriptionTask: Task<Void, Never>?
    @State private var subscribedConversationId: UUID?
    @State private var realtimeConnectionStatus: ChatRealtimeConnectionStatus = .connecting
    @State private var chatRealtimeLifecycleGeneration: Int = 0
    @State private var ownedGroupChannelGeneration: Int = 0
    @State private var groupRealtimeStopTask: Task<Void, Never>?
    @State private var groupHadSuccessfulSubscribe = false
    @State private var seenMessageIds: Set<UUID> = []
    @State private var reportTarget: GroupMessageRow?
    @State private var reportCategory: ModerationReportCategory = .spam
    @State private var isSubmittingReport = false
    @State private var reportBanner: String?
    /// Session-local guard: backend allows multiple reports per message; UI must not.
    @State private var reportedMessageIds: Set<UUID> = []
    @State private var showEmojiQuickTray = false
    @State private var isRefreshingMessages = false
    @State private var showPollCreateSheet = false
    @State private var hiddenPollIds: Set<UUID> = []
    @State private var pendingScrollToMessageId: UUID?
    @State private var replyDraft: ChatReplyComposerDraft?
    @State private var highlightedReplyMessageId: UUID?
    @State private var showConversationSearch = false
    @FocusState private var composerFocused: Bool
    /// Suppress eligibility/status animations while the first open `.task` hydrates membership.
    @State private var isThreadOpening = true

    private let service = GroupChatService()
    private let pollService = PickupGamePollService()
    private let identityService = SocialIdentityService()
    private let maxBodyLength = 1000

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var isPickupGameChat: Bool {
        pickupContext != nil || details.first?.isPickupGameChat == true
    }

    private var effectivePickupGameId: UUID? {
        pickupContext?.pickupGameId ?? details.first?.pickup_game_id
    }

    /// Pickup chats assign `admin` to the game creator. Co-organizers are not supported yet.
    private var viewerIsPickupOrganizer: Bool {
        guard isPickupGameChat else { return false }
        return details.first?.viewer_is_admin == true
    }

    private var pickupPollCreatePermission: PickupPollCreatePermission {
        guard let id = effectivePickupGameId else { return .organizerOnly }
        if let row = mapViewModel.resolvedPickupGameRow(for: id) {
            return row.pollCreatePermission
        }
        return .organizerOnly
    }

    private var canCreatePickupPoll: Bool {
        PickupGamePollAccess.canCreate(
            isOrganizer: viewerIsPickupOrganizer,
            permission: pickupPollCreatePermission,
            isApprovedParticipant: viewerIsActiveMember && isPickupGameChat
        )
            && viewerIsActiveMember
            && !sendingDisabled
            && effectivePickupGameId != nil
    }

    /// Newest open poll message in this thread (for Group Info → scroll-to).
    private var activePickupPollMessageId: UUID? {
        guard isPickupGameChat else { return nil }
        for message in messages.reversed() {
            guard let payload = PickupGamePollMessage.decode(from: message.body) else { continue }
            if PickupGamePollLocalHide.isHidden(
                userId: chatViewModel.currentUserAuthId,
                pollId: payload.pollId
            ) {
                continue
            }
            if hiddenPollIds.contains(payload.pollId) { continue }
            if let snap = PickupGamePollStore.shared.snapshot(for: payload.pollId) {
                if snap.isClosed || snap.isSoftDeleted { continue }
            }
            return message.id
        }
        return nil
    }

    private var viewerIsActiveMember: Bool {
        guard let me = chatViewModel.currentUserAuthId else { return false }
        return details.contains(where: { $0.member_user_id == me })
    }

    private var sendingDisabled: Bool {
        isSending || (!details.isEmpty && !viewerIsActiveMember)
    }

    private var canSendDraft: Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maxBodyLength
    }

    /// Other members only (excludes viewer when others exist).
    private var headerOtherMembers: [UserPreview] {
        let me = chatViewModel.currentUserAuthId
        let others = details
            .map(\.member_user_id)
            .filter { $0 != me }
            .map { preview(for: $0) }
        if others.isEmpty, let me, details.contains(where: { $0.member_user_id == me }) {
            return [preview(for: me)]
        }
        return others
    }

    private var headerPreviewNames: [String] {
        headerOtherMembers.map { GroupChatMemberIdentity.compactName(from: $0) }
    }

    private var headerSubtitleText: String {
        if let pickupContext {
            let subtitle = pickupContext.headerSubtitle
            if !subtitle.isEmpty { return subtitle }
        }
        if isPickupGameChat {
            let count = details.count
            if count > 0 {
                return "\(count) approved · Pickup game"
            }
            return "Pickup game"
        }
        return GroupChatMemberIdentity.headerSubtitle(
            names: headerPreviewNames,
            totalOtherCount: headerOtherMembers.count,
            isOnlyViewer: details.count == 1 && details.first?.member_user_id == chatViewModel.currentUserAuthId,
            languageCode: languageCode
        )
    }

    private var displayTitle: String {
        if let pickupContext {
            let trimmed = pickupContext.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return title
    }

    private var headerAccessibilityLabel: String {
        let names = headerPreviewNames
        if names.isEmpty {
            return title
        }
        if details.count == 1, details.first?.member_user_id == chatViewModel.currentUserAuthId {
            return "\(title). \(L10n.t("group_chat_just_you", languageCode: languageCode))"
        }
        let joined: String
        if names.count <= 2 {
            joined = names.joined(separator: ", ")
        } else {
            let shown = names.prefix(2).joined(separator: ", ")
            let remaining = names.count - 2
            joined = String(
                format: L10n.t("group_chat_members_a11y_more_format", languageCode: languageCode),
                shown,
                remaining
            )
        }
        return String(
            format: L10n.t("group_chat_members_a11y_format", languageCode: languageCode),
            joined
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if canLoadOlder, !messages.isEmpty {
                        Button {
                            Task { await loadOlder() }
                        } label: {
                            HStack {
                                Spacer()
                                if isLoadingOlder {
                                    ProgressView()
                                } else {
                                    Text(L10n.t("group_chat_load_earlier", languageCode: appLanguageRaw))
                                        .font(.caption.weight(.semibold))
                                }
                                Spacer()
                            }
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoadingOlder)
                    }

                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        groupBubble(message, showsSenderIdentity: showsSenderIdentity(at: index))
                            .chatReplyHighlight(
                                isHighlighted: highlightedReplyMessageId == message.id,
                                colorScheme: colorScheme
                            )
                            .contextMenu {
                                if !message.isSystemMessage {
                                    groupMessageContextMenu(for: message)
                                }
                            }
                            .id(message.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: messages.last?.id) { _, newId in
                guard let newId else { return }
                withAnimation {
                    proxy.scrollTo(newId, anchor: .bottom)
                }
            }
            .onChange(of: pendingScrollToMessageId) { _, messageId in
                guard let messageId else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(messageId, anchor: .center)
                    }
                    highlightedReplyMessageId = messageId
                    pendingScrollToMessageId = nil
                    let clearDelay: TimeInterval = UIAccessibility.isReduceMotionEnabled ? 0.15 : 1.1
                    DispatchQueue.main.asyncAfter(deadline: .now() + clearDelay) {
                        if highlightedReplyMessageId == messageId {
                            highlightedReplyMessageId = nil
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 8) {
            groupComposer
        }
        .background(colorScheme == .dark ? Color.black : Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    showInfo = true
                } label: {
                    VStack(spacing: 2) {
                        Text(displayTitle)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)

                        if isPickupGameChat {
                            Text(headerSubtitleText)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        } else if !details.isEmpty {
                            GroupChatMemberHeaderPreview(
                                members: Array(headerOtherMembers.prefix(3)),
                                subtitle: headerSubtitleText,
                                colorScheme: colorScheme
                            )
                            .frame(maxWidth: 220)
                        }
                    }
                    .frame(minHeight: details.isEmpty && pickupContext == nil ? 28 : 40)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(headerAccessibilityLabel)
                .accessibilityHint(L10n.t("group_chat_info_a11y", languageCode: languageCode))
            }

            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Button {
                        showConversationSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel(L10n.t("chat_conversation_search_title", languageCode: languageCode))

                    Button {
                        showInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel(L10n.t("group_chat_info_a11y", languageCode: appLanguageRaw))
                }
            }
        }
        .sheet(isPresented: $showConversationSearch) {
            ChatConversationSearchSheet(
                conversationId: conversationId,
                languageCode: languageCode,
                onSelectMessage: { messageId in
                    jumpToGroupRepliedMessage(messageId)
                }
            )
        }
        .sheet(isPresented: $showInfo) {
            GroupChatInfoView(
                conversationId: conversationId,
                details: details,
                memberPreviews: memberPreviews,
                chatViewModel: chatViewModel,
                isPickupGameChat: isPickupGameChat,
                pickupContext: pickupContext,
                pickupGameId: effectivePickupGameId,
                pollCreatePermission: pickupPollCreatePermission,
                canEditPollPermission: viewerIsPickupOrganizer && viewerIsActiveMember,
                isApprovedPickupParticipant: viewerIsActiveMember && isPickupGameChat,
                activePollMessageId: activePickupPollMessageId,
                onCreatePoll: {
                    showInfo = false
                    showPollCreateSheet = true
                },
                onChangePollPermission: { permission in
                    guard let gameId = effectivePickupGameId else {
                        return L10n.t("pickup_poll_error_create_not_allowed", languageCode: languageCode)
                    }
                    do {
                        try await mapViewModel.updatePickupGamePollCreatePermission(
                            id: gameId,
                            permission: permission
                        )
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                },
                onViewActivePoll: { messageId in
                    showInfo = false
                    pendingScrollToMessageId = messageId
                },
                onViewPickupGame: { gameId in
                    let snapshot = mapViewModel.resolvedPickupGameRow(for: gameId)
                    showInfo = false
                    mapViewModel.openPickupGameFromChatGroupInfo(gameId: gameId, snapshot: snapshot)
                },
                onLeft: {
                    showInfo = false
                    dismiss()
                },
                onDetailsChanged: { updated, previews in
                    details = updated
                    memberPreviews = previews
                    if let first = updated.first {
                        title = first.title
                    }
                }
            )
            .environmentObject(mapViewModel)
        }
        .sheet(item: $reportTarget) { message in
            NavigationStack {
                Form {
                    Section {
                        Text(message.body)
                            .font(.body)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    } header: {
                        Text(L10n.t("group_chat_report_message", languageCode: appLanguageRaw))
                    }

                    Section {
                        Picker(L10n.t("group_chat_report_category", languageCode: appLanguageRaw), selection: $reportCategory) {
                            ForEach(ModerationReportCategory.allCases) { category in
                                Text(category.displayTitle).tag(category)
                            }
                        }
                    }
                }
                .navigationTitle(L10n.t("group_chat_report_message", languageCode: appLanguageRaw))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.t("Cancel", languageCode: appLanguageRaw)) {
                            reportTarget = nil
                        }
                        .disabled(isSubmittingReport)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.t("group_chat_report_submit", languageCode: appLanguageRaw)) {
                            Task { await submitReport(message) }
                        }
                        .disabled(isSubmittingReport)
                    }
                }
                .interactiveDismissDisabled(isSubmittingReport)
            }
            .presentationDetents([.medium])
        }
        .task {
#if DEBUG
            print("[ChatNav] destination.taskBegin kind=group")
#endif
            isThreadOpening = true
            await load()
            if let highlightId = chatViewModel.pendingOpenHighlightMessageId {
                chatViewModel.pendingOpenHighlightMessageId = nil
                jumpToGroupRepliedMessage(highlightId)
            }
            PickupGamePollStore.shared.bind(conversationId: conversationId)
            groupRealtimeStopTask?.cancel()
            // Fire owned subscribe lifecycle; do not bind subscribeWithError to this SwiftUI `.task`.
            await subscribeGroupRealtime(reason: "open", beginNewLifecycle: true)
            isThreadOpening = false
        }
        .onAppear {
#if DEBUG
            ChatNavDebugCounters.log("directChat.onAppear", detail: "kind=group")
#endif
            // Cancel stale stop only — floating-tab chrome is owned by parent route state.
            // Initial load + realtime owned by `.task`.
            groupRealtimeStopTask?.cancel()
            chatViewModel.setActiveVisibleGroupConversationId(conversationId, reason: "group_chat_appear")
            PickupGamePollStore.shared.bind(conversationId: conversationId)
            ChatRealtimeAudit.log(
                conversationId: conversationId,
                generation: chatRealtimeLifecycleGeneration,
                event: "appear",
                status: String(describing: realtimeConnectionStatus)
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: FanProfileChangeCenter.avatarDidChangeNotification)) { notification in
            guard let change = FanProfileChangeCenter.avatarChange(from: notification) else { return }
            applyMemberAvatarChange(change)
        }
        .onDisappear {
#if DEBUG
            ChatNavDebugCounters.log("directChat.onDisappear", detail: "kind=group")
#endif
            replyDraft = nil
            chatViewModel.clearActiveVisibleGroupConversationId(reason: "group_chat_disappear")
            let disappearGen = chatRealtimeLifecycleGeneration
            ChatRealtimeAudit.log(
                conversationId: conversationId,
                generation: disappearGen,
                event: "disappear",
                status: String(describing: realtimeConnectionStatus)
            )
            groupRealtimeStopTask?.cancel()
            groupRealtimeStopTask = Task {
                await tearDownGroupRealtime(
                    statusAfter: .connecting,
                    expectedGeneration: disappearGen
                )
                await PickupGamePollStore.shared.stop()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                ChatRealtimeAudit.log(
                    conversationId: conversationId,
                    generation: chatRealtimeLifecycleGeneration,
                    event: "foregroundRepair",
                    status: String(describing: realtimeConnectionStatus)
                )
                await subscribeGroupRealtime(reason: "foreground", beginNewLifecycle: true)
            }
        }
        .onChange(of: chatViewModel.currentUserAuthId) { _, newId in
            Task {
                if newId != nil {
                    await subscribeGroupRealtime(reason: "accountSwitch", beginNewLifecycle: true)
                } else {
                    await tearDownGroupRealtime(
                        statusAfter: .offline,
                        expectedGeneration: chatRealtimeLifecycleGeneration
                    )
                }
            }
        }
        .onChange(of: chatViewModel.directChatReadVisibilityVersion) { _, _ in
            chatViewModel.setActiveVisibleGroupConversationId(
                conversationId,
                reason: "became_visible"
            )
        }
    }

    private var groupComposer: some View {
        VStack(spacing: FGSpacing.sm) {
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let reportBanner {
                Text(reportBanner)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.accentGreen)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !details.isEmpty, !viewerIsActiveMember {
                Text(L10n.t("group_chat_composer_not_member", languageCode: languageCode))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ChatRealtimeConnectionStatusView(status: realtimeConnectionStatus)
                .padding(.top, showEmojiQuickTray ? 0 : FGSpacing.xs)
                .padding(.bottom, FGSpacing.xs)

            if let reply = validatedGroupReplyDraft() {
                ChatReplyComposerBanner(
                    senderDisplayName: reply.targetSenderDisplayName,
                    previewLine: reply.previewLine,
                    languageCode: languageCode,
                    colorScheme: colorScheme,
                    onCancel: { replyDraft = nil }
                )
                .padding(.bottom, FGSpacing.xs)
            }

            // Always mounted — membership/`sendingDisabled` flips only disable controls.
            ChatMessageComposer(
                draft: $draft,
                showEmojiQuickTray: $showEmojiQuickTray,
                composerFocused: $composerFocused,
                canSend: canSendDraft,
                sendingDisabled: sendingDisabled,
                isRefreshing: isRefreshingMessages,
                showsRefreshButton: true,
                refreshEnabled: !isRefreshingMessages && !isLoading,
                placeholder: L10n.t("group_chat_message_placeholder", languageCode: languageCode),
                maxBodyLength: maxBodyLength,
                colorScheme: colorScheme,
                emojis: ChatQuickReactions.emojis,
                refreshAccessibilityLabel: L10n.t("group_chat_refresh_a11y", languageCode: languageCode),
                emojiToggleAccessibilityLabel: "Toggle emoji reactions",
                sendAccessibilityLabel: L10n.t("Send", languageCode: languageCode),
                emojiReactionAccessibilityFormat: "Send %@ reaction",
                onSend: {
                    Task { await send() }
                },
                onQuickEmoji: { emoji in
                    Task { await sendQuickReaction(emoji) }
                },
                onRefresh: {
                    Task { await refreshMessages() }
                },
                onTrimDraft: {
                    if draft.count > maxBodyLength {
                        draft = String(draft.prefix(maxBodyLength))
                    }
                },
                attachmentAccessibilityLabel: L10n.t("chat_location_share_location", languageCode: languageCode),
                // Always reserve the control so membership/enable flips do not rebuild Button identity mid-navigation.
                showsAttachmentButton: true
            )
        }
        .padding(.horizontal, FGSpacing.lg)
        .padding(.top, FGSpacing.sm)
        .padding(.bottom, 0)
        .transaction { transaction in
            if isThreadOpening {
                transaction.animation = nil
            }
        }
        .onChange(of: sendingDisabled) { _, disabled in
            guard disabled else { return }
            Task { @MainActor in
                await Task.yield()
                guard sendingDisabled else { return }
                if composerFocused { composerFocused = false }
                if showEmojiQuickTray { showEmojiQuickTray = false }
            }
        }
        .chatLocationAttachment(
            context: groupLocationShareContext,
            languageCode: languageCode,
            isEnabled: viewerIsActiveMember && !sendingDisabled,
            favoriteVenues: mapViewModel.followingTabSavedVenues,
            recentSharedCoordinate: recentSharedLocationInGroupThread,
            sendStructuredBody: { body in
                await sendStructuredBody(body)
            }
        )
        .sheet(isPresented: $showPollCreateSheet) {
            PickupGamePollCreateSheet(
                languageCode: languageCode,
                onCancel: { showPollCreateSheet = false },
                onCreate: { question, options, allowMultiple, isAnonymous, autoClose in
                    await createPickupPoll(
                        question: question,
                        options: options,
                        allowMultiple: allowMultiple,
                        isAnonymous: isAnonymous,
                        autoCloseAtGameStart: autoClose
                    )
                }
            )
        }
    }

    private var groupLocationShareContext: ChatLocationShareContext? {
        guard let senderId = chatViewModel.currentUserAuthId else { return nil }
        let senderName = mapViewModel.currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let memberCount = max(1, details.count)
        return ChatLocationShareContext(
            kind: .group,
            conversationId: conversationId,
            audienceLabel: title,
            memberCount: memberCount,
            senderDisplayName: senderName.isEmpty ? "Fan" : senderName,
            senderUserId: senderId,
            pickupDestinationName: pickupContext?.locationLabel ?? pickupContext?.title,
            pickupLatitude: pickupContext?.latitude,
            pickupLongitude: pickupContext?.longitude,
            pickupGameId: effectivePickupGameId
        )
    }

    private var recentSharedLocationInGroupThread: (name: String, lat: Double, lon: Double)? {
        for message in messages.reversed() {
            if let payload = ChatLocationShareMessage.decode(from: message.body) {
                return (
                    payload.placeLabel ?? L10n.t("chat_location_shared_location_title", languageCode: languageCode),
                    payload.latitude,
                    payload.longitude
                )
            }
            if let payload = ChatOnMyWayMessage.decode(from: message.body) {
                return (payload.destinationName, payload.latitude, payload.longitude)
            }
        }
        return nil
    }

    @MainActor
    private func sendStructuredBody(_ rawBody: String) async -> String? {
        let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body.count <= maxBodyLength, !sendingDisabled else {
            return L10n.t("chat_location_unavailable", languageCode: languageCode)
        }
        isSending = true
        errorText = nil
        defer { isSending = false }
        do {
            let id = try await service.sendMessage(conversationId: conversationId, body: body)
            if !seenMessageIds.contains(id) {
                await refreshAfterGroupSend(body: body)
            } else {
                await chatViewModel.refreshInboxSummaries()
            }
            return nil
        } catch {
            AgeAccessBackendDenial.handle(error, requestUserId: nil)
            errorText = error.localizedDescription
            return error.localizedDescription
        }
    }

    @MainActor
    private func createPickupPoll(
        question: String,
        options: [String],
        allowMultiple: Bool,
        isAnonymous: Bool,
        autoCloseAtGameStart: Bool
    ) async -> String? {
        guard canCreatePickupPoll else {
            return L10n.t("pickup_poll_error_create_not_allowed", languageCode: languageCode)
        }
        if let issue = PickupGamePollValidation.validate(question: question, options: options) {
            return PickupGamePollValidation.userMessage(for: issue, languageCode: languageCode)
        }

        isSending = true
        errorText = nil
        defer { isSending = false }

        do {
            let pollId = try await pollService.createPoll(
                conversationId: conversationId,
                question: question,
                options: options,
                allowMultiple: allowMultiple,
                isAnonymous: isAnonymous,
                autoCloseAtGameStart: autoCloseAtGameStart
            )

            let senderName = mapViewModel.currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let snapshot = try? await pollService.fetchSnapshot(pollId: pollId)
            let payload = PickupGamePollPayload(
                pollId: pollId,
                question: question,
                allowMultiple: allowMultiple,
                isAnonymous: isAnonymous,
                autoCloseAtGameStart: autoCloseAtGameStart,
                closesAt: snapshot?.closesAtDate,
                createdByName: senderName.isEmpty ? nil : senderName
            )
            let body = PickupGamePollMessage.encodeBody(payload: payload)
            let messageId = try await service.sendMessage(conversationId: conversationId, body: body)
            try? await pollService.attachMessage(pollId: pollId, messageId: messageId)
            await PickupGamePollStore.shared.refresh(pollId)

            if !seenMessageIds.contains(messageId) {
                await refreshAfterGroupSend(body: body)
            } else {
                await chatViewModel.refreshInboxSummaries()
            }
            showPollCreateSheet = false
            return nil
        } catch {
            AgeAccessBackendDenial.handle(error, requestUserId: nil)
            return error.localizedDescription
        }
    }

    @MainActor
    private func sendOnMyWayArrived(_ payload: ChatOnMyWayPayload) async {
        let arrived = ChatOnMyWayPayload(
            v: 1,
            destinationName: payload.destinationName,
            latitude: payload.latitude,
            longitude: payload.longitude,
            sharedByName: payload.sharedByName,
            sharedByUserId: payload.sharedByUserId,
            departedAt: payload.departedAt,
            estimatedArrivalAt: payload.estimatedArrivalAt,
            etaMinutes: payload.etaMinutes,
            distanceMeters: payload.distanceMeters,
            transportMode: payload.transportMode,
            etaSource: payload.etaSource,
            pickupGameId: payload.pickupGameId,
            venueId: payload.venueId,
            liveSessionId: payload.liveSessionId,
            status: "arrived",
            arrivedAt: ISO8601DateFormatter.chatLocation.string(from: Date())
        )
        _ = await sendStructuredBody(ChatOnMyWayMessage.encodeBody(payload: arrived))
    }

    private func preview(for userId: UUID) -> UserPreview {
        if let cached = memberPreviews[userId] {
            return cached
        }
        if let friend = chatViewModel.friends.first(where: { $0.preview.id == userId }) {
            return friend.preview
        }
        if userId == chatViewModel.currentUserAuthId {
            return currentUserPreviewFallback()
        }
        return UserPreview(
            id: userId,
            displayName: "Fan",
            avatarURL: nil,
            avatarThumbnailURL: nil
        )
    }

    private func currentUserPreviewFallback() -> UserPreview {
        let id = chatViewModel.currentUserAuthId ?? UUID()
        let name = mapViewModel.currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return UserPreview(
            id: id,
            displayName: name.isEmpty ? L10n.t("group_chat_you", languageCode: languageCode) : name,
            avatarURL: mapViewModel.currentUserAvatarURL.isEmpty ? nil : mapViewModel.currentUserAvatarURL,
            avatarThumbnailURL: mapViewModel.currentUserAvatarThumbnailURL.isEmpty
                ? nil
                : mapViewModel.currentUserAvatarThumbnailURL
        )
    }

    @MainActor
    private func hydrateMemberPreviews(from rows: [GroupConversationDetailRow]) async {
        let ids = Array(Set(rows.map(\.member_user_id)))
        guard !ids.isEmpty else {
            memberPreviews = [:]
            return
        }

        var seeded: [UUID: UserPreview] = [:]
        for id in ids {
            seeded[id] = preview(for: id)
        }
        memberPreviews = seeded

        do {
            let fetched = try await identityService.fetchUserPreviews(for: ids)
            var merged = seeded
            for (id, preview) in fetched {
                merged[id] = preview
            }
            memberPreviews = merged
        } catch {
            // Keep seeded friends/current-user fallbacks; do not blank the header.
        }
    }

    /// Keeps message-row avatars current when a member updates their photo elsewhere in the app.
    @MainActor
    private func applyMemberAvatarChange(_ change: FanProfileAvatarChange) {
        guard let existing = memberPreviews[change.userId] else { return }
        let nextFull = change.avatarURL.isEmpty ? existing.avatarURL : change.avatarURL
        let nextThumb = change.avatarThumbnailURL ?? existing.avatarThumbnailURL
        let updated = existing.replacingAvatars(avatarURL: nextFull, avatarThumbnailURL: nextThumb)
        guard updated != existing else { return }
        memberPreviews[change.userId] = updated
    }

    /// Small circular sender avatar next to incoming group bubbles.
    private static let groupSenderAvatarSize: CGFloat = 26
    /// Fixed gutter so grouped follow-up bubbles stay aligned with the first one.
    private static let groupSenderAvatarColumnWidth: CGFloat = 32
    /// Trailing breathing room for incoming rows; keeps usable bubble width close to
    /// the pre-avatar layout instead of stacking a new column on top of the old inset.
    private static let groupIncomingTrailingInset: CGFloat = 12

    /// True for the first incoming message in a same-sender run (avatar + name row).
    /// Outgoing and system rows never show sender identity.
    private func showsSenderIdentity(at index: Int) -> Bool {
        guard messages.indices.contains(index) else { return false }
        let message = messages[index]
        guard !message.isSystemMessage else { return false }
        guard message.sender_id != chatViewModel.currentUserAuthId else { return false }
        guard index > 0 else { return true }
        let previous = messages[index - 1]
        if previous.isSystemMessage { return true }
        return previous.sender_id != message.sender_id
    }

    @ViewBuilder
    private func groupSenderAvatarColumn(
        for message: GroupMessageRow,
        showsSenderIdentity: Bool
    ) -> some View {
        if showsSenderIdentity {
            ProfileAvatarView(
                preview: preview(for: message.sender_id),
                size: Self.groupSenderAvatarSize,
                profileTapContext: "group_chat_message_avatar"
            )
            .frame(width: Self.groupSenderAvatarColumnWidth, alignment: .center)
        } else {
            Color.clear
                .frame(width: Self.groupSenderAvatarColumnWidth, height: 1)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func groupBubble(
        _ message: GroupMessageRow,
        showsSenderIdentity: Bool
    ) -> some View {
        let isMine = message.sender_id == chatViewModel.currentUserAuthId
        if message.isSystemMessage {
            let eventText = GroupSystemEventFormatting.displayText(
                for: message,
                languageCode: languageCode
            )
            let pickupId = message.system_payload?.pickup_game_id
                ?? (GroupSystemEventKind.parse(message.system_event) == .pickupGameUpdated
                    ? (pickupContext?.pickupGameId ?? details.first?.pickup_game_id)
                    : nil)
            Group {
                Text(eventText)
                    .font(FGTypography.metadata)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.vertical, FGSpacing.xs + 2)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard let pickupId else { return }
                mapViewModel.presentSharedPickupGameDetail(gameId: pickupId)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(eventText)
            .accessibilityHint(
                pickupId == nil
                    ? ""
                    : L10n.t("pickup_edit_open_game_a11y_hint", languageCode: languageCode)
            )
            .accessibilityAddTraits(pickupId == nil ? [] : .isButton)
        } else {
            switch ChatMessagePresentation.build(
                body: message.body,
                messageType: message.message_type
            ) {
            case .profileShare(let payload):
            HStack(alignment: .bottom, spacing: FGSpacing.xs + 2) {
                if isMine {
                    Spacer(minLength: 40)
                } else {
                    groupSenderAvatarColumn(for: message, showsSenderIdentity: showsSenderIdentity)
                }
                VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                    if !isMine, showsSenderIdentity {
                        Text(senderName(message.sender_id))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                    groupReplyHeader(for: message, isMine: isMine)
                    FanProfileShareChatCardView(
                        payload: payload,
                        isFromCurrentUser: isMine,
                        showFriendAvatar: false,
                        friendPreview: preview(for: message.sender_id),
                        timestamp: nil,
                        mapViewModel: mapViewModel
                    )
                }
                if !isMine { Spacer(minLength: Self.groupIncomingTrailingInset) }
            }
            case .pickupShare(let payload):
            HStack(alignment: .bottom, spacing: FGSpacing.xs + 2) {
                if isMine {
                    Spacer(minLength: 40)
                } else {
                    groupSenderAvatarColumn(for: message, showsSenderIdentity: showsSenderIdentity)
                }
                VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                    if !isMine, showsSenderIdentity {
                        Text(senderName(message.sender_id))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                    groupReplyHeader(for: message, isMine: isMine)
                    PickupGameShareChatCardView(
                        payload: payload,
                        isFromCurrentUser: isMine,
                        showFriendAvatar: false,
                        friendPreview: preview(for: message.sender_id),
                        timestamp: nil,
                        mapViewModel: mapViewModel
                    )
                }
                if !isMine { Spacer(minLength: Self.groupIncomingTrailingInset) }
            }
            case .proShare(let payload):
            HStack(alignment: .bottom, spacing: FGSpacing.xs + 2) {
                if isMine {
                    Spacer(minLength: 40)
                } else {
                    groupSenderAvatarColumn(for: message, showsSenderIdentity: showsSenderIdentity)
                }
                VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                    if !isMine, showsSenderIdentity {
                        Text(senderName(message.sender_id))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                    groupReplyHeader(for: message, isMine: isMine)
                    ProGameShareChatCardView(
                        payload: payload,
                        isFromCurrentUser: isMine,
                        showFriendAvatar: false,
                        friendPreview: preview(for: message.sender_id),
                        timestamp: nil,
                        mapViewModel: mapViewModel
                    )
                }
                if !isMine { Spacer(minLength: Self.groupIncomingTrailingInset) }
            }
            case .venueShare(let payload):
            HStack(alignment: .bottom, spacing: FGSpacing.xs + 2) {
                if isMine {
                    Spacer(minLength: 40)
                } else {
                    groupSenderAvatarColumn(for: message, showsSenderIdentity: showsSenderIdentity)
                }
                VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                    if !isMine, showsSenderIdentity {
                        Text(senderName(message.sender_id))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                    groupReplyHeader(for: message, isMine: isMine)
                    VenueShareChatCardView(
                        payload: payload,
                        isFromCurrentUser: isMine,
                        showFriendAvatar: false,
                        friendPreview: preview(for: message.sender_id),
                        timestamp: nil,
                        mapViewModel: mapViewModel
                    )
                }
                if !isMine { Spacer(minLength: Self.groupIncomingTrailingInset) }
            }
            case .locationShare(let payload):
            HStack(alignment: .bottom, spacing: FGSpacing.xs + 2) {
                if isMine {
                    Spacer(minLength: 40)
                } else {
                    groupSenderAvatarColumn(for: message, showsSenderIdentity: showsSenderIdentity)
                }
                VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                    if !isMine, showsSenderIdentity {
                        Text(senderName(message.sender_id))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                    groupReplyHeader(for: message, isMine: isMine)
                    ChatLocationShareChatCardView(
                        payload: payload,
                        isFromCurrentUser: isMine,
                        showFriendAvatar: false,
                        friendPreview: preview(for: message.sender_id),
                        timestamp: nil,
                        languageCode: languageCode
                    )
                }
                if !isMine { Spacer(minLength: Self.groupIncomingTrailingInset) }
            }
            case .liveLocation(let payload):
            HStack(alignment: .bottom, spacing: FGSpacing.xs + 2) {
                if isMine {
                    Spacer(minLength: 40)
                } else {
                    groupSenderAvatarColumn(for: message, showsSenderIdentity: showsSenderIdentity)
                }
                VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                    if !isMine, showsSenderIdentity {
                        Text(senderName(message.sender_id))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                    groupReplyHeader(for: message, isMine: isMine)
                    ChatLiveLocationShareChatCardView(
                        payload: payload,
                        isFromCurrentUser: isMine,
                        showFriendAvatar: false,
                        friendPreview: preview(for: message.sender_id),
                        timestamp: nil,
                        languageCode: languageCode,
                        audienceMemberCount: max(1, details.count),
                        expectedConversationKind: "group",
                        expectedConversationId: conversationId,
                        expectedSenderUserId: message.sender_id,
                        authoritativeDisplayName: senderName(message.sender_id),
                        onStopSharing: {
                            Task { await ChatLiveLocationManager.shared.stopLiveSession(sessionId: payload.sessionId) }
                        }
                    )
                }
                if !isMine { Spacer(minLength: Self.groupIncomingTrailingInset) }
            }
            case .onMyWay(let payload):
            HStack(alignment: .bottom, spacing: FGSpacing.xs + 2) {
                if isMine {
                    Spacer(minLength: 40)
                } else {
                    groupSenderAvatarColumn(for: message, showsSenderIdentity: showsSenderIdentity)
                }
                VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                    if !isMine, showsSenderIdentity {
                        Text(senderName(message.sender_id))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                    groupReplyHeader(for: message, isMine: isMine)
                    ChatOnMyWayChatCardView(
                        payload: payload,
                        isFromCurrentUser: isMine,
                        showFriendAvatar: false,
                        friendPreview: preview(for: message.sender_id),
                        timestamp: nil,
                        languageCode: languageCode,
                        authoritativeDisplayName: senderName(message.sender_id),
                        onImHere: {
                            Task { await sendOnMyWayArrived(payload) }
                        }
                    )
                }
                if !isMine { Spacer(minLength: Self.groupIncomingTrailingInset) }
            }
            case .poll(let payload):
            if hiddenPollIds.contains(payload.pollId)
                || PickupGamePollLocalHide.isHidden(
                    userId: chatViewModel.currentUserAuthId,
                    pollId: payload.pollId
                )
            {
                EmptyView()
            } else {
                HStack(alignment: .bottom, spacing: FGSpacing.xs + 2) {
                    if isMine {
                        Spacer(minLength: 40)
                    } else {
                        groupSenderAvatarColumn(for: message, showsSenderIdentity: showsSenderIdentity)
                    }
                    VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                        if !isMine, showsSenderIdentity {
                            Text(senderName(message.sender_id))
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                        }
                        PickupGamePollChatCardView(
                            payload: payload,
                            message: message,
                            isFromCurrentUser: isMine,
                            showFriendAvatar: false,
                            friendPreview: preview(for: message.sender_id),
                            timestamp: nil,
                            languageCode: languageCode,
                            memberPreviews: memberPreviews,
                            currentUserId: chatViewModel.currentUserAuthId,
                            isOrganizer: viewerIsPickupOrganizer,
                            onReport: {
                                if reportedMessageIds.contains(message.id) {
                                    reportBanner = L10n.t(
                                        "group_chat_report_already_submitted",
                                        languageCode: appLanguageRaw
                                    )
                                } else {
                                    reportCategory = .spam
                                    reportTarget = message
                                }
                            },
                            onHide: {
                                PickupGamePollLocalHide.hide(
                                    userId: chatViewModel.currentUserAuthId,
                                    pollId: payload.pollId
                                )
                                hiddenPollIds.insert(payload.pollId)
                            }
                        )
                        .onAppear {
                            PickupGamePollStore.shared.ensureLoaded(payload.pollId)
                        }
                    }
                    if !isMine { Spacer(minLength: Self.groupIncomingTrailingInset) }
                }
            }
            case .unavailable(let kind):
            HStack(alignment: .bottom, spacing: FGSpacing.xs + 2) {
                if isMine {
                    Spacer(minLength: 40)
                } else {
                    groupSenderAvatarColumn(for: message, showsSenderIdentity: showsSenderIdentity)
                }
                VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                    if !isMine, showsSenderIdentity {
                        Text(senderName(message.sender_id))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                    groupReplyHeader(for: message, isMine: isMine)
                    FanGeoStructuredUnavailableCard(
                        kind: kind,
                        languageCode: languageCode,
                        isFromCurrentUser: isMine
                    )
                    .onAppear {
                        kind.logDecodeFailure(category: "decodeNilOrUnsupportedVersion")
                    }
                }
                if !isMine { Spacer(minLength: Self.groupIncomingTrailingInset) }
            }
            case .text(let text):
            HStack(alignment: .bottom, spacing: FGSpacing.xs + 2) {
                if isMine {
                    Spacer(minLength: 40)
                } else {
                    groupSenderAvatarColumn(for: message, showsSenderIdentity: showsSenderIdentity)
                }
                VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                    if !isMine, showsSenderIdentity {
                        Text(senderName(message.sender_id))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                    groupReplyHeader(for: message, isMine: isMine)
                    Text(text)
                        .font(.body)
                        .foregroundStyle(isMine ? Color.white : FGColor.primaryText(colorScheme))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(isMine ? FGColor.accentGreen : FGColor.cardBackground(colorScheme))
                        }
                }
                if !isMine { Spacer(minLength: Self.groupIncomingTrailingInset) }
            }
            }
        }
    }

    @ViewBuilder
    private func groupReplyHeader(for message: GroupMessageRow, isMine: Bool) -> some View {
        if let reference = groupReplyReference(for: message) {
            ChatReplyQuoteHeader(
                reference: reference,
                languageCode: languageCode,
                colorScheme: colorScheme,
                isFromCurrentUser: isMine,
                onTap: { jumpToGroupRepliedMessage(reference.originalMessageId) }
            )
            .frame(maxWidth: 280, alignment: isMine ? .trailing : .leading)
        }
    }

    private func groupReplyReference(for message: GroupMessageRow) -> ChatReplyReference? {
        guard message.reply_to_message_id != nil else { return nil }
        return ChatReplyResolution.resolveGroup(
            replyToMessageId: message.reply_to_message_id,
            messagesById: ChatReplyResolution.messageMap(messages),
            displayNameForSender: { senderName($0) },
            languageCode: languageCode
        )
    }

    /// After send: reload latest messages (pre–Phase 1) then refresh inbox summaries.
    private func refreshAfterGroupSend(body: String) async {
        if let latest = try? await service.fetchLatestMessages(conversationId: conversationId) {
            messages = latest
            seenMessageIds = Set(latest.map(\.id))
        }
        await chatViewModel.refreshInboxSummaries()
    }

    @ViewBuilder
    private func groupMessageContextMenu(for message: GroupMessageRow) -> some View {
        let isMine = message.sender_id == chatViewModel.currentUserAuthId
        if ChatReplyPreviewFormatting.isReplyEligible(
            body: message.body,
            messageType: message.message_type,
            isDeleted: message.is_deleted,
            deletedAt: message.deleted_at
        ) {
            Button {
                beginGroupReply(to: message)
            } label: {
                Label(L10n.t("chat_reply", languageCode: languageCode), systemImage: "arrowshape.turn.up.left")
            }
        }
        if !isMine, !message.isSystemMessage {
            if reportedMessageIds.contains(message.id) {
                Label(
                    L10n.t("group_chat_report_already_submitted", languageCode: appLanguageRaw),
                    systemImage: "flag.fill"
                )
            } else {
                Button(role: .destructive) {
                    reportCategory = .spam
                    reportTarget = message
                } label: {
                    Label(
                        L10n.t("group_chat_report_message", languageCode: appLanguageRaw),
                        systemImage: "flag"
                    )
                }
            }
        }
    }

    private func beginGroupReply(to message: GroupMessageRow) {
        guard let me = chatViewModel.currentUserAuthId else { return }
        guard ChatReplyPreviewFormatting.isReplyEligible(
            body: message.body,
            messageType: message.message_type,
            isDeleted: message.is_deleted,
            deletedAt: message.deleted_at
        ) else { return }
        let name = isMineSender(message.sender_id)
            ? L10n.t("chat_preview_you_prefix", languageCode: languageCode)
            : senderName(message.sender_id)
        replyDraft = ChatReplyComposerDraft(
            conversationId: conversationId,
            accountUserId: me,
            targetMessageId: message.id,
            targetSenderId: message.sender_id,
            targetSenderDisplayName: name,
            previewLine: ChatReplyPreviewFormatting.previewLine(
                body: message.body,
                messageType: message.message_type,
                languageCode: languageCode
            )
        )
    }

    private func isMineSender(_ id: UUID) -> Bool {
        id == chatViewModel.currentUserAuthId
    }

    private func validatedGroupReplyDraft() -> ChatReplyComposerDraft? {
        guard let draft = replyDraft,
              draft.isValid(forConversation: conversationId, accountUserId: chatViewModel.currentUserAuthId)
        else {
            replyDraft = nil
            return nil
        }
        return draft
    }

    private func jumpToGroupRepliedMessage(_ messageId: UUID) {
        if messages.contains(where: { $0.id == messageId }) {
            pendingScrollToMessageId = messageId
            return
        }
        Task { @MainActor in
            var pages = 0
            while pages < ChatReplyResolution.maxOlderPagesWhenSeeking {
                if messages.contains(where: { $0.id == messageId }) {
                    pendingScrollToMessageId = messageId
                    return
                }
                guard canLoadOlder, !isLoadingOlder else { break }
                let before = messages.count
                await loadOlder()
                pages += 1
                if messages.count <= before { break }
            }
            if messages.contains(where: { $0.id == messageId }) {
                pendingScrollToMessageId = messageId
            } else {
                reportBanner = L10n.t("chat_reply_original_not_found", languageCode: languageCode)
            }
        }
    }

    private func senderName(_ id: UUID) -> String {
        preview(for: id).displayName
    }

    @MainActor
    private func load() async {
        isLoading = true
        do {
            async let detailRows = service.fetchDetails(conversationId: conversationId)
            async let messageRows = service.fetchLatestMessages(conversationId: conversationId)
            details = try await detailRows
            messages = try await messageRows
            seenMessageIds = Set(messages.map(\.id))
            canLoadOlder = messages.count >= 50
            if let first = details.first {
                title = first.title
            } else if let pickupContext {
                title = pickupContext.title
            }
            await hydrateMemberPreviews(from: details)
            try await service.markRead(conversationId: conversationId)
            await chatViewModel.refreshInboxSummaries()
        } catch {
            errorText = error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func loadOlder() async {
        guard let oldest = messages.first, !isLoadingOlder, canLoadOlder else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let older = try await service.fetchOlderMessages(
                conversationId: conversationId,
                beforeCreatedAt: oldest.created_at,
                beforeId: oldest.id
            )
            if older.isEmpty {
                canLoadOlder = false
                return
            }
            let fresh = older.filter { seenMessageIds.insert($0.id).inserted }
            messages.insert(contentsOf: fresh, at: 0)
            if !fresh.isEmpty {
            }
            if older.count < 40 {
                canLoadOlder = false
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func beginGroupRealtimeLifecycle(reason: String) -> Int {
        chatRealtimeLifecycleGeneration += 1
        let gen = chatRealtimeLifecycleGeneration
        ChatRealtimeAudit.log(
            conversationId: conversationId,
            generation: gen,
            event: "generationStart",
            status: String(describing: realtimeConnectionStatus),
            extra: "reason=\(reason)"
        )
        return gen
    }

    @MainActor
    private func setGroupRealtimeStatus(
        _ next: ChatRealtimeConnectionStatus,
        reason: String,
        generation: Int? = nil
    ) {
        let gen = generation ?? chatRealtimeLifecycleGeneration
        let old = realtimeConnectionStatus
        guard old != next else { return }
        realtimeConnectionStatus = next
        ChatRealtimeAudit.statusTransition(
            conversationId: conversationId,
            generation: gen,
            from: old,
            to: next,
            reason: reason
        )
    }

    /// If the channel is already subscribed but UI status is stale, repair without reconnecting.
    @MainActor
    private func repairGroupRealtimeStatusFromChannelHealth(reason: String) -> Bool {
        guard let channel = realtimeChannel,
              subscribedConversationId == conversationId else {
            return false
        }
        let channelStatus = String(describing: channel.status)
        ChatRealtimeAudit.log(
            conversationId: conversationId,
            generation: chatRealtimeLifecycleGeneration,
            event: "channelHealthCheck",
            status: String(describing: realtimeConnectionStatus),
            extra: "reason=\(reason) channelStatus=\(channelStatus) topic=\(channel.topic)"
        )
        guard channel.status == .subscribed else { return false }
        if realtimeConnectionStatus != .live && realtimeConnectionStatus != .connected {
            setGroupRealtimeStatus(.live, reason: "repairFromChannelHealth:\(reason)")
            groupHadSuccessfulSubscribe = true
            ChatRealtimeAudit.log(
                conversationId: conversationId,
                generation: chatRealtimeLifecycleGeneration,
                event: "subscribeResult",
                status: "live",
                extra: "result=subscribed source=channelHealthRepair topic=\(channel.topic)"
            )
        }
        return true
    }

    @MainActor
    private func tearDownGroupRealtime(
        statusAfter: ChatRealtimeConnectionStatus,
        expectedGeneration: Int? = nil
    ) async {
        let stopGen = expectedGeneration ?? chatRealtimeLifecycleGeneration
        ChatRealtimeAudit.log(
            conversationId: conversationId,
            generation: stopGen,
            event: "stopBegin",
            status: String(describing: realtimeConnectionStatus),
            extra: "currentGen=\(chatRealtimeLifecycleGeneration) next=\(String(describing: statusAfter))"
        )
        guard stopGen == chatRealtimeLifecycleGeneration else {
            ChatRealtimeAudit.log(
                conversationId: conversationId,
                generation: stopGen,
                event: "stopSkipped",
                status: String(describing: realtimeConnectionStatus),
                extra: "reason=staleGeneration currentGen=\(chatRealtimeLifecycleGeneration)"
            )
            return
        }

        groupRealtimeSubscriptionTask?.cancel()
        groupRealtimeSubscriptionTask = nil
        realtimeListenTask?.cancel()
        realtimeListenTask = nil
        let channel = realtimeChannel
        let channelGen = ownedGroupChannelGeneration

        if channelGen > stopGen {
            ChatRealtimeAudit.log(
                conversationId: conversationId,
                generation: stopGen,
                event: "teardownSkipped",
                status: String(describing: realtimeConnectionStatus),
                extra: "reason=channelOwnedByNewerGeneration ownedGen=\(channelGen)"
            )
            return
        }

        realtimeChannel = nil
        subscribedConversationId = nil
        setGroupRealtimeStatus(statusAfter, reason: "teardown", generation: stopGen)

        if let channel {
            ChatRealtimeAudit.log(
                conversationId: conversationId,
                generation: stopGen,
                event: "channelRemoved",
                extra: "topic=\(channel.topic)"
            )
            await ChatRealtimeChannelSerializer.shared.removeExclusive(
                topic: channel.topic,
                channel: channel
            ) { [service] ch in
                await service.removeRealtimeChannel(ch)
            }
        }

        ChatRealtimeAudit.log(
            conversationId: conversationId,
            generation: stopGen,
            event: "stopCompleted",
            status: String(describing: realtimeConnectionStatus)
        )
    }

    /// Postgres INSERT on `group_messages` (includes system join/leave rows). Edit/delete events are not published.
    ///
    /// Starts an owned subscription task so SwiftUI `.task` / sheet / popover cancellation cannot leave
    /// a successful channel stuck at `.connecting`.
    @MainActor
    private func subscribeGroupRealtime(reason: String, beginNewLifecycle: Bool = false) async {
        groupRealtimeStopTask?.cancel()

        if !beginNewLifecycle {
            if chatRealtimeLifecycleGeneration == 0 {
                ChatRealtimeAudit.log(
                    conversationId: conversationId,
                    generation: 0,
                    event: "ensureSkipped",
                    status: String(describing: realtimeConnectionStatus),
                    extra: "reason=\(reason) detail=lifecycleNotStarted"
                )
                return
            }
            if repairGroupRealtimeStatusFromChannelHealth(reason: reason) {
                if realtimeListenTask != nil || groupRealtimeSubscriptionTask != nil {
                    ChatRealtimeAudit.log(
                        conversationId: conversationId,
                        generation: chatRealtimeLifecycleGeneration,
                        event: "ensureHealthy",
                        status: String(describing: realtimeConnectionStatus),
                        extra: "reason=\(reason)"
                    )
                    return
                }
                ChatRealtimeAudit.log(
                    conversationId: conversationId,
                    generation: chatRealtimeLifecycleGeneration,
                    event: "listenMissingRepair",
                    status: String(describing: realtimeConnectionStatus),
                    extra: "reason=\(reason)"
                )
                // Fall through: rebuild under same generation.
            } else if groupRealtimeSubscriptionTask != nil {
                ChatRealtimeAudit.log(
                    conversationId: conversationId,
                    generation: chatRealtimeLifecycleGeneration,
                    event: "ensureInFlight",
                    status: String(describing: realtimeConnectionStatus),
                    extra: "reason=\(reason)"
                )
                return
            } else if realtimeChannel != nil,
                      subscribedConversationId == conversationId,
                      realtimeConnectionStatus == .live || realtimeConnectionStatus == .connected {
                return
            }
        }

        let gen: Int
        if beginNewLifecycle {
            let previousGen = chatRealtimeLifecycleGeneration
            groupRealtimeSubscriptionTask?.cancel()
            groupRealtimeSubscriptionTask = nil
            if realtimeChannel != nil || realtimeListenTask != nil {
                await tearDownGroupRealtime(statusAfter: .connecting, expectedGeneration: previousGen)
            }
            gen = beginGroupRealtimeLifecycle(reason: reason)
            setGroupRealtimeStatus(.connecting, reason: "lifecycleStart:\(reason)", generation: gen)
        } else {
            gen = chatRealtimeLifecycleGeneration
            groupRealtimeSubscriptionTask?.cancel()
            groupRealtimeSubscriptionTask = nil
            if realtimeChannel != nil {
                await tearDownGroupRealtime(statusAfter: .connecting, expectedGeneration: gen)
            } else {
                setGroupRealtimeStatus(.connecting, reason: "ensureReconnect:\(reason)", generation: gen)
            }
        }

        guard gen == chatRealtimeLifecycleGeneration else { return }

        let topic = "group-thread-\(conversationId.uuidString.lowercased())"
        ChatRealtimeAudit.log(
            conversationId: conversationId,
            generation: gen,
            event: "ensure",
            status: String(describing: realtimeConnectionStatus),
            extra: "reason=\(reason) beginNewLifecycle=\(beginNewLifecycle) topic=\(topic)"
        )

        groupRealtimeSubscriptionTask = Task { @MainActor in
            await self.runGroupRealtimeSubscribeLoop(generation: gen, reason: reason, topic: topic)
            if self.chatRealtimeLifecycleGeneration == gen {
                self.groupRealtimeSubscriptionTask = nil
            }
        }
    }

    @MainActor
    private func runGroupRealtimeSubscribeLoop(generation gen: Int, reason: String, topic: String) async {
        let delaysNs: [UInt64] = [0, 1_000_000_000, 2_000_000_000, 4_000_000_000]
        var attempt = 0
        while !Task.isCancelled {
            guard gen == chatRealtimeLifecycleGeneration else {
                ChatRealtimeAudit.log(
                    conversationId: conversationId,
                    generation: gen,
                    event: "callbackIgnored",
                    status: String(describing: realtimeConnectionStatus),
                    extra: "reason=staleGeneration source=groupSubscribeLoop"
                )
                return
            }

            let nextStatus: ChatRealtimeConnectionStatus =
                (attempt == 0 && !groupHadSuccessfulSubscribe) ? .connecting : .reconnecting
            setGroupRealtimeStatus(nextStatus, reason: attempt == 0 ? "subscribeBegin" : "retry", generation: gen)
            ChatRealtimeAudit.log(
                conversationId: conversationId,
                generation: gen,
                event: attempt == 0 ? "subscribeBegin" : "retry",
                status: String(describing: realtimeConnectionStatus),
                extra: "attempt=\(attempt + 1) topic=\(topic) openReason=\(reason)"
            )

            await ChatRealtimeChannelSerializer.shared.waitForTopicIdle(topic)
            guard gen == chatRealtimeLifecycleGeneration, !Task.isCancelled else { return }

            let (channel, stream) = service.groupMessagesInsertChannel(conversationId: conversationId)
            realtimeChannel = channel
            ownedGroupChannelGeneration = gen
            subscribedConversationId = conversationId
            ChatRealtimeAudit.log(
                conversationId: conversationId,
                generation: gen,
                event: "channelCreated",
                extra: "topic=\(channel.topic) channelStatus=\(String(describing: channel.status))"
            )

            do {
                try await channel.subscribeWithError()
                let stillCurrent = gen == chatRealtimeLifecycleGeneration
                    && subscribedConversationId == conversationId
                let channelSubscribed = channel.status == .subscribed

                if !stillCurrent {
                    ChatRealtimeAudit.log(
                        conversationId: conversationId,
                        generation: gen,
                        event: "callbackIgnored",
                        status: String(describing: realtimeConnectionStatus),
                        extra: "reason=staleGeneration source=subscribeResult channelStatus=\(String(describing: channel.status))"
                    )
                    await ChatRealtimeChannelSerializer.shared.removeExclusive(
                        topic: channel.topic,
                        channel: channel
                    ) { [service] ch in
                        await service.removeRealtimeChannel(ch)
                    }
                    if gen == chatRealtimeLifecycleGeneration {
                        realtimeChannel = nil
                        subscribedConversationId = nil
                    }
                    return
                }

                // Prefer authoritative channel health over Task.isCancelled (parent lifecycle cancel).
                if channelSubscribed || stillCurrent {
                    groupHadSuccessfulSubscribe = true
                    setGroupRealtimeStatus(.live, reason: "subscribeResult:subscribed", generation: gen)
                    ChatRealtimeAudit.log(
                        conversationId: conversationId,
                        generation: gen,
                        event: "subscribeResult",
                        status: "live",
                        extra: "result=subscribed topic=\(channel.topic) channelStatus=\(String(describing: channel.status))"
                    )
                    realtimeListenTask?.cancel()
                    realtimeListenTask = Task { @MainActor in
                        ChatRealtimeAudit.log(
                            conversationId: conversationId,
                            generation: gen,
                            event: "listenStart",
                            status: String(describing: realtimeConnectionStatus),
                            extra: "topic=\(channel.topic)"
                        )
                        for await action in stream {
                            if Task.isCancelled { break }
                            guard gen == chatRealtimeLifecycleGeneration else { break }
                            guard subscribedConversationId == conversationId else { break }
                            guard let row = try? action.decodeRecord(as: GroupMessageRow.self, decoder: JSONDecoder()) else {
                                continue
                            }
                            if row.message_type != "system",
                               chatViewModel.isEitherDirectionBlocked(with: row.sender_id) {
                                continue
                            }
                            guard seenMessageIds.insert(row.id).inserted else { continue }
                            messages.append(row)
                            try? await service.markRead(conversationId: conversationId)
                            await chatViewModel.refreshInboxSummaries()
                        }
                        ChatRealtimeAudit.log(
                            conversationId: conversationId,
                            generation: gen,
                            event: "listenEnd",
                            status: String(describing: realtimeConnectionStatus),
                            extra: "cancelled=\(Task.isCancelled)"
                        )
                        guard gen == chatRealtimeLifecycleGeneration else {
                            ChatRealtimeAudit.log(
                                conversationId: conversationId,
                                generation: gen,
                                event: "callbackIgnored",
                                status: String(describing: realtimeConnectionStatus),
                                extra: "reason=staleGeneration source=groupListenEnd"
                            )
                            return
                        }
                        if !Task.isCancelled, subscribedConversationId == conversationId {
                            setGroupRealtimeStatus(.reconnecting, reason: "streamEnded", generation: gen)
                            ChatRealtimeAudit.log(
                                conversationId: conversationId,
                                generation: gen,
                                event: "streamEnded",
                                status: "reconnecting",
                                extra: "autoResubscribe=true"
                            )
                            await subscribeGroupRealtime(reason: "listenEnded", beginNewLifecycle: true)
                        }
                    }
                    return
                }

                await ChatRealtimeChannelSerializer.shared.removeExclusive(
                    topic: channel.topic,
                    channel: channel
                ) { [service] ch in
                    await service.removeRealtimeChannel(ch)
                }
                if gen == chatRealtimeLifecycleGeneration {
                    realtimeChannel = nil
                    subscribedConversationId = nil
                }
                return
            } catch is CancellationError {
                ChatRealtimeAudit.log(
                    conversationId: conversationId,
                    generation: gen,
                    event: "subscribeCancelled",
                    status: String(describing: realtimeConnectionStatus),
                    extra: "topic=\(channel.topic) channelStatus=\(String(describing: channel.status))"
                )
                // Intentional teardown cancels this owned task — do not resurrect `.live`.
                if gen == chatRealtimeLifecycleGeneration {
                    realtimeChannel = nil
                    subscribedConversationId = nil
                }
                await ChatRealtimeChannelSerializer.shared.removeExclusive(
                    topic: channel.topic,
                    channel: channel
                ) { [service] ch in
                    await service.removeRealtimeChannel(ch)
                }
                return
            } catch {
                if gen == chatRealtimeLifecycleGeneration {
                    realtimeChannel = nil
                    subscribedConversationId = nil
                }
                await ChatRealtimeChannelSerializer.shared.removeExclusive(
                    topic: channel.topic,
                    channel: channel
                ) { [service] ch in
                    await service.removeRealtimeChannel(ch)
                }
                attempt += 1
                ChatRealtimeAudit.log(
                    conversationId: conversationId,
                    generation: gen,
                    event: "subscribeResult",
                    status: String(describing: realtimeConnectionStatus),
                    extra: "result=error attempt=\(attempt) error=\(error.localizedDescription)"
                )
                if attempt >= delaysNs.count {
                    if gen == chatRealtimeLifecycleGeneration {
                        setGroupRealtimeStatus(
                            groupHadSuccessfulSubscribe ? .reconnecting : .offline,
                            reason: "subscribeExhausted",
                            generation: gen
                        )
                    }
                    return
                }
                let delay = delaysNs[attempt]
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }
        ChatRealtimeAudit.log(
            conversationId: conversationId,
            generation: gen,
            event: "subscribeLoopCancelled",
            status: String(describing: realtimeConnectionStatus),
            extra: "topic=\(topic)"
        )
    }

    @MainActor
    private func send() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body.count <= maxBodyLength, !sendingDisabled else { return }
        let activeReply = validatedGroupReplyDraft()
        isSending = true
        errorText = nil
        do {
            _ = try await service.sendMessage(
                conversationId: conversationId,
                body: body,
                replyToMessageId: activeReply?.targetMessageId
            )
            draft = ""
            replyDraft = nil
            showEmojiQuickTray = false
            await refreshAfterGroupSend(body: body)
        } catch {
            AgeAccessBackendDenial.handle(error, requestUserId: nil)
            errorText = error.localizedDescription
        }
        isSending = false
    }

    @MainActor
    private func sendQuickReaction(_ raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxBodyLength, !sendingDisabled else { return }
        isSending = true
        errorText = nil
        do {
            _ = try await service.sendMessage(conversationId: conversationId, body: trimmed)
            showEmojiQuickTray = false
            await refreshAfterGroupSend(body: trimmed)
        } catch {
            AgeAccessBackendDenial.handle(error, requestUserId: nil)
            errorText = error.localizedDescription
        }
        isSending = false
    }

    @MainActor
    private func refreshMessages() async {
        guard !isRefreshingMessages else { return }
        isRefreshingMessages = true
        defer { isRefreshingMessages = false }
        let wasLive = realtimeConnectionStatus == .live || realtimeConnectionStatus == .connected
        _ = repairGroupRealtimeStatusFromChannelHealth(reason: "manualRefreshPrecheck")
        let channelHealthy = realtimeChannel?.status == .subscribed
            && subscribedConversationId == conversationId
        let needsRepair = realtimeChannel == nil
            || subscribedConversationId != conversationId
            || !(realtimeConnectionStatus == .live || realtimeConnectionStatus == .connected)
            || !channelHealthy
        ChatRealtimeAudit.log(
            conversationId: conversationId,
            generation: chatRealtimeLifecycleGeneration,
            event: "manualRefresh",
            status: String(describing: realtimeConnectionStatus),
            extra: "needsRepair=\(needsRepair) channelHealthy=\(channelHealthy)"
        )
        do {
            let latest = try await service.fetchLatestMessages(conversationId: conversationId)
            messages = latest
            seenMessageIds = Set(latest.map(\.id))
            try? await service.markRead(conversationId: conversationId)
            await chatViewModel.refreshInboxSummaries()
            if wasLive, realtimeConnectionStatus == .live || realtimeConnectionStatus == .connected {
                // Keep healthy live status after REST merge.
            }
            if needsRepair {
                ChatRealtimeAudit.log(
                    conversationId: conversationId,
                    generation: chatRealtimeLifecycleGeneration,
                    event: "refreshRepair",
                    status: String(describing: realtimeConnectionStatus)
                )
                await subscribeGroupRealtime(reason: "manual_refresh_repair", beginNewLifecycle: true)
            }
            ChatRealtimeAudit.log(
                conversationId: conversationId,
                generation: chatRealtimeLifecycleGeneration,
                event: "manualRefreshFinished",
                status: String(describing: realtimeConnectionStatus),
                extra: "repaired=\(needsRepair)"
            )
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func submitReport(_ message: GroupMessageRow) async {
        guard !isSubmittingReport else { return }
        if reportedMessageIds.contains(message.id) {
            reportTarget = nil
            reportBanner = L10n.t("group_chat_report_already_submitted", languageCode: appLanguageRaw)
            return
        }
        isSubmittingReport = true
        defer { isSubmittingReport = false }
        do {
            try await service.reportMessage(
                messageId: message.id,
                category: reportCategory.rawValue,
                details: nil
            )
            reportedMessageIds.insert(message.id)
            reportTarget = nil
            reportBanner = L10n.t("group_chat_report_submitted", languageCode: appLanguageRaw)
        } catch {
            errorText = ModerationService.userFacingReportSubmitError(error)
            reportTarget = nil
        }
    }
}

// MARK: - Group info / admin

struct GroupChatInfoView: View {
    let conversationId: UUID
    let details: [GroupConversationDetailRow]
    let memberPreviews: [UUID: UserPreview]
    @ObservedObject var chatViewModel: ChatViewModel
    @EnvironmentObject private var mapViewModel: MapViewModel
    var isPickupGameChat: Bool = false
    var pickupContext: PickupGameChatContext? = nil
    var pickupGameId: UUID? = nil
    var pollCreatePermission: PickupPollCreatePermission = .organizerOnly
    var canEditPollPermission: Bool = false
    var isApprovedPickupParticipant: Bool = false
    var activePollMessageId: UUID? = nil
    var onCreatePoll: (() -> Void)? = nil
    var onChangePollPermission: ((PickupPollCreatePermission) async -> String?)? = nil
    var onViewActivePoll: ((UUID) -> Void)? = nil
    /// Dismiss Group Info first, then open Discover + existing pickup detail (owned by caller).
    var onViewPickupGame: ((UUID) -> Void)? = nil
    var onLeft: () -> Void
    var onDetailsChanged: (([GroupConversationDetailRow], [UUID: UserPreview]) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var localDetails: [GroupConversationDetailRow] = []
    @State private var localPreviews: [UUID: UserPreview] = [:]
    @State private var errorText: String?
    @State private var inviteConfirmationText: String?
    @State private var isMuted = false
    /// Suppresses mute RPC while applying authoritative server/cached state into the toggle.
    @State private var isHydratingMuteState = true
    @State private var isApplyingMuteChange = false
    @State private var showAddMembers = false
    @State private var pendingInvites: [GroupConversationPendingInviteRow] = []
    @State private var pendingInvitePreviews: [UUID: UserPreview] = [:]
    @State private var showReportGroup = false
    @State private var reportCategory: GroupConversationReportCategory?
    @State private var reportDetails = ""
    @State private var isSubmittingReport = false
    @State private var reportSheetError: String?
    @State private var showReportSuccessAlert = false
    @State private var hasReportedThisGroupSession = false
    @State private var memberReportTarget: GroupMemberReportTarget?
    @State private var reportedMemberIdsThisSession: Set<UUID> = []
    @State private var localPollCreatePermission: PickupPollCreatePermission = .organizerOnly
    @State private var isUpdatingPollPermission = false
    @State private var showPollPermissionPicker = false
    @State private var pickupSummaryRow: PickupGameRow?
    @State private var pickupSummaryLoadCompleted = false
    @State private var pickupSummaryUnavailable = false

    private let service = GroupChatService()
    private let identityService = SocialIdentityService()
    private static let reportDetailsMaxCharacters = 1000

    private struct GroupMemberReportTarget: Identifiable, Equatable {
        let id: UUID
        let displayName: String
    }

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var effectiveIsPickupGameChat: Bool {
        isPickupGameChat || localDetails.first?.isPickupGameChat == true || details.first?.isPickupGameChat == true
    }

    private var title: String {
        localDetails.first?.title ?? L10n.t("group_chat_default_title", languageCode: languageCode)
    }

    private var viewerIsAdmin: Bool {
        localDetails.first?.viewer_is_admin == true
    }

    /// True only while the viewer still appears in active membership details.
    private var viewerIsActiveMember: Bool {
        guard let me = chatViewModel.currentUserAuthId else { return false }
        return localDetails.contains(where: { $0.member_user_id == me })
    }

    private var memberIds: Set<UUID> {
        Set(localDetails.map(\.member_user_id))
    }

    private var showsPickupPollsSection: Bool {
        effectiveIsPickupGameChat && pickupGameId != nil && viewerIsActiveMember
    }

    private var showsPickupGameSummarySection: Bool {
        effectiveIsPickupGameChat && pickupGameId != nil
    }

    private var effectiveCanCreatePoll: Bool {
        PickupGamePollAccess.canCreate(
            isOrganizer: canEditPollPermission,
            permission: localPollCreatePermission,
            isApprovedParticipant: isApprovedPickupParticipant
        )
    }

    private var createPollDisabledReason: String? {
        guard showsPickupPollsSection, !effectiveCanCreatePoll else { return nil }
        guard isApprovedPickupParticipant, !canEditPollPermission else { return nil }
        if localPollCreatePermission == .organizerOnly {
            return L10n.t("pickup_poll_create_organizer_only_hint", languageCode: languageCode)
        }
        return nil
    }

    private var showsDisabledCreatePollRow: Bool {
        createPollDisabledReason != nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(title)
                        .font(.headline)
                    if effectiveIsPickupGameChat {
                        Text(L10n.t("group_info_pickup_private_chat_caption", languageCode: languageCode))
                            .font(.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                        Text(L10n.t("group_info_pickup_membership_caption", languageCode: languageCode))
                            .font(.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                }

                if showsPickupGameSummarySection {
                    Section {
                        GroupInfoPickupGameSummaryCard(
                            gameId: pickupGameId,
                            row: pickupSummaryRow,
                            fallbackContext: pickupContext,
                            loadCompleted: pickupSummaryLoadCompleted,
                            isUnavailable: pickupSummaryUnavailable || GroupInfoPickupGameSummaryCard.isArchivedOrDeleted(pickupSummaryRow),
                            mapViewModel: mapViewModel,
                            languageCode: languageCode,
                            onViewPickupGame: { id in
                                onViewPickupGame?(id)
                            }
                        )
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        .listRowBackground(Color.clear)
                    }
                }

                Section(L10n.t("group_chat_members_section", languageCode: languageCode)) {
                    ForEach(localDetails, id: \.member_user_id) { member in
                        groupMemberRow(member)
                    }

                    if viewerIsAdmin, !effectiveIsPickupGameChat, memberIds.count + pendingInvites.count < 25 {
                        Button {
                            showAddMembers = true
                        } label: {
                            Label(
                                L10n.t("group_chat_invite_members", languageCode: languageCode),
                                systemImage: "person.badge.plus"
                            )
                        }
                    }
                }

                if showsPickupPollsSection {
                    Section {
                        if effectiveCanCreatePoll {
                            Button {
                                onCreatePoll?()
                            } label: {
                                Label {
                                    Text(L10n.t("pickup_poll_create_row", languageCode: languageCode))
                                        .foregroundStyle(FGColor.primaryText(colorScheme))
                                } icon: {
                                    Image(systemName: "chart.bar.xaxis")
                                        .foregroundStyle(FGColor.accentGreen)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.t("pickup_poll_create_row", languageCode: languageCode))
                            .accessibilityHint(L10n.t("pickup_poll_create_row_a11y_hint", languageCode: languageCode))
                        } else if showsDisabledCreatePollRow, let reason = createPollDisabledReason {
                            HStack(alignment: .center, spacing: 12) {
                                Image(systemName: "chart.bar.xaxis")
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L10n.t("pickup_poll_create_row", languageCode: languageCode))
                                        .font(.body)
                                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                                    Text(reason)
                                        .font(.caption)
                                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(minHeight: 44)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(L10n.t("pickup_poll_create_row", languageCode: languageCode))
                            .accessibilityValue(reason)
                            .accessibilityHint(reason)
                        }

                        if canEditPollPermission {
                            Button {
                                showPollPermissionPicker = true
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "person.badge.shield.checkmark")
                                        .foregroundStyle(FGColor.accentGreen)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(L10n.t("pickup_poll_permissions_who_can_create", languageCode: languageCode))
                                            .font(.body)
                                            .foregroundStyle(FGColor.primaryText(colorScheme))
                                        Text(localPollCreatePermission.title(languageCode: languageCode))
                                            .font(.caption)
                                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                                    }
                                    Spacer(minLength: 8)
                                    if isUpdatingPollPermission {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                                            .accessibilityHidden(true)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isUpdatingPollPermission)
                            .accessibilityLabel(L10n.t("pickup_poll_permissions_who_can_create", languageCode: languageCode))
                            .accessibilityValue(localPollCreatePermission.title(languageCode: languageCode))
                            .accessibilityHint(L10n.t("pickup_poll_permission_edit_a11y_hint", languageCode: languageCode))
                        } else {
                            HStack(spacing: 12) {
                                Image(systemName: "person.badge.shield.checkmark")
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L10n.t("pickup_poll_permissions_who_can_create", languageCode: languageCode))
                                        .font(.body)
                                        .foregroundStyle(FGColor.primaryText(colorScheme))
                                    Text(localPollCreatePermission.title(languageCode: languageCode))
                                        .font(.caption)
                                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(minHeight: 44)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(L10n.t("pickup_poll_permissions_who_can_create", languageCode: languageCode))
                            .accessibilityValue(localPollCreatePermission.title(languageCode: languageCode))
                        }

                        if let activePollMessageId {
                            Button {
                                onViewActivePoll?(activePollMessageId)
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(L10n.t("pickup_poll_active_row", languageCode: languageCode))
                                            .foregroundStyle(FGColor.primaryText(colorScheme))
                                        Text(L10n.t("pickup_poll_view_active", languageCode: languageCode))
                                            .font(.caption)
                                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                                    }
                                } icon: {
                                    Image(systemName: "chart.bar.fill")
                                        .foregroundStyle(FGColor.accentGreen)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.t("pickup_poll_active_row", languageCode: languageCode))
                            .accessibilityHint(L10n.t("pickup_poll_view_active", languageCode: languageCode))
                        }
                    } header: {
                        Text(L10n.t("pickup_polls_section", languageCode: languageCode))
                    }
                }

                if viewerIsAdmin, !effectiveIsPickupGameChat, !pendingInvites.isEmpty {
                    Section(L10n.t("group_chat_pending_invitations_section", languageCode: languageCode)) {
                        ForEach(pendingInvites) { invite in
                            HStack(spacing: 12) {
                                ProfileAvatarView(
                                    preview: pendingInvitePreviews[invite.invitee_user_id]
                                        ?? UserPreview(id: invite.invitee_user_id, displayName: "Fan", avatarURL: nil, avatarThumbnailURL: nil),
                                    size: 36
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(
                                        pendingInvitePreviews[invite.invitee_user_id]?.displayName
                                            ?? L10n.t("group_chat_system_member_fallback", languageCode: languageCode)
                                    )
                                    .font(.body.weight(.medium))
                                    Text(L10n.t("group_chat_invitation_pending_status", languageCode: languageCode))
                                        .font(.caption)
                                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                                }
                                Spacer()
                                Button(L10n.t("Cancel", languageCode: languageCode)) {
                                    Task { await cancelPendingInvite(invite.invitation_id) }
                                }
                                .font(.caption.weight(.semibold))
                            }
                        }
                    }
                }

                if let inviteConfirmationText {
                    Section {
                        Text(inviteConfirmationText)
                            .font(.caption)
                            .foregroundStyle(FGColor.accentGreen)
                    }
                }

                Section {
                    Toggle(
                        L10n.t("group_chat_mute", languageCode: languageCode),
                        isOn: Binding(
                            get: { isMuted },
                            set: { newValue in
                                guard newValue != isMuted else { return }
                                guard !isHydratingMuteState, !isApplyingMuteChange else { return }
                                Task { await commitMuteChange(to: newValue) }
                            }
                        )
                    )
                    .disabled(isHydratingMuteState || isApplyingMuteChange)

                    if viewerIsActiveMember {
                        Button {
                            resetReportSheetState()
                            showReportGroup = true
                        } label: {
                            Label(
                                L10n.t("group_chat_report_group", languageCode: languageCode),
                                systemImage: "flag"
                            )
                        }
                        .accessibilityLabel(
                            L10n.t("group_chat_report_group_a11y", languageCode: languageCode)
                        )
                        .accessibilityHint(
                            L10n.t("group_chat_report_group_a11y_hint", languageCode: languageCode)
                        )
                    }

                    if !effectiveIsPickupGameChat {
                        Button(role: .destructive) {
                            Task { await leave() }
                        } label: {
                            Text(L10n.t("group_chat_leave", languageCode: languageCode))
                        }
                        .accessibilityLabel(
                            L10n.t("group_chat_leave", languageCode: languageCode)
                        )
                    } else {
                        Text("To leave this chat, withdraw from the pickup game.")
                            .font(.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.t("group_chat_info_title", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("done", languageCode: languageCode)) { dismiss() }
                }
            }
            .sheet(isPresented: $showAddMembers) {
                GroupChatAddMembersSheet(
                    chatViewModel: chatViewModel,
                    existingMemberIds: memberIds,
                    pendingInviteeIds: Set(pendingInvites.map(\.invitee_user_id)),
                    onAdd: { ids in
                        Task { await add(ids) }
                    }
                )
                .environmentObject(mapViewModel)
            }
            .sheet(isPresented: $showReportGroup) {
                groupConversationReportSheet
            }
            .sheet(item: $memberReportTarget) { target in
                FanProfileUserReportSheet(
                    reportedUserId: target.id,
                    onDismiss: { memberReportTarget = nil },
                    onSubmitted: {
                        reportedMemberIdsThisSession.insert(target.id)
                        memberReportTarget = nil
                        mapViewModel.showSocialActionToast(
                            L10n.t("group_chat_user_reported", languageCode: languageCode),
                            isError: false
                        )
                    }
                )
            }
            .alert(
                L10n.t("group_chat_report_group_success_title", languageCode: languageCode),
                isPresented: $showReportSuccessAlert
            ) {
                if !effectiveIsPickupGameChat {
                    Button(L10n.t("group_chat_leave", languageCode: languageCode), role: .destructive) {
                        Task { await leave() }
                    }
                }
                Button(L10n.t("done", languageCode: languageCode), role: .cancel) {}
            } message: {
                Text(L10n.t("group_chat_report_group_success_body", languageCode: languageCode))
            }
            .onAppear {
                // Seed from parent cache first (patched after successful mute) while fetch runs.
                isHydratingMuteState = true
                localDetails = details
                localPreviews = memberPreviews
                isMuted = details.first?.viewer_is_muted == true
                localPollCreatePermission = pollCreatePermission
            }
            .onChange(of: pollCreatePermission) { _, newValue in
                localPollCreatePermission = newValue
            }
            .confirmationDialog(
                L10n.t("pickup_poll_permissions_who_can_create", languageCode: languageCode),
                isPresented: $showPollPermissionPicker,
                titleVisibility: .visible
            ) {
                ForEach(PickupPollCreatePermission.allCases) { option in
                    Button(option.title(languageCode: languageCode)) {
                        Task { await commitPollCreatePermission(option) }
                    }
                }
                Button(L10n.t("Cancel", languageCode: languageCode), role: .cancel) {}
            }
            .task(id: conversationId) {
                await hydrateAuthoritativeMuteState()
                await refreshPendingInvitesIfAdmin()
            }
            .task(id: pickupGameId) {
                await loadPickupGameSummaryIfNeeded()
            }
        }
    }

    @MainActor
    private func loadPickupGameSummaryIfNeeded() async {
        guard showsPickupGameSummarySection, let id = pickupGameId else {
            pickupSummaryRow = nil
            pickupSummaryLoadCompleted = true
            pickupSummaryUnavailable = false
            return
        }
        pickupSummaryLoadCompleted = false
        pickupSummaryUnavailable = false
        if let cached = mapViewModel.resolvedPickupGameRow(for: id) {
            pickupSummaryRow = cached
            pickupSummaryLoadCompleted = true
            pickupSummaryUnavailable = GroupInfoPickupGameSummaryCard.isArchivedOrDeleted(cached)
            await mapViewModel.loadPickupCreatorDisplayNameIfNeeded(creatorUserId: cached.creator_user_id)
            return
        }
        let row = await mapViewModel.loadPickupGameRowForDetailIfNeeded(id: id)
        guard !Task.isCancelled, pickupGameId == id else { return }
        if let row {
            pickupSummaryRow = row
            pickupSummaryUnavailable = GroupInfoPickupGameSummaryCard.isArchivedOrDeleted(row)
            await mapViewModel.loadPickupCreatorDisplayNameIfNeeded(creatorUserId: row.creator_user_id)
        } else {
            pickupSummaryRow = nil
            pickupSummaryUnavailable = true
        }
        pickupSummaryLoadCompleted = true
    }

    @MainActor
    private func commitPollCreatePermission(_ permission: PickupPollCreatePermission) async {
        guard canEditPollPermission, permission != localPollCreatePermission else { return }
        guard let onChangePollPermission else { return }
        isUpdatingPollPermission = true
        errorText = nil
        defer { isUpdatingPollPermission = false }
        let previous = localPollCreatePermission
        localPollCreatePermission = permission
        if let err = await onChangePollPermission(permission) {
            localPollCreatePermission = previous
            errorText = err
        }
    }

    /// Loads persisted mute from the server (or falls back to passed-in details) without firing a mute RPC.
    @MainActor
    private func hydrateAuthoritativeMuteState() async {
        isHydratingMuteState = true
        defer { isHydratingMuteState = false }

        let fallbackMuted = (localDetails.first ?? details.first)?.viewer_is_muted == true
        do {
            let fresh = try await service.fetchDetails(conversationId: conversationId)
            if !fresh.isEmpty {
                localDetails = fresh
                isMuted = fresh.first?.viewer_is_muted == true
                onDetailsChanged?(localDetails, localPreviews)
                chatViewModel.patchGroupInboxMuted(conversationId: conversationId, isMuted: isMuted)
                return
            }
        } catch {
            // Keep UI usable offline / on transient errors using the best local snapshot.
        }
        isMuted = fallbackMuted
    }

    @MainActor
    private func commitMuteChange(to muted: Bool) async {
        let previous = isMuted
        isApplyingMuteChange = true
        isMuted = muted
        errorText = nil
        defer { isApplyingMuteChange = false }

        do {
            try await service.setMuted(conversationId: conversationId, muted: muted)
            localDetails = localDetails.map { $0.withViewerMuted(muted) }
            onDetailsChanged?(localDetails, localPreviews)
            chatViewModel.patchGroupInboxMuted(conversationId: conversationId, isMuted: muted)
        } catch {
            isMuted = previous
            errorText = error.localizedDescription
        }
    }

    private var groupConversationReportSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(
                        L10n.t("group_chat_report_group_why", languageCode: languageCode),
                        selection: $reportCategory
                    ) {
                        Text(L10n.t("group_chat_report_group_select_category", languageCode: languageCode))
                            .tag(Optional<GroupConversationReportCategory>.none)
                        ForEach(GroupConversationReportCategory.allCases) { category in
                            Text(category.localizedTitle(languageCode: languageCode))
                                .tag(Optional(category))
                                .accessibilityLabel(category.localizedTitle(languageCode: languageCode))
                        }
                    }
                    .disabled(isSubmittingReport)
                } footer: {
                    if reportCategory == nil {
                        Text(L10n.t("group_chat_report_group_choose_category", languageCode: languageCode))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField(
                        L10n.t("group_chat_report_group_details", languageCode: languageCode),
                        text: $reportDetails,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                    .disabled(isSubmittingReport)
                    .onChange(of: reportDetails) { _, newValue in
                        if newValue.count > Self.reportDetailsMaxCharacters {
                            reportDetails = String(newValue.prefix(Self.reportDetailsMaxCharacters))
                        }
                    }
                }

                if isSubmittingReport {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(L10n.t("group_chat_report_group_reporting", languageCode: languageCode))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let reportSheetError, !reportSheetError.isEmpty {
                    Section {
                        Text(reportSheetError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .navigationTitle(L10n.t("group_chat_report_group", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel", languageCode: languageCode)) {
                        showReportGroup = false
                    }
                    .disabled(isSubmittingReport)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("group_chat_report_group_submit", languageCode: languageCode)) {
                        Task { await submitGroupReport() }
                    }
                    .disabled(isSubmittingReport || reportCategory == nil)
                    .accessibilityLabel(
                        L10n.t("group_chat_report_group_submit_a11y", languageCode: languageCode)
                    )
                }
            }
            .interactiveDismissDisabled(isSubmittingReport)
        }
        .presentationDetents([.medium, .large])
    }

    private func resetReportSheetState() {
        reportCategory = nil
        reportDetails = ""
        reportSheetError = nil
        isSubmittingReport = false
    }

    @MainActor
    private func submitGroupReport() async {
        guard !isSubmittingReport else { return }
        guard viewerIsActiveMember else {
            reportSheetError = L10n.t("group_chat_report_group_not_member", languageCode: languageCode)
            return
        }
        guard let category = reportCategory else {
            reportSheetError = L10n.t("group_chat_report_group_choose_category", languageCode: languageCode)
            return
        }
        if hasReportedThisGroupSession {
            reportSheetError = L10n.t("group_chat_report_group_already_reported", languageCode: languageCode)
            return
        }

        isSubmittingReport = true
        reportSheetError = nil
        defer { isSubmittingReport = false }

        let trimmedDetails = reportDetails.trimmingCharacters(in: .whitespacesAndNewlines)
        let detailsPayload = trimmedDetails.isEmpty ? nil : trimmedDetails

        do {
            try await service.reportConversation(
                conversationId: conversationId,
                category: category.rawValue,
                details: detailsPayload
            )
            hasReportedThisGroupSession = true
            showReportGroup = false
            showReportSuccessAlert = true
            mapViewModel.showSocialActionToast(
                L10n.t("group_chat_report_group_success_title", languageCode: languageCode),
                isError: false
            )
        } catch let reportError as GroupChatConversationReportError {
#if DEBUG
            print("[GroupReportDebug] typedFailure conversationId=\(conversationId.uuidString.lowercased()) error=\(reportError)")
#endif
            if reportError == .duplicateOpenReport {
                hasReportedThisGroupSession = true
            }
            switch reportError {
            case .duplicateOpenReport:
                reportSheetError = L10n.t("group_chat_report_group_already_reported", languageCode: languageCode)
            case .notActiveMember:
                reportSheetError = L10n.t("group_chat_report_group_not_member", languageCode: languageCode)
            }
        } catch {
#if DEBUG
            print("[GroupReportDebug] failure conversationId=\(conversationId.uuidString.lowercased()) error=\(error)")
#endif
            ModerationService.logReportSubmitFailure(error, context: "group_conversation_report")
            let mapped = ModerationService.userFacingReportSubmitError(error)
            reportSheetError = mapped.isEmpty
                ? L10n.t("group_chat_report_group_failed", languageCode: languageCode)
                : mapped
        }
    }

    @ViewBuilder
    private func groupMemberRow(_ member: GroupConversationDetailRow) -> some View {
        let preview = preview(for: member.member_user_id)
        let isSelf = member.member_user_id == chatViewModel.currentUserAuthId
        let name = isSelf
            ? L10n.t("group_chat_you", languageCode: languageCode)
            : preview.displayName
        let roleLabel = roleDisplayName(member.member_role)
        let rowA11y = String(
            format: L10n.t(
                member.member_role.lowercased() == "admin"
                    ? "group_chat_member_a11y_admin_format"
                    : "group_chat_member_a11y_member_format",
                languageCode: languageCode
            ),
            name
        )
        let canShowMemberActions = !isSelf && memberHasReportableIdentity(member.member_user_id, preview: preview)

        HStack(spacing: 12) {
            if isSelf {
                SocialAvatarRenderer.socialAvatarView(for: preview, size: 42)
                    .frame(width: 42, height: 42)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                    }
                    .accessibilityHidden(true)
            } else {
                ProfileAvatarView(preview: preview, size: 42, profileTapContext: "group_chat_info")
                    .accessibilityLabel(
                        String(
                            format: L10n.t("group_chat_avatar_a11y_format", languageCode: languageCode),
                            preview.displayName
                        )
                    )
            }

            if isSelf {
                Text(name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button {
                    mapViewModel.presentPublicProfile(
                        userId: member.member_user_id,
                        context: "group_chat_info"
                    )
                } label: {
                    Text(name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    String(
                        format: L10n.t("group_chat_view_profile_a11y_format", languageCode: languageCode),
                        preview.displayName
                    )
                )
            }

            Text(roleLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .lineLimit(1)
                .layoutPriority(1)

            if canShowMemberActions {
                Menu {
                    Button {
                        mapViewModel.presentPublicProfile(
                            userId: member.member_user_id,
                            context: "group_chat_info_menu"
                        )
                    } label: {
                        Label(
                            L10n.t("View Profile", languageCode: languageCode),
                            systemImage: "person.crop.circle"
                        )
                    }
                    .accessibilityLabel(
                        String(
                            format: L10n.t("group_chat_view_profile_a11y_format", languageCode: languageCode),
                            preview.displayName
                        )
                    )

                    Button(role: .destructive) {
                        presentReportUser(for: member, displayName: preview.displayName)
                    } label: {
                        Label(
                            L10n.t("group_chat_report_user", languageCode: languageCode),
                            systemImage: "flag"
                        )
                    }
                    .accessibilityLabel(
                        String(
                            format: L10n.t("group_chat_report_user_a11y_format", languageCode: languageCode),
                            preview.displayName
                        )
                    )

                    if viewerIsAdmin, !effectiveIsPickupGameChat {
                        Button(role: .destructive) {
                            Task { await remove(member.member_user_id) }
                        } label: {
                            Label(
                                L10n.t("group_chat_remove_from_group", languageCode: languageCode),
                                systemImage: "person.badge.minus"
                            )
                        }
                        .accessibilityLabel(
                            String(
                                format: L10n.t("group_chat_remove_member_a11y_format", languageCode: languageCode),
                                preview.displayName
                            )
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(
                    String(
                        format: L10n.t("group_chat_member_more_a11y_format", languageCode: languageCode),
                        preview.displayName
                    )
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(rowA11y)
    }

    /// Active member rows always carry a canonical UUID; disable only unresolved placeholders.
    private func memberHasReportableIdentity(_ userId: UUID, preview: UserPreview) -> Bool {
        let trimmedName = preview.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedName.isEmpty
    }

    private func presentReportUser(for member: GroupConversationDetailRow, displayName: String) {
        let userId = member.member_user_id
        guard userId != chatViewModel.currentUserAuthId else { return }
        if reportedMemberIdsThisSession.contains(userId) {
            mapViewModel.showSocialActionToast(
                L10n.t("group_chat_user_already_reported", languageCode: languageCode),
                isError: true
            )
            return
        }
        memberReportTarget = GroupMemberReportTarget(id: userId, displayName: displayName)
    }

    private func preview(for userId: UUID) -> UserPreview {
        if let cached = localPreviews[userId] {
            return cached
        }
        if let friend = chatViewModel.friends.first(where: { $0.preview.id == userId }) {
            return friend.preview
        }
        if userId == chatViewModel.currentUserAuthId {
            let name = mapViewModel.currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return UserPreview(
                id: userId,
                displayName: name.isEmpty ? L10n.t("group_chat_you", languageCode: languageCode) : name,
                avatarURL: mapViewModel.currentUserAvatarURL.isEmpty ? nil : mapViewModel.currentUserAvatarURL,
                avatarThumbnailURL: mapViewModel.currentUserAvatarThumbnailURL.isEmpty
                    ? nil
                    : mapViewModel.currentUserAvatarThumbnailURL
            )
        }
        return UserPreview(id: userId, displayName: "Fan", avatarURL: nil, avatarThumbnailURL: nil)
    }

    private func roleDisplayName(_ role: String) -> String {
        role.lowercased() == "admin"
            ? L10n.t("Admin", languageCode: languageCode)
            : L10n.t("group_chat_role_member", languageCode: languageCode)
    }

    @MainActor
    private func refreshDetailsAndPreviews() async throws {
        localDetails = try await service.fetchDetails(conversationId: conversationId)
        let ids = Array(Set(localDetails.map(\.member_user_id)))
        var seeded: [UUID: UserPreview] = [:]
        for id in ids {
            seeded[id] = preview(for: id)
        }
        localPreviews = seeded
        if let fetched = try? await identityService.fetchUserPreviews(for: ids) {
            var merged = seeded
            for (id, value) in fetched {
                merged[id] = value
            }
            localPreviews = merged
        }
        onDetailsChanged?(localDetails, localPreviews)
        await refreshPendingInvitesIfAdmin()
    }

    @MainActor
    private func refreshPendingInvitesIfAdmin() async {
        guard viewerIsAdmin else {
            pendingInvites = []
            return
        }
        do {
            let rows = try await service.fetchPendingInvitations(conversationId: conversationId)
            pendingInvites = rows
            let ids = Array(Set(rows.map(\.invitee_user_id)))
            if let fetched = try? await identityService.fetchUserPreviews(for: ids) {
                pendingInvitePreviews = fetched
            }
        } catch {
            // Older servers without invitation RPCs: leave empty.
            pendingInvites = []
        }
    }

    @MainActor
    private func cancelPendingInvite(_ invitationId: UUID) async {
        do {
            try await service.cancelInvitation(invitationId: invitationId)
            await refreshPendingInvitesIfAdmin()
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func add(_ ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        do {
            let invited = try await service.addMembers(conversationId: conversationId, memberIds: ids)
            try await refreshDetailsAndPreviews()
            showAddMembers = false
            if invited > 0 {
                inviteConfirmationText = L10n.t("group_chat_invitations_sent", languageCode: languageCode)
            } else {
                inviteConfirmationText = nil
            }
            await chatViewModel.refreshInboxSummaries()
        } catch {
            errorText = groupChatNeutralInviteErrorText(error, languageCode: languageCode)
        }
    }

    @MainActor
    private func remove(_ userId: UUID) async {
        do {
            try await service.removeMember(conversationId: conversationId, userId: userId)
            try await refreshDetailsAndPreviews()
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func leave() async {
        do {
            try await service.leave(conversationId: conversationId)
            await chatViewModel.refreshInboxSummaries()
            onLeft()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Pickup game summary (Group Info)

/// Compact pickup identity card for Group Info. Loads once via MapViewModel cache/select.
private struct GroupInfoPickupGameSummaryCard: View {
    let gameId: UUID?
    let row: PickupGameRow?
    let fallbackContext: PickupGameChatContext?
    let loadCompleted: Bool
    let isUnavailable: Bool
    @ObservedObject var mapViewModel: MapViewModel
    let languageCode: String
    let onViewPickupGame: (UUID) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private enum StatusKind {
        case upcoming
        case today
        case inProgress
        case finished
        case cancelled
        case unavailable
    }

    static func isArchivedOrDeleted(_ row: PickupGameRow?) -> Bool {
        guard let row else { return false }
        switch row.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "removed", "deleted", "expired", "archived":
            return true
        default:
            return false
        }
    }

    private var statusKind: StatusKind {
        if isUnavailable { return .unavailable }
        guard let row else { return loadCompleted ? .unavailable : .upcoming }
        let raw = row.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw == "cancelled" || raw == "canceled" { return .cancelled }
        if Self.isArchivedOrDeleted(row) { return .unavailable }

        let now = Date()
        guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else {
            return .upcoming
        }
        let end: Date = {
            if let rawEnd = row.end_time, let parsed = PickupGameModels.parseSupabaseTimestamptz(rawEnd) {
                return parsed
            }
            return start.addingTimeInterval(2 * 3600)
        }()
        if now >= end { return .finished }
        if row.hasPickupGameStarted(now: now) { return .inProgress }
        if Calendar.current.isDate(start, inSameDayAs: now) { return .today }
        return .upcoming
    }

    private var statusLabel: String {
        switch statusKind {
        case .upcoming: return L10n.t("group_info_pickup_status_upcoming", languageCode: languageCode)
        case .today: return L10n.t("group_info_pickup_status_today", languageCode: languageCode)
        case .inProgress: return L10n.t("group_info_pickup_status_in_progress", languageCode: languageCode)
        case .finished: return L10n.t("group_info_pickup_status_finished", languageCode: languageCode)
        case .cancelled: return L10n.t("group_info_pickup_status_cancelled", languageCode: languageCode)
        case .unavailable: return L10n.t("group_info_pickup_unavailable_title", languageCode: languageCode)
        }
    }

    private var statusColor: Color {
        switch statusKind {
        case .inProgress: return FGColor.dangerRed
        case .cancelled, .unavailable, .finished: return FGColor.secondaryText(colorScheme)
        case .today: return FGColor.intentPlay
        case .upcoming: return FGColor.intentPlay.opacity(0.85)
        }
    }

    private var canOpenDetail: Bool {
        guard gameId != nil, row != nil, !isUnavailable else { return false }
        switch statusKind {
        case .unavailable: return false
        case .upcoming, .today, .inProgress, .finished, .cancelled: return true
        }
    }

    private var sportLabel: String {
        if let row {
            return AppSportCatalog.displayLabel(forSportToken: row.sport)
        }
        return fallbackContext?.sportLabel.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var titleText: String {
        if let row {
            let t = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        let fallback = fallbackContext?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fallback.isEmpty
            ? L10n.t("group_info_pickup_section_label", languageCode: languageCode)
            : fallback
    }

    private var whenLine: String? {
        if let row, let line = row.pickupDateWithCompactTimeRange(languageCode: languageCode), !line.isEmpty {
            return line
        }
        let fallback = fallbackContext?.whenLabel.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fallback.isEmpty ? nil : fallback
    }

    private var venueLine: String? {
        if let row {
            let address = row.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return address.isEmpty ? nil : address
        }
        let fallback = fallbackContext?.locationLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fallback.isEmpty ? nil : fallback
    }

    private var cityRegionLine: String? {
        guard let row else { return nil }
        let cityRegion = [row.city, row.state]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        guard !cityRegion.isEmpty else { return nil }
        if let venue = venueLine, venue.localizedCaseInsensitiveContains(cityRegion) {
            return nil
        }
        return cityRegion
    }

    private var organizerName: String? {
        guard let row else { return nil }
        let label = mapViewModel.pickupCreatorDisplayLabel(for: row.creator_user_id)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !label.isEmpty { return label }
        return L10n.t("share_pickup_organizer_fallback", languageCode: languageCode)
    }

    private var participantsLine: String? {
        if let row, row.approved_join_count != nil {
            // Joiners + organizer (creator is separate from approved_join_count).
            let playerCount = max(1, row.approvedJoinCount + 1)
            let playersKey = playerCount == 1
                ? "group_info_pickup_players_one_format"
                : "group_info_pickup_players_other_format"
            let players = String(
                format: L10n.t(playersKey, languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                Int64(playerCount)
            )
            if row.isPickupFullForDiscover {
                return "\(players) · \(L10n.t("pickup_status_full", languageCode: languageCode))"
            }
            let open = row.pickupOpenSlotsRemaining
            if open > 0 {
                return "\(players) · \(pickupLocalizedSpotsLeft(open, languageCode: languageCode))"
            }
            return players
        }
        if let count = fallbackContext?.approvedParticipantCount, count > 0 {
            let key = count == 1
                ? "group_info_pickup_players_one_format"
                : "group_info_pickup_players_other_format"
            return String(
                format: L10n.t(key, languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                Int64(count)
            )
        }
        return nil
    }

    private var accessibilitySummary: String {
        if isUnavailable || (loadCompleted && row == nil && fallbackContext == nil) {
            return L10n.t("group_info_pickup_unavailable_title", languageCode: languageCode)
        }
        var parts: [String] = []
        let sport = sportLabel
        if !sport.isEmpty {
            parts.append(
                String(
                    format: L10n.t("group_info_pickup_a11y_sport_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    sport
                )
            )
        } else {
            parts.append(titleText)
        }
        if !titleText.isEmpty, sportLabel.isEmpty == false {
            parts.append(titleText)
        }
        if let whenLine { parts.append(whenLine) }
        if let venueLine { parts.append(venueLine) }
        if let cityRegionLine { parts.append(cityRegionLine) }
        if let participantsLine { parts.append(participantsLine) }
        parts.append(statusLabel)
        return parts.joined(separator: ". ")
    }

    @ViewBuilder
    private var cardMainBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(L10n.t("group_info_pickup_section_label", languageCode: languageCode))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.intentPlay)
                    .textCase(.uppercase)
                    .tracking(0.4)
                Spacer(minLength: 0)
                Text(statusLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(colorScheme == .dark ? 0.22 : 0.12), in: Capsule())
            }

            if isUnavailable && loadCompleted {
                unavailableContent
            } else if !loadCompleted && row == nil && fallbackContext == nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(L10n.t("group_info_pickup_loading", languageCode: languageCode))
                        .font(.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            } else {
                summaryContent
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardMainBlock
            if canOpenDetail, let gameId {
                Button {
                    onViewPickupGame(gameId)
                } label: {
                    Text(L10n.t("group_info_view_pickup_game", languageCode: languageCode))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(FGColor.intentPlay, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("group_info_view_pickup_game", languageCode: languageCode))
                .accessibilityHint(L10n.t("pickup_edit_open_game_a11y_hint", languageCode: languageCode))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(FGColor.intentPlay.opacity(colorScheme == .dark ? 0.16 : 0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(FGColor.intentPlay.opacity(colorScheme == .dark ? 0.38 : 0.28), lineWidth: 1)
        }
    }

    private var unavailableContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("group_info_pickup_unavailable_title", languageCode: languageCode))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
            Text(L10n.t("group_info_pickup_unavailable_body", languageCode: languageCode))
                .font(.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var summaryContent: some View {
        HStack(alignment: .top, spacing: 12) {
            if let row {
                SportArtworkIconView(sport: row.sport, diameter: 44)
                    .accessibilityHidden(true)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(FGColor.intentPlay.opacity(colorScheme == .dark ? 0.28 : 0.18))
                    Image(systemName: "figure.run")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(FGColor.intentPlay)
                }
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 5) {
                if !sportLabel.isEmpty {
                    Text(sportLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FGColor.intentPlay)
                        .lineLimit(1)
                }
                Text(titleText)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let whenLine {
                    Label(whenLine, systemImage: "calendar")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
                if let venueLine {
                    Label(venueLine, systemImage: "mappin.and.ellipse")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
                if let cityRegionLine {
                    Text(cityRegionLine)
                        .font(.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }
                if let organizerName {
                    Label(
                        String(
                            format: L10n.t("group_info_pickup_organizer_format", languageCode: languageCode),
                            locale: Locale(identifier: languageCode),
                            organizerName
                        ),
                        systemImage: "person.fill"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
                }
                if let participantsLine {
                    Label(participantsLine, systemImage: "person.3")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Add members

private struct GroupChatAddMembersSheet: View {
    @ObservedObject var chatViewModel: ChatViewModel
    let existingMemberIds: Set<UUID>
    var pendingInviteeIds: Set<UUID> = []
    var onAdd: ([UUID]) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var selectedIds: Set<UUID> = []

    private var candidates: [ChatViewModel.FriendDisplay] {
        chatViewModel.friends.filter {
            !$0.isGroupConversation
                && !$0.preview.isBusinessAccount
                && !$0.preview.isBusinessVenueConversation
                && !$0.preview.isDeleted
                && !existingMemberIds.contains($0.preview.id)
                && !pendingInviteeIds.contains($0.preview.id)
                && chatViewModel.chipKind(forOtherUserId: $0.preview.id) == .friends
                && !chatViewModel.isEitherDirectionBlocked(with: $0.preview.id)
        }
    }

    private var remainingSlots: Int {
        max(0, 25 - existingMemberIds.count - pendingInviteeIds.count)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(candidates) { friend in
                    Button {
                        toggle(friend.preview.id)
                    } label: {
                        HStack(spacing: 12) {
                            ProfileAvatarView(preview: friend.preview, size: 36)
                            Text(friend.preview.displayName)
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                            Spacer()
                            Image(systemName: selectedIds.contains(friend.preview.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(
                                    selectedIds.contains(friend.preview.id)
                                        ? FGColor.accentGreen
                                        : FGColor.mutedText(colorScheme)
                                )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(L10n.t("group_chat_invite_members", languageCode: appLanguageRaw))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel", languageCode: appLanguageRaw)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("group_chat_invite_action", languageCode: appLanguageRaw)) {
                        onAdd(Array(selectedIds))
                    }
                    .disabled(selectedIds.isEmpty)
                }
            }
            .overlay {
                if candidates.isEmpty {
                    Text(L10n.t("group_chat_no_friends_to_invite", languageCode: appLanguageRaw))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .padding()
                }
            }
        }
    }

    private func toggle(_ id: UUID) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else if selectedIds.count < remainingSlots {
            selectedIds.insert(id)
        }
    }
}

// MARK: - Member identity helpers / header preview

private enum GroupChatMemberIdentity {
    static func compactName(from preview: UserPreview) -> String {
        let trimmed = preview.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if let username = preview.username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty {
                return username
            }
            return "Fan"
        }
        let parts = trimmed.split(separator: " ").map(String.init)
        return parts.first ?? trimmed
    }

    static func headerSubtitle(
        names: [String],
        totalOtherCount: Int,
        isOnlyViewer: Bool,
        languageCode: String
    ) -> String {
        if isOnlyViewer || names.isEmpty {
            return L10n.t("group_chat_just_you", languageCode: languageCode)
        }
        if names.count == 1 {
            return names[0]
        }
        if names.count == 2, totalOtherCount <= 2 {
            return String(
                format: L10n.t("group_chat_members_two_format", languageCode: languageCode),
                names[0],
                names[1]
            )
        }
        let remaining = max(0, totalOtherCount - 2)
        return String(
            format: L10n.t("group_chat_members_many_format", languageCode: languageCode),
            names[0],
            names[1],
            remaining
        )
    }
}

private struct GroupChatMemberHeaderPreview: View {
    let members: [UserPreview]
    let subtitle: String
    let colorScheme: ColorScheme

    private let avatarSize: CGFloat = 22

    var body: some View {
        HStack(spacing: 6) {
            if !members.isEmpty {
                HStack(spacing: -avatarSize * 0.34) {
                    ForEach(Array(members.enumerated()), id: \.element.id) { _, member in
                        SocialAvatarRenderer.socialAvatarView(for: member, size: avatarSize)
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
                }
            }

            Text(subtitle)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity)
    }
}
