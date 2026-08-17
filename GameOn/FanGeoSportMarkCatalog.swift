import SwiftUI

/// Official FanGeo sport-mark identity: one glyph + tasteful ring color per sport.
/// Presentation-only. Does not change stored sport tokens, RPCs, or clustering.
nonisolated enum FanGeoSportMarkKind: String, CaseIterable, Equatable, Sendable {
    case soccer
    case basketball
    case football
    case baseball
    case hockey
    case tennis
    case badminton
    case golf
    case volleyball
    case tableTennis
    case pickleball
    case padel
    case cricket
    case rugby
    case softball
    case lacrosse
    case handball
    case running
    case trackField
    case cycling
    case roadCycling
    case mountainBike
    case swimming
    case triathlon
    case climbing
    case skateboarding
    case inlineSkating
    case electricScooter
    case skiing
    case snowboarding
    case bowling
    case boxing
    case mma
    case wrestling
    case martialArts
    case karate
    case judo
    case taekwondo
    case gym
    case crossFit
    case yoga
    case motorsport
    case nascar
    case motocross
    case esports
    case chess
    case paragliding
    case hangGliding
    case paramotoring
    case breakdance
    case ballet
    case discGolf
    case hiking
    case kayaking
    case surfing
    case generic
}

nonisolated struct FanGeoSportMarkDescriptor: Equatable, Sendable {
    let kind: FanGeoSportMarkKind
    let accentRed: Double
    let accentGreen: Double
    let accentBlue: Double

    var accent: Color {
        Color(red: accentRed, green: accentGreen, blue: accentBlue)
    }
}

/// Resolves the official circular sport mark for any FanGeo sport token or subtype.
nonisolated enum FanGeoSportMarkCatalog {

    static let genericDescriptor = FanGeoSportMarkDescriptor(
        kind: .generic,
        accentRed: 0.46,
        accentGreen: 0.40,
        accentBlue: 0.72
    )

    static func descriptor(sport: String, subtype: String? = nil) -> FanGeoSportMarkDescriptor {
        if let fromSubtype = kind(forSubtype: subtype, sport: sport) {
            return descriptor(for: fromSubtype)
        }
        if let extra = extraKind(for: sport) {
            return descriptor(for: extra)
        }
        guard let key = SportFilterCatalog.canonicalKey(for: sport) else {
            return genericDescriptor
        }
        return descriptor(for: kind(forCatalogKey: key))
    }

    static func kind(sport: String, subtype: String? = nil) -> FanGeoSportMarkKind {
        descriptor(sport: sport, subtype: subtype).kind
    }

    static func accent(sport: String, subtype: String? = nil) -> Color {
        descriptor(sport: sport, subtype: subtype).accent
    }

    static func descriptor(for kind: FanGeoSportMarkKind) -> FanGeoSportMarkDescriptor {
        switch kind {
        case .soccer:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.14, accentGreen: 0.52, accentBlue: 0.32)
        case .basketball:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.86, accentGreen: 0.46, accentBlue: 0.16)
        case .football:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.16, accentGreen: 0.28, accentBlue: 0.52)
        case .baseball:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.76, accentGreen: 0.22, accentBlue: 0.22)
        case .hockey:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.42, accentGreen: 0.68, accentBlue: 0.82)
        case .tennis:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.28, accentGreen: 0.62, accentBlue: 0.28)
        case .badminton:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.52, accentGreen: 0.38, accentBlue: 0.95)
        case .golf:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.14, accentGreen: 0.55, accentBlue: 0.38)
        case .volleyball:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.86, accentGreen: 0.72, accentBlue: 0.22)
        case .tableTennis:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.52, accentGreen: 0.24, accentBlue: 0.72)
        case .pickleball:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.32, accentGreen: 0.62, accentBlue: 0.42)
        case .padel:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.12, accentGreen: 0.56, accentBlue: 0.54)
        case .cricket:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.22, accentGreen: 0.38, accentBlue: 0.62)
        case .rugby:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.18, accentGreen: 0.42, accentBlue: 0.30)
        case .softball:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.86, accentGreen: 0.52, accentBlue: 0.22)
        case .lacrosse:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.28, accentGreen: 0.50, accentBlue: 0.36)
        case .handball:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.78, accentGreen: 0.42, accentBlue: 0.20)
        case .running:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.16, accentGreen: 0.62, accentBlue: 0.72)
        case .trackField:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.50, accentGreen: 0.40, accentBlue: 0.72)
        case .cycling:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.46, accentGreen: 0.68, accentBlue: 0.22)
        case .roadCycling:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.38, accentGreen: 0.62, accentBlue: 0.28)
        case .mountainBike:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.42, accentGreen: 0.58, accentBlue: 0.22)
        case .swimming:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.16, accentGreen: 0.52, accentBlue: 0.78)
        case .triathlon:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.22, accentGreen: 0.48, accentBlue: 0.62)
        case .climbing:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.42, accentGreen: 0.48, accentBlue: 0.68)
        case .skateboarding:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.48, accentGreen: 0.46, accentBlue: 0.52)
        case .inlineSkating:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.46, accentGreen: 0.38, accentBlue: 0.78)
        case .electricScooter:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.18, accentGreen: 0.62, accentBlue: 0.50)
        case .skiing:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.28, accentGreen: 0.52, accentBlue: 0.78)
        case .snowboarding:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.32, accentGreen: 0.46, accentBlue: 0.72)
        case .bowling:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.62, accentGreen: 0.36, accentBlue: 0.72)
        case .boxing:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.72, accentGreen: 0.22, accentBlue: 0.20)
        case .mma:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.58, accentGreen: 0.18, accentBlue: 0.22)
        case .wrestling:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.42, accentGreen: 0.34, accentBlue: 0.62)
        case .martialArts:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.36, accentGreen: 0.32, accentBlue: 0.52)
        case .karate:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.62, accentGreen: 0.22, accentBlue: 0.22)
        case .judo:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.22, accentGreen: 0.32, accentBlue: 0.58)
        case .taekwondo:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.22, accentGreen: 0.28, accentBlue: 0.48)
        case .gym:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.42, accentGreen: 0.44, accentBlue: 0.50)
        case .crossFit:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.62, accentGreen: 0.32, accentBlue: 0.22)
        case .yoga:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.48, accentGreen: 0.42, accentBlue: 0.68)
        case .motorsport:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.78, accentGreen: 0.24, accentBlue: 0.24)
        case .nascar:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.22, accentGreen: 0.32, accentBlue: 0.68)
        case .motocross:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.52, accentGreen: 0.38, accentBlue: 0.24)
        case .esports:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.50, accentGreen: 0.30, accentBlue: 0.78)
        case .chess:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.42, accentGreen: 0.36, accentBlue: 0.32)
        case .paragliding:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.32, accentGreen: 0.54, accentBlue: 0.78)
        case .hangGliding:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.42, accentGreen: 0.46, accentBlue: 0.68)
        case .paramotoring:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.50, accentGreen: 0.38, accentBlue: 0.64)
        case .breakdance:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.54, accentGreen: 0.32, accentBlue: 0.78)
        case .ballet:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.78, accentGreen: 0.42, accentBlue: 0.64)
        case .discGolf:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.42, accentGreen: 0.58, accentBlue: 0.28)
        case .hiking:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.42, accentGreen: 0.52, accentBlue: 0.32)
        case .kayaking:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.18, accentGreen: 0.50, accentBlue: 0.68)
        case .surfing:
            return FanGeoSportMarkDescriptor(kind: kind, accentRed: 0.18, accentGreen: 0.58, accentBlue: 0.72)
        case .generic:
            return genericDescriptor
        }
    }

    static func compactWordmark(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.count >= 2 {
            let first = String(words[0].prefix(8)).uppercased()
            let second = String(words[1].prefix(8)).uppercased()
            let joined = "\(first) \(second)"
            return String(joined.prefix(16))
        }
        return String(trimmed.uppercased().prefix(12))
    }

    static func kind(forCatalogKey key: String) -> FanGeoSportMarkKind {
        switch key {
        case "soccer": return .soccer
        case "basketball": return .basketball
        case "football": return .football
        case "baseball": return .baseball
        case "hockey": return .hockey
        case "tennis": return .tennis
        case "badminton": return .badminton
        case "golf": return .golf
        case "volleyball": return .volleyball
        case "pingpong": return .tableTennis
        case "pickleball": return .pickleball
        case "padel": return .padel
        case "cricket": return .cricket
        case "rugby": return .rugby
        case "softball": return .softball
        case "lacrosse": return .lacrosse
        case "handball": return .handball
        case "running": return .running
        case "trackfield": return .trackField
        case "cycling": return .cycling
        case "swimming": return .swimming
        case "climbing": return .climbing
        case "skateboarding": return .skateboarding
        case "inlineskating": return .inlineSkating
        case "electricscooter": return .electricScooter
        case "skiing": return .skiing
        case "bowling": return .bowling
        case "boxing": return .boxing
        case "mma": return .mma
        case "wrestling": return .wrestling
        case "racing": return .motorsport
        case "nascar": return .nascar
        case "motocross": return .motocross
        case "esports": return .esports
        case "paragliding": return .paragliding
        case "hanggliding": return .hangGliding
        case "paramotoring": return .paramotoring
        case "breakdance": return .breakdance
        case "ballet": return .ballet
        default: return .generic
        }
    }

    private static func kind(forSubtype raw: String?, sport: String) -> FanGeoSportMarkKind? {
        let token = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !token.isEmpty else { return nil }
        switch token {
        case "mountain_biking", "mtb", "mountainbike":
            return .mountainBike
        case "road_cycling", "road_bike", "roadbike":
            return .roadCycling
        case "bmx":
            return .cycling
        default:
            if SportSubtypeCatalog.family(forSport: sport) == .cycling,
               ["gravel", "e_bike", "casual_ride", "other"].contains(token) {
                return .cycling
            }
            return nil
        }
    }

    private static func extraKind(for raw: String) -> FanGeoSportMarkKind? {
        let n = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !n.isEmpty else { return nil }
        if n.contains("yoga") { return .yoga }
        if n.contains("crossfit") || n.contains("cross fit") { return .crossFit }
        if n.contains("gym") || n.contains("weight") || n == "fitness" { return .gym }
        if n.contains("chess") { return .chess }
        if n.contains("snowboard") { return .snowboarding }
        if n.contains("triathlon") { return .triathlon }
        if n.contains("karate") { return .karate }
        if n.contains("judo") { return .judo }
        if n.contains("taekwondo") || n.contains("tae kwon") { return .taekwondo }
        if n.contains("martial") { return .martialArts }
        if n.contains("mountain bike") || n.contains("mtb") { return .mountainBike }
        if n.contains("road cycl") || n.contains("road bike") { return .roadCycling }
        if n.contains("disc golf") || n.contains("discgolf") { return .discGolf }
        if n.contains("hiking") || n.contains("hike") { return .hiking }
        if n.contains("kayak") { return .kayaking }
        if n.contains("surf") { return .surfing }
        return nil
    }
}

/// Future-ready recruiting presentation. Today Discover only has `lookingForPlayers`.
enum FanTeamRecruitingKind: String, Equatable, CaseIterable, Sendable {
    case players
    case athletes
    case fans
    case fanClubOpen

    static func advertised(lookingForPlayers: Bool) -> FanTeamRecruitingKind? {
        lookingForPlayers ? .players : nil
    }

    var localizationKey: String {
        switch self {
        case .players: return "team_discovery_looking_for_players"
        case .athletes: return "team_discovery_looking_for_athletes"
        case .fans: return "team_discovery_looking_for_fans"
        case .fanClubOpen: return "team_discovery_fan_club_open"
        }
    }
}
