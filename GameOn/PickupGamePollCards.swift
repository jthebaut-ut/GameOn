import Combine
import SwiftUI
import UIKit

// MARK: - Chat card

struct PickupGamePollChatCardView: View {
    let payload: PickupGamePollPayload
    let message: GroupMessageRow
    let isFromCurrentUser: Bool
    let showFriendAvatar: Bool
    let friendPreview: UserPreview
    let timestamp: String?
    let languageCode: String
    let memberPreviews: [UUID: UserPreview]
    let currentUserId: UUID?
    let isOrganizer: Bool
    var onReport: (() -> Void)? = nil
    var onHide: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var store = PickupGamePollStore.shared
    @State private var showVoters = false
    @State private var actionError: String?
    @State private var tick = Date()
    @State private var isVoting = false

    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var snapshot: PickupGamePollSnapshot? {
        store.snapshot(for: payload.pollId)
    }

    /// Prefer server snapshot question; body text is loading preview only until hydration.
    private var displayQuestion: String {
        if let snapshot, conversationMatches {
            return snapshot.question
        }
        if store.loadingPollIds.contains(payload.pollId) {
            return payload.question
        }
        if snapshot != nil, !conversationMatches {
            return L10n.t("pickup_poll_unavailable", languageCode: languageCode)
        }
        return payload.question
    }

    private var conversationMatches: Bool {
        guard let snapshot else { return true }
        if snapshot.conversationId != message.conversation_id { return false }
        if let attached = snapshot.messageId, attached != message.id { return false }
        return true
    }

    private var closed: Bool {
        if let snapshot { return snapshot.isClosed || snapshot.isSoftDeleted }
        if let raw = payload.closesAt,
           let date = ISO8601DateFormatter.pickupPoll.date(from: raw) ?? ISO8601DateFormatter().date(from: raw),
           date <= Date() {
            return true
        }
        return false
    }

    private var canVote: Bool {
        guard currentUserId != nil else { return false }
        guard conversationMatches else { return false }
        guard let snapshot else { return false }
        return !snapshot.isClosed && !snapshot.isSoftDeleted
    }

    var body: some View {
        pollCardChrome(isFromCurrentUser: isFromCurrentUser, showFriendAvatar: showFriendAvatar, friendPreview: friendPreview, timestamp: timestamp) {
            VStack(alignment: .leading, spacing: 12) {
                headerRow
                Text(displayQuestion)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                if let snapshot, conversationMatches {
                    optionsList(snapshot)
                    footerRow(snapshot)
                } else if store.loadingPollIds.contains(payload.pollId) {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .accessibilityLabel(L10n.t("pickup_poll_loading", languageCode: languageCode))
                } else {
                    Text(L10n.t("pickup_poll_unavailable", languageCode: languageCode))
                        .font(.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }

                if let actionError {
                    Text(actionError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .contextMenu {
            if !isFromCurrentUser {
                Button(role: .destructive) {
                    onReport?()
                } label: {
                    Label(L10n.t("pickup_poll_report", languageCode: languageCode), systemImage: "flag")
                }
            }
            Button {
                onHide?()
            } label: {
                Label(L10n.t("pickup_poll_hide", languageCode: languageCode), systemImage: "eye.slash")
            }
            if isOrganizer || snapshot?.viewerIsOrganizer == true {
                Divider()
                if !closed {
                    Button {
                        Task { await closePoll() }
                    } label: {
                        Label(L10n.t("pickup_poll_close", languageCode: languageCode), systemImage: "xmark.circle")
                    }
                }
                Button {
                    Task { await pinPoll() }
                } label: {
                    Label(
                        snapshot?.isPinned == true
                            ? L10n.t("pickup_poll_unpin", languageCode: languageCode)
                            : L10n.t("pickup_poll_pin", languageCode: languageCode),
                        systemImage: "pin"
                    )
                }
                Button(role: .destructive) {
                    Task { await deletePoll() }
                } label: {
                    Label(L10n.t("pickup_poll_delete", languageCode: languageCode), systemImage: "trash")
                }
            }
        }
        .onAppear {
            store.ensureLoaded(payload.pollId)
        }
        .onReceive(ticker) { tick = $0 }
        .sheet(isPresented: $showVoters) {
            if let snapshot, !snapshot.isAnonymous {
                PickupGamePollVotersSheet(
                    snapshot: snapshot,
                    memberPreviews: memberPreviews,
                    languageCode: languageCode
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(PickupGamePollMessage.previewLine(for: payload, languageCode: languageCode))
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.fill")
                .foregroundStyle(FGColor.accentBlue)
                .accessibilityHidden(true)
            Text(L10n.t("pickup_poll_badge", languageCode: languageCode))
                .font(.caption.weight(.bold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
            Spacer(minLength: 0)
            if closed {
                Text(
                    snapshot?.isSoftDeleted == true
                        ? L10n.t("pickup_poll_deleted_badge", languageCode: languageCode)
                        : L10n.t("pickup_poll_closed_badge", languageCode: languageCode)
                )
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        FGColor.secondaryText(colorScheme).opacity(colorScheme == .dark ? 0.22 : 0.12),
                        in: Capsule()
                    )
            }
        }
    }

    @ViewBuilder
    private func optionsList(_ snapshot: PickupGamePollSnapshot) -> some View {
        VStack(spacing: 8) {
            ForEach(snapshot.options) { option in
                pollOptionRow(option: option, snapshot: snapshot)
            }
        }
    }

    private func pollOptionRow(option: PickupGamePollOptionSnapshot, snapshot: PickupGamePollSnapshot) -> some View {
        let selected = snapshot.mySelectedOptionIds.contains(option.id)
        let totalOptionVotes = max(1, snapshot.options.map(\.voteCount).reduce(0, +))
        let progress = Double(option.voteCount) / Double(totalOptionVotes)

        return Button {
            Task { await toggleVote(optionId: option.id, snapshot: snapshot) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: selected
                          ? (snapshot.allowMultiple ? "checkmark.square.fill" : "checkmark.circle.fill")
                          : (snapshot.allowMultiple ? "square" : "circle"))
                        .foregroundStyle(selected ? FGColor.accentGreen : FGColor.secondaryText(colorScheme))
                        .frame(width: 22)
                        .accessibilityHidden(true)

                    Text(option.text)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("\(option.voteCount)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .accessibilityLabel(
                            String(
                                format: L10n.t("pickup_poll_vote_count_a11y_format", languageCode: languageCode),
                                locale: Locale(identifier: languageCode),
                                Int64(option.voteCount)
                            )
                        )
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(FGColor.divider(colorScheme))
                            .frame(height: 6)
                        Capsule()
                            .fill(selected ? FGColor.accentGreen : FGColor.accentBlue.opacity(0.85))
                            .frame(width: max(6, geo.size.width * progress), height: 6)
                            .animation(.spring(response: 0.38, dampingFraction: 0.86), value: progress)
                    }
                }
                .frame(height: 6)
                .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                    .fill(
                        selected
                            ? FGColor.accentGreen.opacity(colorScheme == .dark ? 0.18 : 0.10)
                            : FGColor.cardBackground(colorScheme).opacity(0.55)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                    .strokeBorder(
                        selected ? FGColor.accentGreen.opacity(0.45) : FGColor.divider(colorScheme),
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canVote || isVoting)
        .frame(minHeight: 44)
        .accessibilityLabel(option.text)
        .accessibilityValue(
            selected
                ? L10n.t("pickup_poll_selected_a11y", languageCode: languageCode)
                : L10n.t("pickup_poll_not_selected_a11y", languageCode: languageCode)
        )
        .accessibilityHint(
            canVote
                ? L10n.t("pickup_poll_vote_hint_a11y", languageCode: languageCode)
                : L10n.t("pickup_poll_closed_badge", languageCode: languageCode)
        )
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private func footerRow(_ snapshot: PickupGamePollSnapshot) -> some View {
        HStack(spacing: 8) {
            Text(
                String(
                    format: L10n.t("pickup_poll_total_votes_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    Int64(snapshot.totalVoters)
                )
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(FGColor.secondaryText(colorScheme))

            if let remaining = timeRemainingLabel(snapshot) {
                Text("·")
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .accessibilityHidden(true)
                Text(remaining)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }

            Spacer(minLength: 0)

            if !snapshot.isAnonymous, snapshot.totalVoters > 0 {
                Button {
                    showVoters = true
                } label: {
                    Text(L10n.t("pickup_poll_view_voters", languageCode: languageCode))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(FGColor.accentBlue)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityLabel(L10n.t("pickup_poll_view_voters", languageCode: languageCode))
            }
        }
    }

    private func timeRemainingLabel(_ snapshot: PickupGamePollSnapshot) -> String? {
        _ = tick
        guard !snapshot.isClosed, let closes = snapshot.closesAtDate else { return nil }
        let remaining = closes.timeIntervalSinceNow
        if remaining <= 0 { return L10n.t("pickup_poll_closed_badge", languageCode: languageCode) }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let relative = formatter.localizedString(fromTimeInterval: remaining)
        return String(
            format: L10n.t("pickup_poll_time_remaining_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            relative
        )
    }

    @MainActor
    private func toggleVote(optionId: UUID, snapshot: PickupGamePollSnapshot) async {
        guard canVote, !isVoting else { return }
        isVoting = true
        defer { isVoting = false }
        actionError = nil

        var next = snapshot.mySelectedOptionIds
        if snapshot.allowMultiple {
            if next.contains(optionId) {
                next.remove(optionId)
            } else {
                next.insert(optionId)
            }
        } else if next == Set([optionId]) {
            next = []
        } else {
            next = [optionId]
        }

        do {
            try await store.setVote(pollId: payload.pollId, optionIds: Array(next))
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } catch {
            actionError = error.localizedDescription
        }
    }

    @MainActor
    private func closePoll() async {
        do {
            try await store.closePoll(payload.pollId)
        } catch {
            actionError = error.localizedDescription
        }
    }

    @MainActor
    private func deletePoll() async {
        do {
            try await store.deletePoll(payload.pollId)
        } catch {
            actionError = error.localizedDescription
        }
    }

    @MainActor
    private func pinPoll() async {
        let pinned = !(snapshot?.isPinned ?? false)
        do {
            try await store.setPinned(payload.pollId, pinned: pinned)
        } catch {
            actionError = error.localizedDescription
        }
    }
}

// MARK: - Voters sheet

struct PickupGamePollVotersSheet: View {
    let snapshot: PickupGamePollSnapshot
    let memberPreviews: [UUID: UserPreview]
    let languageCode: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            List {
                ForEach(snapshot.options) { option in
                    Section {
                        let voters = snapshot.voters.filter { $0.optionId == option.id }
                        if voters.isEmpty {
                            Text(L10n.t("pickup_poll_no_voters", languageCode: languageCode))
                                .font(.subheadline)
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                        } else {
                            ForEach(voters, id: \.voterUserId) { row in
                                let preview = memberPreviews[row.voterUserId]
                                    ?? UserPreview(id: row.voterUserId, displayName: "Fan", avatarURL: nil, avatarThumbnailURL: nil)
                                HStack(spacing: 12) {
                                    ProfileAvatarView(preview: preview, size: 36)
                                    Text(preview.displayName)
                                        .font(.body)
                                        .foregroundStyle(FGColor.primaryText(colorScheme))
                                }
                                .frame(minHeight: 44)
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel(preview.displayName)
                            }
                        }
                    } header: {
                        Text("\(option.text) · \(option.voteCount)")
                    }
                }
            }
            .navigationTitle(L10n.t("pickup_poll_voters_title", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Done", languageCode: languageCode)) { dismiss() }
                        .frame(minHeight: 44)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Chrome

@ViewBuilder
private func pollCardChrome<Content: View>(
    isFromCurrentUser: Bool,
    showFriendAvatar: Bool,
    friendPreview: UserPreview,
    timestamp: String?,
    @ViewBuilder content: () -> Content
) -> some View {
    PickupGamePollCardChrome(
        isFromCurrentUser: isFromCurrentUser,
        showFriendAvatar: showFriendAvatar,
        friendPreview: friendPreview,
        timestamp: timestamp,
        content: content()
    )
}

private struct PickupGamePollCardChrome<Content: View>: View {
    let isFromCurrentUser: Bool
    let showFriendAvatar: Bool
    let friendPreview: UserPreview
    let timestamp: String?
    let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .bottom, spacing: FGSpacing.sm) {
            if !isFromCurrentUser, showFriendAvatar {
                ProfileAvatarView(preview: friendPreview, size: 30)
                    .frame(width: 34, alignment: .center)
            } else if !isFromCurrentUser {
                Color.clear.frame(width: 34, height: 1)
            }

            VStack(alignment: isFromCurrentUser ? .trailing : .leading, spacing: FGSpacing.xs + 1) {
                content
                    .frame(maxWidth: 300, alignment: .leading)
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.vertical, FGSpacing.sm + 2)
                    .background {
                        RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                            .fill(FGColor.cardBackground(colorScheme))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                            .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                    }
                    .softCardShadow()

                if let timestamp, !timestamp.isEmpty {
                    Text(timestamp)
                        .font(FGTypography.metadata)
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .padding(.horizontal, FGSpacing.xs)
                }
            }
            .frame(maxWidth: .infinity, alignment: isFromCurrentUser ? .trailing : .leading)
            .padding(.leading, isFromCurrentUser ? 40 : 0)
            .padding(.trailing, isFromCurrentUser ? 0 : 40)

            if isFromCurrentUser {
                Color.clear.frame(width: 34, height: 1)
            }
        }
    }
}
