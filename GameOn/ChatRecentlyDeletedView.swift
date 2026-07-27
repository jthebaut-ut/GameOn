import SwiftUI

/// Chat → overflow → Recently Deleted. Lists per-user soft-deleted conversations.
struct ChatRecentlyDeletedView: View {
    @ObservedObject var chatViewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var rows: [RecentlyDeletedChatConversationRow] = []
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var actionError: String?
    @State private var permanentDeleteTarget: RecentlyDeletedChatConversationRow?
    @State private var busyConversationIds: Set<UUID> = []

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    var body: some View {
        Group {
            if isLoading && rows.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                emptyState
            } else {
                listContent
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(L10n.t("chat_recently_deleted_title", languageCode: languageCode))
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            L10n.t("chat_recently_deleted_permanent_confirm_title", languageCode: languageCode),
            isPresented: Binding(
                get: { permanentDeleteTarget != nil },
                set: { if !$0 { permanentDeleteTarget = nil } }
            )
        ) {
            Button(
                L10n.t("chat_recently_deleted_delete_permanently", languageCode: languageCode),
                role: .destructive
            ) {
                if let target = permanentDeleteTarget {
                    Task { await permanentlyDelete(target) }
                }
            }
            Button(L10n.t("chat_recently_deleted_cancel", languageCode: languageCode), role: .cancel) {
                permanentDeleteTarget = nil
            }
        } message: {
            Text(L10n.t("chat_recently_deleted_permanent_confirm_message", languageCode: languageCode))
        }
        .alert(
            "FanGeo",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button(L10n.t("chat_recently_deleted_cancel", languageCode: languageCode), role: .cancel) {
                actionError = nil
            }
        } message: {
            Text(actionError ?? "")
        }
        .task {
            await reload()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "trash")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
            Text(L10n.t("chat_recently_deleted_empty_title", languageCode: languageCode))
                .font(.headline.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)
            Text(L10n.t("chat_recently_deleted_empty_body", languageCode: languageCode))
                .font(.subheadline)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            if loadFailed {
                Button(L10n.t("group_chat_refresh_a11y", languageCode: languageCode)) {
                    Task { await reload() }
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var listContent: some View {
        List {
            Section {
                Text(L10n.t("chat_recently_deleted_banner", languageCode: languageCode))
                    .font(.footnote)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .listRowBackground(Color.clear)
                    .accessibilityLabel(L10n.t("chat_recently_deleted_banner", languageCode: languageCode))
            }

            Section {
                ForEach(rows) { row in
                    RecentlyDeletedChatRow(
                        row: row,
                        languageCode: languageCode,
                        colorScheme: colorScheme,
                        isBusy: busyConversationIds.contains(row.conversation_id),
                        onRestore: { Task { await restore(row) } },
                        onDeletePermanently: { permanentDeleteTarget = row }
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await reload() }
    }

    private func reload() async {
        isLoading = true
        loadFailed = false
        defer { isLoading = false }
        do {
            rows = try await chatViewModel.fetchRecentlyDeletedConversations()
        } catch {
            loadFailed = true
            rows = []
            actionError = error.localizedDescription
        }
    }

    private func restore(_ row: RecentlyDeletedChatConversationRow) async {
        guard !busyConversationIds.contains(row.conversation_id) else { return }
        busyConversationIds.insert(row.conversation_id)
        defer { busyConversationIds.remove(row.conversation_id) }
        do {
            try await chatViewModel.restoreRecentlyDeletedConversation(row)
            rows.removeAll { $0.id == row.id }
            await chatViewModel.refreshInboxSummaries()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func permanentlyDelete(_ row: RecentlyDeletedChatConversationRow) async {
        permanentDeleteTarget = nil
        guard !busyConversationIds.contains(row.conversation_id) else { return }
        busyConversationIds.insert(row.conversation_id)
        defer { busyConversationIds.remove(row.conversation_id) }
        do {
            try await chatViewModel.permanentlyDeleteRecentlyDeletedConversation(row)
            rows.removeAll { $0.id == row.id }
        } catch {
            actionError = error.localizedDescription
        }
    }
}

private struct RecentlyDeletedChatRow: View {
    let row: RecentlyDeletedChatConversationRow
    let languageCode: String
    let colorScheme: ColorScheme
    let isBusy: Bool
    let onRestore: () -> Void
    let onDeletePermanently: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                avatar
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(row.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                             ?? L10n.t("chat_recently_deleted_title", languageCode: languageCode))
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(1)
                        typeBadge
                    }
                    Text(deletedDateText)
                        .font(.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .accessibilityLabel(deletedDateText)
                    Text(daysRemainingText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .accessibilityLabel(daysRemainingText)
                    if let preview = row.last_message_body?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !preview.isEmpty {
                        Text(preview)
                            .font(.subheadline)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button(action: onRestore) {
                    Text(L10n.t("chat_recently_deleted_restore", languageCode: languageCode))
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .foregroundStyle(FGColor.accentGreen)
                .background(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(isBusy)
                .accessibilityLabel(L10n.t("chat_recently_deleted_restore", languageCode: languageCode))
                .accessibilityHint(L10n.t("chat_recently_deleted_restore_a11y_hint", languageCode: languageCode))

                Button(role: .destructive, action: onDeletePermanently) {
                    Text(L10n.t("chat_recently_deleted_delete_permanently", languageCode: languageCode))
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.red)
                .background(Color.red.opacity(colorScheme == .dark ? 0.18 : 0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(isBusy)
                .accessibilityLabel(L10n.t("chat_recently_deleted_delete_permanently", languageCode: languageCode))
                .accessibilityHint(L10n.t("chat_recently_deleted_delete_permanently_a11y_hint", languageCode: languageCode))
            }
        }
        .padding(14)
        .background(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.96))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.55), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(rowAccessibilityLabel)
    }

    private var avatar: some View {
        Group {
            if row.kind == .group {
                ZStack {
                    Circle()
                        .fill(FGColor.accentGreen.opacity(0.18))
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(FGColor.accentGreen)
                }
            } else {
                let preview = UserPreview(
                    id: row.peer_user_id ?? row.conversation_id,
                    displayName: row.title ?? "?",
                    username: nil,
                    email: nil,
                    avatarURL: row.peer_avatar_url,
                    avatarThumbnailURL: row.peer_avatar_thumbnail_url
                )
                SocialAvatarRenderer.socialAvatarView(for: preview, size: 48)
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                    }
            }
        }
        .frame(width: 48, height: 48)
        .accessibilityHidden(true)
    }

    private var typeBadge: some View {
        let label: String = {
            switch row.kind {
            case .group:
                return L10n.t("chat_recently_deleted_type_group", languageCode: languageCode)
            case .business:
                return L10n.t("chat_recently_deleted_type_watch_spot", languageCode: languageCode)
            case .direct:
                return L10n.t("chat_recently_deleted_type_direct", languageCode: languageCode)
            }
        }()
        return Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(FGColor.primaryText(colorScheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(FGColor.divider(colorScheme).opacity(0.35), in: Capsule())
            .accessibilityLabel(label)
    }

    private var deletedDateText: String {
        guard let date = ChatRecentlyDeletedFormatting.parseISO8601(row.deleted_at) else {
            return L10n.t("chat_recently_deleted_deleted_today", languageCode: languageCode)
        }
        return ChatRecentlyDeletedFormatting.deletedRelativeLabel(deletedAt: date, languageCode: languageCode)
    }

    private var daysRemainingText: String {
        let days = max(0, row.days_remaining ?? 0)
        return String(
            format: L10n.t("chat_recently_deleted_days_remaining_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            days
        )
    }

    private var rowAccessibilityLabel: String {
        let title = row.title ?? ""
        return "\(title). \(typeBadgeLabel). \(deletedDateText). \(daysRemainingText)"
    }

    private var typeBadgeLabel: String {
        switch row.kind {
        case .group:
            return L10n.t("chat_recently_deleted_type_group", languageCode: languageCode)
        case .business:
            return L10n.t("chat_recently_deleted_type_watch_spot", languageCode: languageCode)
        case .direct:
            return L10n.t("chat_recently_deleted_type_direct", languageCode: languageCode)
        }
    }
}

enum ChatRecentlyDeletedFormatting {
    static func parseISO8601(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: trimmed) { return date }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: trimmed)
    }

    static func deletedRelativeLabel(deletedAt: Date, languageCode: String, now: Date = Date()) -> String {
        let cal = Calendar.current
        let startDeleted = cal.startOfDay(for: deletedAt)
        let startNow = cal.startOfDay(for: now)
        let days = cal.dateComponents([.day], from: startDeleted, to: startNow).day ?? 0
        if days <= 0 {
            return L10n.t("chat_recently_deleted_deleted_today", languageCode: languageCode)
        }
        if days == 1 {
            return L10n.t("chat_recently_deleted_deleted_yesterday", languageCode: languageCode)
        }
        return String(
            format: L10n.t("chat_recently_deleted_deleted_days_ago_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            days
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
