import Foundation

/// Typed managed-player avatar change for immediate My Players / Team surface refresh.
struct FanManagedPlayerAvatarChange: Equatable, Sendable {
    let managedPlayerId: UUID
    let avatarURL: String?
    let avatarThumbnailURL: String?
    let previousAvatarURL: String?
    let previousAvatarThumbnailURL: String?
    let displayRefreshToken: UUID
    let updatedAt: Date

    init(
        managedPlayerId: UUID,
        avatarURL: String?,
        avatarThumbnailURL: String?,
        previousAvatarURL: String?,
        previousAvatarThumbnailURL: String?,
        displayRefreshToken: UUID = UUID(),
        updatedAt: Date = Date()
    ) {
        self.managedPlayerId = managedPlayerId
        let nextFull = ImageDisplayURL.canonicalStorageURLString(avatarURL)
        let nextThumb = ImageDisplayURL.canonicalStorageURLString(avatarThumbnailURL)
        self.avatarURL = nextFull.isEmpty ? nil : nextFull
        self.avatarThumbnailURL = nextThumb.isEmpty ? nil : nextThumb
        let prevFull = ImageDisplayURL.canonicalStorageURLString(previousAvatarURL)
        let prevThumb = ImageDisplayURL.canonicalStorageURLString(previousAvatarThumbnailURL)
        self.previousAvatarURL = prevFull.isEmpty ? nil : prevFull
        self.previousAvatarThumbnailURL = prevThumb.isEmpty ? nil : prevThumb
        self.displayRefreshToken = displayRefreshToken
        self.updatedAt = updatedAt
    }
}

/// Managed player gained/lost an active Team seat (presentation refresh only).
struct FanManagedPlayerTeamMembershipChange: Equatable, Sendable {
    let managedPlayerId: UUID
    let teamId: UUID
    let membershipId: UUID?
    let added: Bool
    let updatedAt: Date

    init(
        managedPlayerId: UUID,
        teamId: UUID,
        membershipId: UUID?,
        added: Bool,
        updatedAt: Date = Date()
    ) {
        self.managedPlayerId = managedPlayerId
        self.teamId = teamId
        self.membershipId = membershipId
        self.added = added
        self.updatedAt = updatedAt
    }
}

/// Single app-local hub for managed-player avatar + Team seat propagation (no second realtime system).
enum FanManagedPlayerChangeCenter {
    static let avatarDidChangeNotification = Notification.Name("FanGeo.FanManagedPlayerAvatarDidChange")
    static let teamMembershipDidChangeNotification = Notification.Name("FanGeo.FanManagedPlayerTeamMembershipDidChange")

    private static let changeUserInfoKey = "FanGeo.FanManagedPlayerAvatarChange"
    private static let membershipUserInfoKey = "FanGeo.FanManagedPlayerTeamMembershipChange"

    static func postAvatarChange(_ change: FanManagedPlayerAvatarChange) {
        invalidateCachedAvatarImages(
            previousAvatarURL: change.previousAvatarURL,
            previousThumbnailURL: change.previousAvatarThumbnailURL,
            nextAvatarURL: change.avatarURL,
            nextThumbnailURL: change.avatarThumbnailURL
        )
        NotificationCenter.default.post(
            name: avatarDidChangeNotification,
            object: nil,
            userInfo: [changeUserInfoKey: change]
        )
    }

    static func avatarChange(from notification: Notification) -> FanManagedPlayerAvatarChange? {
        notification.userInfo?[changeUserInfoKey] as? FanManagedPlayerAvatarChange
    }

    static func postTeamMembershipChange(_ change: FanManagedPlayerTeamMembershipChange) {
        NotificationCenter.default.post(
            name: teamMembershipDidChangeNotification,
            object: nil,
            userInfo: [membershipUserInfoKey: change]
        )
    }

    static func teamMembershipChange(from notification: Notification) -> FanManagedPlayerTeamMembershipChange? {
        notification.userInfo?[membershipUserInfoKey] as? FanManagedPlayerTeamMembershipChange
    }

    /// Drop decoded images for superseded managed-player avatar URLs only.
    static func invalidateCachedAvatarImages(
        previousAvatarURL: String?,
        previousThumbnailURL: String?,
        nextAvatarURL: String?,
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
}

extension FanManagedPlayer {
    func applyingAvatar(
        avatarURL: String?,
        avatarThumbnailURL: String?
    ) -> FanManagedPlayer {
        var copy = self
        let full = ImageDisplayURL.canonicalStorageURLString(avatarURL)
        let thumb = ImageDisplayURL.canonicalStorageURLString(avatarThumbnailURL)
        copy.avatarURL = full.isEmpty ? nil : full
        copy.avatarThumbnailURL = thumb.isEmpty ? nil : thumb
        return copy
    }
}

extension FanTeamManagedPlayerSeat {
    func applyingAvatar(
        avatarURL: String?,
        avatarThumbnailURL: String?
    ) -> FanTeamManagedPlayerSeat {
        let full = ImageDisplayURL.canonicalStorageURLString(avatarURL)
        let thumb = ImageDisplayURL.canonicalStorageURLString(avatarThumbnailURL)
        return FanTeamManagedPlayerSeat(
            id: id,
            managedPlayerId: managedPlayerId,
            displayName: displayName,
            avatarURL: full.isEmpty ? nil : full,
            avatarThumbnailURL: thumb.isEmpty ? nil : thumb,
            playerNumber: playerNumber,
            preferredPositionCode: preferredPositionCode,
            joinedAt: joinedAt
        )
    }
}

extension FanTeamMember {
    func applyingManagedPlayerAvatar(
        managedPlayerId: UUID,
        avatarURL: String?,
        avatarThumbnailURL: String?
    ) -> FanTeamMember {
        guard self.managedPlayerId == managedPlayerId else { return self }
        let full = ImageDisplayURL.canonicalStorageURLString(avatarURL)
        let thumb = ImageDisplayURL.canonicalStorageURLString(avatarThumbnailURL)
        return FanTeamMember(
            membershipId: membershipId,
            userId: userId,
            managedPlayerId: self.managedPlayerId,
            role: role,
            joinedAt: joinedAt,
            displayName: displayName,
            username: username,
            avatarURL: full.isEmpty ? nil : full,
            avatarThumbnailURL: thumb.isEmpty ? nil : thumb,
            lastSeenAtRaw: lastSeenAtRaw,
            playerNumber: playerNumber,
            preferredPositionCode: preferredPositionCode,
            genderRaw: genderRaw
        )
    }
}

extension FanTeamMemberAvatarPreview {
    /// Remap when prior avatar URLs match, or when `managedPlayerId` matches the change.
    func applyingManagedPlayerAvatarChange(_ change: FanManagedPlayerAvatarChange) -> FanTeamMemberAvatarPreview {
        guard isManagedPlayer else { return self }
        let idMatch = managedPlayerId == change.managedPlayerId
        let full = ImageDisplayURL.canonicalStorageURLString(avatarURL)
        let thumb = ImageDisplayURL.canonicalStorageURLString(avatarThumbnailURL)
        let prevFull = change.previousAvatarURL ?? ""
        let prevThumb = change.previousAvatarThumbnailURL ?? ""
        let matchesPrevious =
            (!prevFull.isEmpty && (full == prevFull || thumb == prevFull))
            || (!prevThumb.isEmpty && (full == prevThumb || thumb == prevThumb))
        guard idMatch || matchesPrevious else { return self }
        let nextFull = change.avatarURL
        let nextThumb = change.avatarThumbnailURL
        return FanTeamMemberAvatarPreview(
            membershipId: membershipId,
            managedPlayerId: managedPlayerId ?? change.managedPlayerId,
            displayName: displayName,
            avatarURL: nextFull,
            avatarThumbnailURL: nextThumb,
            role: role,
            isManagedPlayer: isManagedPlayer
        )
    }
}

extension FanTeamSummary {
    func applyingManagedPlayerAvatarChange(_ change: FanManagedPlayerAvatarChange) -> FanTeamSummary {
        let updated = memberAvatarPreviews.map { $0.applyingManagedPlayerAvatarChange(change) }
        guard updated != memberAvatarPreviews else { return self }
        return FanTeamSummary(
            id: id,
            name: name,
            sport: sport,
            logoURL: logoURL,
            logoThumbnailURL: logoThumbnailURL,
            colorHex: colorHex,
            competitionLevel: competitionLevel,
            ownerUserId: ownerUserId,
            groupConversationId: groupConversationId,
            myRole: myRole,
            memberCount: memberCount,
            pendingInvitationCount: pendingInvitationCount,
            pushNotificationsMuted: pushNotificationsMuted,
            nextGameStartsAt: nextGameStartsAt,
            nextGameTitle: nextGameTitle,
            nextGameVenue: nextGameVenue,
            createdAt: createdAt,
            memberAvatarPreviews: updated,
            accessVia: accessVia,
            viaManagedPlayerNames: viaManagedPlayerNames
        )
    }
}

#if DEBUG
enum ManagedPlayerAvatarDebug {
    static func log(
        _ event: String,
        managedPlayerId: UUID,
        oldAvatarURL: String? = nil,
        newAvatarURL: String? = nil,
        oldThumbnailURL: String? = nil,
        newThumbnailURL: String? = nil,
        uploadSuccess: Bool? = nil,
        dbUpdateSuccess: Bool? = nil,
        localArrayReplaced: Bool? = nil,
        refreshTriggered: Bool? = nil
    ) {
        print("[ManagedPlayerAvatarDebug] event=\(event)")
        print("[ManagedPlayerAvatarDebug] managed_player_id=\(managedPlayerId.uuidString.lowercased())")
        if let oldAvatarURL {
            print("[ManagedPlayerAvatarDebug] old_avatar_url=\(oldAvatarURL)")
        }
        if let newAvatarURL {
            print("[ManagedPlayerAvatarDebug] new_avatar_url=\(newAvatarURL)")
        }
        if let oldThumbnailURL {
            print("[ManagedPlayerAvatarDebug] old_thumbnail_url=\(oldThumbnailURL)")
        }
        if let newThumbnailURL {
            print("[ManagedPlayerAvatarDebug] new_thumbnail_url=\(newThumbnailURL)")
        }
        if let uploadSuccess {
            print("[ManagedPlayerAvatarDebug] upload_success=\(uploadSuccess)")
        }
        if let dbUpdateSuccess {
            print("[ManagedPlayerAvatarDebug] db_update_success=\(dbUpdateSuccess)")
        }
        if let localArrayReplaced {
            print("[ManagedPlayerAvatarDebug] local_array_replaced=\(localArrayReplaced)")
        }
        if let refreshTriggered {
            print("[ManagedPlayerAvatarDebug] refresh_triggered=\(refreshTriggered)")
        }
    }
}
#endif
