import Combine
import Foundation
import Supabase

struct ChatGlobalSearchConversationRPCRow: Decodable, Sendable {
    let conversation_id: UUID
    let conversation_kind: String
    let title: String
    let subtitle: String?
    let peer_user_id: UUID?
    let pickup_game_id: UUID?
    let avatar_url: String?
    let avatar_thumbnail_url: String?
    let unread_count: Int?
    let last_message_at: String?
}

struct ChatGlobalSearchMessageRPCRow: Decodable, Sendable {
    let message_id: UUID
    let conversation_id: UUID
    let conversation_kind: String
    let conversation_title: String
    let peer_user_id: UUID?
    let pickup_game_id: UUID?
    let sender_id: UUID
    let created_at: String?
    let safe_preview: String
}

/// Local + server chat inbox search. Does not load full histories into memory.
@MainActor
final class ChatGlobalSearchController: ObservableObject {
    @Published private(set) var snapshot = ChatGlobalSearchSnapshot()
    @Published var query: String = "" {
        didSet { scheduleSearch() }
    }

    private let client: SupabaseClient
    private var searchGeneration = 0
    private var debounceTask: Task<Void, Never>?
    private var activeAccountId: UUID?
    private var latestInbox: [ChatViewModel.FriendDisplay] = []
    private var activeFilter: ChatInboxTypeFilter = .all
    private var languageCode: String = L10n.defaultLanguageCode

    init(client: SupabaseClient? = nil) {
        self.client = client ?? supabase
    }

    func bind(
        accountId: UUID?,
        inbox: [ChatViewModel.FriendDisplay],
        filter: ChatInboxTypeFilter,
        languageCode: String
    ) {
        let accountChanged = activeAccountId != accountId
        activeAccountId = accountId
        latestInbox = inbox
        activeFilter = filter
        self.languageCode = languageCode
        if accountChanged {
            clear(reason: "accountChanged")
            return
        }
        // Re-run local merge when inbox/filter changes while a query is active.
        if ChatGlobalSearchLocalMatcher.normalize(query).count >= 2 {
            scheduleSearch(immediate: true)
        }
    }

    func clear(reason: String) {
        _ = reason
        debounceTask?.cancel()
        searchGeneration &+= 1
        query = ""
        snapshot = ChatGlobalSearchSnapshot()
    }

    /// Patch active search hits when a peer (or self) avatar URL changes — no RPC re-query.
    func applyFanProfileAvatarChange(_ change: FanProfileAvatarChange) {
        let userId = change.userId
        let nextFull = change.avatarURL.isEmpty ? nil : change.avatarURL
        let nextThumb = change.avatarThumbnailURL
        guard !snapshot.conversations.isEmpty || !latestInbox.isEmpty else { return }

        latestInbox = latestInbox.map { row in
            guard !row.isGroupConversation, row.preview.id == userId else { return row }
            return ChatViewModel.FriendDisplay(
                id: row.id,
                preview: row.preview.replacingAvatars(
                    avatarURL: nextFull ?? row.preview.avatarURL,
                    avatarThumbnailURL: nextThumb ?? row.preview.avatarThumbnailURL
                ),
                subtitle: row.subtitle,
                lastMessageAt: row.lastMessageAt,
                unreadCount: row.unreadCount,
                isConversationBacked: row.isConversationBacked,
                conversationId: row.conversationId,
                inboxKind: row.inboxKind,
                groupMemberCount: row.groupMemberCount,
                isGroupMuted: row.isGroupMuted,
                pickupGameId: row.pickupGameId,
                fanTeamId: row.fanTeamId
            )
        }

        guard !snapshot.conversations.isEmpty else { return }
        let nextConversations = snapshot.conversations.map { hit -> ChatGlobalSearchConversationHit in
            guard hit.peerUserId == userId else { return hit }
            return ChatGlobalSearchConversationHit(
                conversationId: hit.conversationId,
                kind: hit.kind,
                title: hit.title,
                subtitle: hit.subtitle,
                peerUserId: hit.peerUserId,
                pickupGameId: hit.pickupGameId,
                avatarURL: nextFull ?? hit.avatarURL,
                avatarThumbnailURL: nextThumb ?? hit.avatarThumbnailURL,
                unreadCount: hit.unreadCount,
                lastMessageAt: hit.lastMessageAt,
                matchedInboxFriend: hit.matchedInboxFriend.map { row in
                    guard row.preview.id == userId else { return row }
                    return ChatViewModel.FriendDisplay(
                        id: row.id,
                        preview: row.preview.replacingAvatars(
                            avatarURL: nextFull ?? row.preview.avatarURL,
                            avatarThumbnailURL: nextThumb ?? row.preview.avatarThumbnailURL
                        ),
                        subtitle: row.subtitle,
                        lastMessageAt: row.lastMessageAt,
                        unreadCount: row.unreadCount,
                        isConversationBacked: row.isConversationBacked,
                        conversationId: row.conversationId,
                        inboxKind: row.inboxKind,
                        groupMemberCount: row.groupMemberCount,
                        isGroupMuted: row.isGroupMuted,
                        pickupGameId: row.pickupGameId,
                        fanTeamId: row.fanTeamId
                    )
                }
            )
        }
        if nextConversations != snapshot.conversations {
            var next = snapshot
            next.conversations = nextConversations
            snapshot = next
        }
    }

    var isActive: Bool {
        ChatGlobalSearchLocalMatcher.normalize(query).count >= 2
    }

    private func scheduleSearch(immediate: Bool = false) {
        debounceTask?.cancel()
        let normalized = ChatGlobalSearchLocalMatcher.normalize(query)
        guard normalized.count >= 2 else {
            // Keep focus stable: only publish when leaving an active search, not on every 1-char keystroke.
            searchGeneration &+= 1
            let idle = ChatGlobalSearchSnapshot(query: query, isSearching: false, didSearch: false)
            if snapshot.didSearch || snapshot.isSearching || !snapshot.conversations.isEmpty || !snapshot.messages.isEmpty || snapshot.query != query {
                snapshot = idle
            }
            return
        }
        let generation = searchGeneration &+ 1
        searchGeneration = generation
        let delayNs: UInt64 = immediate ? 0 : 300_000_000
        let inbox = latestInbox
        let filter = activeFilter
        let accountId = activeAccountId
        let q = query
        debounceTask = Task { [weak self] in
            if delayNs > 0 {
                try? await Task.sleep(nanoseconds: delayNs)
            }
            guard let self, !Task.isCancelled else { return }
            guard self.searchGeneration == generation else { return }
            await self.runSearch(
                generation: generation,
                rawQuery: q,
                inbox: inbox,
                filter: filter,
                accountId: accountId
            )
        }
    }

    private func runSearch(
        generation: Int,
        rawQuery: String,
        inbox: [ChatViewModel.FriendDisplay],
        filter: ChatInboxTypeFilter,
        accountId: UUID?
    ) async {
        guard activeAccountId == accountId else { return }
        var next = ChatGlobalSearchSnapshot(
            query: rawQuery,
            conversations: ChatGlobalSearchLocalMatcher.conversationHits(
                from: inbox,
                query: rawQuery,
                filter: filter
            ),
            messages: [],
            isSearching: true,
            didSearch: true
        )
        snapshot = next

        async let serverConversations = fetchServerConversations(query: rawQuery, inbox: inbox)
        async let serverMessages = fetchServerMessages(query: rawQuery, conversationId: nil, inbox: inbox)

        let remoteConversations = (try? await serverConversations) ?? []
        let remoteMessages = (try? await serverMessages) ?? []
        guard searchGeneration == generation, activeAccountId == accountId else { return }

        next.conversations = Self.mergeConversations(
            local: next.conversations,
            remote: remoteConversations,
            inbox: inbox,
            filter: filter
        )
        next.messages = remoteMessages.filter { hit in
            hit.kind.matches(filter: filter == .unread ? .all : filter)
                || (filter == .unread && (next.conversations.first(where: { $0.conversationId == hit.conversationId })?.unreadCount ?? 0) > 0)
        }
        // Unread chip: keep message hits whose conversation is unread in inbox when possible.
        if filter == .unread {
            let unreadIds = Set(
                inbox.filter { $0.unreadCount > 0 }.compactMap { $0.conversationId ?? $0.id }
            )
            next.messages = next.messages.filter { unreadIds.contains($0.conversationId) }
        }
        next.isSearching = false
        snapshot = next
    }

    /// In-conversation scoped search (same RPC, conversation filter).
    func searchMessagesInConversation(
        query: String,
        conversationId: UUID
    ) async -> [ChatGlobalSearchMessageHit] {
        let normalized = ChatGlobalSearchLocalMatcher.normalize(query)
        guard normalized.count >= 2 else { return [] }
        return (try? await fetchServerMessages(
            query: query,
            conversationId: conversationId,
            inbox: latestInbox
        )) ?? []
    }

    private func fetchServerConversations(
        query: String,
        inbox: [ChatViewModel.FriendDisplay]
    ) async throws -> [ChatGlobalSearchConversationHit] {
        struct Params: Encodable {
            let p_query: String
            let p_limit: Int
        }
        let rows: [ChatGlobalSearchConversationRPCRow] = try await client
            .rpc("search_chat_conversations", params: Params(p_query: query, p_limit: 25))
            .execute()
            .value
        return rows.compactMap { row in
            guard let rawKind = ChatGlobalSearchConversationKind(rawValue: row.conversation_kind) else { return nil }
            let kind = ChatGlobalSearchConversationKind.resolve(
                raw: rawKind,
                conversationId: row.conversation_id,
                pickupGameId: row.pickup_game_id,
                inbox: inbox
            )
            let title: String = {
                guard kind == .team else { return row.title }
                let teamName = FanTeamIdentityRealtimeCoordinator.shared.markSnapshot(
                    teamId: FanTeamIdentityRealtimeCoordinator.shared.teamId(
                        forConversationId: row.conversation_id
                    ),
                    conversationId: row.conversation_id
                )?.name
                return ChatInboxFanTeamRowIdentity.preferredTitle(
                    teamName: teamName,
                    fallbackConversationTitle: row.title
                )
            }()
            return ChatGlobalSearchConversationHit(
                conversationId: row.conversation_id,
                kind: kind,
                title: title,
                subtitle: row.subtitle ?? "",
                peerUserId: row.peer_user_id,
                pickupGameId: row.pickup_game_id,
                avatarURL: row.avatar_url,
                avatarThumbnailURL: row.avatar_thumbnail_url,
                unreadCount: row.unread_count ?? 0,
                lastMessageAt: SupabaseTimestampParsing.parseTimestamptz(row.last_message_at ?? ""),
                matchedInboxFriend: nil
            )
        }
    }

    private func fetchServerMessages(
        query: String,
        conversationId: UUID?,
        inbox: [ChatViewModel.FriendDisplay]
    ) async throws -> [ChatGlobalSearchMessageHit] {
        struct Params: Encodable {
            let p_query: String
            let p_conversation_id: UUID?
            let p_limit: Int

            enum CodingKeys: String, CodingKey {
                case p_query
                case p_conversation_id
                case p_limit
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(p_query, forKey: .p_query)
                try c.encode(p_limit, forKey: .p_limit)
                try c.encodeIfPresent(p_conversation_id, forKey: .p_conversation_id)
            }
        }
        let rows: [ChatGlobalSearchMessageRPCRow] = try await client
            .rpc(
                "search_chat_messages",
                params: Params(p_query: query, p_conversation_id: conversationId, p_limit: 40)
            )
            .execute()
            .value
        return rows.compactMap { row in
            guard let rawKind = ChatGlobalSearchConversationKind(rawValue: row.conversation_kind) else { return nil }
            let kind = ChatGlobalSearchConversationKind.resolve(
                raw: rawKind,
                conversationId: row.conversation_id,
                pickupGameId: row.pickup_game_id,
                inbox: inbox
            )
            let preview = row.safe_preview.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !preview.isEmpty else { return nil }
            // Re-run through client formatter for localization of known English server summaries.
            let localized = Self.localizeServerPreview(preview, languageCode: languageCode)
            let conversationTitle: String = {
                guard kind == .team else { return row.conversation_title }
                let teamName = FanTeamIdentityRealtimeCoordinator.shared.markSnapshot(
                    teamId: FanTeamIdentityRealtimeCoordinator.shared.teamId(
                        forConversationId: row.conversation_id
                    ),
                    conversationId: row.conversation_id
                )?.name
                return ChatInboxFanTeamRowIdentity.preferredTitle(
                    teamName: teamName,
                    fallbackConversationTitle: row.conversation_title
                )
            }()
            return ChatGlobalSearchMessageHit(
                messageId: row.message_id,
                conversationId: row.conversation_id,
                kind: kind,
                conversationTitle: conversationTitle,
                peerUserId: row.peer_user_id,
                pickupGameId: row.pickup_game_id,
                senderId: row.sender_id,
                createdAt: SupabaseTimestampParsing.parseTimestamptz(row.created_at ?? ""),
                safePreview: localized
            )
        }
    }

    private static func mergeConversations(
        local: [ChatGlobalSearchConversationHit],
        remote: [ChatGlobalSearchConversationHit],
        inbox: [ChatViewModel.FriendDisplay],
        filter: ChatInboxTypeFilter
    ) -> [ChatGlobalSearchConversationHit] {
        var byId: [UUID: ChatGlobalSearchConversationHit] = [:]
        for hit in local {
            byId[hit.conversationId] = hit
        }
        let inboxByConversationId: [UUID: ChatViewModel.FriendDisplay] = Dictionary(
            uniqueKeysWithValues: inbox.compactMap { row in
                let id = row.conversationId ?? row.id
                return (id, row)
            }
        )
        for hit in remote where hit.kind.matches(filter: filter == .unread ? .all : filter) {
            if filter == .unread {
                let unread = inboxByConversationId[hit.conversationId]?.unreadCount ?? hit.unreadCount
                if unread <= 0 { continue }
            }
            if var existing = byId[hit.conversationId] {
                // Prefer local FriendDisplay-backed row for richer avatar/unread.
                if existing.matchedInboxFriend == nil, let friend = inboxByConversationId[hit.conversationId] {
                    existing = ChatGlobalSearchConversationHit(
                        conversationId: existing.conversationId,
                        kind: existing.kind,
                        title: friend.preview.displayName,
                        subtitle: existing.subtitle,
                        peerUserId: existing.peerUserId,
                        pickupGameId: existing.pickupGameId ?? friend.pickupGameId,
                        avatarURL: friend.preview.avatarURL ?? existing.avatarURL,
                        avatarThumbnailURL: friend.preview.avatarThumbnailURL ?? existing.avatarThumbnailURL,
                        unreadCount: friend.unreadCount,
                        lastMessageAt: friend.lastMessageAt ?? existing.lastMessageAt,
                        matchedInboxFriend: friend
                    )
                    byId[hit.conversationId] = existing
                }
            } else {
                var merged = hit
                if let friend = inboxByConversationId[hit.conversationId] {
                    merged = ChatGlobalSearchConversationHit(
                        conversationId: hit.conversationId,
                        kind: hit.kind,
                        title: friend.preview.displayName,
                        subtitle: hit.subtitle.isEmpty ? (friend.subtitle ?? "") : hit.subtitle,
                        peerUserId: hit.peerUserId ?? (friend.isGroupConversation ? nil : friend.preview.id),
                        pickupGameId: hit.pickupGameId ?? friend.pickupGameId,
                        avatarURL: friend.preview.avatarURL ?? hit.avatarURL,
                        avatarThumbnailURL: friend.preview.avatarThumbnailURL ?? hit.avatarThumbnailURL,
                        unreadCount: friend.unreadCount,
                        lastMessageAt: friend.lastMessageAt ?? hit.lastMessageAt,
                        matchedInboxFriend: friend
                    )
                }
                byId[hit.conversationId] = merged
            }
        }
        return byId.values.sorted { lhs, rhs in
            let l = lhs.lastMessageAt ?? .distantPast
            let r = rhs.lastMessageAt ?? .distantPast
            if l != r { return l > r }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func localizeServerPreview(_ preview: String, languageCode: String) -> String {
        switch preview {
        case "Shared a location":
            return L10n.t("chat_reply_preview_shared_location", languageCode: languageCode)
        case "Started sharing live location":
            return L10n.t("chat_reply_preview_live_location", languageCode: languageCode)
        case "Is on the way":
            return L10n.t("chat_reply_preview_on_my_way", languageCode: languageCode)
        case "Arrived":
            return L10n.t("chat_reply_preview_arrived", languageCode: languageCode)
        case "Created a poll":
            return L10n.t("chat_reply_preview_poll", languageCode: languageCode)
        case "Shared a profile":
            return L10n.t("chat_reply_preview_profile", languageCode: languageCode)
        case "Shared a pickup game":
            return L10n.t("chat_reply_preview_pickup", languageCode: languageCode)
        case "Shared a professional game":
            return L10n.t("chat_reply_preview_pro_game", languageCode: languageCode)
        case "Shared a venue":
            return L10n.t("chat_reply_preview_venue", languageCode: languageCode)
        case "This message was unsent":
            return L10n.t("chat_reply_original_unsent", languageCode: languageCode)
        default:
            return preview
        }
    }
}
