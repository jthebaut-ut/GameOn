import Foundation

/// Global Following expansion entities (competitions, women’s soccer, leagues, multi-sport tournaments).
/// Official names only; no third-party logos. Stable IDs never rename existing persisted favorites.
extension FavoriteTeamCatalog {
    static let expandedGlobalEntities: [FavoriteTeam] =
        expandedMensInternationalSoccer
        + expandedMensClubSoccer
        + expandedWomensInternationalSoccer
        + expandedWomensClubCompetitions
        + expandedWomensNationalTeams
        + expandedWomensClubsHighConfidence
        + expandedAdditionalSoccerLeagues
        + expandedBaseballTournaments
        + expandedBasketballTournaments
        + expandedFootballTournaments
        + expandedHockeyTournaments
        + expandedCricketTournaments
        + expandedRugbyTournaments
        + expandedMotorsportTournaments
        + expandedTennisTournaments
        + expandedGolfTournaments
        + expandedOlympics
        + expandedWorldwideCoverage

    // MARK: Phase 2 — Men’s international soccer

    private static let expandedMensInternationalSoccer: [FavoriteTeam] = [
        make(
            "tournament-uefa-euro", "UEFA European Championship", .soccer, "Soccer Tournament", "soccerball",
            0.12, 0.28, 0.68, region: "Leagues & Tournaments", kind: .competition, shortCode: "EURO",
            aliases: ["UEFA Euro", "Euro", "Euros", "European Championship"]
        ),
        make(
            "tournament-copa-america", "Copa América", .soccer, "Soccer Tournament", "soccerball",
            0.12, 0.52, 0.28, region: "Leagues & Tournaments", kind: .competition, shortCode: "CA",
            aliases: ["Copa America"]
        ),
        make(
            "tournament-gold-cup", "CONCACAF Gold Cup", .soccer, "Soccer Tournament", "soccerball",
            0.78, 0.62, 0.12, region: "Leagues & Tournaments", kind: .competition, shortCode: "GC",
            aliases: ["Gold Cup"]
        ),
        make(
            "tournament-afc-asian-cup", "AFC Asian Cup", .soccer, "Soccer Tournament", "soccerball",
            0.78, 0.18, 0.22, region: "Leagues & Tournaments", kind: .competition, shortCode: "AAC",
            aliases: ["Asian Cup"]
        ),
        make(
            "tournament-afcon", "Africa Cup of Nations", .soccer, "Soccer Tournament", "soccerball",
            0.12, 0.48, 0.28, region: "Leagues & Tournaments", kind: .competition, shortCode: "AFCON",
            aliases: ["AFCON", "CAN", "Coupe d'Afrique des Nations"]
        ),
        make(
            "tournament-uefa-nations-league", "UEFA Nations League", .soccer, "Soccer Tournament", "soccerball",
            0.22, 0.32, 0.72, region: "Leagues & Tournaments", kind: .competition, shortCode: "UNL",
            aliases: ["Nations League"]
        ),
        make(
            "tournament-fifa-club-world-cup", "FIFA Club World Cup", .soccer, "Soccer Tournament", "soccerball",
            0.12, 0.42, 0.62, region: "Leagues & Tournaments", kind: .competition, shortCode: "CWC",
            aliases: ["Club World Cup"]
        )
    ]

    // MARK: Phase 2 — Men’s club competitions

    private static let expandedMensClubSoccer: [FavoriteTeam] = [
        make(
            "tournament-europa-league", "UEFA Europa League", .soccer, "Soccer Tournament", "soccerball",
            0.78, 0.42, 0.12, region: "Leagues & Tournaments", kind: .competition, shortCode: "UEL",
            aliases: ["Europa League", "UEL"]
        ),
        make(
            "tournament-conference-league", "UEFA Conference League", .soccer, "Soccer Tournament", "soccerball",
            0.12, 0.62, 0.48, region: "Leagues & Tournaments", kind: .competition, shortCode: "UECL",
            aliases: ["Conference League", "UECL", "UEFA Europa Conference League"]
        ),
        make(
            "tournament-copa-libertadores", "Copa Libertadores", .soccer, "Soccer Tournament", "soccerball",
            0.92, 0.72, 0.12, region: "Leagues & Tournaments", kind: .competition, shortCode: "LIB",
            aliases: ["Libertadores", "CONMEBOL Libertadores"]
        ),
        make(
            "tournament-copa-sudamericana", "Copa Sudamericana", .soccer, "Soccer Tournament", "soccerball",
            0.12, 0.52, 0.72, region: "Leagues & Tournaments", kind: .competition, shortCode: "SUD",
            aliases: ["Sudamericana", "CONMEBOL Sudamericana"]
        )
    ]

    // MARK: Phase 2/3 — Women’s competitions

    private static let expandedWomensInternationalSoccer: [FavoriteTeam] = [
        make(
            "tournament-fifa-womens-world-cup", "FIFA Women's World Cup", .soccer, "Soccer Tournament", "soccerball",
            0.72, 0.18, 0.52, region: "Leagues & Tournaments", kind: .competition, shortCode: "WWC",
            aliases: ["Women's World Cup", "WWC", "FIFA Womens World Cup"]
        ),
        make(
            "tournament-womens-euro", "UEFA Women's Championship", .soccer, "Soccer Tournament", "soccerball",
            0.52, 0.18, 0.72, region: "Leagues & Tournaments", kind: .competition, shortCode: "WEURO",
            aliases: ["Women's Euro", "UEFA Women's Euro", "Women's European Championship"]
        )
    ]

    private static let expandedWomensClubCompetitions: [FavoriteTeam] = [
        make(
            "tournament-uwcl", "UEFA Women's Champions League", .soccer, "Soccer Tournament", "soccerball",
            0.12, 0.28, 0.62, region: "Leagues & Tournaments", kind: .competition, shortCode: "UWCL",
            aliases: ["UWCL", "Women's Champions League"]
        ),
        make(
            "league-nwsl", "NWSL", .soccer, "Soccer League", "soccerball",
            0.12, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "NWSL",
            aliases: ["National Women's Soccer League", "National Womens Soccer League"]
        ),
        make(
            "league-wsl", "Women's Super League", .soccer, "Soccer League", "soccerball",
            0.72, 0.12, 0.32, region: "Leagues & Tournaments", kind: .league, shortCode: "WSL",
            aliases: ["WSL", "Barclays Women's Super League", "FA WSL"]
        ),
        make(
            "league-liga-f", "Liga F", .soccer, "Soccer League", "soccerball",
            0.78, 0.18, 0.22, region: "Leagues & Tournaments", kind: .league, shortCode: "LIGAF",
            aliases: ["Liga Femenina", "Spanish Women's League"]
        ),
        make(
            "league-frauen-bundesliga", "Frauen-Bundesliga", .soccer, "Soccer League", "soccerball",
            0.18, 0.18, 0.18, region: "Leagues & Tournaments", kind: .league, shortCode: "FBL",
            aliases: ["Google Pixel Frauen-Bundesliga", "Women's Bundesliga"]
        ),
        make(
            "league-d1-feminine", "Division 1 Féminine", .soccer, "Soccer League", "soccerball",
            0.12, 0.28, 0.68, region: "Leagues & Tournaments", kind: .league, shortCode: "D1F",
            aliases: ["D1 Arkema", "Division 1 Feminine", "French Women's League"]
        ),
        make(
            "league-serie-a-femminile", "Serie A Femminile", .soccer, "Soccer League", "soccerball",
            0.12, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "SAF",
            aliases: ["Serie A Women", "Italian Women's Serie A"]
        )
    ]

    // MARK: Phase 3 — Women’s national teams (distinct from men’s IDs)

    private static let expandedWomensNationalTeams: [FavoriteTeam] = [
        wnt("soccer-usa-women", "United States Women", "USW", ["USWNT", "USA Women", "United States WNT"]),
        wnt("soccer-canada-women", "Canada Women", "CANW", ["Canada WNT", "CanWNT"]),
        wnt("soccer-mexico-women", "Mexico Women", "MEXW", ["Mexico WNT", "El Tri Femenil"]),
        wnt("soccer-brazil-women", "Brazil Women", "BRAW", ["Brazil WNT", "Seleção Feminina"]),
        wnt("soccer-argentina-women", "Argentina Women", "ARGW", ["Argentina WNT"]),
        wnt("soccer-colombia-women", "Colombia Women", "COLW", ["Colombia WNT"]),
        wnt("soccer-england-women", "England Women", "ENGW", ["Lionesses", "England WNT"]),
        wnt("soccer-france-women", "France Women", "FRAW", ["France WNT", "Les Bleues"]),
        wnt("soccer-germany-women", "Germany Women", "GERW", ["Germany WNT", "DFB Frauen"]),
        wnt("soccer-spain-women", "Spain Women", "ESPW", ["Spain WNT", "La Roja Femenina"]),
        wnt("soccer-italy-women", "Italy Women", "ITAW", ["Italy WNT"]),
        wnt("soccer-netherlands-women", "Netherlands Women", "NEDW", ["Netherlands WNT", "OranjeLeeuwinnen"]),
        wnt("soccer-sweden-women", "Sweden Women", "SWEW", ["Sweden WNT"]),
        wnt("soccer-norway-women", "Norway Women", "NORW", ["Norway WNT"]),
        wnt("soccer-denmark-women", "Denmark Women", "DENW", ["Denmark WNT"]),
        wnt("soccer-australia-women", "Australia Women", "AUSW", ["Matildas", "Australia WNT"]),
        wnt("soccer-japan-women", "Japan Women", "JPNW", ["Nadeshiko", "Japan WNT"]),
        wnt("soccer-south-korea-women", "South Korea Women", "KORW", ["Korea Women", "South Korea WNT"]),
        wnt("soccer-china-women", "China Women", "CHNW", ["China PR Women", "China WNT"]),
        wnt("soccer-nigeria-women", "Nigeria Women", "NGAW", ["Super Falcons", "Nigeria WNT"]),
        wnt("soccer-south-africa-women", "South Africa Women", "RSAW", ["Banyana Banyana", "South Africa WNT"]),
        wnt("soccer-new-zealand-women", "New Zealand Women", "NZLW", ["Football Ferns", "New Zealand WNT"])
    ]

    /// Bounded high-confidence women’s clubs only (not a complete league table).
    private static let expandedWomensClubsHighConfidence: [FavoriteTeam] = [
        wClub("soccer-barcelona-women", "FC Barcelona Femení", "Liga F", "Europe", "BARW", ["Barcelona Women", "Barça Femení", "Barcelona Femeni"]),
        wClub("soccer-real-madrid-women", "Real Madrid Femenino", "Liga F", "Europe", "RMAW", ["Real Madrid Women"]),
        wClub("soccer-atletico-madrid-women", "Atlético de Madrid Femenino", "Liga F", "Europe", "ATMW", ["Atletico Madrid Women"]),
        wClub("soccer-chelsea-women", "Chelsea Women", "Women's Super League", "Europe", "CHEW", ["Chelsea FC Women", "Chelsea WFC"]),
        wClub("soccer-arsenal-women", "Arsenal Women", "Women's Super League", "Europe", "ARSW", ["Arsenal WFC"]),
        wClub("soccer-man-city-women", "Manchester City Women", "Women's Super League", "Europe", "MCIW", ["Man City Women"]),
        wClub("soccer-man-utd-women", "Manchester United Women", "Women's Super League", "Europe", "MUNW", ["Man United Women", "Man Utd Women"]),
        wClub("soccer-lyon-women", "Olympique Lyonnais Féminin", "Division 1 Féminine", "Europe", "OLW", ["Lyon Women", "OL Feminine"]),
        wClub("soccer-psg-women", "Paris Saint-Germain Féminine", "Division 1 Féminine", "Europe", "PSGW", ["PSG Women"]),
        wClub("soccer-bayern-women", "Bayern Munich Women", "Frauen-Bundesliga", "Europe", "BAYW", ["FC Bayern Women", "Bayern München Women"]),
        wClub("soccer-wolfsburg-women", "VfL Wolfsburg Women", "Frauen-Bundesliga", "Europe", "WOBW", ["Wolfsburg Women"]),
        wClub("soccer-juventus-women", "Juventus Women", "Serie A Femminile", "Europe", "JUVW", ["Juventus Femminile"]),
        wClub("soccer-roma-women", "AS Roma Women", "Serie A Femminile", "Europe", "ROMW", ["Roma Femminile"]),
        wClub("soccer-portland-thorns", "Portland Thorns FC", "NWSL", "North America", "PTFC", ["Portland Thorns"]),
        wClub("soccer-gotham-fc", "Gotham FC", "NWSL", "North America", "GFC", ["NJ/NY Gotham", "Gotham"]),
        wClub("soccer-angel-city", "Angel City FC", "NWSL", "North America", "ACFC", ["Angel City"]),
        wClub("soccer-kansas-city-current", "Kansas City Current", "NWSL", "North America", "KCC", ["KC Current"]),
        wClub("soccer-orlando-pride", "Orlando Pride", "NWSL", "North America", "ORL", ["Pride"]),
        wClub("soccer-washington-spirit", "Washington Spirit", "NWSL", "North America", "WAS", ["Spirit"])
    ]

    // MARK: Phase 4 — Additional leagues (followable; clubs only where already verified elsewhere)

    private static let expandedAdditionalSoccerLeagues: [FavoriteTeam] = [
        league("league-efl-championship", "EFL Championship", "EFL", ["Championship", "English Championship"]),
        league("league-eredivisie", "Eredivisie", "ERE", ["Dutch Eredivisie"]),
        league("league-primeira-liga", "Primeira Liga", "LIGA", ["Liga Portugal", "Portuguese Liga"]),
        league("league-scottish-premiership", "Scottish Premiership", "SPL", ["SPFL Premiership"]),
        league("league-belgian-pro-league", "Belgian Pro League", "BPL", ["Jupiler Pro League"]),
        league("league-austrian-bundesliga", "Austrian Bundesliga", "ABL", ["Admiral Bundesliga"]),
        league("league-swiss-super-league", "Swiss Super League", "SSL", ["Credit Suisse Super League"]),
        league("league-brasileirao", "Campeonato Brasileiro Série A", "BRA1", ["Brasileirão", "Brasileirao", "Brazil Serie A"]),
        league("league-argentina-primera", "Argentine Primera División", "ARG1", ["Liga Profesional", "Argentina Primera"]),
        league("league-saudi-pro-league", "Saudi Pro League", "SPLSA", ["Roshn Saudi League"]),
        league("league-j1", "J1 League", "J1", ["J.League", "J League"]),
        league("league-k-league-1", "K League 1", "KL1", ["K League", "K-League"]),
        league("league-a-league-men", "A-League Men", "ALM", ["A-League", "Hyundai A-League"]),
        league("league-isl", "Indian Super League", "ISL", ["Hero Indian Super League"]),
        league("league-egyptian-premier", "Egyptian Premier League", "EGPL", ["Egyptian Premier"]),
        league("league-south-african-premiership", "South African Premiership", "PSL", ["DStv Premiership", "Premier Soccer League"])
    ]

    // MARK: Phase 5 — Non-soccer tournaments

    private static let expandedBaseballTournaments: [FavoriteTeam] = [
        make("tournament-world-baseball-classic", "World Baseball Classic", .baseball, "Baseball Tournament", "baseball.fill", 0.12, 0.32, 0.62, region: "Leagues & Tournaments", kind: .competition, shortCode: "WBC", aliases: ["WBC"]),
        make("tournament-mlb-postseason", "MLB Postseason", .baseball, "Baseball Tournament", "baseball.fill", 0.78, 0.12, 0.18, region: "Leagues & Tournaments", kind: .competition, shortCode: "MLBPS", aliases: ["MLB Playoffs"]),
        make("tournament-world-series", "World Series", .baseball, "Baseball Tournament", "baseball.fill", 0.12, 0.22, 0.48, region: "Leagues & Tournaments", kind: .competition, shortCode: "WS", aliases: ["MLB World Series"])
    ]

    private static let expandedBasketballTournaments: [FavoriteTeam] = [
        make("tournament-nba-playoffs", "NBA Playoffs", .basketball, "Basketball Tournament", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .competition, shortCode: "NBAPO", aliases: ["NBA Postseason"]),
        make("tournament-nba-finals", "NBA Finals", .basketball, "Basketball Tournament", "basketball.fill", 0.42, 0.18, 0.62, region: "Leagues & Tournaments", kind: .competition, shortCode: "NBAF"),
        make("tournament-wnba-playoffs", "WNBA Playoffs", .basketball, "Basketball Tournament", "basketball.fill", 0.78, 0.32, 0.52, region: "Leagues & Tournaments", kind: .competition, shortCode: "WNBAPO"),
        make("tournament-wnba-finals", "WNBA Finals", .basketball, "Basketball Tournament", "basketball.fill", 0.72, 0.18, 0.42, region: "Leagues & Tournaments", kind: .competition, shortCode: "WNBAF"),
        // Men's March Madness already exists as `tournament-march-madness`.
        make("tournament-ncaa-womens", "NCAA Women's Tournament", .ncaa, "College Basketball Tournament", "building.columns.fill", 0.72, 0.18, 0.42, region: "Leagues & Tournaments", kind: .competition, shortCode: "NCAAW", aliases: ["Women's March Madness", "NCAA Women's Basketball Tournament"])
    ]

    private static let expandedFootballTournaments: [FavoriteTeam] = [
        make("tournament-nfl-playoffs", "NFL Playoffs", .football, "Football Tournament", "football.fill", 0.12, 0.32, 0.62, region: "Leagues & Tournaments", kind: .competition, shortCode: "NFLPO", aliases: ["NFL Postseason"]),
        make("tournament-super-bowl", "Super Bowl", .football, "Football Tournament", "football.fill", 0.78, 0.62, 0.12, region: "Leagues & Tournaments", kind: .competition, shortCode: "SB", aliases: ["NFL Super Bowl"])
    ]

    private static let expandedHockeyTournaments: [FavoriteTeam] = [
        make("tournament-stanley-cup-playoffs", "Stanley Cup Playoffs", .hockey, "Hockey Tournament", "hockey.puck.fill", 0.12, 0.42, 0.72, region: "Leagues & Tournaments", kind: .competition, shortCode: "SCP", aliases: ["NHL Playoffs"]),
        make("tournament-stanley-cup-final", "Stanley Cup Final", .hockey, "Hockey Tournament", "hockey.puck.fill", 0.72, 0.62, 0.18, region: "Leagues & Tournaments", kind: .competition, shortCode: "SCF", aliases: ["Stanley Cup"]),
        make("tournament-iihf-worlds", "IIHF World Championship", .hockey, "Hockey Tournament", "hockey.puck.fill", 0.12, 0.32, 0.62, region: "Leagues & Tournaments", kind: .competition, shortCode: "IIHF", aliases: ["World Hockey Championship", "Ice Hockey World Championship"])
    ]

    private static let expandedCricketTournaments: [FavoriteTeam] = [
        make("tournament-icc-cricket-world-cup", "ICC Cricket World Cup", .cricket, "Cricket Tournament", "sportscourt.fill", 0.10, 0.68, 0.54, region: "Leagues & Tournaments", kind: .competition, shortCode: "ICCWC", aliases: ["Cricket World Cup"]),
        make("tournament-icc-t20-world-cup", "ICC T20 World Cup", .cricket, "Cricket Tournament", "sportscourt.fill", 0.12, 0.48, 0.42, region: "Leagues & Tournaments", kind: .competition, shortCode: "T20WC", aliases: ["T20 World Cup"]),
        make("tournament-ipl", "Indian Premier League", .cricket, "Cricket League", "sportscourt.fill", 0.18, 0.32, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "IPL", aliases: ["IPL"])
    ]

    private static let expandedRugbyTournaments: [FavoriteTeam] = [
        make("tournament-rugby-world-cup", "Rugby World Cup", .rugby, "Rugby Tournament", "sportscourt.fill", 0.48, 0.18, 0.13, region: "Leagues & Tournaments", kind: .competition, shortCode: "RWC"),
        make("tournament-six-nations", "Six Nations", .rugby, "Rugby Tournament", "sportscourt.fill", 0.12, 0.28, 0.62, region: "Leagues & Tournaments", kind: .competition, shortCode: "6N", aliases: ["Six Nations Championship"]),
        make("tournament-the-rugby-championship", "The Rugby Championship", .rugby, "Rugby Tournament", "sportscourt.fill", 0.12, 0.42, 0.28, region: "Leagues & Tournaments", kind: .competition, shortCode: "TRC"),
        make("tournament-premiership-rugby", "Premiership Rugby", .rugby, "Rugby League", "sportscourt.fill", 0.12, 0.22, 0.48, region: "Leagues & Tournaments", kind: .league, shortCode: "PR", aliases: ["English Premiership Rugby"]),
        make("tournament-urc", "United Rugby Championship", .rugby, "Rugby League", "sportscourt.fill", 0.78, 0.18, 0.22, region: "Leagues & Tournaments", kind: .league, shortCode: "URC"),
        make("tournament-super-rugby-pacific", "Super Rugby Pacific", .rugby, "Rugby League", "sportscourt.fill", 0.12, 0.42, 0.62, region: "Leagues & Tournaments", kind: .league, shortCode: "SRP", aliases: ["Super Rugby"]),
        make("tournament-nrl", "National Rugby League", .rugby, "Rugby League", "sportscourt.fill", 0.12, 0.32, 0.52, region: "Leagues & Tournaments", kind: .league, shortCode: "NRL", aliases: ["NRL"])
    ]

    private static let expandedMotorsportTournaments: [FavoriteTeam] = [
        make("tournament-nascar-cup", "NASCAR Cup Series", .racing, "Stock Car", "flag.checkered.2.crossed.fill", 0.78, 0.12, 0.16, region: "Leagues & Tournaments", kind: .competition, shortCode: "NASCAR", aliases: ["NASCAR", "Cup Series"]),
        make("tournament-motogp", "MotoGP World Championship", .racing, "Motorcycle", "flag.checkered.2.crossed.fill", 0.12, 0.32, 0.72, region: "Leagues & Tournaments", kind: .competition, shortCode: "MotoGP", aliases: ["MotoGP"])
    ]

    private static let expandedTennisTournaments: [FavoriteTeam] = [
        make("tournament-atp-finals", "ATP Finals", .tennis, "Tennis Tournament", "tennisball.fill", 0.12, 0.28, 0.62, region: "Tournaments", kind: .competition, shortCode: "ATPF"),
        make("tournament-wta-finals", "WTA Finals", .tennis, "Tennis Tournament", "tennisball.fill", 0.72, 0.18, 0.42, region: "Tournaments", kind: .competition, shortCode: "WTAF"),
        make("tournament-davis-cup", "Davis Cup", .tennis, "Tennis Tournament", "tennisball.fill", 0.12, 0.42, 0.72, region: "Tournaments", kind: .competition, shortCode: "DC"),
        make("tournament-bjk-cup", "Billie Jean King Cup", .tennis, "Tennis Tournament", "tennisball.fill", 0.72, 0.28, 0.52, region: "Tournaments", kind: .competition, shortCode: "BJK", aliases: ["BJK Cup", "Fed Cup"])
    ]

    private static let expandedGolfTournaments: [FavoriteTeam] = [
        make("tournament-pga-championship", "PGA Championship", .golf, "Golf Major", "figure.golf", 0.12, 0.42, 0.28, region: "Tournaments", kind: .competition, shortCode: "PGA", aliases: ["PGA Champ"]),
        make("tournament-solheim-cup", "Solheim Cup", .golf, "Golf Tournament", "figure.golf", 0.72, 0.28, 0.52, region: "Tournaments", kind: .competition, shortCode: "SOL")
    ]

    private static let expandedOlympics: [FavoriteTeam] = [
        make("tournament-summer-olympics", "Summer Olympic Games", .olympics, "Olympics", "medal.fill", 0.12, 0.42, 0.72, region: "Leagues & Tournaments", kind: .competition, shortCode: "SOG", aliases: ["Summer Olympics", "Olympics", "Olympic Games"]),
        make("tournament-winter-olympics", "Winter Olympic Games", .olympics, "Olympics", "medal.fill", 0.42, 0.62, 0.88, region: "Leagues & Tournaments", kind: .competition, shortCode: "WOG", aliases: ["Winter Olympics"])
    ]

    // MARK: Helpers

    private static func wnt(_ id: String, _ name: String, _ code: String, _ aliases: [String]) -> FavoriteTeam {
        make(
            id, name, .soccer, "Women's National Team", "soccerball",
            0.72, 0.22, 0.48, region: "Women's National Teams", kind: .nationalTeam, shortCode: code, aliases: aliases
        )
    }

    private static func wClub(
        _ id: String,
        _ name: String,
        _ league: String,
        _ region: String,
        _ code: String,
        _ aliases: [String]
    ) -> FavoriteTeam {
        make(
            id, name, .soccer, league, "soccerball",
            0.62, 0.18, 0.42, region: region, kind: .team, shortCode: code, aliases: aliases
        )
    }

    private static func league(_ id: String, _ name: String, _ code: String, _ aliases: [String]) -> FavoriteTeam {
        make(
            id, name, .soccer, "Soccer League", "soccerball",
            0.18, 0.52, 0.38, region: "Leagues & Tournaments", kind: .league, shortCode: code, aliases: aliases
        )
    }

    static func make(
        _ id: String,
        _ name: String,
        _ sport: FavoriteTeamSport,
        _ league: String,
        _ symbol: String,
        _ r: Double,
        _ g: Double,
        _ b: Double,
        region: String? = nil,
        kind: FavoriteTeamKind = .team,
        shortCode: String? = nil,
        aliases: [String] = []
    ) -> FavoriteTeam {
        FavoriteTeam(
            id: id,
            name: name,
            sport: sport,
            league: league,
            region: region ?? league,
            kind: kind,
            shortCode: shortCode,
            searchAliases: aliases,
            fallbackSymbol: symbol,
            badgeRed: r,
            badgeGreen: g,
            badgeBlue: b
        )
    }
}
