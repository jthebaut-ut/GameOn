import Foundation

/// Team identity attached to a Discover-visible Pickup Game (from
/// `list_pickup_discover_team_identities` or RLS fallback). Not a parallel game model.
struct PickupDiscoverTeamIdentity: Equatable, Sendable, Hashable {
    let pickupGameId: UUID
    let teamId: UUID
    let teamName: String
    let teamSport: String
    let colorHex: String?
    let logoURL: String?
    let logoThumbnailURL: String?
    /// Bumped when FanTeamIdentityChangeCenter posts a matching Team change.
    var displayRefreshToken: UUID?

    var hasCustomLogo: Bool {
        let thumb = ImageDisplayURL.canonicalStorageURLString(logoThumbnailURL)
        let full = ImageDisplayURL.canonicalStorageURLString(logoURL)
        return !thumb.isEmpty || !full.isEmpty
    }

    func applyingIdentityChange(_ change: FanTeamIdentityChange) -> PickupDiscoverTeamIdentity {
        guard change.teamId == teamId else { return self }
        return PickupDiscoverTeamIdentity(
            pickupGameId: pickupGameId,
            teamId: teamId,
            teamName: change.name.isEmpty ? teamName : change.name,
            teamSport: change.sport.isEmpty ? teamSport : change.sport,
            colorHex: change.colorHex ?? colorHex,
            logoURL: change.logoURL,
            logoThumbnailURL: change.logoThumbnailURL,
            displayRefreshToken: change.displayRefreshToken
        )
    }
}

/// Wire row for `list_pickup_discover_team_identities`.
struct PickupDiscoverTeamIdentityRPCRow: Decodable, Sendable {
    let pickup_game_id: UUID
    let team_id: UUID
    let team_name: String?
    let team_sport: String?
    let color_hex: String?
    let logo_url: String?
    let logo_thumbnail_url: String?

    func asIdentity() -> PickupDiscoverTeamIdentity? {
        let name = (team_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let sport = (team_sport ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return PickupDiscoverTeamIdentity(
            pickupGameId: pickup_game_id,
            teamId: team_id,
            teamName: name,
            teamSport: sport,
            colorHex: FanTeamColorPalette.normalized(color_hex),
            logoURL: ImageDisplayURL.canonicalStorageURLString(logo_url).nilIfEmptyDiscoverTeam,
            logoThumbnailURL: ImageDisplayURL.canonicalStorageURLString(logo_thumbnail_url).nilIfEmptyDiscoverTeam,
            displayRefreshToken: nil
        )
    }
}

/// Centralized Discover presentation for Team-linked vs ordinary Pickup Games.
/// Rules use Team-link + outside recruiting — never `is_visible == private` alone.
enum PickupDiscoverTeamPresentation {
    static func isOutsideRecruiting(for game: PickupGameRow) -> Bool {
        PickupTeamOutsideRecruiting.isEnabled(
            playersNeeded: game.playersNeededClamped,
            maxPlayers: game.max_players
        )
    }

    static func isTeamLinked(_ identity: PickupDiscoverTeamIdentity?) -> Bool {
        identity != nil
    }

    /// Whether map availability badge / “spots left” chip may advertise open spots.
    static func shouldShowPublicAvailability(
        isTeamLinked: Bool,
        isOutsideRecruiting: Bool
    ) -> Bool {
        if !isTeamLinked { return true }
        return isOutsideRecruiting
    }

    static func shouldShowPublicAvailability(
        identity: PickupDiscoverTeamIdentity?,
        game: PickupGameRow
    ) -> Bool {
        shouldShowPublicAvailability(
            isTeamLinked: isTeamLinked(identity),
            isOutsideRecruiting: isOutsideRecruiting(for: game)
        )
    }

    /// Classic “Request to Join” / misleading join CTA for outsiders on Team-only games.
    static func shouldOfferOutsideJoinCTA(
        isTeamLinked: Bool,
        isOutsideRecruiting: Bool
    ) -> Bool {
        if !isTeamLinked { return true }
        return isOutsideRecruiting
    }

    static func previewPrimaryCTATitleKey(
        isTeamLinked: Bool,
        isOutsideRecruiting: Bool
    ) -> String {
        if isTeamLinked, !isOutsideRecruiting {
            return "pickup_preview_details"
        }
        return "pickup_preview_details_and_join"
    }

    /// VoiceOver for a Discover map pin.
    static func mapPinAccessibilityLabel(
        gameTitle: String,
        sportLabel: String,
        identity: PickupDiscoverTeamIdentity?,
        showsPublicAvailability: Bool,
        spotsNeeded: Int,
        languageCode: String
    ) -> String {
        if let identity {
            var parts: [String] = [identity.teamName, sportLabel]
            if showsPublicAvailability {
                parts.append(
                    pickupLocalizedSpotsLeft(spotsNeeded, languageCode: languageCode)
                )
            }
            if !gameTitle.isEmpty,
               gameTitle.caseInsensitiveCompare(identity.teamName) != .orderedSame {
                parts.append(gameTitle)
            }
            return parts.joined(separator: ", ")
        }
        return "Pickup \(sportLabel), \(pickupLocalizedSpotsLeft(spotsNeeded, languageCode: languageCode)), \(gameTitle)"
    }
}

private extension String {
    var nilIfEmptyDiscoverTeam: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
