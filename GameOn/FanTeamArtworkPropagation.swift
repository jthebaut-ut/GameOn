import Foundation

/// One Team-scoped artwork identity path for Discover / Chat / cache keys.
/// Version changes only when Team artwork actually changes — never per render.
nonisolated enum FanTeamArtworkPropagation {
    static func artworkChanged(_ change: FanTeamIdentityChange) -> Bool {
        if change.artworkReplaced { return true }
        return change.previousLogoURL != change.logoURL
            || change.previousLogoThumbnailURL != change.logoThumbnailURL
    }

    static func applying(_ change: FanTeamIdentityChange, to row: DiscoverableFanTeamMapRow) -> DiscoverableFanTeamMapRow {
        guard change.teamId == row.id else { return row }
        return DiscoverableFanTeamMapRow(
            id: row.id,
            name: change.name.isEmpty ? row.name : change.name,
            sport: change.sport.isEmpty ? row.sport : change.sport,
            sportSubtype: row.sportSubtype,
            logoURL: change.logoURL,
            logoThumbnailURL: change.logoThumbnailURL,
            colorHex: change.colorHex ?? row.colorHex,
            lookingForPlayers: row.lookingForPlayers,
            memberCount: row.memberCount,
            precision: row.precision,
            placeName: row.placeName,
            city: row.city,
            region: row.region,
            postalCode: row.postalCode,
            countryCode: row.countryCode,
            latitude: row.latitude,
            longitude: row.longitude,
            displayRefreshToken: artworkChanged(change) ? change.displayRefreshToken : row.displayRefreshToken
        )
    }

    static func patchRows(
        _ rows: [DiscoverableFanTeamMapRow],
        with change: FanTeamIdentityChange
    ) -> (rows: [DiscoverableFanTeamMapRow], didChange: Bool) {
        var didChange = false
        let next = rows.map { row -> DiscoverableFanTeamMapRow in
            let patched = applying(change, to: row)
            if artworkIdentity(patched) != artworkIdentity(row)
                || patched.name != row.name
                || patched.sport != row.sport
                || patched.colorHex != row.colorHex {
                didChange = true
            }
            return patched
        }
        return (next, didChange)
    }

    /// Map annotation render identity. Team id/location stay stable; artwork version can change.
    static func annotationFingerprint(for row: DiscoverableFanTeamMapRow) -> String {
        [
            row.id.uuidString.lowercased(),
            FanGeoFixedFloatFormat.d4(row.latitude),
            FanGeoFixedFloatFormat.d4(row.longitude),
            row.sport,
            row.sportSubtype ?? "",
            row.lookingForPlayers ? "1" : "0",
            ImageDisplayURL.canonicalStorageURLString(row.logoThumbnailURL),
            ImageDisplayURL.canonicalStorageURLString(row.logoURL),
            row.displayRefreshToken?.uuidString.lowercased() ?? "-"
        ].joined(separator: ":")
    }

    private static func artworkIdentity(_ row: DiscoverableFanTeamMapRow) -> String {
        annotationFingerprint(for: row)
    }

    static func cacheIdentity(url: String, version: UUID?) -> String {
        let canonical = ImageDisplayURL.canonicalStorageURLString(url)
        guard let version else { return canonical }
        return ImageDisplayURL.displayVersionedURLString(canonical, refreshToken: version)
    }

    static func urlsToInvalidate(from change: FanTeamIdentityChange) -> [URL] {
        guard artworkChanged(change) else { return [] }
        var candidates: [String] = []
        let prevFull = ImageDisplayURL.canonicalStorageURLString(change.previousLogoURL)
        let prevThumb = ImageDisplayURL.canonicalStorageURLString(change.previousLogoThumbnailURL)
        let nextFull = ImageDisplayURL.canonicalStorageURLString(change.logoURL)
        let nextThumb = ImageDisplayURL.canonicalStorageURLString(change.logoThumbnailURL)
        if !prevFull.isEmpty, prevFull != nextFull || change.artworkReplaced {
            candidates.append(prevFull)
        }
        if !prevThumb.isEmpty,
           (prevThumb != nextThumb && prevThumb != nextFull) || change.artworkReplaced {
            candidates.append(prevThumb)
        }
        if let list = ImageDisplayURL.forList(
            thumbnail: change.previousLogoThumbnailURL,
            full: change.previousLogoURL
        ) {
            candidates.append(list)
        }
        var seen = Set<String>()
        return candidates.compactMap { raw -> URL? in
            let canonical = ImageDisplayURL.canonicalStorageURLString(raw)
            guard !canonical.isEmpty, seen.insert(canonical).inserted else { return nil }
            return URL(string: canonical)
        }
    }
}
