import SwiftUI

// MARK: - Authorization

/// Whether FanGeo may display a specific artwork asset in-product.
/// Fail closed: missing / unknown / unverified → do not render remote official marks.
/// Pure authorization policy — nonisolated under default MainActor isolation.
nonisolated enum SportsArtworkAuthorization: String, Codable, Hashable, Sendable {
    /// Documented commercial license on file for this asset.
    case verifiedLicensed
    /// Drawn or authored by FanGeo (initials badges, generic SF Symbols, product art).
    case fanGeoOwned
    /// Platform/system-provided (e.g. Unicode regional-indicator flags, SF Symbols).
    case systemProvided
    /// Source exists but commercial rights are not documented.
    case unverified
    /// No usable artwork.
    case unavailable

    /// Remote official crest/photo may render only when verified licensed.
    var allowsOfficialRemoteArtwork: Bool {
        self == .verifiedLicensed
    }

    /// Safe for in-app display (FanGeo-owned, system, or verified).
    var allowsDisplay: Bool {
        switch self {
        case .verifiedLicensed, .fanGeoOwned, .systemProvided:
            return true
        case .unverified, .unavailable:
            return false
        }
    }
}

nonisolated enum SportsIdentityEntityType: String, Codable, Hashable, Sendable {
    case team
    case nationalTeam
    case league
    case competition
    case tournament
    case athlete
    case unknown
}

/// Provenance record for a single artwork asset. Empty registry ⇒ nothing is verified licensed.
nonisolated struct SportsArtworkProvenance: Hashable, Sendable, Codable {
    let entityID: String
    let entityType: SportsIdentityEntityType
    let artworkSource: String
    let authorization: SportsArtworkAuthorization
    let attribution: String?
    let licenseName: String?
    let licenseReference: String?
    let commercialUseAllowed: Bool?
    let verifiedAt: String?
    let notes: String?
}

/// Local, reviewable registry of verified artwork. Intentionally empty until legal review adds rows.
nonisolated enum SportsArtworkAuthorizationRegistry {
    /// Only entries with ``SportsArtworkAuthorization/verifiedLicensed`` may unlock remote official marks.
    private static let records: [String: SportsArtworkProvenance] = [:]

    static func provenance(entityID: String) -> SportsArtworkProvenance? {
        let key = entityID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return records[key]
    }

    static func authorization(
        entityID: String?,
        remoteURL: String?
    ) -> SportsArtworkAuthorization {
        let trimmedURL = remoteURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedURL.isEmpty {
            return .unavailable
        }
        guard URL(string: trimmedURL) != nil else {
            return .unavailable
        }
        guard let entityID,
              let record = provenance(entityID: entityID),
              record.authorization == .verifiedLicensed,
              record.commercialUseAllowed == true else {
            // Fail closed: presence of a URL alone never implies a license.
            return .unverified
        }
        return .verifiedLicensed
    }
}

// MARK: - Resolved display model

/// RGB components for domain resolution (avoids SwiftUI Color in nonisolated resolvers).
nonisolated struct SportsIdentityRGB: Equatable, Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(badgeRed: Double, badgeGreen: Double, badgeBlue: Double) {
        self.red = badgeRed
        self.green = badgeGreen
        self.blue = badgeBlue
    }
}

nonisolated enum SportsIdentityArtworkKind: Equatable, Sendable {
    case verifiedRemote(URL)
    case countryFlag(String)
    case fanGeoMonogram(text: String, rgb: SportsIdentityRGB, style: FanGeoTeamIdentityStyle)
    case genericSymbol(systemName: String, rgb: SportsIdentityRGB)
}

nonisolated struct SportsIdentityArtworkDescriptor: Equatable, Sendable {
    let kind: SportsIdentityArtworkKind
    let authorization: SportsArtworkAuthorization
    let accessibilityIsDecorative: Bool
}

/// Resolves the safest displayable identity artwork for an entity.
nonisolated enum SportsIdentityArtworkResolver {
    static func resolve(favoriteTeam team: FavoriteTeam) -> SportsIdentityArtworkDescriptor {
        let rgb = SportsIdentityRGB(
            badgeRed: team.badgeRed,
            badgeGreen: team.badgeGreen,
            badgeBlue: team.badgeBlue
        )
        if team.kind == .nationalTeam,
           let flag = CountryFlagHelper.flag(for: team.name)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !flag.isEmpty {
            return SportsIdentityArtworkDescriptor(
                kind: .countryFlag(flag),
                authorization: .systemProvided,
                accessibilityIsDecorative: true
            )
        }

        if team.kind.isCompetitionLike {
            return SportsIdentityArtworkDescriptor(
                kind: .genericSymbol(systemName: "trophy.fill", rgb: rgb),
                authorization: .fanGeoOwned,
                accessibilityIsDecorative: true
            )
        }

        if team.kind == .player || team.kind == .driver || team.kind == .fighter {
            return SportsIdentityArtworkDescriptor(
                kind: .fanGeoMonogram(
                    text: monogram(from: team.name, shortCode: team.shortCode),
                    rgb: rgb,
                    style: .standard
                ),
                authorization: .fanGeoOwned,
                accessibilityIsDecorative: true
            )
        }

        return SportsIdentityArtworkDescriptor(
            kind: .fanGeoMonogram(
                text: monogram(from: team.name, shortCode: team.shortCode),
                rgb: rgb,
                style: FanGeoTeamIdentityStyle.forSport(team.sport)
            ),
            authorization: .fanGeoOwned,
            accessibilityIsDecorative: true
        )
    }

    /// Live/schedule/Going team crest path — remote official marks only when verified licensed.
    static func resolveProGameTeam(
        teamName: String,
        badgeURL: String?,
        entityID: String? = nil,
        source: String
    ) -> SportsIdentityArtworkDescriptor {
        let cleaned = ProGameTeamScoreIdentity.cleanTeamName(teamName)
        if let flag = CountryFlagHelper.flag(for: cleaned, source: source)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !flag.isEmpty {
            return SportsIdentityArtworkDescriptor(
                kind: .countryFlag(flag),
                authorization: .systemProvided,
                accessibilityIsDecorative: true
            )
        }

        let auth = SportsArtworkAuthorizationRegistry.authorization(
            entityID: entityID ?? cleaned.lowercased(),
            remoteURL: badgeURL
        )
        if auth.allowsOfficialRemoteArtwork,
           let raw = badgeURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: raw) {
            return SportsIdentityArtworkDescriptor(
                kind: .verifiedRemote(url),
                authorization: .verifiedLicensed,
                accessibilityIsDecorative: true
            )
        }

        let mono = monogram(from: cleaned, shortCode: nil)
        let rgb = deterministicBadgeRGB(entityKey: cleaned)
        return SportsIdentityArtworkDescriptor(
            kind: .fanGeoMonogram(text: mono, rgb: rgb, style: .standard),
            authorization: .fanGeoOwned,
            accessibilityIsDecorative: true
        )
    }

    static func monogram(from name: String, shortCode: String?) -> String {
        if let shortCode {
            let trimmed = shortCode.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return String(trimmed.prefix(4)).uppercased()
            }
        }
        let parts = name.split(separator: " ").filter { !$0.isEmpty }
        if parts.count >= 2 {
            return String((parts[0].prefix(1) + parts[1].prefix(1))).uppercased()
        }
        return String(name.prefix(3)).uppercased()
    }

    /// Deterministic FanGeo palette from stable entity key (not scraped from unofficial crests).
    static func deterministicBadgeRGB(entityKey: String) -> SportsIdentityRGB {
        let key = entityKey
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var hash: UInt64 = 5381
        for scalar in key.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ UInt64(scalar.value)
        }
        let palette: [(Double, Double, Double)] = [
            (0.12, 0.45, 0.72),
            (0.18, 0.55, 0.38),
            (0.72, 0.22, 0.28),
            (0.45, 0.28, 0.70),
            (0.15, 0.35, 0.55),
            (0.55, 0.40, 0.18),
            (0.20, 0.55, 0.58),
            (0.35, 0.35, 0.42)
        ]
        let rgb = palette[Int(hash % UInt64(palette.count))]
        return SportsIdentityRGB(red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    /// View-facing convenience; domain resolution uses ``deterministicBadgeRGB``.
    static func deterministicBadgeColor(entityKey: String) -> Color {
        let rgb = deterministicBadgeRGB(entityKey: entityKey)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

// MARK: - Shared renderer

/// Single sports-identity artwork renderer. Consumers must not decide logo safety independently.
struct SportsIdentityArtworkView: View {
    let descriptor: SportsIdentityArtworkDescriptor
    var diameter: CGFloat = 40
    /// When set, prefer the established FanGeo favorite-team badge shapes.
    private var favoriteTeam: FavoriteTeam? = nil

    init(descriptor: SportsIdentityArtworkDescriptor, diameter: CGFloat = 40) {
        self.descriptor = descriptor
        self.diameter = diameter
        self.favoriteTeam = nil
    }

    init(favoriteTeam team: FavoriteTeam, diameter: CGFloat = 40) {
        self.descriptor = SportsIdentityArtworkResolver.resolve(favoriteTeam: team)
        self.diameter = diameter
        self.favoriteTeam = team
    }

    var body: some View {
        Group {
            if let favoriteTeam {
                FanGeoTeamIdentityBadge(team: favoriteTeam, diameter: diameter)
            } else {
                resolvedArtwork
            }
        }
        .accessibilityHidden(descriptor.accessibilityIsDecorative)
    }

    @ViewBuilder
    private var resolvedArtwork: some View {
        switch descriptor.kind {
        case .verifiedRemote(let url):
            DiscoverCachedRemoteImage(url: url, contentMode: .fit) {
                let fallbackRGB = SportsIdentityArtworkResolver.deterministicBadgeRGB(entityKey: url.absoluteString)
                FanGeoMonogramBadge(
                    text: "FG",
                    color: Color(red: fallbackRGB.red, green: fallbackRGB.green, blue: fallbackRGB.blue),
                    style: .standard,
                    diameter: diameter
                )
            }
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())

        case .countryFlag(let flag):
            ZStack {
                Circle()
                    .fill(Color(.tertiarySystemFill))
                Text(flag)
                    .font(.system(size: max(18, diameter * 0.54)))
                    .minimumScaleFactor(0.82)
                    .lineLimit(1)
            }
            .frame(width: diameter, height: diameter)

        case .fanGeoMonogram(let text, let rgb, let style):
            FanGeoMonogramBadge(
                text: text,
                color: Color(red: rgb.red, green: rgb.green, blue: rgb.blue),
                style: style,
                diameter: diameter
            )

        case .genericSymbol(let systemName, let rgb):
            let tint = Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
            ZStack {
                Circle()
                    .fill(tint.opacity(0.18))
                Image(systemName: systemName)
                    .font(.system(size: diameter * 0.42, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: diameter, height: diameter)
        }
    }
}

/// FanGeo-owned monogram badge (not an imitation of any official crest).
struct FanGeoMonogramBadge: View {
    let text: String
    let color: Color
    var style: FanGeoTeamIdentityStyle = .standard
    var diameter: CGFloat = 40

    var body: some View {
        // Reuse sport-specific shapes via a lightweight FavoriteTeam stand-in path is heavy;
        // keep a clean circular monogram for shared non-catalog entities.
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [color, color.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(text)
                .font(.system(size: diameter * 0.32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(width: diameter, height: diameter)
        .overlay {
            Circle()
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: color.opacity(0.35), radius: 4, y: 2)
    }
}
