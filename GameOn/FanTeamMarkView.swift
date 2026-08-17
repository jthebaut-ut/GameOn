import SwiftUI
import UIKit

/// Compact Team mark: uploaded logo, otherwise the official FanGeo sport mark.
/// Never resolves TheSportsDB / professional crests — FanGeo user-created Teams are a separate identity family.
struct FanTeamMarkView: View {
    let sport: String
    let logoURL: String?
    let logoThumbnailURL: String?
    let colorHex: String?
    var sportSubtype: String? = nil
    var size: CGFloat = 48
    var wordmark: String? = nil
    /// Prefer full logo URL for larger detail/header marks; list rows prefer thumbnail-first.
    /// Team Detail header intentionally uses `false` on first paint to avoid heavy full-logo
    /// AttributeGraph churn during sheet presentation (`hasDetail=false` shell).
    var preferDetailURL: Bool = false
    var localPreviewImage: UIImage? = nil
    var displayRefreshToken: UUID? = nil

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
        return FanTeamMarkIdentity.safeURL(from: raw)
    }

    private var accent: Color {
        if let colorHex, let color = Color(fanTeamHex: colorHex) {
            return color
        }
        return FanGeoSportMarkCatalog.accent(sport: sport, subtype: sportSubtype)
    }

    private var identityToken: String {
        FanTeamMarkIdentity.token(
            sport: sport,
            logoURL: logoURL,
            logoThumbnailURL: logoThumbnailURL,
            colorHex: colorHex,
            preferDetailURL: preferDetailURL,
            displayRefreshToken: displayRefreshToken,
            sportSubtype: sportSubtype
        )
    }

    var body: some View {
        Group {
            if let localPreviewImage {
                Image(uiImage: localPreviewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(accent.opacity(0.86), lineWidth: max(1.5, size * 0.04))
                    }
            } else if let resolvedURL {
                DiscoverCachedRemoteImage(
                    url: resolvedURL,
                    contentMode: .fill,
                    bucket: DiscoverMapImageCache.Bucket.forPointSize(size, preferDetail: preferDetailURL)
                ) {
                    sportBadge
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(accent.opacity(0.86), lineWidth: max(1.5, size * 0.04))
                }
            } else {
                sportBadge
            }
        }
        .accessibilityHidden(true)
        // Short stable identity — never embed raw logo URL strings (AttributeGraph thrash).
        .id(identityToken)
    }

    private var sportBadge: some View {
        FanGeoSportMark(
            sport: sport,
            subtype: sportSubtype,
            size: size,
            wordmark: wordmark
        )
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

/// Action Center leading identity: cached Team mark (logo → sport badge).
/// Falls back to the existing kind glyph when Team identity is not in cache
/// (offline, left Team, or deleted Team). Does not load images itself.
struct ActionCenterTeamIdentityMark: View, Equatable {
    let teamId: UUID
    var size: CGFloat = 44
    var fallbackSystemImage: String
    var accent: Color
    var languageCode: String = L10n.defaultLanguageCode
    /// Snapshot sport from the inbox payload when the Team is no longer in cache
    /// (removed member / left Team). Never a raw logo URL.
    var fallbackSport: String? = nil

    static func == (lhs: ActionCenterTeamIdentityMark, rhs: ActionCenterTeamIdentityMark) -> Bool {
        lhs.teamId == rhs.teamId
            && lhs.size == rhs.size
            && lhs.fallbackSystemImage == rhs.fallbackSystemImage
            && lhs.languageCode == rhs.languageCode
            && lhs.fallbackSport == rhs.fallbackSport
    }

    @Environment(\.colorScheme) private var colorScheme
    @State private var localRefreshToken: UUID?

    private var snapshot: FanTeamIdentityRealtimeCoordinator.MarkSnapshot? {
        FanTeamIdentityRealtimeCoordinator.shared.markSnapshot(
            teamId: teamId,
            conversationId: nil
        )
    }

    var body: some View {
        let _ = FanGeoInboxOpenPerf.teamIdentityMarkBody()
        if let mark = snapshot {
            FanTeamMarkView(
                sport: mark.sport,
                logoURL: mark.logoURL,
                logoThumbnailURL: mark.logoThumbnailURL,
                colorHex: mark.colorHex,
                size: size,
                preferDetailURL: false,
                displayRefreshToken: localRefreshToken ?? mark.displayRefreshToken
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.t("fan_teams_logo_a11y", languageCode: languageCode))
            .onReceive(NotificationCenter.default.publisher(for: FanTeamIdentityChangeCenter.identityDidChangeNotification)) { note in
                guard let change = FanTeamIdentityChangeCenter.identityChange(from: note),
                      change.teamId == teamId else { return }
                localRefreshToken = change.displayRefreshToken
            }
        } else if let sport = fallbackSport?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sport.isEmpty {
            FanTeamMarkView(
                sport: sport,
                logoURL: nil,
                logoThumbnailURL: nil,
                colorHex: nil,
                size: size,
                preferDetailURL: false
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.t("fan_teams_logo_a11y", languageCode: languageCode))
        } else {
            Image(systemName: fallbackSystemImage)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: size, height: size)
                .background(Circle().fill(accent.opacity(colorScheme == .dark ? 0.24 : 0.12)))
                .accessibilityHidden(true)
        }
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
