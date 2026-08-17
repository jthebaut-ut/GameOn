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
    /// True when bytes were replaced (including same-URL overwrite) or the logo was removed.
    /// Name/sport/color-only edits stay false so working bitmaps are not dropped.
    let artworkReplaced: Bool

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
        updatedAt: Date = Date(),
        artworkReplaced: Bool? = nil
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
        let urlsChanged = self.previousLogoURL != self.logoURL
            || self.previousLogoThumbnailURL != self.logoThumbnailURL
        self.artworkReplaced = artworkReplaced ?? urlsChanged
    }
}

enum FanTeamIdentityChangeCenter {
    static let identityDidChangeNotification = Notification.Name("FanGeo.FanTeamIdentityDidChange")
    private static let changeUserInfoKey = "FanGeo.FanTeamIdentityChange"

    static func postIdentityChange(_ change: FanTeamIdentityChange) {
        let urls = FanTeamArtworkPropagation.urlsToInvalidate(from: change)
        if !urls.isEmpty {
            Task {
                await DiscoverMapImageCache.shared.invalidate(urls: urls)
            }
        }
        Task { @MainActor in
            ProfilePhase1PersonalizationCache.applyFanTeamIdentityChange(change)
        }
        NotificationCenter.default.post(
            name: identityDidChangeNotification,
            object: nil,
            userInfo: [changeUserInfoKey: change]
        )
    }

    static func identityChange(from notification: Notification) -> FanTeamIdentityChange? {
        notification.userInfo?[changeUserInfoKey] as? FanTeamIdentityChange
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
