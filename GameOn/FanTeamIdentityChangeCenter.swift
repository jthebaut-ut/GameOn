import Foundation

/// Typed Team identity change for immediate My Teams / Detail / Chat / mark refresh.
struct FanTeamIdentityChange: Equatable, Sendable {
    let teamId: UUID
    let conversationId: UUID
    let name: String
    let sport: String
    let colorHex: String?
    let competitionLevel: PickupCompetitionLevel?
    let logoURL: String?
    let logoThumbnailURL: String?
    let previousLogoURL: String?
    let previousLogoThumbnailURL: String?
    let displayRefreshToken: UUID
    let updatedAt: Date

    init(
        teamId: UUID,
        conversationId: UUID,
        name: String,
        sport: String,
        colorHex: String?,
        competitionLevel: PickupCompetitionLevel? = nil,
        logoURL: String?,
        logoThumbnailURL: String?,
        previousLogoURL: String?,
        previousLogoThumbnailURL: String?,
        displayRefreshToken: UUID = UUID(),
        updatedAt: Date = Date()
    ) {
        self.teamId = teamId
        self.conversationId = conversationId
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sport = sport.trimmingCharacters(in: .whitespacesAndNewlines)
        self.colorHex = colorHex
        self.competitionLevel = competitionLevel
        self.logoURL = ImageDisplayURL.canonicalStorageURLString(logoURL).nilIfEmpty
        self.logoThumbnailURL = ImageDisplayURL.canonicalStorageURLString(logoThumbnailURL).nilIfEmpty
        self.previousLogoURL = ImageDisplayURL.canonicalStorageURLString(previousLogoURL).nilIfEmpty
        self.previousLogoThumbnailURL = ImageDisplayURL.canonicalStorageURLString(previousLogoThumbnailURL).nilIfEmpty
        self.displayRefreshToken = displayRefreshToken
        self.updatedAt = updatedAt
    }
}

enum FanTeamIdentityChangeCenter {
    static let identityDidChangeNotification = Notification.Name("FanGeo.FanTeamIdentityDidChange")
    private static let changeUserInfoKey = "FanGeo.FanTeamIdentityChange"

    static func postIdentityChange(_ change: FanTeamIdentityChange) {
        invalidateCachedTeamLogoImages(
            previousLogoURL: change.previousLogoURL,
            previousThumbnailURL: change.previousLogoThumbnailURL,
            nextLogoURL: change.logoURL,
            nextThumbnailURL: change.logoThumbnailURL
        )
        NotificationCenter.default.post(
            name: identityDidChangeNotification,
            object: nil,
            userInfo: [changeUserInfoKey: change]
        )
    }

    static func identityChange(from notification: Notification) -> FanTeamIdentityChange? {
        notification.userInfo?[changeUserInfoKey] as? FanTeamIdentityChange
    }

    /// Drop decoded images for superseded Team logo URLs so marks never keep showing the old photo.
    static func invalidateCachedTeamLogoImages(
        previousLogoURL: String?,
        previousThumbnailURL: String?,
        nextLogoURL: String?,
        nextThumbnailURL: String?
    ) {
        let nextFull = ImageDisplayURL.canonicalStorageURLString(nextLogoURL)
        let nextThumb = ImageDisplayURL.canonicalStorageURLString(nextThumbnailURL)
        var candidates: [String] = []
        let prevFull = ImageDisplayURL.canonicalStorageURLString(previousLogoURL)
        let prevThumb = ImageDisplayURL.canonicalStorageURLString(previousThumbnailURL)
        if !prevFull.isEmpty, prevFull != nextFull, prevFull != nextThumb {
            candidates.append(prevFull)
        }
        if !prevThumb.isEmpty, prevThumb != nextFull, prevThumb != nextThumb {
            candidates.append(prevThumb)
        }
        if let list = ImageDisplayURL.forList(thumbnail: previousThumbnailURL, full: previousLogoURL),
           list != ImageDisplayURL.forList(thumbnail: nextThumbnailURL, full: nextLogoURL) {
            candidates.append(list)
        }
        let urls = candidates.compactMap { URL(string: $0) }
        guard !urls.isEmpty else { return }
        Task {
            await DiscoverMapImageCache.shared.invalidate(urls: urls)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
