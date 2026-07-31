import SwiftUI

struct ShareFanProfileSheet: View {
    let profile: PublicUserProfileData
    @ObservedObject var mapViewModel: MapViewModel

    @EnvironmentObject private var chatViewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var selectedRecipientIds: Set<UUID> = []
    @State private var searchText = ""
    @State private var isSending = false
    @State private var errorText: String?

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var sharePayload: FanProfileSharePayload? {
        FanProfileShareMessage.payload(
            from: profile,
            sharedByDisplayName: mapViewModel.currentUserDisplayName,
            languageCode: languageCode
        )
    }

    /// Supported destinations: fan DMs, friend rows, groups, and business venue DMs (same direct_messages path).
    private var eligibleRecipients: [ChatViewModel.FriendDisplay] {
        let me = mapViewModel.currentUserAuthId
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return chatViewModel.friends
            .filter { friend in
                guard friend.id != me else { return false }
                if friend.inboxKind == .direct || (!friend.isConversationBacked && !friend.isGroupConversation) {
                    guard !chatViewModel.isEitherDirectionBlocked(with: friend.preview.id) else { return false }
                }
                guard query.isEmpty else {
                    let name = friend.preview.displayName.lowercased()
                    let handle = friend.preview.username?.lowercased() ?? ""
                    return name.contains(query) || handle.contains(query)
                }
                return true
            }
            .sorted { lhs, rhs in
                if lhs.isConversationBacked != rhs.isConversationBacked {
                    return lhs.isConversationBacked && !rhs.isConversationBacked
                }
                if let l = lhs.lastMessageAt, let r = rhs.lastMessageAt, l != r {
                    return l > r
                }
                return lhs.preview.displayName.localizedCaseInsensitiveCompare(rhs.preview.displayName) == .orderedAscending
            }
    }

    private var selectedRecipients: [ChatViewModel.FriendDisplay] {
        eligibleRecipients.filter { selectedRecipientIds.contains($0.id) }
    }

    private var canSend: Bool {
        !selectedRecipients.isEmpty && !isSending && sharePayload != nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    Section {
                        TextField(L10n.t("share_profile_search_friends", languageCode: languageCode), text: $searchText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Section {
                        if eligibleRecipients.isEmpty {
                            Text(L10n.t("share_profile_no_chats", languageCode: languageCode))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                        } else {
                            ForEach(eligibleRecipients) { friend in
                                shareRecipientRow(friend)
                            }
                        }
                    } header: {
                        Text(L10n.t("share_profile_chats_friends", languageCode: languageCode))
                    } footer: {
                        Text(
                            String(
                                format: L10n.t("share_profile_selected_count_format", languageCode: languageCode),
                                selectedRecipientIds.count
                            )
                        )
                    }
                }
                .scrollContentBackground(.hidden)

                if let errorText, !errorText.isEmpty {
                    Text(errorText)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.dangerRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, FGSpacing.lg)
                        .padding(.vertical, FGSpacing.sm)
                }
            }
            .fanGeoScreenBackground()
            .navigationTitle(L10n.t("share_profile_sheet_title", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Close", languageCode: languageCode)) { dismiss() }
                        .disabled(isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await sendShare() }
                    } label: {
                        if isSending {
                            ProgressView()
                                .accessibilityLabel(L10n.t("share_profile_sharing", languageCode: languageCode))
                        } else {
                            Text(L10n.t("Send", languageCode: languageCode))
                        }
                    }
                    .disabled(!canSend)
                }
            }
            .task {
                await chatViewModel.loadIfNeeded()
            }
        }
    }

    private func shareRecipientRow(_ friend: ChatViewModel.FriendDisplay) -> some View {
        let isSelected = selectedRecipientIds.contains(friend.id)
        return Button {
            toggleSelection(friend.id)
        } label: {
            HStack(spacing: 12) {
                if friend.isGroupConversation {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(FGColor.accentGreen)
                        .frame(width: 40, height: 40)
                        .background(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.18 : 0.10), in: Circle())
                } else {
                    ProfileAvatarView(preview: friend.preview, size: 40)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.preview.displayName)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                    if friend.isGroupConversation {
                        if friend.groupMemberCount > 0 {
                            Text(groupChatLocalizedMemberCount(friend.groupMemberCount, languageCode: languageCode))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                        }
                    } else if let handle = friend.preview.username?.trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty {
                        Text("@\(handle)")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    } else if let subtitle = friend.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isSelected ? FGColor.accentGreen : FGColor.secondaryText(colorScheme).opacity(0.55))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSending)
    }

    private func toggleSelection(_ friendId: UUID) {
        if selectedRecipientIds.contains(friendId) {
            selectedRecipientIds.remove(friendId)
        } else {
            selectedRecipientIds.insert(friendId)
        }
    }

    private func sendShare() async {
        guard !isSending else { return }
        guard let payload = sharePayload else {
            await MainActor.run { errorText = L10n.t("share_profile_unavailable", languageCode: languageCode) }
            return
        }

        let recipients = selectedRecipients
        guard !recipients.isEmpty else {
            await MainActor.run { errorText = L10n.t("share_profile_choose_recipient", languageCode: languageCode) }
            return
        }

        let body = FanProfileShareMessage.encodeBody(payload: payload)
        // Match DirectChat composer limit so shared cards remain renderable in DM threads.
        guard body.count <= 1000 else {
#if DEBUG
            print("[ProfileShareDebug] payloadTooLarge bytes=\(body.count)")
#endif
            await MainActor.run { errorText = L10n.t("share_profile_payload_too_large", languageCode: languageCode) }
            return
        }

#if DEBUG
        print("[ProfileShareDebug] sourceDisplayName=\(profile.displayName)")
        print("[ProfileShareDebug] sourceUserId=\(profile.userId.uuidString.lowercased())")
        print("[ProfileShareDebug] sourceHandle=\(FanProfileShareMessage.sanitizedPublicHandle(profile.publicHandleLine) ?? "nil")")
        print("[ProfileShareDebug] recipientCount=\(recipients.count) kinds=\(recipients.map(\.inboxKind.rawValue))")
        for recipient in recipients {
            print(
                "[ProfileShareDebug] recipient displayId=\(recipient.id.uuidString.lowercased()) peer=\(recipient.preview.id.uuidString.lowercased()) conversationId=\(recipient.conversationId?.uuidString.lowercased() ?? "nil") kind=\(recipient.inboxKind.rawValue)"
            )
        }
#endif

        await MainActor.run {
            isSending = true
            errorText = nil
        }
        defer {
            Task { @MainActor in isSending = false }
        }

        if let err = await chatViewModel.shareFanProfileMessage(
            body: body,
            toRecipients: recipients
        ) {
            await MainActor.run { errorText = err }
            return
        }

        await MainActor.run {
            mapViewModel.showSocialActionToast(L10n.t("share_profile_success", languageCode: languageCode), isError: false)
            dismiss()
        }
    }
}
