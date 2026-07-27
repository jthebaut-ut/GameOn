import SwiftUI
import Supabase

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
    @State private var subscribedConversationId: UUID?
    @State private var realtimeConnectionStatus: ChatRealtimeConnectionStatus = .connecting
    @State private var seenMessageIds: Set<UUID> = []
    @State private var reportTarget: GroupMessageRow?
    @State private var reportCategory: ModerationReportCategory = .spam
    @State private var isSubmittingReport = false
    @State private var reportBanner: String?
    /// Session-local guard: backend allows multiple reports per message; UI must not.
    @State private var reportedMessageIds: Set<UUID> = []
    @State private var showEmojiQuickTray = false
    @State private var isRefreshingMessages = false
    @FocusState private var composerFocused: Bool

    private let service = GroupChatService()
    private let identityService = SocialIdentityService()
    private let maxBodyLength = 1000

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var isPickupGameChat: Bool {
        pickupContext != nil || details.first?.isPickupGameChat == true
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
                Button {
                    showInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel(L10n.t("group_chat_info_a11y", languageCode: appLanguageRaw))
            }
        }
        .sheet(isPresented: $showInfo) {
            GroupChatInfoView(
                conversationId: conversationId,
                details: details,
                memberPreviews: memberPreviews,
                chatViewModel: chatViewModel,
                isPickupGameChat: isPickupGameChat,
                pickupLocationLabel: pickupContext?.locationLabel,
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
            await load()
            await subscribeGroupRealtime(reason: "open")
        }
        .onAppear {
            chatViewModel.hidesFloatingTabBarForDirectChat = true
        }
        .onReceive(NotificationCenter.default.publisher(for: FanProfileChangeCenter.avatarDidChangeNotification)) { notification in
            guard let change = FanProfileChangeCenter.avatarChange(from: notification) else { return }
            applyMemberAvatarChange(change)
        }
        .onDisappear {
            chatViewModel.hidesFloatingTabBarForDirectChat = false
            Task { await tearDownGroupRealtime(statusAfter: .offline) }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await tearDownGroupRealtime(statusAfter: .connecting)
                await subscribeGroupRealtime(reason: "foreground")
            }
        }
        .onChange(of: chatViewModel.currentUserAuthId) { _, newId in
            Task {
                await tearDownGroupRealtime(statusAfter: .offline)
                if newId != nil {
                    await subscribeGroupRealtime(reason: "accountSwitch")
                }
            }
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
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.18), value: realtimeConnectionStatus)

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
                }
            )
        }
        .padding(.horizontal, FGSpacing.lg)
        .padding(.top, FGSpacing.sm)
        .padding(.bottom, 0)
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
            Text(eventText)
                .font(FGTypography.metadata)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, FGSpacing.md)
                .padding(.vertical, FGSpacing.xs + 2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(eventText)
        } else if let payload = FanProfileShareMessage.decode(from: message.body) {
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
                    Text(message.body)
                        .font(.body)
                        .foregroundStyle(isMine ? Color.white : FGColor.primaryText(colorScheme))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(isMine ? FGColor.accentGreen : FGColor.cardBackground(colorScheme))
                        }
                        .contextMenu {
                            if !isMine {
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
                }
                if !isMine { Spacer(minLength: Self.groupIncomingTrailingInset) }
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
            if older.count < 40 {
                canLoadOlder = false
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func tearDownGroupRealtime(statusAfter: ChatRealtimeConnectionStatus) async {
        realtimeListenTask?.cancel()
        realtimeListenTask = nil
        let channel = realtimeChannel
        realtimeChannel = nil
        subscribedConversationId = nil
        realtimeConnectionStatus = statusAfter
        if let channel {
            await service.removeRealtimeChannel(channel)
        }
    }

    /// Postgres INSERT on `group_messages` (includes system join/leave rows). Edit/delete events are not published.
    @MainActor
    private func subscribeGroupRealtime(reason: String) async {
        // Prevent duplicate live channels when reopen / task re-entry races.
        if realtimeChannel != nil,
           subscribedConversationId == conversationId,
           realtimeConnectionStatus == .live || realtimeConnectionStatus == .connected {
            return
        }

        await tearDownGroupRealtime(statusAfter: .connecting)

        let delaysNs: [UInt64] = [0, 1_000_000_000, 2_000_000_000, 4_000_000_000]
        var attempt = 0
        while !Task.isCancelled {
            realtimeConnectionStatus = attempt == 0 ? .connecting : .reconnecting
            let (channel, stream) = service.groupMessagesInsertChannel(conversationId: conversationId)
            realtimeChannel = channel
            subscribedConversationId = conversationId
            do {
                try await channel.subscribeWithError()
                guard !Task.isCancelled, subscribedConversationId == conversationId else {
                    if subscribedConversationId == conversationId {
                        realtimeChannel = nil
                        subscribedConversationId = nil
                    }
                    await service.removeRealtimeChannel(channel)
                    return
                }
                realtimeConnectionStatus = .live
                realtimeListenTask = Task { @MainActor in
                    for await action in stream {
                        if Task.isCancelled { break }
                        guard subscribedConversationId == conversationId else { break }
                        guard let row = try? action.decodeRecord(as: GroupMessageRow.self, decoder: JSONDecoder()) else {
                            continue
                        }
                        // Defense in depth: hide blocked senders even if Realtime delivers the row.
                        if row.message_type != "system",
                           chatViewModel.isEitherDirectionBlocked(with: row.sender_id) {
                            continue
                        }
                        guard seenMessageIds.insert(row.id).inserted else { continue }
                        messages.append(row)
                        try? await service.markRead(conversationId: conversationId)
                    }
                    if !Task.isCancelled, subscribedConversationId == conversationId {
                        realtimeConnectionStatus = .reconnecting
                    }
                }
                return
            } catch is CancellationError {
                if subscribedConversationId == conversationId {
                    realtimeChannel = nil
                    subscribedConversationId = nil
                }
                await service.removeRealtimeChannel(channel)
                return
            } catch {
                if subscribedConversationId == conversationId {
                    realtimeChannel = nil
                    subscribedConversationId = nil
                }
                await service.removeRealtimeChannel(channel)
                attempt += 1
                if attempt >= delaysNs.count {
                    realtimeConnectionStatus = .reconnecting
                    return
                }
                let delay = delaysNs[attempt]
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }
        _ = reason
    }

    @MainActor
    private func send() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body.count <= maxBodyLength, !sendingDisabled else { return }
        isSending = true
        errorText = nil
        do {
            let id = try await service.sendMessage(conversationId: conversationId, body: body)
            draft = ""
            showEmojiQuickTray = false
            if !seenMessageIds.contains(id) {
                // Optimistic reconcile via refresh if realtime is slow.
                messages = try await service.fetchLatestMessages(conversationId: conversationId)
                seenMessageIds = Set(messages.map(\.id))
            }
            await chatViewModel.refreshInboxSummaries()
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
            let id = try await service.sendMessage(conversationId: conversationId, body: trimmed)
            showEmojiQuickTray = false
            if seenMessageIds.insert(id).inserted {
                messages = try await service.fetchLatestMessages(conversationId: conversationId)
                seenMessageIds = Set(messages.map(\.id))
            }
            await chatViewModel.refreshInboxSummaries()
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
        do {
            let latest = try await service.fetchLatestMessages(conversationId: conversationId)
            messages = latest
            seenMessageIds = Set(latest.map(\.id))
            try? await service.markRead(conversationId: conversationId)
            await chatViewModel.refreshInboxSummaries()
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
    var pickupLocationLabel: String? = nil
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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(title)
                        .font(.headline)
                    if effectiveIsPickupGameChat {
                        Text("Private chat for this pickup game")
                            .font(.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                        if let location = pickupLocationLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !location.isEmpty {
                            Text(location)
                                .font(.caption)
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                        }
                        Text("Membership follows approved players for this game.")
                            .font(.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
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
            }
            .task(id: conversationId) {
                await hydrateAuthoritativeMuteState()
                await refreshPendingInvitesIfAdmin()
            }
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
