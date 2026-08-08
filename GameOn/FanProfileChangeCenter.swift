import Foundation

/// Typed fan profile avatar change. Prefer this over ad-hoc NotificationCenter string literals.
struct FanProfileAvatarChange: Equatable, Sendable {
    let userId: UUID
    let avatarURL: String
    let avatarThumbnailURL: String?
    let updatedAt: Date

    init(
        userId: UUID,
        avatarURL: String,
        avatarThumbnailURL: String?,
        updatedAt: Date = Date()
    ) {
        self.userId = userId
        self.avatarURL = ImageDisplayURL.canonicalStorageURLString(avatarURL)
        let thumb = ImageDisplayURL.canonicalStorageURLString(avatarThumbnailURL)
        self.avatarThumbnailURL = thumb.isEmpty ? nil : thumb
        self.updatedAt = updatedAt
    }
}

/// Single app-wide hub for fan profile avatar propagation (local save + remote realtime merges).
enum FanProfileChangeCenter {
    static let avatarDidChangeNotification = Notification.Name("FanGeo.FanProfileAvatarDidChange")

    private static let changeUserInfoKey = "FanGeo.FanProfileAvatarChange"

    static func postAvatarChange(_ change: FanProfileAvatarChange) {
        guard !change.avatarURL.isEmpty || !(change.avatarThumbnailURL ?? "").isEmpty else { return }
        PublicUserProfileProcessCache.invalidate(userId: change.userId, reason: "avatarPosted")
        NotificationCenter.default.post(
            name: avatarDidChangeNotification,
            object: nil,
            userInfo: [changeUserInfoKey: change]
        )
    }

    /// Drop decoded images for superseded avatar URLs so list rows never keep showing the old photo.
    static func invalidateCachedAvatarImages(
        previousAvatarURL: String?,
        previousThumbnailURL: String?,
        nextAvatarURL: String,
        nextThumbnailURL: String?
    ) {
        let nextFull = ImageDisplayURL.canonicalStorageURLString(nextAvatarURL)
        let nextThumb = ImageDisplayURL.canonicalStorageURLString(nextThumbnailURL)
        var candidates: [String] = []
        let prevFull = ImageDisplayURL.canonicalStorageURLString(previousAvatarURL)
        let prevThumb = ImageDisplayURL.canonicalStorageURLString(previousThumbnailURL)
        if !prevFull.isEmpty, prevFull != nextFull, prevFull != nextThumb {
            candidates.append(prevFull)
        }
        if !prevThumb.isEmpty, prevThumb != nextFull, prevThumb != nextThumb {
            candidates.append(prevThumb)
        }
        if let list = ImageDisplayURL.forList(thumbnail: previousThumbnailURL, full: previousAvatarURL),
           list != ImageDisplayURL.forList(thumbnail: nextThumbnailURL, full: nextAvatarURL) {
            candidates.append(list)
        }
        let urls = candidates.compactMap { URL(string: $0) }
        guard !urls.isEmpty else { return }
        Task {
            await DiscoverMapImageCache.shared.invalidate(urls: urls)
        }
    }

    static func avatarChange(from notification: Notification) -> FanProfileAvatarChange? {
        notification.userInfo?[changeUserInfoKey] as? FanProfileAvatarChange
    }
}

extension UserPreview {
    func replacingAvatars(
        avatarURL: String?,
        avatarThumbnailURL: String?
    ) -> UserPreview {
        UserPreview(
            id: id,
            displayName: displayName,
            username: username,
            email: email,
            avatarURL: avatarURL,
            avatarThumbnailURL: avatarThumbnailURL,
            isBusinessAccount: isBusinessAccount,
            isDeleted: isDeleted,
            lastSeenAtRaw: lastSeenAtRaw,
            activityStatusVisible: activityStatusVisible,
            dmConversationId: dmConversationId,
            businessVenueId: businessVenueId,
            businessVenueBusinessId: businessVenueBusinessId,
            businessVenueBusinessName: businessVenueBusinessName,
            venueScopedThread: venueScopedThread
        )
    }
}
