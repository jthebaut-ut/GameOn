import CryptoKit
import SwiftUI
import UIKit

/// Shared profile avatar: optional ``AsyncImage`` from stored URLs (thumbnail-aware), otherwise initials on a neutral circle (same rules as Settings hero).
struct UserAvatarView: View {
    var avatarThumbnailURL: String?
    let avatarURL: String
    var avatarDisplayRefreshToken: UUID
    var localPreviewImage: UIImage? = nil
    let displayName: String
    let email: String
    let size: CGFloat
    var fallbackStyle: FallbackStyle = .lightOnWhiteChrome
    /// When set, used as ``ProgressView`` tint while the image loads (e.g. white on dark hero cards).
    var imagePlaceholderTint: Color? = nil

    enum FallbackStyle {
        /// Translucent circle + white initials (dark gradient cards).
        case darkCardTranslucent
        /// Soft gray circle + dark initials (floating tab bar on light chrome).
        case lightOnWhiteChrome
    }

    private var resolvedListURL: URL? {
        guard let urlString = ImageDisplayURL.forListDisplay(
            thumbnail: avatarThumbnailURL,
            full: avatarURL,
            refreshToken: avatarDisplayRefreshToken
        ),
              let url = URL(string: urlString) else {
#if DEBUG
            let displayCandidate = ImageDisplayURL.forListDisplay(
                thumbnail: avatarThumbnailURL,
                full: avatarURL,
                refreshToken: avatarDisplayRefreshToken
            )
            let reason: String
            if (avatarThumbnailURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                && avatarURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reason = "no_thumbnail_or_full_url_in_view_model"
            } else if displayCandidate == nil {
                reason = "forListDisplay_returned_nil"
            } else {
                reason = "url_string_parse_failed"
            }
            ProfileAvatarDebug.avatarViewResolved(
                context: "UserAvatarView.resolvedListURL",
                thumbnailInput: avatarThumbnailURL,
                fullInput: avatarURL,
                displayURLString: displayCandidate,
                urlParseSucceeded: false,
                fallbackReason: reason
            )
#endif
            return nil
        }
        return url
    }

    var body: some View {
        ZStack {
            fallbackContent

            if let localPreviewImage {
                Image(uiImage: localPreviewImage)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if let url = resolvedListURL {
                SmoothCachedAvatarImage(url: url, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .contentShape(Circle())
        .onAppear {
#if DEBUG
            if localPreviewImage == nil, resolvedListURL == nil {
                ProfileAvatarDebug.avatarRenderSource("initials")
            } else if let url = resolvedListURL {
                ProfileAvatarDebug.avatarViewResolved(
                    context: "UserAvatarView.onAppear",
                    thumbnailInput: avatarThumbnailURL,
                    fullInput: avatarURL,
                    displayURLString: url.absoluteString,
                    urlParseSucceeded: true,
                    fallbackReason: "image_load_pending_or_failed_underneath"
                )
            }
#endif
        }
    }

    @ViewBuilder
    private var fallbackContent: some View {
        if shouldShowGenericPerson {
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(.secondary)
        } else {
            fallbackCircle
            Text(Self.initials(displayName: displayName, email: email))
                .font(.system(size: max(12, size * 0.28), weight: .bold, design: .rounded))
                .foregroundStyle(fallbackInitialsForeground)
        }

        if resolvedListURL != nil, localPreviewImage == nil, let imagePlaceholderTint {
            ProgressView()
                .controlSize(.small)
                .tint(imagePlaceholderTint)
        }
    }
}

extension UserAvatarView {
    static let placeholderRefreshToken = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    static func stableRefreshToken(
        userId: UUID,
        thumbnailURL: String?,
        avatarURL: String?,
        versionSuffix: String = ""
    ) -> UUID {
        let material = "\(userId.uuidString.lowercased())|\(thumbnailURL ?? "")|\(avatarURL ?? "")|\(versionSuffix)"
        let digest = Insecure.MD5.hash(data: Data(material.utf8))
        return digest.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            return UUID(
                uuid: (
                    bytes[0], bytes[1], bytes[2], bytes[3],
                    bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11],
                    bytes[12], bytes[13], bytes[14], bytes[15]
                )
            )
        }
    }
}

private struct SmoothCachedAvatarImage: View {
    let url: URL
    let size: CGFloat

    @State private var uiImage: UIImage?
    @State private var imageOpacity = 0.0
    @State private var loadToken: UInt64 = 0

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .opacity(imageOpacity)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .task(id: url.absoluteString) {
            let requestedURL = url
            let token = loadToken &+ 1
            loadToken = token
            imageOpacity = 0
            uiImage = nil

            if let cached = await DiscoverMapImageCache.shared.cachedImage(for: requestedURL, bucket: .avatar) {
                guard isCurrentLoad(token: token, requestedURL: requestedURL) else { return }
                if uiImage !== cached {
                    uiImage = cached
                }
                imageOpacity = 1
#if DEBUG
                ProfileAvatarDebug.avatarRenderSource("cache")
                ProfileAvatarDebug.avatarImageLoadFinished(url: requestedURL, succeeded: true, detail: "memory_cache_hit")
#endif
                return
            }

            guard let loaded = await DiscoverMapImageCache.shared.image(for: requestedURL, bucket: .avatar) else {
#if DEBUG
                ProfileAvatarDebug.avatarImageLoadFinished(
                    url: requestedURL,
                    succeeded: false,
                    detail: Task.isCancelled ? "task_cancelled" : "discover_map_image_cache_returned_nil"
                )
                ProfileAvatarDebug.avatarRenderSource("initials_visible_under_failed_load")
#endif
                return
            }
            guard isCurrentLoad(token: token, requestedURL: requestedURL) else { return }
            if uiImage !== loaded {
                uiImage = loaded
            }
#if DEBUG
            ProfileAvatarDebug.avatarRenderSource("server")
            ProfileAvatarDebug.avatarImageLoadFinished(url: requestedURL, succeeded: true, detail: "network_or_disk_decode_ok")
#endif
            withAnimation(.easeOut(duration: 0.22)) {
                imageOpacity = 1
            }
        }
    }

    private func isCurrentLoad(token: UInt64, requestedURL: URL) -> Bool {
        if Task.isCancelled {
            ImagePerf.waiterCancelled()
            return false
        }
        if loadToken != token || url != requestedURL {
            ImagePerf.staleResultRejected()
            return false
        }
        return true
    }
}

extension UserAvatarView {

    /// True only when there is no usable name or email to derive initials (anonymous / pre-sign-in surfaces).
    private var shouldShowGenericPerson: Bool {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return false }
        if mail.isEmpty { return true }
        let local = mail.split(separator: "@").first.map(String.init) ?? ""
        return local.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var fallbackCircle: some View {
        switch fallbackStyle {
        case .darkCardTranslucent:
            Circle().fill(Color.white.opacity(0.10))
        case .lightOnWhiteChrome:
            Circle().fill(Color(white: 0.88))
        }
    }

    private var fallbackInitialsForeground: Color {
        switch fallbackStyle {
        case .darkCardTranslucent:
            return .white
        case .lightOnWhiteChrome:
            return Color(white: 0.28)
        }
    }

    // MARK: - Initials (matches ``SettingsProfileHero``)

    static func initials(displayName: String, email: String) -> String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            let parts = name.split(separator: " ").filter { !$0.isEmpty }
            if parts.count >= 2 {
                return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
            }
            return "\(name.prefix(2))".uppercased()
        }
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = mail.split(separator: "@").first.map(String.init) ?? ""
        return local.isEmpty ? "U" : "\(local.prefix(2))".uppercased()
    }

    /// Email line for account hero / tab: fan session email vs venue-owner session email.
    static func accountEmailLine(isLoggedIn: Bool, userEmail: String, venueOwnerEmail: String) -> String {
        if isLoggedIn {
            return userEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return OwnerBusinessEmail.normalized(venueOwnerEmail)
    }

    /// Display name resolution aligned with ``SettingsProfileHero``.
    static func accountResolvedDisplayName(
        isLoggedIn: Bool,
        currentUserDisplayName: String,
        isVenueOwnerLoggedIn: Bool,
        ownerVenueName: String,
        userEmail: String,
        venueOwnerEmail: String
    ) -> String {
        let current = currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty { return current }
        if isVenueOwnerLoggedIn && !isLoggedIn {
            let venue = ownerVenueName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !venue.isEmpty { return venue }
        }
        let emailLine = accountEmailLine(isLoggedIn: isLoggedIn, userEmail: userEmail, venueOwnerEmail: venueOwnerEmail)
        let local = emailLine.split(separator: "@").first.map(String.init) ?? ""
        guard !local.isEmpty else { return "" }
        return local.prefix(1).uppercased() + local.dropFirst()
    }
}
