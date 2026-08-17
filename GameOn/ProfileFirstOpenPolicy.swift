import CoreLocation
import Foundation

/// First-open Profile work that must not compete with the first scroll.
enum ProfileFirstOpenWorkItem: String, Equatable, CaseIterable, Sendable {
    case profileIdentity
    case myTeams
    case favoriteTeamsFromAppStorage
    case homeCrowdCached
    case artworkSeed
    case pickupOrganizer
    case suggestedFans
    case sponsoredPlacement
    case profileStats
    case suggestedFanAvatarPrefetch
    case providerArtworkRefresh
}

enum ProfileFirstOpenPriority: Int, Equatable, Sendable {
    /// Hero / My Teams / Favorite Teams / cached Home Crowd.
    case immediateViewport = 0
    /// Remaining first-card chrome after the first frame.
    case afterFirstFrame = 1
    /// Below-fold / optional. Must not monopolize MainActor or image decode.
    case idleSecondary = 2
}

enum ProfileFirstOpenScheduler {
    static func priority(for item: ProfileFirstOpenWorkItem) -> ProfileFirstOpenPriority {
        switch item {
        case .profileIdentity, .myTeams, .favoriteTeamsFromAppStorage, .homeCrowdCached:
            return .immediateViewport
        case .artworkSeed, .pickupOrganizer:
            return .afterFirstFrame
        case .suggestedFans, .sponsoredPlacement, .profileStats, .suggestedFanAvatarPrefetch, .providerArtworkRefresh:
            return .idleSecondary
        }
    }

    static func shouldStartOnFirstAppear(_ item: ProfileFirstOpenWorkItem) -> Bool {
        priority(for: item) == .immediateViewport
    }

    static func shouldDeferUntilIdle(_ item: ProfileFirstOpenWorkItem) -> Bool {
        priority(for: item) == .idleSecondary
    }
}

/// Sponsored Profile ads may use cached GPS / Home Crowd. They must not wait on a fresh fix
/// before the first Profile frame can scroll.
enum ProfileSponsoredLocationPolicy {
    static func isUsable(_ location: CLLocationCoordinate2D?) -> Bool {
        guard let location,
              CLLocationCoordinate2DIsValid(location),
              abs(location.latitude) > 0.0001 || abs(location.longitude) > 0.0001 else {
            return false
        }
        return true
    }

    static func firstPaintLocation(
        cached: CLLocationCoordinate2D?,
        homeCrowd: CLLocationCoordinate2D?
    ) -> CLLocationCoordinate2D? {
        if isUsable(cached) { return cached }
        if isUsable(homeCrowd) { return homeCrowd }
        return nil
    }
}

extension ProfileIdentityScrollSnapshotBuilder {
    /// Cheap Favorite Teams paint identity. Resolving each crest URL on every parent body
    /// was N+1 MainActor work even when `ProfileIdentityScrollGate` skipped descendants.
    static func compactArtworkFingerprint(teamIDs: [String], paintRevision: UInt64) -> String {
        "rev=\(paintRevision)|ids=\(teamIDs.joined(separator: ","))"
    }
}
