import SwiftUI
import UIKit

/// Compact Team mark: real logo when available, otherwise a sport SF Symbol badge (never initials).
struct FanTeamMarkView: View {
    let sport: String
    let logoURL: String?
    let logoThumbnailURL: String?
    let colorHex: String?
    var size: CGFloat = 48
    /// Prefer full logo URL for larger detail/header marks; list rows prefer thumbnail-first.
    var preferDetailURL: Bool = false
    var localPreviewImage: UIImage? = nil
    var displayRefreshToken: UUID? = nil

    @Environment(\.colorScheme) private var colorScheme

    private var resolvedURL: URL? {
        if localPreviewImage != nil { return nil }
        let canonicalThumb = ImageDisplayURL.canonicalStorageURLString(logoThumbnailURL)
        let canonicalFull = ImageDisplayURL.canonicalStorageURLString(logoURL)
        let base: String? = preferDetailURL
            ? ImageDisplayURL.forDetail(
                thumbnail: canonicalThumb.isEmpty ? nil : canonicalThumb,
                full: canonicalFull.isEmpty ? nil : canonicalFull
            )
            : ImageDisplayURL.forList(
                thumbnail: canonicalThumb.isEmpty ? nil : canonicalThumb,
                full: canonicalFull.isEmpty ? nil : canonicalFull
            )
        guard var raw = base, !raw.isEmpty else { return nil }
        if let displayRefreshToken {
            raw = ImageDisplayURL.displayVersionedURLString(raw, refreshToken: displayRefreshToken)
        }
        return URL(string: raw)
    }

    private var accent: Color {
        if let colorHex, let color = Color(fanTeamHex: colorHex) {
            return color
        }
        return SportFilterCatalog.resolve(sport).accent
    }

    private var systemImage: String {
        SportFilterCatalog.resolve(sport).systemImage
    }

    var body: some View {
        Group {
            if let localPreviewImage {
                Image(uiImage: localPreviewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let resolvedURL {
                DiscoverCachedRemoteImage(url: resolvedURL, contentMode: .fill) {
                    sportBadge
                }
            } else {
                sportBadge
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            accent.opacity(colorScheme == .dark ? 0.55 : 0.35),
                            accent.opacity(0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: max(1.5, size * 0.04)
                )
        }
        .accessibilityHidden(true)
        .id(displayRefreshToken?.uuidString ?? resolvedURL?.absoluteString ?? "sport-\(sport)-\(colorHex ?? "")")
    }

    private var sportBadge: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            accent.opacity(colorScheme == .dark ? 0.42 : 0.28),
                            accent.opacity(colorScheme == .dark ? 0.18 : 0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.35))
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(accent)
                .symbolRenderingMode(.hierarchical)
        }
    }
}

/// Pure avatar source decision for Fan Team chat rows (testable; no network).
nonisolated enum ChatInboxFanTeamAvatarDecision {
    enum Source: Equatable {
        case logoThumbnail
        case logoURL
        case sportColorMark
    }

    /// Priority: thumbnail → full logo → sport/color mark. Never member/group avatars.
    static func preferredSource(logoThumbnailURL: String?, logoURL: String?) -> Source {
        let thumb = ImageDisplayURL.canonicalStorageURLString(logoThumbnailURL)
        if !thumb.isEmpty { return .logoThumbnail }
        let full = ImageDisplayURL.canonicalStorageURLString(logoURL)
        if !full.isEmpty { return .logoURL }
        return .sportColorMark
    }

    static func usesTeamIdentityMark(isFanTeamChat: Bool) -> Bool {
        isFanTeamChat
    }
}

/// Inbox / search presentation rules for Fan Team conversations (no string inference).
nonisolated enum ChatInboxFanTeamRowIdentity {
    /// Authoritative Team name wins over the underlying group conversation title.
    static func preferredTitle(teamName: String?, fallbackConversationTitle: String) -> String {
        let trimmed = teamName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        let fallback = fallbackConversationTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback
    }

    static func showsTeamChatBadge(isFanTeamChat: Bool) -> Bool {
        isFanTeamChat
    }
}

/// Chat inbox / search / header Team avatar: logo → sport/color mark (never member faces).
struct ChatInboxFanTeamConversationAvatar: View {
    let teamId: UUID?
    let conversationId: UUID
    var size: CGFloat = 48
    var languageCode: String = L10n.defaultLanguageCode

    @State private var localRefreshToken: UUID?

    private var snapshot: FanTeamIdentityRealtimeCoordinator.MarkSnapshot? {
        FanTeamIdentityRealtimeCoordinator.shared.markSnapshot(
            teamId: teamId,
            conversationId: conversationId
        )
    }

    var body: some View {
        let mark = snapshot
        FanTeamMarkView(
            sport: mark?.sport ?? "",
            logoURL: mark?.logoURL,
            logoThumbnailURL: mark?.logoThumbnailURL,
            colorHex: mark?.colorHex,
            size: size,
            preferDetailURL: false,
            displayRefreshToken: localRefreshToken ?? mark?.displayRefreshToken
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("fan_teams_logo_a11y", languageCode: languageCode))
        .onReceive(NotificationCenter.default.publisher(for: FanTeamIdentityChangeCenter.identityDidChangeNotification)) { note in
            guard let change = FanTeamIdentityChangeCenter.identityChange(from: note) else { return }
            let matchesTeam = teamId == change.teamId
            let matchesConversation = change.conversationId == conversationId
            guard matchesTeam || matchesConversation else { return }
            localRefreshToken = change.displayRefreshToken
        }
    }
}

extension Color {
    /// Shared hex parser for Team accent colors (UI-only).
    init?(fanTeamHex: String) {
        var hex = fanTeamHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}
