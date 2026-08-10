import SwiftUI

/// Native-style Chat inbox search field (global conversations + messages).
/// Focus is owned by the parent so List/header rebuilds cannot destroy `@FocusState`.
struct ChatInboxGlobalSearchBar: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    /// Search mode stays true after Done / interactive keyboard dismiss until Cancel.
    let isSearchModeActive: Bool
    let isSearching: Bool
    let isRefreshingInbox: Bool
    let languageCode: String
    let colorScheme: ColorScheme
    var onCancel: (() -> Void)?

    private var showsCancel: Bool {
        isSearchModeActive || isFocused.wrappedValue || !text.isEmpty
    }

    var body: some View {
        HStack(spacing: FGSpacing.sm) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .accessibilityHidden(true)

                TextField(
                    L10n.t("chat_global_search_placeholder", languageCode: languageCode),
                    text: $text
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline)
                .focused(isFocused)
                .submitLabel(.search)
                .accessibilityLabel(L10n.t("chat_global_search_placeholder", languageCode: languageCode))
                // Only while THIS field is focused. An always-registered `.keyboard` toolbar
                // can leak into Team Detail Chat sheets (floating "Done" over the composer).
                .toolbar {
                    if isFocused.wrappedValue {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button(L10n.t("done", languageCode: languageCode)) {
                                // Dismiss keyboard only — keep query, results, and search mode.
                                isFocused.wrappedValue = false
                            }
                            .fontWeight(.semibold)
                        }
                    }
                }

                // Reserve trailing chrome so spinner/clear swaps do not resize the field.
                ZStack {
                    if isSearching || isRefreshingInbox {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityLabel(L10n.t("chat_global_search_searching_a11y", languageCode: languageCode))
                    } else if !text.isEmpty {
                        Button {
                            text = ""
                            // Keep focus / search mode so the user can continue typing.
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.t("chat_global_search_clear_a11y", languageCode: languageCode))
                    }
                }
                .frame(width: 28, height: 28)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.94))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme).opacity(0.5), lineWidth: 1)
            }

            if showsCancel {
                Button(L10n.t("chat_global_search_cancel", languageCode: languageCode)) {
                    text = ""
                    isFocused.wrappedValue = false
                    onCancel?()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FGColor.accentBlue)
                .accessibilityLabel(L10n.t("chat_global_search_close_a11y", languageCode: languageCode))
                .transition(.opacity)
            }
        }
        // Avoid layout animation that can dismiss the keyboard when Cancel appears.
        .animation(nil, value: showsCancel)
        .animation(nil, value: isSearching)
        .animation(nil, value: isRefreshingInbox)
        .accessibilityElement(children: .contain)
    }
}

struct ChatGlobalSearchMessageResultRow: View {
    let hit: ChatGlobalSearchMessageHit
    let languageCode: String
    let colorScheme: ColorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            messageRowAvatar

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(resolvedConversationTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(ChatInboxTimestampFormatting.label(for: hit.createdAt, languageCode: languageCode))
                        .font(.caption2)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                Text(hit.safePreview)
                    .font(.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(resolvedConversationTitle). \(hit.safePreview)")
    }

    private var resolvedConversationTitle: String {
        guard hit.kind == .team else { return hit.conversationTitle }
        let teamName = FanTeamIdentityRealtimeCoordinator.shared.markSnapshot(
            teamId: FanTeamIdentityRealtimeCoordinator.shared.teamId(
                forConversationId: hit.conversationId
            ),
            conversationId: hit.conversationId
        )?.name
        return ChatInboxFanTeamRowIdentity.preferredTitle(
            teamName: teamName,
            fallbackConversationTitle: hit.conversationTitle
        )
    }

    @ViewBuilder
    private var messageRowAvatar: some View {
        if hit.kind == .team {
            ChatInboxFanTeamConversationAvatar(
                teamId: FanTeamIdentityRealtimeCoordinator.shared.teamId(
                    forConversationId: hit.conversationId
                ),
                conversationId: hit.conversationId,
                size: 36,
                languageCode: languageCode
            )
        } else {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(FGColor.accentBlue)
                .frame(width: 36, height: 36)
                .background(FGColor.cardBackground(colorScheme))
                .clipShape(Circle())
        }
    }

    private var iconName: String {
        switch hit.kind {
        case .direct: return "person.fill"
        case .business: return "building.2.fill"
        case .group: return "person.3.fill"
        case .team: return "shield.fill"
        case .pickup: return "figure.run"
        }
    }
}

/// In-conversation message search sheet (scoped to one thread).
struct ChatConversationSearchSheet: View {
    let conversationId: UUID
    let languageCode: String
    var onSelectMessage: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var query: String = ""
    @State private var hits: [ChatGlobalSearchMessageHit] = []
    @State private var isLoading = false
    @State private var searchTask: Task<Void, Never>?
    private let searchService = ChatGlobalSearchController()

    var body: some View {
        NavigationStack {
            List {
                if hits.isEmpty, ChatGlobalSearchLocalMatcher.normalize(query).count >= 2, !isLoading {
                    Text(L10n.t("chat_global_search_empty", languageCode: languageCode))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(hits) { hit in
                        Button {
                            onSelectMessage(hit.messageId)
                            dismiss()
                        } label: {
                            ChatGlobalSearchMessageResultRow(
                                hit: hit,
                                languageCode: languageCode,
                                colorScheme: colorScheme
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.plain)
            .searchable(
                text: $query,
                prompt: L10n.t("chat_conversation_search_placeholder", languageCode: languageCode)
            )
            .navigationTitle(L10n.t("chat_conversation_search_title", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("chat_global_search_cancel", languageCode: languageCode)) {
                        dismiss()
                    }
                }
            }
            .onChange(of: query) { _, newValue in
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    await refreshHits(newValue)
                }
            }
        }
    }

    @MainActor
    private func refreshHits(_ raw: String) async {
        let q = ChatGlobalSearchLocalMatcher.normalize(raw)
        guard q.count >= 2 else {
            hits = []
            isLoading = false
            return
        }
        isLoading = true
        hits = await searchService.searchMessagesInConversation(query: raw, conversationId: conversationId)
        isLoading = false
    }
}
