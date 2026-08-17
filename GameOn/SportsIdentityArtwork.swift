import SwiftUI

// MARK: - Authorization

/// Whether FanGeo may display a specific artwork asset in-product.
/// Fail closed: missing / unknown / unverified → do not render remote official marks.
/// Pure authorization policy — nonisolated under default MainActor isolation.
nonisolated enum SportsArtworkAuthorization: String, Codable, Hashable, Sendable {
    /// Documented commercial license on file for this asset.
    case verifiedLicensed
    /// TheSportsDB official API artwork, displayed unmodified ("as is").
    case providerAPIAsIs
    /// Drawn or authored by FanGeo (initials badges, generic SF Symbols, product art).
    case fanGeoOwned
    /// Platform/system-provided (e.g. Unicode regional-indicator flags, SF Symbols).
    case systemProvided
    /// Source exists but commercial rights are not documented.
    case unverified
    /// No usable artwork.
    case unavailable

    /// Remote official crest/photo may render when verified licensed or returned by TheSportsDB API.
    var allowsOfficialRemoteArtwork: Bool {
        self == .verifiedLicensed || self == .providerAPIAsIs
    }

    /// Safe for in-app display (FanGeo-owned, system, or verified).
    var allowsDisplay: Bool {
        switch self {
        case .verifiedLicensed, .providerAPIAsIs, .fanGeoOwned, .systemProvided:
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
        if SportsArtworkURLStore.isTheSportsDBArtworkURL(trimmedURL) {
            return .providerAPIAsIs
        }
        guard let entityID,
              let record = provenance(entityID: entityID),
              record.authorization == .verifiedLicensed,
              record.commercialUseAllowed == true else {
            // Fail closed for non-TheSportsDB hosts: presence of a URL alone never implies a license.
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
    /// Professional player / featured athlete with no authorized photo.
    case playerAthleteFallback(rgb: SportsIdentityRGB)
    /// League / competition / tournament with no authorized provider mark.
    case competitionFallback(rgb: SportsIdentityRGB)
}

nonisolated struct SportsIdentityArtworkDescriptor: Equatable, Sendable {
    let kind: SportsIdentityArtworkKind
    let authorization: SportsArtworkAuthorization
    let accessibilityIsDecorative: Bool
}

/// Neutral plate behind provider artwork. The container may be circular;
/// the crest itself stays unmodified aspect-fit (no recolor, no circular crop).
enum SportsIdentityArtworkPlate: Equatable, Sendable {
    /// Default system fill for light Profile / picker chrome.
    case system
    /// Light translucent plate for Favorite Team cards on saturated gradients.
    case lightTranslucent
    /// Near-white circular plate for the light Favorite Teams identity card.
    case neutralLogo
}

/// Canonical identity slot + optical inset. Source logos keep their aspect ratio;
/// padding equalizes visual weight across NBA wordmarks, soccer crests, and portraits.
enum SportsIdentityArtworkMetrics {
    static let favoriteSlot: CGFloat = 56
    static let favoriteCardPlate: CGFloat = 118
    static let matchupSlot: CGFloat = 28
    /// Primary LIVE scoreboard crests. Compact title-area logos stay on `matchupSlot`.
    static let liveScoreboardSlot: CGFloat = 72
    /// Schedule → Live featured matchup crests (Your Teams Live + Live Now scoreboard).
    static let featuredMatchupSlot: CGFloat = 52
    /// Own + public Profile hero My Team / National Team circular plate.
    static let profileHeroIdentitySlot: CGFloat = 56
    /// Visible crest inside ``profileHeroIdentitySlot`` (not the plate diameter).
    static let profileHeroVisibleArtwork: CGFloat = 48
    static let crestInsetRatio: CGFloat = 0.18
    static let playerInsetRatio: CGFloat = 0.06

    enum OpticalInset: Equatable, Sendable {
        case standard
        case profileHero
    }

    static func inset(
        for diameter: CGFloat,
        playerPortrait: Bool,
        optical: OpticalInset = .standard
    ) -> CGFloat {
        if optical == .profileHero {
            return max(4, (diameter - profileHeroVisibleArtwork) / 2)
        }
        let ratio = playerPortrait ? playerInsetRatio : crestInsetRatio
        let minimum: CGFloat = playerPortrait ? 2 : 7
        return max(minimum, diameter * ratio)
    }

    static func visibleArtworkSize(
        container: CGFloat,
        playerPortrait: Bool = false,
        optical: OpticalInset = .standard
    ) -> CGFloat {
        max(0, container - 2 * inset(for: container, playerPortrait: playerPortrait, optical: optical))
    }
}

/// Resolves the safest displayable identity artwork for an entity.
/// FanGeo user-created Teams must use ``FanTeamMarkView`` — never this resolver.
nonisolated enum SportsIdentityArtworkResolver {
    static func resolve(favoriteTeam team: FavoriteTeam, diameter: CGFloat = 44) -> SportsIdentityArtworkDescriptor {
        let rgb = SportsIdentityRGB(
            badgeRed: team.badgeRed,
            badgeGreen: team.badgeGreen,
            badgeBlue: team.badgeBlue
        )

        switch team.kind {
        case .player, .driver, .fighter:
            if let remote = officialRemote(
                playerImageURL(for: team),
                entityID: team.id,
                diameter: diameter
            ) {
                return remote
            }
            return playerAthleteFallbackDescriptor(
                rgb: FanGeoPlayerAthleteFallbackMarkMetrics.plateRGB(from: rgb)
            )

        case .nationalTeam:
            if let remote = officialRemote(
                providerBadgeURL(for: team),
                entityID: team.id,
                diameter: diameter
            ) {
                return remote
            }
            if let flag = CountryFlagHelper.flag(for: team.name)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !flag.isEmpty {
                return SportsIdentityArtworkDescriptor(
                    kind: .countryFlag(flag),
                    authorization: .systemProvided,
                    accessibilityIsDecorative: true
                )
            }
            return monogramDescriptor(name: team.name, shortCode: team.shortCode, rgb: rgb, style: .standard)

        case .league, .competition, .tournament:
            if let remote = officialRemote(
                competitionArtworkURL(for: team),
                entityID: team.id,
                diameter: diameter
            ) {
                return remote
            }
            return competitionFallbackDescriptor(rgb: rgb)

        case .team, .interest:
            if let remote = officialRemote(
                providerBadgeURL(for: team),
                entityID: team.id,
                diameter: diameter
            ) {
                return remote
            }
            return monogramDescriptor(
                name: team.name,
                shortCode: team.shortCode,
                rgb: rgb,
                style: FanGeoTeamIdentityStyle.forSport(team.sport)
            )
        }
    }

    static func resolveNationalTeam(
        countryName: String,
        flag: String?,
        diameter: CGFloat = 44
    ) -> SportsIdentityArtworkDescriptor {
        if let remote = officialRemote(
            SportsArtworkURLStore.shared.badgeURL(teamName: countryName),
            entityID: countryName,
            diameter: diameter
        ) {
            return remote
        }
        let trimmedFlag = flag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedFlag.isEmpty {
            return SportsIdentityArtworkDescriptor(
                kind: .countryFlag(trimmedFlag),
                authorization: .systemProvided,
                accessibilityIsDecorative: true
            )
        }
        if let derived = CountryFlagHelper.flag(for: countryName)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !derived.isEmpty {
            return SportsIdentityArtworkDescriptor(
                kind: .countryFlag(derived),
                authorization: .systemProvided,
                accessibilityIsDecorative: true
            )
        }
        let rgb = deterministicBadgeRGB(entityKey: countryName)
        return monogramDescriptor(name: countryName, shortCode: nil, rgb: rgb, style: .standard)
    }

    /// Live/schedule/Going team crest path.
    /// Priority: TheSportsDB badge → cached provider art → national flag → FanGeo monogram.
    static func resolveProGameTeam(
        teamName: String,
        badgeURL: String?,
        entityID: String? = nil,
        league: String? = nil,
        source: String,
        diameter: CGFloat = 44
    ) -> SportsIdentityArtworkDescriptor {
        let cleaned = ProGameTeamScoreIdentity.cleanTeamName(teamName)
        let cached = SportsArtworkURLStore.shared.badgeURL(
            providerId: entityID,
            league: league,
            teamName: cleaned
        )
        if let remote = officialRemote(
            firstNonEmpty(badgeURL, cached),
            entityID: entityID ?? cleaned,
            diameter: diameter
        ) {
            return remote
        }
        if let flag = CountryFlagHelper.flag(for: cleaned, source: source)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !flag.isEmpty {
            return SportsIdentityArtworkDescriptor(
                kind: .countryFlag(flag),
                authorization: .systemProvided,
                accessibilityIsDecorative: true
            )
        }

        let rgb = deterministicBadgeRGB(entityKey: cleaned)
        return monogramDescriptor(name: cleaned, shortCode: nil, rgb: rgb, style: .standard)
    }

    /// FanGeo user-created Teams never resolve through TheSportsDB.
    static func resolveFanGeoUserTeam() -> SportsIdentityArtworkDescriptor {
        SportsIdentityArtworkDescriptor(
            kind: .genericSymbol(
                systemName: "person.3.fill",
                rgb: SportsIdentityRGB(red: 0.45, green: 0.28, blue: 0.70)
            ),
            authorization: .fanGeoOwned,
            accessibilityIsDecorative: true
        )
    }

    /// Provider ID (when the store already has it) → catalog ID → league + name → name-only.
    /// Conference/group labels such as "Western Conference" also try the sport's
    /// canonical league token (NBA / NFL / …) so Profile favorites match live ingest.
    static func providerBadgeURL(for team: FavoriteTeam) -> String? {
        let store = SportsArtworkURLStore.shared
        if let url = store.badgeURL(catalogId: team.id) {
            return url
        }
        for name in artworkLookupNames(for: team) {
            for league in artworkLookupLeagues(for: team) {
                if let url = store.badgeURL(league: league, teamName: name) {
                    return url
                }
            }
            if let url = store.badgeURL(teamName: name) {
                return url
            }
        }
        return nil
    }

    static func artworkLookupNames(for team: FavoriteTeam) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        func add(_ raw: String?) {
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { return }
            let key = trimmed.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            ).lowercased()
            guard seen.insert(key).inserted else { return }
            names.append(trimmed)
        }
        add(team.name)
        for alias in team.searchAliases {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 4 else { continue }
            if trimmed.uppercased() == trimmed, trimmed.count <= 4 { continue }
            add(trimmed)
        }
        let parts = team.name.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        if parts.count >= 2 {
            let last = parts[parts.count - 1]
            if last.count >= 4 {
                add(last)
            }
        }
        return names
    }

    static func artworkLookupLeagues(for team: FavoriteTeam) -> [String] {
        var seen = Set<String>()
        var leagues: [String] = []
        func add(_ raw: String?) {
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { return }
            let key = trimmed.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            ).lowercased()
            guard seen.insert(key).inserted else { return }
            leagues.append(trimmed)
        }
        add(team.league)
        add(team.region)
        add(team.sport.discoverSportToken)
        return leagues
    }

    private static func playerImageURL(for team: FavoriteTeam) -> String? {
        let store = SportsArtworkURLStore.shared
        if let url = store.playerImageURL(playerName: team.name) {
            return url
        }
        for alias in team.searchAliases {
            if let url = store.playerImageURL(playerName: alias) {
                return url
            }
        }
        return nil
    }

    /// Competition / league / tournament marks only — never a club crest or national flag.
    static func competitionArtworkURL(for team: FavoriteTeam) -> String? {
        let store = SportsArtworkURLStore.shared
        if let url = store.badgeURL(catalogId: team.id) {
            return url
        }
        if let url = store.leagueBadgeURL(leagueName: team.name) {
            return url
        }
        for alias in team.searchAliases {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 4 else { continue }
            if let url = store.leagueBadgeURL(leagueName: trimmed) {
                return url
            }
        }
        return nil
    }

    static func competitionFallbackDescriptor(rgb: SportsIdentityRGB) -> SportsIdentityArtworkDescriptor {
        SportsIdentityArtworkDescriptor(
            kind: .competitionFallback(rgb: FanGeoCompetitionFallbackMarkMetrics.plateRGB(from: rgb)),
            authorization: .fanGeoOwned,
            accessibilityIsDecorative: true
        )
    }

    private static func officialRemote(
        _ raw: String?,
        entityID: String?,
        diameter: CGFloat
    ) -> SportsIdentityArtworkDescriptor? {
        let auth = SportsArtworkAuthorizationRegistry.authorization(
            entityID: entityID,
            remoteURL: raw
        )
        guard auth.allowsOfficialRemoteArtwork,
              let url = SportsArtworkURLStore.displayURL(from: raw, diameter: diameter) else {
            return nil
        }
        return SportsIdentityArtworkDescriptor(
            kind: .verifiedRemote(url),
            authorization: auth,
            accessibilityIsDecorative: true
        )
    }

    private static func monogramDescriptor(
        name: String,
        shortCode: String?,
        rgb: SportsIdentityRGB,
        style: FanGeoTeamIdentityStyle
    ) -> SportsIdentityArtworkDescriptor {
        SportsIdentityArtworkDescriptor(
            kind: .fanGeoMonogram(
                text: monogram(from: name, shortCode: shortCode),
                rgb: rgb,
                style: style
            ),
            authorization: .fanGeoOwned,
            accessibilityIsDecorative: true
        )
    }

    static func playerAthleteFallbackDescriptor(
        rgb: SportsIdentityRGB = FanGeoPlayerAthleteFallbackMarkMetrics.canonicalRGB
    ) -> SportsIdentityArtworkDescriptor {
        SportsIdentityArtworkDescriptor(
            kind: .playerAthleteFallback(rgb: rgb),
            authorization: .fanGeoOwned,
            accessibilityIsDecorative: true
        )
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
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
struct SportsIdentityArtworkView: View, Equatable {
    private enum Source: Equatable {
        case snapshot(SportsIdentityArtworkDescriptor)
        case favorite(FavoriteTeam)
        case national(countryName: String, flag: String?)
        case proGame(teamName: String, badgeURL: String?, entityID: String?, league: String?, source: String)
    }

    private let source: Source
    var diameter: CGFloat = 40
    var plate: SportsIdentityArtworkPlate = .system
    var opticalInset: SportsIdentityArtworkMetrics.OpticalInset = .standard
    @Environment(\.colorScheme) private var colorScheme

    init(
        descriptor: SportsIdentityArtworkDescriptor,
        diameter: CGFloat = 40,
        plate: SportsIdentityArtworkPlate = .system,
        opticalInset: SportsIdentityArtworkMetrics.OpticalInset = .standard
    ) {
        self.source = .snapshot(descriptor)
        self.diameter = diameter
        self.plate = plate
        self.opticalInset = opticalInset
    }

    init(
        favoriteTeam team: FavoriteTeam,
        diameter: CGFloat = 40,
        plate: SportsIdentityArtworkPlate = .system,
        opticalInset: SportsIdentityArtworkMetrics.OpticalInset = .standard
    ) {
        self.source = .favorite(team)
        self.diameter = diameter
        self.plate = plate
        self.opticalInset = opticalInset
    }

    init(
        countryName: String,
        flag: String?,
        diameter: CGFloat = 40,
        plate: SportsIdentityArtworkPlate = .system,
        opticalInset: SportsIdentityArtworkMetrics.OpticalInset = .standard
    ) {
        self.source = .national(countryName: countryName, flag: flag)
        self.diameter = diameter
        self.plate = plate
        self.opticalInset = opticalInset
    }

    init(
        teamName: String,
        badgeURL: String?,
        entityID: String? = nil,
        league: String? = nil,
        source: String,
        diameter: CGFloat = 40,
        plate: SportsIdentityArtworkPlate = .system,
        opticalInset: SportsIdentityArtworkMetrics.OpticalInset = .standard
    ) {
        self.source = .proGame(
            teamName: teamName,
            badgeURL: badgeURL,
            entityID: entityID,
            league: league,
            source: source
        )
        self.diameter = diameter
        self.plate = plate
        self.opticalInset = opticalInset
    }

    static func == (lhs: SportsIdentityArtworkView, rhs: SportsIdentityArtworkView) -> Bool {
        lhs.source == rhs.source
            && lhs.diameter == rhs.diameter
            && lhs.plate == rhs.plate
            && lhs.opticalInset == rhs.opticalInset
    }

    private var resolvedDescriptor: SportsIdentityArtworkDescriptor {
        switch source {
        case .snapshot(let descriptor):
            return descriptor
        case .favorite(let team):
            return SportsIdentityArtworkResolver.resolve(favoriteTeam: team, diameter: diameter)
        case .national(let countryName, let flag):
            return SportsIdentityArtworkResolver.resolveNationalTeam(
                countryName: countryName,
                flag: flag,
                diameter: diameter
            )
        case .proGame(let teamName, let badgeURL, let entityID, let league, let sourceName):
            return SportsIdentityArtworkResolver.resolveProGameTeam(
                teamName: teamName,
                badgeURL: badgeURL,
                entityID: entityID,
                league: league,
                source: sourceName,
                diameter: diameter
            )
        }
    }

    private var plateFill: Color {
        switch plate {
        case .system:
            return Color(.tertiarySystemFill)
        case .lightTranslucent:
            return Color.white.opacity(colorScheme == .dark ? 0.18 : 0.90)
        case .neutralLogo:
            return colorScheme == .dark
                ? Color.white.opacity(0.96)
                : Color(red: 0.97, green: 0.975, blue: 0.98)
        }
    }

    private var plateStroke: Color {
        switch plate {
        case .neutralLogo:
            return colorScheme == .dark
                ? Color.black.opacity(0.08)
                : Color.black.opacity(0.06)
        case .system, .lightTranslucent:
            return Color.clear
        }
    }

    var body: some View {
        let _ = FanGeoInboxOpenPerf.artworkResolverCall()
        artwork(for: resolvedDescriptor)
            .accessibilityHidden(resolvedDescriptor.accessibilityIsDecorative)
    }

    private var isPlayerPortrait: Bool {
        if case .favorite(let team) = source {
            return team.kind.isProfessionalAthlete
        }
        return false
    }

    @ViewBuilder
    private func artwork(for descriptor: SportsIdentityArtworkDescriptor) -> some View {
        switch descriptor.kind {
        case .verifiedRemote(let url):
            ZStack {
                Circle()
                    .fill(plateFill)
                DiscoverCachedRemoteImage(
                    url: url,
                    contentMode: isPlayerPortrait ? .fill : .fit,
                    bucket: DiscoverMapImageCache.Bucket.forPointSize(diameter)
                ) {
                    Color.clear
                }
                .padding(
                    SportsIdentityArtworkMetrics.inset(
                        for: diameter,
                        playerPortrait: isPlayerPortrait,
                        optical: opticalInset
                    )
                )
            }
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .strokeBorder(plateStroke, lineWidth: plate == .neutralLogo ? 0.75 : 0)
            }

        case .countryFlag(let flag):
            ZStack {
                Circle()
                    .fill(plateFill)
                Text(flag)
                    .font(.system(size: max(18, diameter * (opticalInset == .profileHero ? 0.62 : 0.54))))
                    .minimumScaleFactor(0.82)
                    .lineLimit(1)
            }
            .frame(width: diameter, height: diameter)

        case .fanGeoMonogram(let text, let rgb, let style):
            if isPlayerPortrait {
                FanGeoPlayerAthleteFallbackMark(diameter: diameter, rgb: rgb)
            } else if case .favorite(let team) = source {
                FanGeoTeamIdentityBadge(team: team, diameter: diameter)
            } else {
                FanGeoMonogramBadge(
                    text: text,
                    color: Color(red: rgb.red, green: rgb.green, blue: rgb.blue),
                    style: style,
                    diameter: diameter
                )
            }

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

        case .playerAthleteFallback(let rgb):
            FanGeoPlayerAthleteFallbackMark(diameter: diameter, rgb: rgb)

        case .competitionFallback(let rgb):
            FanGeoCompetitionFallbackMark(diameter: diameter, rgb: rgb)
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

/// Vector fallback for professional players / featured athletes when no photo exists.
nonisolated enum FanGeoPlayerAthleteFallbackMarkMetrics {
    /// Sport-neutral teal used when the catalog RGB is too near-gray to read as an athlete mark.
    static let canonicalRGB = SportsIdentityRGB(red: 0.12, green: 0.58, blue: 0.62)

    static func plateRGB(from catalog: SportsIdentityRGB) -> SportsIdentityRGB {
        let luma = catalog.red * 0.299 + catalog.green * 0.587 + catalog.blue * 0.114
        if luma < 0.22 || luma > 0.82 {
            return canonicalRGB
        }
        return catalog
    }

    static func personFontSize(diameter: CGFloat) -> CGFloat {
        max(11, diameter * 0.46)
    }

    static func starFontSize(diameter: CGFloat) -> CGFloat {
        max(6, diameter * 0.22)
    }

    static func starOffset(diameter: CGFloat) -> CGSize {
        CGSize(width: diameter * 0.22, height: diameter * 0.20)
    }
}

/// Vector fallback for leagues / competitions / tournaments when no provider mark exists.
nonisolated enum FanGeoCompetitionFallbackMarkMetrics {
    static let canonicalRGB = SportsIdentityRGB(red: 0.78, green: 0.58, blue: 0.16)

    static func plateRGB(from catalog: SportsIdentityRGB) -> SportsIdentityRGB {
        let luma = catalog.red * 0.299 + catalog.green * 0.587 + catalog.blue * 0.114
        if luma < 0.22 || luma > 0.82 {
            return canonicalRGB
        }
        return catalog
    }

    /// Visible trophy inside the circular plate. Target ~70–90pt at the 118pt Favorite card.
    static func trophyFontSize(diameter: CGFloat) -> CGFloat {
        max(16, diameter * 0.62)
    }

    static func laurelFontSize(diameter: CGFloat) -> CGFloat {
        max(9, diameter * 0.28)
    }

    static func starFontSize(diameter: CGFloat) -> CGFloat {
        max(5, diameter * 0.11)
    }

    static func ringInset(diameter: CGFloat) -> CGFloat {
        max(3, diameter * 0.08)
    }
}

struct FanGeoCompetitionFallbackMark: View {
    var diameter: CGFloat = 40
    var rgb: SportsIdentityRGB = FanGeoCompetitionFallbackMarkMetrics.canonicalRGB

    var body: some View {
        let plate = FanGeoCompetitionFallbackMarkMetrics.plateRGB(from: rgb)
        let color = Color(red: plate.red, green: plate.green, blue: plate.blue)
        let trophySize = FanGeoCompetitionFallbackMarkMetrics.trophyFontSize(diameter: diameter)
        let laurelSize = FanGeoCompetitionFallbackMarkMetrics.laurelFontSize(diameter: diameter)
        let starSize = FanGeoCompetitionFallbackMarkMetrics.starFontSize(diameter: diameter)
        let ringPad = FanGeoCompetitionFallbackMarkMetrics.ringInset(diameter: diameter)
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [color, color.opacity(0.76)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .strokeBorder(Color.white.opacity(0.16), lineWidth: max(1, diameter * 0.018))
                .padding(ringPad)
            Image(systemName: "laurel.leading")
                .font(.system(size: laurelSize, weight: .semibold))
                .foregroundStyle(.white.opacity(0.42))
                .offset(x: -diameter * 0.28, y: diameter * 0.04)
            Image(systemName: "laurel.trailing")
                .font(.system(size: laurelSize, weight: .semibold))
                .foregroundStyle(.white.opacity(0.42))
                .offset(x: diameter * 0.28, y: diameter * 0.04)
            Image(systemName: "trophy.fill")
                .font(.system(size: trophySize, weight: .semibold))
                .foregroundStyle(.white)
                .offset(y: diameter * 0.03)
            Image(systemName: "star.fill")
                .font(.system(size: starSize, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
                .offset(y: -diameter * 0.34)
        }
        .frame(width: diameter, height: diameter)
        .overlay {
            Circle()
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

struct FanGeoPlayerAthleteFallbackMark: View {
    var diameter: CGFloat = 40
    var rgb: SportsIdentityRGB = FanGeoPlayerAthleteFallbackMarkMetrics.canonicalRGB

    var body: some View {
        let plate = FanGeoPlayerAthleteFallbackMarkMetrics.plateRGB(from: rgb)
        let color = Color(red: plate.red, green: plate.green, blue: plate.blue)
        let starOffset = FanGeoPlayerAthleteFallbackMarkMetrics.starOffset(diameter: diameter)
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [color, color.opacity(0.74)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "person.fill")
                .font(.system(size: FanGeoPlayerAthleteFallbackMarkMetrics.personFontSize(diameter: diameter), weight: .semibold))
                .foregroundStyle(.white)
                .offset(y: diameter * 0.03)
            Image(systemName: "star.fill")
                .font(.system(size: FanGeoPlayerAthleteFallbackMarkMetrics.starFontSize(diameter: diameter), weight: .bold))
                .foregroundStyle(.white)
                .offset(x: starOffset.width, y: starOffset.height)
        }
        .frame(width: diameter, height: diameter)
        .overlay {
            Circle()
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}
