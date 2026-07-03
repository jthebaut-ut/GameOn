import Combine
import Supabase
import SwiftUI

@MainActor
final class AdminSupportInboxPresenter: ObservableObject {
    @Published private(set) var conversations: [AdminSupportConversationRow] = []
    @Published private(set) var messages: [SupportMessageRow] = []
    @Published var selectedConversationId: UUID?
    @Published private(set) var isLoadingList = false
    @Published private(set) var isLoadingThread = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSending = false
    @Published private(set) var loadError: String?
    @Published var draft = ""
    @Published private(set) var isRealtimeConnected = false

    private let service = AdminSupportInboxService()
    private var adminEmail = ""
    private var inboxRealtimeTask: Task<Void, Never>?
    private var threadRealtimeTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var inboxRealtimeChannel: RealtimeChannelV2?
    private var threadRealtimeChannel: RealtimeChannelV2?

    var canSend: Bool {
        selectedConversationId != nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSending
    }

    func configure(adminEmail: String) {
        self.adminEmail = adminEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func loadInbox() async {
        guard !adminEmail.isEmpty else {
            loadError = "Enter an admin email ending in @fangeosports.com."
            return
        }

        isLoadingList = true
        loadError = nil
        defer { isLoadingList = false }

        do {
            conversations = try await service.listConversations(adminEmail: adminEmail)
            print("[SupportInboxRealtime] loaded conversation count=\(conversations.count)")
            startInboxRealtimeIfNeeded()
            startPollingFallbackIfNeeded()
        } catch {
            loadError = error.localizedDescription
            print("[SupportInboxRealtime] load failed error=\(error.localizedDescription)")
        }
    }

    func refreshInbox(logRefreshTapped: Bool = false) async {
        if logRefreshTapped {
            print("[SupportInboxRealtime] refresh tapped")
        }

        isRefreshing = true
        defer { isRefreshing = false }

        guard !adminEmail.isEmpty else { return }

        do {
            conversations = try await service.listConversations(adminEmail: adminEmail)
            if let cid = selectedConversationId {
                messages = try await service.fetchMessages(
                    conversationId: cid,
                    adminEmail: adminEmail
                )
            }
            loadError = nil
            print("[SupportInboxRealtime] loaded conversation count=\(conversations.count)")
        } catch {
            loadError = error.localizedDescription
            print("[SupportInboxRealtime] refresh failed error=\(error.localizedDescription)")
        }
    }

    func selectConversation(_ conversationId: UUID) async {
        selectedConversationId = conversationId
        await loadThread(conversationId: conversationId)
        restartThreadRealtime(conversationId: conversationId)
    }

    func loadThread(conversationId: UUID) async {
        isLoadingThread = true
        defer { isLoadingThread = false }

        do {
            messages = try await service.fetchMessages(
                conversationId: conversationId,
                adminEmail: adminEmail
            )
            print("[SupportInboxRealtime] loaded message count=\(messages.count) conversationId=\(conversationId.uuidString.lowercased())")
        } catch {
            loadError = error.localizedDescription
            print("[SupportInboxRealtime] thread load failed error=\(error.localizedDescription)")
        }
    }

    func sendDraft() async {
        guard let cid = selectedConversationId else { return }
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !isSending else { return }

        isSending = true
        defer { isSending = false }

        do {
            _ = try await service.sendSupportReply(
                conversationId: cid,
                body: body,
                adminEmail: adminEmail
            )
            draft = ""
            await loadThread(conversationId: cid)
            await refreshInbox()
        } catch {
            loadError = error.localizedDescription
            print("[SupportInboxRealtime] send failed error=\(error.localizedDescription)")
        }
    }

    func openChat(for conversationId: UUID) async {
        guard !adminEmail.isEmpty else { return }
        do {
            _ = try await service.openSupportChat(
                conversationId: conversationId,
                adminEmail: adminEmail
            )
            await refreshInbox()
            if selectedConversationId == conversationId {
                await loadThread(conversationId: conversationId)
            }
        } catch {
            loadError = error.localizedDescription
            print("[SupportInboxRealtime] open chat failed error=\(error.localizedDescription)")
        }
    }

    var selectedConversation: AdminSupportConversationRow? {
        guard let cid = selectedConversationId else { return nil }
        return conversations.first(where: { $0.id == cid })
    }

    func stopAllRealtimeAndPolling() async {
        pollingTask?.cancel()
        pollingTask = nil
        inboxRealtimeTask?.cancel()
        inboxRealtimeTask = nil
        threadRealtimeTask?.cancel()
        threadRealtimeTask = nil

        if let channel = inboxRealtimeChannel {
            inboxRealtimeChannel = nil
            await service.removeRealtimeChannel(channel)
            print("[SupportInboxRealtime] unsubscribed inbox channel")
        }
        if let channel = threadRealtimeChannel {
            threadRealtimeChannel = nil
            await service.removeRealtimeChannel(channel)
            print("[SupportInboxRealtime] unsubscribed thread channel")
        }
        isRealtimeConnected = false
    }

    private func startInboxRealtimeIfNeeded() {
        guard inboxRealtimeTask == nil else { return }

        inboxRealtimeTask = Task { [weak self] in
            guard let self else { return }
            await self.runInboxRealtimeSubscription()
        }
    }

    private func restartThreadRealtime(conversationId: UUID) {
        threadRealtimeTask?.cancel()
        threadRealtimeTask = nil
        if let channel = threadRealtimeChannel {
            threadRealtimeChannel = nil
            Task { await service.removeRealtimeChannel(channel) }
        }

        threadRealtimeTask = Task { [weak self] in
            guard let self else { return }
            await self.runThreadRealtimeSubscription(conversationId: conversationId)
        }
    }

    private func startPollingFallbackIfNeeded() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled, let self else { return }
                guard !self.isRealtimeConnected else { continue }
                await self.refreshInbox()
            }
        }
    }

    private func runInboxRealtimeSubscription() async {
        let (channel, stream) = service.supportInboxInsertChannel()
        inboxRealtimeChannel = channel
        print("[SupportInboxRealtime] subscribe start channel=\(channel.topic)")

        do {
            try await service.subscribeChannelWithTimeout(channel)
            isRealtimeConnected = true
            print("[SupportInboxRealtime] subscribe success channel=\(channel.topic)")
        } catch {
            isRealtimeConnected = false
            print("[SupportInboxRealtime] subscribe failed error=\(error.localizedDescription)")
            await service.removeRealtimeChannel(channel)
            if inboxRealtimeChannel === channel {
                inboxRealtimeChannel = nil
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
                continue
            }

            print("[SupportInboxRealtime] insert received id=\(row.id.uuidString.lowercased()) senderKind=\(row.sender_kind) conversationId=\(row.conversation_id.uuidString.lowercased())")
            await handleIncomingMessage(row)
        }

        isRealtimeConnected = false
        await service.removeRealtimeChannel(channel)
        if inboxRealtimeChannel === channel {
            inboxRealtimeChannel = nil
        }
        print("[SupportInboxRealtime] inbox stream ended channel=\(channel.topic)")
    }

    private func runThreadRealtimeSubscription(conversationId: UUID) async {
        let (channel, stream) = service.supportThreadInsertChannel(conversationId: conversationId)
        threadRealtimeChannel = channel
        let cid = conversationId.uuidString.lowercased()
        print("[SupportInboxRealtime] thread subscribe start conversationId=\(cid)")

        do {
            try await service.subscribeChannelWithTimeout(channel)
            print("[SupportInboxRealtime] thread subscribe success conversationId=\(cid)")
        } catch {
            print("[SupportInboxRealtime] thread subscribe failed conversationId=\(cid) error=\(error.localizedDescription)")
            await service.removeRealtimeChannel(channel)
            if threadRealtimeChannel === channel {
                threadRealtimeChannel = nil
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
                continue
            }

            print("[SupportInboxRealtime] thread insert received id=\(row.id.uuidString.lowercased()) conversationId=\(cid)")
            await handleIncomingMessage(row)
        }

        await service.removeRealtimeChannel(channel)
        if threadRealtimeChannel === channel {
            threadRealtimeChannel = nil
        }
        print("[SupportInboxRealtime] thread stream ended conversationId=\(cid)")
    }

    private func handleIncomingMessage(_ row: SupportMessageRow) async {
        if let index = conversations.firstIndex(where: { $0.id == row.conversation_id }) {
            var updated = conversations
            let existing = updated[index]
            updated.remove(at: index)
            let patched = AdminSupportConversationRow(
                id: existing.id,
                user_id: existing.user_id,
                status: existing.status,
                subject: existing.subject,
                issue_type: existing.issue_type,
                chat_opened_at: row.isFromSupport ? (row.created_at ?? existing.chat_opened_at) : existing.chat_opened_at,
                last_message_at: row.created_at ?? existing.last_message_at,
                last_user_message_at: row.isFromSupport ? existing.last_user_message_at : (row.created_at ?? existing.last_user_message_at),
                last_support_message_at: row.isFromSupport ? (row.created_at ?? existing.last_support_message_at) : existing.last_support_message_at,
                created_at: existing.created_at,
                updated_at: row.created_at ?? existing.updated_at,
                last_message_body: row.body,
                last_message_sender_kind: row.sender_kind
            )
            updated.insert(patched, at: 0)
            conversations = updated
        } else {
            await refreshInbox()
        }

        guard selectedConversationId == row.conversation_id else { return }
        guard !messages.contains(where: { $0.id == row.id }) else { return }
        messages.append(row)
        messages.sort { lhs, rhs in
            let left = lhs.created_at ?? ""
            let right = rhs.created_at ?? ""
            if left == right { return lhs.id.uuidString < rhs.id.uuidString }
            return left < right
        }
        print("[SupportInboxRealtime] loaded message count=\(messages.count)")
    }
}

struct AdminSupportInboxView: View {
    @ObservedObject var viewModel: MapViewModel
    @StateObject private var presenter = AdminSupportInboxPresenter()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationSplitView {
            inboxList
                .navigationTitle("Support Inbox")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            Task { await dismissInbox() }
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await presenter.refreshInbox(logRefreshTapped: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(presenter.isRefreshing)
                    }
                }
        } detail: {
            threadPane
        }
        .onAppear {
            presenter.configure(adminEmail: viewModel.adminEmail)
            Task { await presenter.loadInbox() }
        }
        .onDisappear {
            Task { await presenter.stopAllRealtimeAndPolling() }
        }
        .onChange(of: viewModel.adminEmail) { _, email in
            presenter.configure(adminEmail: email)
        }
    }

    private func dismissInbox() async {
        await presenter.stopAllRealtimeAndPolling()
        dismiss()
    }

    private var inboxList: some View {
        Group {
            if presenter.isLoadingList && presenter.conversations.isEmpty {
                ProgressView("Loading support inbox…")
            } else if presenter.conversations.isEmpty {
                ContentUnavailableView(
                    "No support conversations",
                    systemImage: "tray",
                    description: Text("User messages will appear here.")
                )
            } else {
                List(presenter.conversations) { row in
                    Button {
                        Task { await presenter.selectConversation(row.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.subject?.isEmpty == false ? row.subject! : "User \(row.user_id.uuidString.prefix(8))")
                                .font(.subheadline.weight(.bold))
                                .lineLimit(1)
                            Text(row.issueTypeTitle)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(row.last_message_body ?? "No messages yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            if !row.isChatOpen {
                                Text("Awaiting admin review")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .refreshable {
                    await presenter.refreshInbox(logRefreshTapped: true)
                }
            }
        }
    }

    @ViewBuilder
    private var threadPane: some View {
        if let cid = presenter.selectedConversationId {
            VStack(spacing: 0) {
                if let ticket = presenter.selectedConversation {
                    adminTicketHeader(ticket)
                }

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(presenter.messages) { row in
                            adminMessageBubble(row)
                        }
                    }
                    .padding()
                }

                HStack(spacing: 8) {
                    TextField("Reply as FanGeo Support", text: $presenter.draft, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        Task { await presenter.sendDraft() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(!presenter.canSend)
                }
                .padding()
            }
            .navigationTitle("Conversation")
            .navigationSubtitle(cid.uuidString.prefix(8).uppercased())
            .task(id: cid) {
                await presenter.loadThread(conversationId: cid)
            }
        } else {
            ContentUnavailableView(
                "Select a conversation",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Choose a support thread from the inbox.")
            )
        }
    }

    @ViewBuilder
    private func adminTicketHeader(_ ticket: AdminSupportConversationRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let subject = ticket.subject, !subject.isEmpty {
                Text(subject)
                    .font(.headline.weight(.bold))
            }
            Text(ticket.issueTypeTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if !ticket.isChatOpen {
                    Button("Open Chat") {
                        Task { await presenter.openChat(for: ticket.id) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                if ticket.isChatOpen {
                    Label("Chat open for user", systemImage: "bubble.left.and.bubble.right.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
    }

    @ViewBuilder
    private func adminMessageBubble(_ row: SupportMessageRow) -> some View {
        let isSupport = row.isFromSupport
        HStack {
            if isSupport { Spacer(minLength: 40) }
            VStack(alignment: isSupport ? .trailing : .leading, spacing: 4) {
                Text(isSupport ? "FanGeo Support" : "User")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(row.body)
                    .font(.body)
                    .padding(10)
                    .background(isSupport ? Color.green.opacity(0.18) : Color.gray.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if !isSupport { Spacer(minLength: 40) }
        }
    }
}
