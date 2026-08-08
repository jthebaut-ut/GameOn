import SwiftUI

// MARK: - Relative timestamps (request cards)

enum ChatFriendRequestTimestampFormatting {
    private static let monthDay: DateFormatter = {
        let df = DateFormatter()
        df.locale = .autoupdatingCurrent
        df.setLocalizedDateFormatFromTemplate("MMM d")
        return df
    }()

    private static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseISO8601(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return withFractional.date(from: raw) ?? plain.date(from: raw)
    }

    /// Compact relative labels: `2m ago`, `15m ago`, `Yesterday`, `Aug 7`.
    static func relativeLabel(for date: Date?, languageCode: String) -> String {
        guard let date else { return "" }
        let cal = Calendar.current
        let now = Date()
        if cal.isDateInYesterday(date) {
            return L10n.t("chat_inbox_yesterday", languageCode: languageCode)
        }
        if cal.isDateInToday(date) {
            let seconds = max(0, Int(now.timeIntervalSince(date)))
            if seconds < 60 {
                return L10n.t("chat_requests_time_just_now", languageCode: languageCode)
            }
            let minutes = seconds / 60
            if minutes < 60 {
                return String(
                    format: L10n.t("chat_requests_time_minutes_ago_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    minutes
                )
            }
            let hours = minutes / 60
            if hours < 24 {
                return String(
                    format: L10n.t("chat_requests_time_hours_ago_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    hours
                )
            }
        }
        return monthDay.string(from: date)
    }

    static func sentRelativeLabel(for date: Date?, languageCode: String) -> String {
        let relative = relativeLabel(for: date, languageCode: languageCode)
        guard !relative.isEmpty else { return "" }
        return String(
            format: L10n.t("chat_requests_sent_relative_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            relative
        )
    }
}

// MARK: - Optional enrichment (cache-only; never invent)

enum ChatFriendRequestSocialProof {
    struct Snapshot: Equatable {
        var mutualFriendsCount: Int?
        var mutualFriendAvatarURLs: [String]
        var proofLine: String?
    }

    /// Reads already-loaded public-profile cache only. No network / no new backend calls.
    static func snapshot(for userId: UUID, languageCode: String) -> Snapshot {
        guard let cached = PublicUserProfileProcessCache.snapshot(for: userId) else {
            return Snapshot(mutualFriendsCount: nil, mutualFriendAvatarURLs: [], proofLine: nil)
        }
        let avatars = cached.mutualFanAvatars.prefix(3).compactMap { fan -> String? in
            let trimmed = fan.avatarURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        return Snapshot(
            mutualFriendsCount: max(0, cached.mutualFansCount),
            mutualFriendAvatarURLs: Array(avatars),
            proofLine: proofLine(from: cached, languageCode: languageCode)
        )
    }

    private static func proofLine(from data: PublicUserProfileData, languageCode: String) -> String? {
        if let team = preferredTeamName(from: data) {
            return String(
                format: L10n.t("chat_requests_supports_team_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                team
            )
        }
        if let city = data.homeCityDisplayLine?.trimmingCharacters(in: .whitespacesAndNewlines), !city.isEmpty {
            return city
        }
        if let since = data.memberSinceLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !since.isEmpty {
            return String(
                format: L10n.t("chat_requests_member_since_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                since
            )
        }
        if let year = memberSinceYear(from: data.profileCreatedAt) {
            return String(
                format: L10n.t("chat_requests_member_since_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                String(year)
            )
        }
        return nil
    }

    private static func preferredTeamName(from data: PublicUserProfileData) -> String? {
        if let primary = data.primaryFavoriteTeamID,
           let match = data.favoriteTeams.first(where: { $0.id == primary }) {
            let name = match.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return data.favoriteTeams
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func memberSinceYear(from raw: String?) -> Int? {
        guard let date = ChatFriendRequestTimestampFormatting.parseISO8601(raw) else { return nil }
        return Calendar.current.component(.year, from: date)
    }

    static func mutualFriendsLabel(count: Int, languageCode: String) -> String {
        if count <= 0 {
            return L10n.t("chat_requests_mutual_friends_none", languageCode: languageCode)
        }
        if count == 1 {
            return L10n.t("chat_requests_mutual_friends_one", languageCode: languageCode)
        }
        return String(
            format: L10n.t("chat_requests_mutual_friends_other_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            count
        )
    }
}

// MARK: - Exit animation styles

enum ChatFriendRequestExitStyle: Equatable {
    case acceptFlash
    case declineSlide
    case cancelFade
}

// MARK: - Section chrome

struct ChatFriendRequestSectionHeader: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let subtitle: String
    let count: Int
    let systemImage: String
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(accent.opacity(colorScheme == .dark ? 0.22 : 0.14))
                    .frame(width: 36, height: 36)
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    if count > 0 {
                        Text(count > 99 ? "99+" : "\(count)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 7)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(accent, in: Capsule())
                            .accessibilityLabel("\(count)")
                    }
                    Spacer(minLength: 0)
                }
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct ChatFriendRequestSectionCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.78 : 0.98))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.45 : 0.55), lineWidth: 1)
        }
        .softCardShadow()
    }
}

// MARK: - Incoming card

struct ChatIncomingFriendRequestCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let item: ChatViewModel.IncomingRequestDisplay
    let languageCode: String
    let isBusy: Bool
    let exitStyle: ChatFriendRequestExitStyle?
    let onOpenProfile: () -> Void
    let onAccept: () -> Void
    let onDecline: () -> Void
    let onClearDeclined: () -> Void

    private var preview: UserPreview { item.requester }
    private var createdAt: Date? {
        ChatFriendRequestTimestampFormatting.parseISO8601(item.friendship.created_at)
    }
    private var relativeTime: String {
        ChatFriendRequestTimestampFormatting.relativeLabel(for: createdAt, languageCode: languageCode)
    }
    private var handle: String {
        let line = preview.publicHandleLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return line
    }
    private var social: ChatFriendRequestSocialProof.Snapshot {
        ChatFriendRequestSocialProof.snapshot(for: preview.id, languageCode: languageCode)
    }
    private var declined: Bool { item.friendship.isDeclinedStatus }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    identityBlock
                    if !declined {
                        VStack(spacing: 8) {
                            acceptButton
                            declineButton
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    identityBlock
                    if !declined {
                        HStack(spacing: 10) {
                            acceptButton
                            declineButton
                        }
                    }
                }
            }

            if declined {
                Button(L10n.t("Clear", languageCode: languageCode), action: onClearDeclined)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(.orange)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    declined
                        ? Color.orange.opacity(colorScheme == .dark ? 0.14 : 0.10)
                        : FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.55 : 1)
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    exitStyle == .acceptFlash
                        ? FGColor.accentGreen.opacity(0.85)
                        : FGColor.divider(colorScheme).opacity(0.5),
                    lineWidth: exitStyle == .acceptFlash ? 1.5 : 1
                )
        }
        .overlay {
            if exitStyle == .acceptFlash {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(FGColor.accentGreen.opacity(0.18))
                    .transition(.opacity)
            }
        }
        .softCardShadow()
        .scaleEffect(exitStyle == .acceptFlash ? 0.96 : (exitStyle == .declineSlide ? 0.98 : 1))
        // Decline keeps a declined row in-place (VM does not remove it), so use a soft settle — not a full dismiss.
        .opacity(exitStyle == .declineSlide ? 0.35 : 1)
        .offset(x: exitStyle == .declineSlide ? -12 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityHint(
            declined
                ? L10n.t("Clear", languageCode: languageCode)
                : L10n.t("chat_requests_incoming_a11y_hint", languageCode: languageCode)
        )
    }

    private var identityBlock: some View {
        HStack(alignment: .top, spacing: 12) {
            ProfileAvatarView(
                preview: preview,
                size: 62,
                profileTapContext: "friend_request_received_avatar"
            )

            Button(action: onOpenProfile) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(preview.displayName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        Spacer(minLength: 4)
                        if !relativeTime.isEmpty, !declined {
                            Text(relativeTime)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                    }

                    if !handle.isEmpty {
                        Text(handle)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }

                    if declined {
                        Text(L10n.t("Declined", languageCode: languageCode))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.orange)
                    } else if let mutualCount = social.mutualFriendsCount {
                        mutualFriendsRow(count: mutualCount, avatarURLs: social.mutualFriendAvatarURLs)
                    }

                    if !declined, let proof = social.proofLine {
                        Text(proof)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!preview.canOpenPublicProfile)
        }
    }

    private var acceptButton: some View {
        Button(action: onAccept) {
            Text(L10n.t("Accept", languageCode: languageCode))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.white)
                .frame(minWidth: 88)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(FGColor.accentGreen, in: Capsule())
                .shadow(color: FGColor.accentGreen.opacity(0.28), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .opacity(isBusy ? 0.55 : 1)
    }

    private var declineButton: some View {
        Button(action: onDecline) {
            Text(L10n.t("Decline", languageCode: languageCode))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .frame(minWidth: 88)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Capsule()
                        .fill(FGColor.cardBackground(colorScheme))
                )
                .overlay {
                    Capsule()
                        .strokeBorder(FGColor.divider(colorScheme).opacity(0.85), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .opacity(isBusy ? 0.55 : 1)
    }

    @ViewBuilder
    private func mutualFriendsRow(count: Int, avatarURLs: [String]) -> some View {
        HStack(spacing: 6) {
            if !avatarURLs.isEmpty {
                HStack(spacing: -8) {
                    ForEach(Array(avatarURLs.enumerated()), id: \.offset) { _, url in
                        SocialAvatarRenderer.socialAvatarView(
                            displayName: "",
                            email: nil,
                            avatarURL: url,
                            avatarThumbnailURL: nil,
                            isBusinessIdentity: false,
                            size: 18,
                            fallbackStyle: .grayInitials
                        )
                        .clipShape(Circle())
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    Color.white.opacity(colorScheme == .dark ? 0.2 : 0.95),
                                    lineWidth: 1
                                )
                        }
                    }
                }
            }
            Text(ChatFriendRequestSocialProof.mutualFriendsLabel(count: count, languageCode: languageCode))
                .font(.caption.weight(.medium))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    private var accessibilityLabelText: String {
        let mutual: String
        if let count = social.mutualFriendsCount {
            mutual = ChatFriendRequestSocialProof.mutualFriendsLabel(count: count, languageCode: languageCode)
        } else {
            mutual = ""
        }
        let timePart: String
        if relativeTime.isEmpty {
            timePart = ""
        } else {
            timePart = String(
                format: L10n.t("chat_requests_received_time_a11y_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                relativeTime
            )
        }
        return [
            preview.displayName,
            handle.isEmpty ? nil : "(\(handle))",
            timePart.isEmpty ? nil : timePart,
            mutual.isEmpty ? nil : mutual,
            social.proofLine
        ]
        .compactMap { $0 }
        .joined(separator: ". ")
    }
}

// MARK: - Outgoing card

struct ChatOutgoingFriendRequestCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let item: ChatViewModel.OutgoingRequestDisplay
    let languageCode: String
    let isBusy: Bool
    let exitStyle: ChatFriendRequestExitStyle?
    let onOpenProfile: () -> Void
    let onCancel: () -> Void
    let onClearDeclined: () -> Void

    private var preview: UserPreview { item.addressee }
    private var createdAt: Date? {
        ChatFriendRequestTimestampFormatting.parseISO8601(item.friendship.created_at)
    }
    private var sentRelative: String {
        ChatFriendRequestTimestampFormatting.sentRelativeLabel(for: createdAt, languageCode: languageCode)
    }
    private var handle: String {
        preview.publicHandleLine.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var declined: Bool { item.friendship.isDeclinedStatus }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ProfileAvatarView(
                preview: preview,
                size: 56,
                profileTapContext: "friend_request_sent_avatar"
            )

            Button(action: onOpenProfile) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(preview.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    if !handle.isEmpty {
                        Text(handle)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    if declined {
                        Text(L10n.t("Declined", languageCode: languageCode))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.orange)
                    } else {
                        Text(L10n.t("chat_requests_awaiting_response", languageCode: languageCode))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                        if !sentRelative.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                    .font(.caption2.weight(.semibold))
                                Text(sentRelative)
                                    .font(.caption.weight(.medium))
                            }
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!preview.canOpenPublicProfile)

            if declined {
                Button(L10n.t("Clear", languageCode: languageCode), action: onClearDeclined)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(.orange)
            } else {
                Button(L10n.t("Cancel", languageCode: languageCode), action: onCancel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.accentBlue)
                    .disabled(isBusy)
                    .opacity(isBusy ? 0.55 : 1)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    declined
                        ? Color.orange.opacity(colorScheme == .dark ? 0.14 : 0.10)
                        : FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.55 : 1)
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.5), lineWidth: 1)
        }
        .softCardShadow()
        .opacity(exitStyle == .cancelFade || exitStyle == .declineSlide ? 0 : 1)
        .scaleEffect(exitStyle == .cancelFade ? 0.98 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityHint(
            declined
                ? L10n.t("Clear", languageCode: languageCode)
                : L10n.t("chat_requests_outgoing_a11y_hint", languageCode: languageCode)
        )
    }

    private var accessibilityLabelText: String {
        [
            preview.displayName,
            handle.isEmpty ? nil : "(\(handle))",
            declined
                ? L10n.t("Declined", languageCode: languageCode)
                : L10n.t("chat_requests_awaiting_response", languageCode: languageCode),
            sentRelative.isEmpty ? nil : sentRelative
        ]
        .compactMap { $0 }
        .joined(separator: ". ")
    }
}

// MARK: - Empty states

struct ChatFriendRequestInlineEmptyCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let bodyText: String
    let systemImage: String
    var showsCelebration: Bool = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.12))
                    .frame(width: 64, height: 64)
                Circle()
                    .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.16 : 0.12))
                    .frame(width: 54, height: 54)
                    .offset(x: 18, y: 6)
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(FGColor.accentGreen)
                    .offset(x: -6, y: -2)
            }
            .padding(.top, 4)

            Text(title + (showsCelebration ? " 🎉" : ""))
                .font(.headline.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)
            Text(bodyText)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }
}

struct ChatFriendRequestsCombinedEmptyState: View {
    @Environment(\.colorScheme) private var colorScheme
    let languageCode: String
    let onDiscoverFans: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    .frame(width: 88, height: 88)
                Circle()
                    .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    .frame(width: 72, height: 72)
                    .offset(x: 28, y: 10)
                Image(systemName: "person.2.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(FGColor.accentGreen)
                    .offset(x: -4, y: -4)
                Image(systemName: "sparkle")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.accentBlue)
                    .offset(x: 34, y: -28)
                Image(systemName: "sparkle")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(FGColor.accentGreen)
                    .offset(x: -30, y: 24)
            }
            .padding(.bottom, 4)

            Text(L10n.t("chat_requests_empty_all_title", languageCode: languageCode) + " 🎉")
                .font(.title3.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)
            Text(L10n.t("chat_requests_empty_all_body", languageCode: languageCode))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)

            Button(action: onDiscoverFans) {
                Text(L10n.t("chat_requests_discover_fans_cta", languageCode: languageCode))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(FGColor.accentGreen, in: Capsule())
                    .shadow(color: FGColor.accentGreen.opacity(0.25), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
        .accessibilityElement(children: .combine)
    }
}
