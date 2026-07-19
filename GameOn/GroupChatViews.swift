import SwiftUI
import Supabase

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

    private var candidates: [ChatViewModel.FriendDisplay] {
        chatViewModel.friends.filter {
            !$0.isGroupConversation
                && !$0.preview.isBusinessAccount
                && !$0.preview.isBusinessVenueConversation
                && !$0.preview.isDeleted
                && chatViewModel.chipKind(forOtherUserId: $0.preview.id) == .friends
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
                    Text(L10n.t("group_chat_create_footer", languageCode: appLanguageRaw))
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
            errorText = error.localizedDescription
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
    @EnvironmentObject private var mapViewModel: MapViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
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
        GroupChatMemberIdentity.headerSubtitle(
            names: headerPreviewNames,
            totalOtherCount: headerOtherMembers.count,
            isOnlyViewer: details.count == 1 && details.first?.member_user_id == chatViewModel.currentUserAuthId,
            languageCode: languageCode
        )
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

                    ForEach(messages) { message in
                        groupBubble(message)
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
                        Text(title)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)

                        if !details.isEmpty {
                            GroupChatMemberHeaderPreview(
                                members: Array(headerOtherMembers.prefix(3)),
                                subtitle: headerSubtitleText,
                                colorScheme: colorScheme
                            )
                            .frame(maxWidth: 220)
                        }
                    }
                    .frame(minHeight: details.isEmpty ? 28 : 40)
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
            await subscribe()
        }
        .onAppear {
            chatViewModel.hidesFloatingTabBarForDirectChat = true
        }
        .onDisappear {
            chatViewModel.hidesFloatingTabBarForDirectChat = false
            Task {
                if let realtimeChannel {
                    await service.removeRealtimeChannel(realtimeChannel)
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

    @ViewBuilder
    private func groupBubble(_ message: GroupMessageRow) -> some View {
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
            HStack {
                if isMine { Spacer(minLength: 40) }
                VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                    if !isMine {
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
                if !isMine { Spacer(minLength: 40) }
            }
        } else {
            HStack {
                if isMine { Spacer(minLength: 40) }
                VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                    if !isMine {
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
                if !isMine { Spacer(minLength: 40) }
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
    private func subscribe() async {
        let (channel, stream) = service.groupMessagesInsertChannel(conversationId: conversationId)
        realtimeChannel = channel
        try? await channel.subscribeWithError()
        Task {
            for await action in stream {
                guard let row = try? action.decodeRecord(as: GroupMessageRow.self, decoder: JSONDecoder()) else {
                    continue
                }
                await MainActor.run {
                    guard seenMessageIds.insert(row.id).inserted else { return }
                    messages.append(row)
                }
                try? await service.markRead(conversationId: conversationId)
            }
        }
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
    var onLeft: () -> Void
    var onDetailsChanged: (([GroupConversationDetailRow], [UUID: UserPreview]) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var localDetails: [GroupConversationDetailRow] = []
    @State private var localPreviews: [UUID: UserPreview] = [:]
    @State private var errorText: String?
    @State private var isMuted = false
    @State private var showAddMembers = false
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
                }

                Section(L10n.t("group_chat_members_section", languageCode: languageCode)) {
                    ForEach(localDetails, id: \.member_user_id) { member in
                        groupMemberRow(member)
                    }

                    if viewerIsAdmin, memberIds.count < 25 {
                        Button {
                            showAddMembers = true
                        } label: {
                            Label(
                                L10n.t("group_chat_add_members", languageCode: languageCode),
                                systemImage: "person.badge.plus"
                            )
                        }
                    }
                }

                Section {
                    Toggle(L10n.t("group_chat_mute", languageCode: languageCode), isOn: $isMuted)
                        .onChange(of: isMuted) { _, newValue in
                            Task { try? await service.setMuted(conversationId: conversationId, muted: newValue) }
                        }

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

                    Button(role: .destructive) {
                        Task { await leave() }
                    } label: {
                        Text(L10n.t("group_chat_leave", languageCode: languageCode))
                    }
                    .accessibilityLabel(
                        L10n.t("group_chat_leave", languageCode: languageCode)
                    )
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
                Button(L10n.t("group_chat_leave", languageCode: languageCode), role: .destructive) {
                    Task { await leave() }
                }
                Button(L10n.t("done", languageCode: languageCode), role: .cancel) {}
            } message: {
                Text(L10n.t("group_chat_report_group_success_body", languageCode: languageCode))
            }
            .onAppear {
                localDetails = details
                localPreviews = memberPreviews
                isMuted = details.first?.viewer_is_muted == true
            }
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

                    if viewerIsAdmin {
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
    }

    @MainActor
    private func add(_ ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        do {
            try await service.addMembers(conversationId: conversationId, memberIds: ids)
            try await refreshDetailsAndPreviews()
            showAddMembers = false
            await chatViewModel.refreshInboxSummaries()
        } catch {
            errorText = error.localizedDescription
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
                && chatViewModel.chipKind(forOtherUserId: $0.preview.id) == .friends
        }
    }

    private var remainingSlots: Int {
        max(0, 25 - existingMemberIds.count)
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
            .navigationTitle(L10n.t("group_chat_add_members", languageCode: appLanguageRaw))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel", languageCode: appLanguageRaw)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("group_chat_add_action", languageCode: appLanguageRaw)) {
                        onAdd(Array(selectedIds))
                    }
                    .disabled(selectedIds.isEmpty)
                }
            }
            .overlay {
                if candidates.isEmpty {
                    Text(L10n.t("group_chat_no_friends_to_add", languageCode: appLanguageRaw))
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
