import Combine
import Supabase
import SwiftUI

// MARK: - Inbox card

struct FanGeoSupportInboxCard: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image("FanGeoCircularLogo")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: 52, height: 52)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(FGColor.divider(colorScheme).opacity(0.45), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text("FanGeo Support")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)

                Text("Official Support Team")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.accentGreen)
                    .lineLimit(1)

                Text("Questions, suggestions, or need help? Contact FanGeo Support.")
                    .font(.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)

                HStack(spacing: 4) {
                    Text("Contact Support")
                        .font(.caption.weight(.bold))
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(FGColor.accentGreen)
                .padding(.top, 4)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.96))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.34 : 0.48), lineWidth: 1)
        }
        .softCardShadow()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("FanGeo Support. Official Support Team. Contact Support.")
    }
}

// MARK: - Thread

@MainActor
private final class SupportChatPresenter: ObservableObject {
    @Published private(set) var conversationId: UUID?
    @Published private(set) var messages: [SupportMessageRow] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    @Published var draft = ""
    @Published private(set) var isSending = false
    @Published private(set) var isRefreshing = false

    private let service = SupportChatService()
    private let fixedConversationId: UUID?
    private var realtimeTask: Task<Void, Never>?
    private var realtimeChannel: RealtimeChannelV2?

    init(conversationId: UUID? = nil) {
        self.fixedConversationId = conversationId
        self.conversationId = conversationId
    }

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    deinit {
        realtimeTask?.cancel()
    }

    func loadThread() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let cid: UUID
            if let fixedConversationId {
                cid = fixedConversationId
            } else {
                cid = try await service.getOrCreateConversationId()
            }
            conversationId = cid
            print("[SupportChat] conversation id=\(cid.uuidString.lowercased())")
            messages = try await service.fetchMessages(conversationId: cid)
            print("[SupportChat] loaded message count=\(messages.count)")
            startRealtimeIfNeeded(conversationId: cid)
        } catch {
            loadError = error.localizedDescription
            print("[SupportChat] load failed error=\(error.localizedDescription)")
        }
    }

    func refreshMessages(logRefreshTapped: Bool = false) async {
        if logRefreshTapped {
            print("[SupportChat] refresh tapped")
        }

        isRefreshing = true
        defer { isRefreshing = false }

        guard let cid = conversationId else {
            await loadThread()
            return
        }

        do {
            messages = try await service.fetchMessages(conversationId: cid)
            loadError = nil
            print("[SupportChat] conversation id=\(cid.uuidString.lowercased())")
            print("[SupportChat] loaded message count=\(messages.count)")
        } catch {
            loadError = error.localizedDescription
            print("[SupportChat] refresh failed error=\(error.localizedDescription)")
        }
    }

    func reloadOnAppear() async {
        if conversationId == nil {
            await loadThread()
        } else {
            await refreshMessages()
            if let cid = conversationId {
                startRealtimeIfNeeded(conversationId: cid)
            }
        }
    }

    func sendDraft() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !isSending else { return }

        isSending = true
        defer { isSending = false }

        do {
            let cid: UUID
            if let conversationId {
                cid = conversationId
            } else if let fixedConversationId {
                cid = fixedConversationId
            } else {
                cid = try await service.getOrCreateConversationId()
                conversationId = cid
                print("[SupportChat] conversation id=\(cid.uuidString.lowercased())")
            }
            _ = try await service.sendMessage(conversationId: cid, body: body)
            draft = ""
            await refreshMessages()
        } catch {
            loadError = error.localizedDescription
            print("[SupportChat] send failed error=\(error.localizedDescription)")
        }
    }

    func stopRealtime() async {
        realtimeTask?.cancel()
        realtimeTask = nil
        if let channel = realtimeChannel {
            realtimeChannel = nil
            await service.removeRealtimeChannel(channel)
            print("[SupportChatRealtime] unsubscribed channel=\(channel.topic)")
        }
    }

    func trimDraftIfNeeded(maxLength: Int = 4000) {
        if draft.count > maxLength {
            draft = String(draft.prefix(maxLength))
        }
    }

    private func startRealtimeIfNeeded(conversationId: UUID) {
        guard realtimeTask == nil else { return }

        let cid = conversationId
        print("[SupportChatRealtime] scheduling subscription conversationId=\(cid.uuidString.lowercased())")
        realtimeTask = Task { [weak self] in
            guard let self else { return }
            await self.runRealtimeSubscription(conversationId: cid)
        }
    }

    private func runRealtimeSubscription(conversationId: UUID) async {
        let cidLower = conversationId.uuidString.lowercased()
        let (channel, stream) = service.supportMessagesInsertChannel(conversationId: conversationId)
        realtimeChannel = channel
        print("[SupportChatRealtime] subscribe start channel=\(channel.topic) filter=\(SupportChatService.supportMessagesThreadRealtimeFilterDescription(conversationId: conversationId))")

        do {
            try await service.subscribeSupportMessagesChannelWithTimeout(channel)
            print("[SupportChatRealtime] subscribe success channel=\(channel.topic) conversationId=\(cidLower)")
        } catch {
            if !Task.isCancelled {
                print("[SupportChatRealtime] subscribe failed conversationId=\(cidLower) error=\(error.localizedDescription)")
            }
            await service.removeRealtimeChannel(channel)
            if realtimeChannel === channel {
                realtimeChannel = nil
            }
            return
        }

        let decoder = JSONDecoder()
        for await insertion in stream {
            if Task.isCancelled { break }

            let row: SupportMessageRow
            do {
                row = try insertion.decodeRecord(as: SupportMessageRow.self, decoder: decoder)
            } catch {
                print("[SupportChatRealtime] decode failed conversationId=\(cidLower)")
                continue
            }

            print("[SupportChatRealtime] insert received id=\(row.id.uuidString.lowercased()) senderKind=\(row.sender_kind) conversationId=\(cidLower)")
            applyIncomingMessage(row, conversationId: conversationId)
        }

        await service.removeRealtimeChannel(channel)
        if realtimeChannel === channel {
            realtimeChannel = nil
        }
        print("[SupportChatRealtime] stream ended channel=\(channel.topic) conversationId=\(cidLower)")
    }

    private func applyIncomingMessage(_ row: SupportMessageRow, conversationId: UUID) {
        guard row.conversation_id == conversationId else { return }
        guard !messages.contains(where: { $0.id == row.id }) else { return }
        messages.append(row)
        messages.sort { lhs, rhs in
            let left = lhs.created_at ?? ""
            let right = rhs.created_at ?? ""
            if left == right { return lhs.id.uuidString < rhs.id.uuidString }
            return left < right
        }
        print("[SupportChat] loaded message count=\(messages.count)")
    }
}

private enum SupportChatTimeFormat {
    private static let isoWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func shortTime(for raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let date = isoWithFractional.date(from: raw) ?? isoPlain.date(from: raw)
        guard let date else { return nil }
        let df = DateFormatter()
        df.locale = .autoupdatingCurrent
        df.timeStyle = .short
        df.dateStyle = .none
        return df.string(from: date)
    }
}

private struct SupportMessageBubbleView: View {
    @Environment(\.colorScheme) private var colorScheme

    let text: String
    let isFromCurrentUser: Bool
    let userPreview: UserPreview
    let timestamp: String?

    private static let avatarColumnWidth: CGFloat = 34

    var body: some View {
        HStack(alignment: .bottom, spacing: FGSpacing.sm) {
            if !isFromCurrentUser {
                Image("FanGeoCircularLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 30, height: 30)
                    .clipShape(Circle())
                    .frame(width: Self.avatarColumnWidth, alignment: .center)
            }

            VStack(alignment: isFromCurrentUser ? .trailing : .leading, spacing: FGSpacing.xs + 1) {
                if !isFromCurrentUser {
                    Text("FanGeo Support")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .padding(.horizontal, FGSpacing.xs)
                }

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
                ProfileAvatarView(preview: userPreview, size: 30)
                    .frame(width: Self.avatarColumnWidth, alignment: .center)
            }
        }
    }
}

struct SupportChatView: View {
    @ObservedObject var mapViewModel: MapViewModel
    @ObservedObject var chatViewModel: ChatViewModel
    let conversationId: UUID?
    let showComposer: Bool
    var onCancelRequest: (() -> Void)?

    @StateObject private var presenter: SupportChatPresenter
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @FocusState private var composerFocused: Bool

    init(
        mapViewModel: MapViewModel,
        chatViewModel: ChatViewModel,
        conversationId: UUID? = nil,
        showComposer: Bool = true,
        onCancelRequest: (() -> Void)? = nil
    ) {
        self.mapViewModel = mapViewModel
        self.chatViewModel = chatViewModel
        self.conversationId = conversationId
        self.showComposer = showComposer
        self.onCancelRequest = onCancelRequest
        _presenter = StateObject(wrappedValue: SupportChatPresenter(conversationId: conversationId))
    }

    private var currentUserPreview: UserPreview {
        UserPreview(
            id: mapViewModel.currentUserAuthId ?? UUID(),
            displayName: mapViewModel.currentUserDisplayName.isEmpty ? "You" : mapViewModel.currentUserDisplayName,
            username: mapViewModel.currentUserUsername.isEmpty ? nil : mapViewModel.currentUserUsername,
            avatarURL: mapViewModel.currentUserAvatarURL.isEmpty ? nil : mapViewModel.currentUserAvatarURL,
            avatarThumbnailURL: mapViewModel.currentUserAvatarThumbnailURL.isEmpty ? nil : mapViewModel.currentUserAvatarThumbnailURL,
            isDeleted: false
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            threadHeader

            Group {
                if presenter.isLoading && presenter.messages.isEmpty {
                    FanGeoLoadingView(message: "Loading support chat…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError = presenter.loadError, presenter.messages.isEmpty {
                    ContentUnavailableView(
                        "Couldn’t load support chat",
                        systemImage: "exclamationmark.bubble",
                        description: Text(loadError)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    messageList
                }
            }
        }
        .background(colorScheme == .dark ? Color.black : Color(.systemBackground))
        .safeAreaInset(edge: .bottom) {
            if showComposer {
                composer
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            chatViewModel.hidesFloatingTabBarForDirectChat = true
            Task {
                await presenter.reloadOnAppear()
            }
        }
        .onDisappear {
            chatViewModel.hidesFloatingTabBarForDirectChat = false
            Task { await presenter.stopRealtime() }
        }
    }

    private var threadHeader: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .frame(width: 36, height: 36)
                    .background(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.96), in: Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(FGColor.divider(colorScheme).opacity(0.55), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            Image("FanGeoCircularLogo")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 40, height: 40)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("FanGeo Support")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text("Official Support Team")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.accentGreen)
            }

            Spacer(minLength: 0)

            if let onCancelRequest {
                Menu {
                    Button("Cancel Request", role: .destructive) {
                        onCancelRequest()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .frame(width: 36, height: 36)
                        .background(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.96), in: Circle())
                        .overlay {
                            Circle()
                                .strokeBorder(FGColor.divider(colorScheme).opacity(0.55), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Request options")
            }

            Button {
                Task {
                    await presenter.refreshMessages(logRefreshTapped: true)
                }
            } label: {
                Group {
                    if presenter.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16, weight: .bold))
                    }
                }
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .frame(width: 36, height: 36)
                .background(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.96), in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(FGColor.divider(colorScheme).opacity(0.55), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(presenter.isRefreshing)
            .accessibilityLabel("Refresh messages")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.92))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FGColor.divider(colorScheme).opacity(0.55))
                .frame(height: 1)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if presenter.messages.isEmpty {
                        Text("Send a message to reach the FanGeo Support team.")
                            .font(.subheadline)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                            .padding(.horizontal, 24)
                    }

                    ForEach(presenter.messages) { row in
                        let isMine = !row.isFromSupport
                        SupportMessageBubbleView(
                            text: row.body,
                            isFromCurrentUser: isMine,
                            userPreview: currentUserPreview,
                            timestamp: SupportChatTimeFormat.shortTime(for: row.created_at)
                        )
                        .id(row.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .refreshable {
                await presenter.refreshMessages(logRefreshTapped: true)
            }
            .onChange(of: presenter.messages.count) { _, _ in
                guard let last = presenter.messages.last?.id else { return }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: FGSpacing.sm) {
            TextField("Message FanGeo Support", text: $presenter.draft)
                .textFieldStyle(.plain)
                .font(FGTypography.body)
                .lineLimit(1...6)
                .submitLabel(.send)
                .onSubmit {
                    guard presenter.canSend else { return }
                    Task { await presenter.sendDraft() }
                }
                .padding(.horizontal, FGSpacing.md)
                .padding(.vertical, FGSpacing.sm + 1)
                .background(
                    RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                        .fill(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.64 : 0.98))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                        .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                )
                .focused($composerFocused)
                .onChange(of: presenter.draft) { _, _ in
                    presenter.trimDraftIfNeeded()
                }
                .frame(minHeight: 38, alignment: .center)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(presenter.isSending)

            Button {
                Task { await presenter.sendDraft() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(presenter.canSend ? FGColor.accentGreen : FGColor.mutedText(colorScheme))
            }
            .buttonStyle(.plain)
            .disabled(!presenter.canSend)
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal, FGSpacing.lg)
        .padding(.top, FGSpacing.sm)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
    }
}
