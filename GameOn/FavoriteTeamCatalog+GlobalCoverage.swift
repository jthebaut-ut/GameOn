import Foundation

/// Worldwide Following catalog expansion: clubs, national teams, leagues, and competitions
/// across continents. Official names only; no third-party logos. New stable IDs only.
nonisolated extension FavoriteTeamCatalog {
    static let expandedWorldwideCoverage: [FavoriteTeam] =
        globalBasketballClubs
        + globalBasketballNationalTeams
        + globalBasketballLeaguesAndComps
        + globalFootballClubs
        + globalFootballLeaguesAndComps
        + globalBaseballClubs
        + globalBaseballNationalTeams
        + globalBaseballLeaguesAndComps
        + globalHockeyClubs
        + globalHockeyNationalTeams
        + globalHockeyLeaguesAndComps
        + globalSoccerClubs
        + globalSoccerNationalTeams
        + globalCricketCoverage
        + globalRugbyCoverage
        + globalCombatCoverage
        + globalWNBAClubs

    // MARK: Basketball — global clubs
    private static let globalBasketballClubs: [FavoriteTeam] = [
        make("bball-real-madrid", "Real Madrid Basketball", .basketball, "Liga ACB", "basketball.fill", 0.12, 0.22, 0.62, region: "Europe", kind: .team, shortCode: "RMB", aliases: ["Real Madrid Baloncesto"]),
        make("bball-barcelona", "FC Barcelona Basketball", .basketball, "Liga ACB", "basketball.fill", 0.12, 0.32, 0.72, region: "Europe", kind: .team, shortCode: "FCBB", aliases: ["Barça Basket", "Barca Basket"]),
        make("bball-baskonia", "Baskonia", .basketball, "Liga ACB", "basketball.fill", 0.78, 0.12, 0.18, region: "Europe", kind: .team, shortCode: "BAS", aliases: ["Cazoo Baskonia", "Saski Baskonia"]),
        make("bball-monaco", "AS Monaco Basketball", .basketball, "LNB Pro A", "basketball.fill", 0.78, 0.18, 0.22, region: "Europe", kind: .team, shortCode: "ASM", aliases: ["Monaco Basket"]),
        make("bball-asvel", "LDLC ASVEL", .basketball, "LNB Pro A", "basketball.fill", 0.12, 0.32, 0.62, region: "Europe", kind: .team, shortCode: "ASV", aliases: ["ASVEL"]),
        make("bball-bayern", "FC Bayern Munich Basketball", .basketball, "BBL Germany", "basketball.fill", 0.78, 0.12, 0.18, region: "Europe", kind: .team, shortCode: "FCBM", aliases: ["Bayern Basketball"]),
        make("bball-alba", "ALBA Berlin", .basketball, "BBL Germany", "basketball.fill", 0.92, 0.82, 0.12, region: "Europe", kind: .team, shortCode: "ALB"),
        make("bball-milan", "Olimpia Milano", .basketball, "Lega Basket Serie A", "basketball.fill", 0.78, 0.12, 0.18, region: "Europe", kind: .team, shortCode: "MIL", aliases: ["EA7 Emporio Armani Milano"]),
        make("bball-virtus", "Virtus Bologna", .basketball, "Lega Basket Serie A", "basketball.fill", 0.12, 0.12, 0.12, region: "Europe", kind: .team, shortCode: "VIR", aliases: ["Virtus Segafredo Bologna"]),
        make("bball-fenerbahce", "Fenerbahçe Basketball", .basketball, "BSL Turkey", "basketball.fill", 0.92, 0.72, 0.12, region: "Europe", kind: .team, shortCode: "FEN", aliases: ["Fenerbahce Beko"]),
        make("bball-efes", "Anadolu Efes", .basketball, "BSL Turkey", "basketball.fill", 0.12, 0.32, 0.72, region: "Europe", kind: .team, shortCode: "EFE", aliases: ["Anadolu Efes Istanbul"]),
        make("bball-olympiacos", "Olympiacos Basketball", .basketball, "Greek Basket League", "basketball.fill", 0.78, 0.12, 0.18, region: "Europe", kind: .team, shortCode: "OLY", aliases: ["Olympiacos Piraeus"]),
        make("bball-panathinaikos", "Panathinaikos Basketball", .basketball, "Greek Basket League", "basketball.fill", 0.12, 0.48, 0.28, region: "Europe", kind: .team, shortCode: "PAO", aliases: ["Panathinaikos AKTOR"]),
        make("bball-zalgiris", "Žalgiris Kaunas", .basketball, "Lithuanian LKL", "basketball.fill", 0.12, 0.48, 0.28, region: "Europe", kind: .team, shortCode: "ZAL", aliases: ["Zalgiris", "Zalgiris Kaunas"]),
        make("bball-partizan", "Partizan Belgrade", .basketball, "Adriatic League", "basketball.fill", 0.12, 0.12, 0.12, region: "Europe", kind: .team, shortCode: "PAR", aliases: ["Partizan Mozzart Bet"]),
        make("bball-crvena-zvezda", "Crvena Zvezda", .basketball, "Adriatic League", "basketball.fill", 0.78, 0.12, 0.18, region: "Europe", kind: .team, shortCode: "CZV", aliases: ["Red Star Belgrade", "KK Crvena zvezda"]),
        make("bball-melbourne-united", "Melbourne United", .basketball, "NBL Australia", "basketball.fill", 0.12, 0.32, 0.72, region: "Oceania", kind: .team, shortCode: "MEL"),
        make("bball-sydney-kings", "Sydney Kings", .basketball, "NBL Australia", "basketball.fill", 0.78, 0.42, 0.12, region: "Oceania", kind: .team, shortCode: "SYD"),
        make("bball-perth-wildcats", "Perth Wildcats", .basketball, "NBL Australia", "basketball.fill", 0.78, 0.12, 0.18, region: "Oceania", kind: .team, shortCode: "PER"),
        make("bball-nz-breakers", "New Zealand Breakers", .basketball, "NBL Australia", "basketball.fill", 0.12, 0.12, 0.12, region: "Oceania", kind: .team, shortCode: "NZB", aliases: ["NZ Breakers"]),
        make("bball-alvark", "Alvark Tokyo", .basketball, "B.League Japan", "basketball.fill", 0.12, 0.32, 0.62, region: "Asia", kind: .team, shortCode: "ALV"),
        make("bball-chiba", "Chiba Jets", .basketball, "B.League Japan", "basketball.fill", 0.12, 0.42, 0.72, region: "Asia", kind: .team, shortCode: "CHB"),
        make("bball-ryukyu", "Ryukyu Golden Kings", .basketball, "B.League Japan", "basketball.fill", 0.78, 0.52, 0.12, region: "Asia", kind: .team, shortCode: "RYU"),
        make("bball-seoul-sk", "Seoul SK Knights", .basketball, "KBL Korea", "basketball.fill", 0.78, 0.12, 0.18, region: "Asia", kind: .team, shortCode: "SKK"),
        make("bball-ulsan", "Ulsan Hyundai Mobis Phoebus", .basketball, "KBL Korea", "basketball.fill", 0.12, 0.32, 0.72, region: "Asia", kind: .team, shortCode: "MOB", aliases: ["Ulsan Mobis"]),
        make("bball-guangdong", "Guangdong Southern Tigers", .basketball, "CBA China", "basketball.fill", 0.78, 0.12, 0.18, region: "Asia", kind: .team, shortCode: "GDT", aliases: ["Guangdong Tigers"]),
        make("bball-liaoning", "Liaoning Flying Leopards", .basketball, "CBA China", "basketball.fill", 0.78, 0.22, 0.12, region: "Asia", kind: .team, shortCode: "LIA"),
        make("bball-beijing", "Beijing Ducks", .basketball, "CBA China", "basketball.fill", 0.12, 0.22, 0.48, region: "Asia", kind: .team, shortCode: "BJD"),
        make("bball-ginebra", "Barangay Ginebra San Miguel", .basketball, "PBA Philippines", "basketball.fill", 0.12, 0.48, 0.28, region: "Asia", kind: .team, shortCode: "GIN", aliases: ["Ginebra"]),
        make("bball-tnt", "TNT Tropang Giga", .basketball, "PBA Philippines", "basketball.fill", 0.12, 0.32, 0.62, region: "Asia", kind: .team, shortCode: "TNT"),
        make("bball-boca", "Boca Juniors Basketball", .basketball, "Liga Nacional Argentina", "basketball.fill", 0.12, 0.22, 0.62, region: "South America", kind: .team, shortCode: "BOC"),
        make("bball-san-lorenzo", "San Lorenzo Basketball", .basketball, "Liga Nacional Argentina", "basketball.fill", 0.12, 0.12, 0.12, region: "South America", kind: .team, shortCode: "SLO"),
        make("bball-flamengo", "Flamengo Basketball", .basketball, "NBB Brazil", "basketball.fill", 0.78, 0.12, 0.18, region: "South America", kind: .team, shortCode: "FLA"),
        make("bball-franca", "Franca Basquetebol", .basketball, "NBB Brazil", "basketball.fill", 0.78, 0.42, 0.12, region: "South America", kind: .team, shortCode: "FRA", aliases: ["Sesi Franca"]),
        make("bball-universidad-chile", "Universidad de Chile Basketball", .basketball, "LNB Chile", "basketball.fill", 0.12, 0.32, 0.72, region: "South America", kind: .team, shortCode: "UCH"),
        make("bball-aguada", "Aguada", .basketball, "LUB Uruguay", "basketball.fill", 0.12, 0.42, 0.72, region: "South America", kind: .team, shortCode: "AGU"),
        make("bball-al-ahly", "Al Ahly Basketball", .basketball, "BAL Africa", "basketball.fill", 0.78, 0.12, 0.18, region: "Africa", kind: .team, shortCode: "AHL"),
        make("bball-us-monastir", "US Monastir", .basketball, "BAL Africa", "basketball.fill", 0.12, 0.42, 0.72, region: "Africa", kind: .team, shortCode: "USM"),
        make("bball-petro", "Petro de Luanda", .basketball, "BAL Africa", "basketball.fill", 0.92, 0.72, 0.12, region: "Africa", kind: .team, shortCode: "PET"),
    ]

    private static let globalWNBAClubs: [FavoriteTeam] = [
        make("wnba-aces", "Las Vegas Aces", .basketball, "WNBA", "basketball.fill", 0.78, 0.12, 0.42, region: "North America", kind: .team, shortCode: "ACE"),
        make("wnba-liberty", "New York Liberty", .basketball, "WNBA", "basketball.fill", 0.12, 0.42, 0.72, region: "North America", kind: .team, shortCode: "NYL"),
        make("wnba-sun", "Connecticut Sun", .basketball, "WNBA", "basketball.fill", 0.78, 0.42, 0.12, region: "North America", kind: .team, shortCode: "CON"),
        make("wnba-lynx", "Minnesota Lynx", .basketball, "WNBA", "basketball.fill", 0.12, 0.42, 0.32, region: "North America", kind: .team, shortCode: "LYN"),
        make("wnba-storm", "Seattle Storm", .basketball, "WNBA", "basketball.fill", 0.12, 0.48, 0.28, region: "North America", kind: .team, shortCode: "SEA"),
        make("wnba-mercury", "Phoenix Mercury", .basketball, "WNBA", "basketball.fill", 0.78, 0.22, 0.42, region: "North America", kind: .team, shortCode: "PHX"),
        make("wnba-fever", "Indiana Fever", .basketball, "WNBA", "basketball.fill", 0.78, 0.12, 0.22, region: "North America", kind: .team, shortCode: "IND", aliases: ["Fever"]),
    ]

    private static let globalBasketballNationalTeams: [FavoriteTeam] = [
        make("bball-nt-usa", "United States", .basketball, "National Team", "basketball.fill", 0.12, 0.22, 0.62, region: "National Teams", kind: .nationalTeam, shortCode: "USA", aliases: ["USA Basketball", "Team USA Basketball"]),
        make("bball-nt-canada", "Canada", .basketball, "National Team", "basketball.fill", 0.78, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "CAN"),
        make("bball-nt-france", "France", .basketball, "National Team", "basketball.fill", 0.12, 0.32, 0.72, region: "National Teams", kind: .nationalTeam, shortCode: "FRA"),
        make("bball-nt-spain", "Spain", .basketball, "National Team", "basketball.fill", 0.78, 0.62, 0.12, region: "National Teams", kind: .nationalTeam, shortCode: "ESP"),
        make("bball-nt-germany", "Germany", .basketball, "National Team", "basketball.fill", 0.12, 0.12, 0.12, region: "National Teams", kind: .nationalTeam, shortCode: "GER"),
        make("bball-nt-serbia", "Serbia", .basketball, "National Team", "basketball.fill", 0.78, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "SRB"),
        make("bball-nt-australia", "Australia", .basketball, "National Team", "basketball.fill", 0.12, 0.32, 0.72, region: "National Teams", kind: .nationalTeam, shortCode: "AUS", aliases: ["Boomers"]),
        make("bball-nt-brazil", "Brazil", .basketball, "National Team", "basketball.fill", 0.12, 0.48, 0.28, region: "National Teams", kind: .nationalTeam, shortCode: "BRA"),
        make("bball-nt-argentina", "Argentina", .basketball, "National Team", "basketball.fill", 0.52, 0.72, 0.88, region: "National Teams", kind: .nationalTeam, shortCode: "ARG"),
        make("bball-nt-japan", "Japan", .basketball, "National Team", "basketball.fill", 0.78, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "JPN"),
        make("bball-nt-china", "China", .basketball, "National Team", "basketball.fill", 0.78, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "CHN"),
        make("bball-nt-philippines", "Philippines", .basketball, "National Team", "basketball.fill", 0.12, 0.32, 0.72, region: "National Teams", kind: .nationalTeam, shortCode: "PHI", aliases: ["Gilas"]),
        make("bball-nt-nigeria", "Nigeria", .basketball, "National Team", "basketball.fill", 0.12, 0.48, 0.28, region: "National Teams", kind: .nationalTeam, shortCode: "NGA", aliases: ["D'Tigers"]),
        make("bball-nt-south-sudan", "South Sudan", .basketball, "National Team", "basketball.fill", 0.12, 0.32, 0.62, region: "National Teams", kind: .nationalTeam, shortCode: "SSD"),
        make("bball-nt-lithuania", "Lithuania", .basketball, "National Team", "basketball.fill", 0.12, 0.48, 0.28, region: "National Teams", kind: .nationalTeam, shortCode: "LTU"),
        make("bball-nt-greece", "Greece", .basketball, "National Team", "basketball.fill", 0.12, 0.32, 0.72, region: "National Teams", kind: .nationalTeam, shortCode: "GRE"),
        make("bball-nt-turkey", "Turkey", .basketball, "National Team", "basketball.fill", 0.78, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "TUR"),
        make("bball-nt-italy", "Italy", .basketball, "National Team", "basketball.fill", 0.12, 0.42, 0.28, region: "National Teams", kind: .nationalTeam, shortCode: "ITA"),
        make("bball-nt-slovenia", "Slovenia", .basketball, "National Team", "basketball.fill", 0.12, 0.32, 0.72, region: "National Teams", kind: .nationalTeam, shortCode: "SLO"),
        make("bball-nt-latvia", "Latvia", .basketball, "National Team", "basketball.fill", 0.78, 0.12, 0.22, region: "National Teams", kind: .nationalTeam, shortCode: "LAT"),
    ]

    private static let globalBasketballLeaguesAndComps: [FavoriteTeam] = [
        make("league-euroleague", "EuroLeague", .basketball, "Basketball League", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "EL", aliases: ["Turkish Airlines EuroLeague"]),
        make("league-eurocup", "EuroCup", .basketball, "Basketball League", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "ECUP", aliases: ["Eurocup Basketball"]),
        make("league-bcl", "Basketball Champions League", .basketball, "Basketball League", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "BCL", aliases: ["FIBA Champions League"]),
        make("league-liga-acb", "Liga ACB", .basketball, "Basketball League", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "ACB", aliases: ["Liga Endesa", "ACB"]),
        make("league-lnb-pro-a", "LNB Pro A", .basketball, "Basketball League", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "PROA", aliases: ["Betclic Elite", "French Pro A"]),
        make("league-bbl-germany", "BBL Germany", .basketball, "Basketball League", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "BBL", aliases: ["easyCredit BBL"]),
        make("league-lega-basket", "Lega Basket Serie A", .basketball, "Basketball League", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "LBA", aliases: ["Serie A Basketball"]),
        make("league-bsl-turkey", "BSL Turkey", .basketball, "Basketball League", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "BSL", aliases: ["Basketbol Süper Ligi"]),
        make("league-greek-basket", "Greek Basket League", .basketball, "Basketball League", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "GBL", aliases: ["Stoiximan GBL"]),
        make("league-aba", "Adriatic League", .basketball, "Basketball League", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "ABA", aliases: ["ABA League", "AdmiralBet ABA League"]),
        make("league-nbl-australia", "NBL Australia", .basketball, "Basketball League", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "NBLA", aliases: ["National Basketball League"]),
        make("league-b-league", "B.League Japan", .basketball, "Basketball League", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "BLJ", aliases: ["B.League"]),
        make("league-kbl", "KBL Korea", .basketball, "Basketball League", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "KBL", aliases: ["Korean Basketball League"]),
        make("league-cba-china", "CBA China", .basketball, "Basketball League", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "CBA", aliases: ["Chinese Basketball Association"]),
        make("league-pba", "PBA Philippines", .basketball, "Basketball League", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "PBA", aliases: ["Philippine Basketball Association"]),
        make("league-lnb-argentina", "Liga Nacional Argentina", .basketball, "Basketball League", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "LNA", aliases: ["LNB Argentina"]),
        make("league-nbb-brazil", "NBB Brazil", .basketball, "Basketball League", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "NBB", aliases: ["Novo Basquete Brasil"]),
        make("league-lnb-chile", "LNB Chile", .basketball, "Basketball League", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "LNBC"),
        make("league-lub-uruguay", "LUB Uruguay", .basketball, "Basketball League", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "LUB"),
        make("league-bal-africa", "BAL Africa", .basketball, "Basketball League", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "BAL", aliases: ["Basketball Africa League"]),
        make("league-wnba", "WNBA", .basketball, "Basketball League", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "WNBA", aliases: ["Women's National Basketball Association"]),
        make("tournament-fiba-world-cup", "FIBA Basketball World Cup", .basketball, "Basketball Tournament", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .competition, shortCode: "FIBAWC", aliases: ["FIBA World Cup"]),
        make("tournament-eurobasket", "EuroBasket", .basketball, "Basketball Tournament", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .competition, shortCode: "EB", aliases: ["FIBA EuroBasket"]),
        make("tournament-americup", "FIBA AmeriCup", .basketball, "Basketball Tournament", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .competition, shortCode: "AMC", aliases: ["AmeriCup"]),
        make("tournament-asia-cup", "FIBA Asia Cup", .basketball, "Basketball Tournament", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .competition, shortCode: "ASIAC", aliases: ["Asia Cup Basketball"]),
        make("tournament-afrobasket", "AfroBasket", .basketball, "Basketball Tournament", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .competition, shortCode: "AFB", aliases: ["FIBA AfroBasket"]),
    ]

    // MARK: American football — global clubs
    private static let globalFootballClubs: [FavoriteTeam] = [
        make("cfl-argonauts", "Toronto Argonauts", .football, "CFL", "football.fill", 0.12, 0.32, 0.62, region: "North America", kind: .team, shortCode: "TOR"),
        make("cfl-stampeders", "Calgary Stampeders", .football, "CFL", "football.fill", 0.78, 0.12, 0.18, region: "North America", kind: .team, shortCode: "CGY"),
        make("cfl-riders", "Saskatchewan Roughriders", .football, "CFL", "football.fill", 0.12, 0.48, 0.28, region: "North America", kind: .team, shortCode: "SSK"),
        make("cfl-alouettes", "Montreal Alouettes", .football, "CFL", "football.fill", 0.12, 0.32, 0.72, region: "North America", kind: .team, shortCode: "MTL"),
        make("cfl-lions", "BC Lions", .football, "CFL", "football.fill", 0.78, 0.42, 0.12, region: "North America", kind: .team, shortCode: "BC"),
        make("cfl-bombers", "Winnipeg Blue Bombers", .football, "CFL", "football.fill", 0.12, 0.32, 0.62, region: "North America", kind: .team, shortCode: "WPG"),
        make("cfl-elks", "Edmonton Elks", .football, "CFL", "football.fill", 0.12, 0.48, 0.28, region: "North America", kind: .team, shortCode: "EDM"),
        make("cfl-redblacks", "Ottawa Redblacks", .football, "CFL", "football.fill", 0.78, 0.12, 0.18, region: "North America", kind: .team, shortCode: "OTT"),
        make("cfl-tigers", "Hamilton Tiger-Cats", .football, "CFL", "football.fill", 0.78, 0.52, 0.12, region: "North America", kind: .team, shortCode: "HAM"),
        make("elf-frankfurt", "Frankfurt Galaxy", .football, "ELF", "football.fill", 0.12, 0.32, 0.72, region: "Europe", kind: .team, shortCode: "FGY"),
        make("elf-rhein", "Rhein Fire", .football, "ELF", "football.fill", 0.78, 0.12, 0.18, region: "Europe", kind: .team, shortCode: "RHF"),
        make("elf-vienna", "Vienna Vikings", .football, "ELF", "football.fill", 0.12, 0.42, 0.28, region: "Europe", kind: .team, shortCode: "VVI"),
        make("elf-berlin", "Berlin Thunder", .football, "ELF", "football.fill", 0.12, 0.12, 0.12, region: "Europe", kind: .team, shortCode: "BTH"),
        make("elf-paris", "Paris Musketeers", .football, "ELF", "football.fill", 0.12, 0.32, 0.72, region: "Europe", kind: .team, shortCode: "PMU"),
        make("elf-hamburg", "Hamburg Sea Devils", .football, "ELF", "football.fill", 0.12, 0.42, 0.62, region: "Europe", kind: .team, shortCode: "HSD"),
        make("lfa-dynamos", "CDMX Dynamos", .football, "LFA Mexico", "football.fill", 0.12, 0.32, 0.72, region: "North America", kind: .team, shortCode: "DYN"),
        make("lfa-rex", "Dinos de Saltillo", .football, "LFA Mexico", "football.fill", 0.12, 0.48, 0.28, region: "North America", kind: .team, shortCode: "DIN"),
        make("gfl-dresden", "Dresden Monarchs", .football, "GFL Germany", "football.fill", 0.78, 0.12, 0.18, region: "Europe", kind: .team, shortCode: "DRM"),
        make("gfl-schwabisch", "Schwäbisch Hall Unicorns", .football, "GFL Germany", "football.fill", 0.12, 0.32, 0.72, region: "Europe", kind: .team, shortCode: "SHU"),
        make("xleague-fujitsu", "Fujitsu Frontiers", .football, "XLeague Japan", "football.fill", 0.78, 0.12, 0.18, region: "Asia", kind: .team, shortCode: "FUJ"),
        make("xleague-ob", "OB Guts", .football, "XLeague Japan", "football.fill", 0.12, 0.32, 0.62, region: "Asia", kind: .team, shortCode: "OBG"),
    ]

    private static let globalFootballLeaguesAndComps: [FavoriteTeam] = [
        make("league-cfl", "CFL", .football, "Football League", "football.fill", 0.12, 0.32, 0.62, region: "Leagues & Tournaments", kind: .league, shortCode: "CFL", aliases: ["Canadian Football League"]),
        make("league-elf", "ELF", .football, "Football League", "football.fill", 0.12, 0.32, 0.62, region: "Leagues & Tournaments", kind: .league, shortCode: "ELF", aliases: ["European League of Football"]),
        make("league-lfa-mexico", "LFA Mexico", .football, "Football League", "football.fill", 0.12, 0.32, 0.62, region: "Leagues & Tournaments", kind: .league, shortCode: "LFA", aliases: ["Liga de Fútbol Americano Profesional"]),
        make("league-gfl", "GFL Germany", .football, "Football League", "football.fill", 0.12, 0.32, 0.62, region: "Leagues & Tournaments", kind: .league, shortCode: "GFL", aliases: ["German Football League"]),
        make("league-xleague", "XLeague Japan", .football, "Football League", "football.fill", 0.12, 0.32, 0.62, region: "Leagues & Tournaments", kind: .league, shortCode: "XLJ", aliases: ["X-League"]),
        make("tournament-grey-cup", "Grey Cup", .football, "Football Tournament", "football.fill", 0.12, 0.32, 0.62, region: "Leagues & Tournaments", kind: .competition, shortCode: "GCUP", aliases: ["CFL Grey Cup"]),
        make("tournament-eurobowl", "Eurobowl", .football, "Football Tournament", "football.fill", 0.12, 0.32, 0.62, region: "Leagues & Tournaments", kind: .competition, shortCode: "EBWL", aliases: ["European Football Championship Final"]),
    ]

    // MARK: Baseball — global clubs
    private static let globalBaseballClubs: [FavoriteTeam] = [
        make("npb-giants", "Yomiuri Giants", .baseball, "NPB Japan", "baseball.fill", 0.78, 0.12, 0.18, region: "Asia", kind: .team, shortCode: "YG"),
        make("npb-tigers", "Hanshin Tigers", .baseball, "NPB Japan", "baseball.fill", 0.92, 0.72, 0.12, region: "Asia", kind: .team, shortCode: "HT"),
        make("npb-carp", "Hiroshima Toyo Carp", .baseball, "NPB Japan", "baseball.fill", 0.78, 0.12, 0.22, region: "Asia", kind: .team, shortCode: "HC"),
        make("npb-swallows", "Tokyo Yakult Swallows", .baseball, "NPB Japan", "baseball.fill", 0.12, 0.32, 0.62, region: "Asia", kind: .team, shortCode: "YS"),
        make("npb-baystars", "Yokohama DeNA BayStars", .baseball, "NPB Japan", "baseball.fill", 0.12, 0.42, 0.72, region: "Asia", kind: .team, shortCode: "YB"),
        make("npb-dragons", "Chunichi Dragons", .baseball, "NPB Japan", "baseball.fill", 0.12, 0.32, 0.62, region: "Asia", kind: .team, shortCode: "CD"),
        make("npb-hawks", "Fukuoka SoftBank Hawks", .baseball, "NPB Japan", "baseball.fill", 0.92, 0.72, 0.12, region: "Asia", kind: .team, shortCode: "SH"),
        make("npb-buffaloes", "Orix Buffaloes", .baseball, "NPB Japan", "baseball.fill", 0.12, 0.32, 0.72, region: "Asia", kind: .team, shortCode: "OB"),
        make("npb-marines", "Chiba Lotte Marines", .baseball, "NPB Japan", "baseball.fill", 0.12, 0.12, 0.12, region: "Asia", kind: .team, shortCode: "LM"),
        make("npb-fighters", "Hokkaido Nippon-Ham Fighters", .baseball, "NPB Japan", "baseball.fill", 0.12, 0.32, 0.62, region: "Asia", kind: .team, shortCode: "NHF"),
        make("npb-eagles", "Tohoku Rakuten Golden Eagles", .baseball, "NPB Japan", "baseball.fill", 0.78, 0.12, 0.18, region: "Asia", kind: .team, shortCode: "RE"),
        make("npb-lions", "Saitama Seibu Lions", .baseball, "NPB Japan", "baseball.fill", 0.12, 0.42, 0.28, region: "Asia", kind: .team, shortCode: "SL"),
        make("kbo-lions", "Samsung Lions", .baseball, "KBO Korea", "baseball.fill", 0.12, 0.32, 0.72, region: "Asia", kind: .team, shortCode: "SSL"),
        make("kbo-wyverns", "SSG Landers", .baseball, "KBO Korea", "baseball.fill", 0.78, 0.12, 0.18, region: "Asia", kind: .team, shortCode: "SSG"),
        make("kbo-twins", "LG Twins", .baseball, "KBO Korea", "baseball.fill", 0.78, 0.12, 0.22, region: "Asia", kind: .team, shortCode: "LGT"),
        make("kbo-giants", "Lotte Giants", .baseball, "KBO Korea", "baseball.fill", 0.12, 0.32, 0.62, region: "Asia", kind: .team, shortCode: "LTG"),
        make("kbo-bears", "Doosan Bears", .baseball, "KBO Korea", "baseball.fill", 0.12, 0.22, 0.48, region: "Asia", kind: .team, shortCode: "DOB"),
        make("kbo-dinos", "NC Dinos", .baseball, "KBO Korea", "baseball.fill", 0.12, 0.48, 0.28, region: "Asia", kind: .team, shortCode: "NCD"),
        make("cpbl-brothers", "CTBC Brothers", .baseball, "CPBL Taiwan", "baseball.fill", 0.92, 0.72, 0.12, region: "Asia", kind: .team, shortCode: "CTB"),
        make("cpbl-dragons", "Wei Chuan Dragons", .baseball, "CPBL Taiwan", "baseball.fill", 0.78, 0.12, 0.18, region: "Asia", kind: .team, shortCode: "WCD"),
        make("cpbl-monkeys", "Rakuten Monkeys", .baseball, "CPBL Taiwan", "baseball.fill", 0.78, 0.22, 0.42, region: "Asia", kind: .team, shortCode: "RKM"),
        make("mex-diablos", "Diablos Rojos del México", .baseball, "Mexican League", "baseball.fill", 0.78, 0.12, 0.18, region: "North America", kind: .team, shortCode: "DRM"),
        make("mex-yaquis", "Yaquis de Obregón", .baseball, "Mexican League", "baseball.fill", 0.78, 0.42, 0.12, region: "North America", kind: .team, shortCode: "YAO"),
        make("abl-auckland", "Auckland Tuatara", .baseball, "Australian Baseball League", "baseball.fill", 0.12, 0.32, 0.62, region: "Oceania", kind: .team, shortCode: "AUC"),
        make("abl-perth", "Perth Heat", .baseball, "Australian Baseball League", "baseball.fill", 0.78, 0.12, 0.18, region: "Oceania", kind: .team, shortCode: "PH"),
    ]

    private static let globalBaseballNationalTeams: [FavoriteTeam] = [
        make("baseball-nt-japan", "Japan", .baseball, "National Team", "baseball.fill", 0.78, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "JPN", aliases: ["Samurai Japan"]),
        make("baseball-nt-usa", "United States", .baseball, "National Team", "baseball.fill", 0.12, 0.22, 0.62, region: "National Teams", kind: .nationalTeam, shortCode: "USA", aliases: ["Team USA Baseball"]),
        make("baseball-nt-mexico", "Mexico", .baseball, "National Team", "baseball.fill", 0.12, 0.48, 0.28, region: "National Teams", kind: .nationalTeam, shortCode: "MEX"),
        make("baseball-nt-dominican", "Dominican Republic", .baseball, "National Team", "baseball.fill", 0.78, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "DOM", aliases: ["DR Baseball"]),
        make("baseball-nt-cuba", "Cuba", .baseball, "National Team", "baseball.fill", 0.78, 0.12, 0.22, region: "National Teams", kind: .nationalTeam, shortCode: "CUB"),
        make("baseball-nt-korea", "South Korea", .baseball, "National Team", "baseball.fill", 0.12, 0.32, 0.72, region: "National Teams", kind: .nationalTeam, shortCode: "KOR"),
        make("baseball-nt-chinese-taipei", "Chinese Taipei", .baseball, "National Team", "baseball.fill", 0.12, 0.32, 0.62, region: "National Teams", kind: .nationalTeam, shortCode: "TPE", aliases: ["Taiwan Baseball"]),
        make("baseball-nt-netherlands", "Netherlands", .baseball, "National Team", "baseball.fill", 0.78, 0.42, 0.12, region: "National Teams", kind: .nationalTeam, shortCode: "NED"),
        make("baseball-nt-italy", "Italy", .baseball, "National Team", "baseball.fill", 0.12, 0.42, 0.28, region: "National Teams", kind: .nationalTeam, shortCode: "ITA"),
        make("baseball-nt-australia", "Australia", .baseball, "National Team", "baseball.fill", 0.12, 0.32, 0.72, region: "National Teams", kind: .nationalTeam, shortCode: "AUS"),
        make("baseball-nt-venezuela", "Venezuela", .baseball, "National Team", "baseball.fill", 0.78, 0.22, 0.12, region: "National Teams", kind: .nationalTeam, shortCode: "VEN"),
        make("baseball-nt-puerto-rico", "Puerto Rico", .baseball, "National Team", "baseball.fill", 0.12, 0.32, 0.72, region: "National Teams", kind: .nationalTeam, shortCode: "PRI"),
    ]

    private static let globalBaseballLeaguesAndComps: [FavoriteTeam] = [
        make("league-npb", "NPB Japan", .baseball, "Baseball League", "baseball.fill", 0.12, 0.32, 0.62, region: "Leagues & Tournaments", kind: .league, shortCode: "NPB", aliases: ["Nippon Professional Baseball"]),
        make("league-kbo", "KBO Korea", .baseball, "Baseball League", "baseball.fill", 0.12, 0.32, 0.62, region: "Leagues & Tournaments", kind: .league, shortCode: "KBO", aliases: ["Korea Baseball Organization"]),
        make("league-cpbl", "CPBL Taiwan", .baseball, "Baseball League", "baseball.fill", 0.12, 0.32, 0.62, region: "Leagues & Tournaments", kind: .league, shortCode: "CPBL", aliases: ["Chinese Professional Baseball League"]),
        make("league-mexican-baseball", "Mexican League", .baseball, "Baseball League", "baseball.fill", 0.12, 0.32, 0.62, region: "Leagues & Tournaments", kind: .league, shortCode: "LMB", aliases: ["Liga Mexicana de Béisbol"]),
        make("league-abl", "Australian Baseball League", .baseball, "Baseball League", "baseball.fill", 0.12, 0.32, 0.62, region: "Leagues & Tournaments", kind: .league, shortCode: "ABL", aliases: ["ABL"]),
        make("tournament-caribbean-series", "Caribbean Series", .baseball, "Baseball Tournament", "baseball.fill", 0.12, 0.32, 0.62, region: "Leagues & Tournaments", kind: .competition, shortCode: "CSER", aliases: ["Serie del Caribe"]),
    ]

    // MARK: Hockey — global clubs
    private static let globalHockeyClubs: [FavoriteTeam] = [
        make("hockey-cska", "CSKA Moscow", .hockey, "KHL", "hockey.puck.fill", 0.78, 0.12, 0.18, region: "Europe", kind: .team, shortCode: "CSK"),
        make("hockey-ska", "SKA Saint Petersburg", .hockey, "KHL", "hockey.puck.fill", 0.12, 0.32, 0.72, region: "Europe", kind: .team, shortCode: "SKA"),
        make("hockey-ak-bars", "Ak Bars Kazan", .hockey, "KHL", "hockey.puck.fill", 0.12, 0.48, 0.28, region: "Europe", kind: .team, shortCode: "AKB"),
        make("hockey-avangard", "Avangard Omsk", .hockey, "KHL", "hockey.puck.fill", 0.12, 0.32, 0.62, region: "Europe", kind: .team, shortCode: "AVA"),
        make("hockey-frolunda", "Frölunda HC", .hockey, "SHL Sweden", "hockey.puck.fill", 0.78, 0.12, 0.18, region: "Europe", kind: .team, shortCode: "FHC"),
        make("hockey-farjestad", "Färjestad BK", .hockey, "SHL Sweden", "hockey.puck.fill", 0.12, 0.32, 0.72, region: "Europe", kind: .team, shortCode: "FBK"),
        make("hockey-skelleftea", "Skellefteå AIK", .hockey, "SHL Sweden", "hockey.puck.fill", 0.92, 0.72, 0.12, region: "Europe", kind: .team, shortCode: "SAIK"),
        make("hockey-tappara", "Tappara", .hockey, "Liiga Finland", "hockey.puck.fill", 0.12, 0.32, 0.62, region: "Europe", kind: .team, shortCode: "TAP"),
        make("hockey-hifk", "HIFK Helsinki", .hockey, "Liiga Finland", "hockey.puck.fill", 0.78, 0.12, 0.18, region: "Europe", kind: .team, shortCode: "HIFK"),
        make("hockey-karpat", "Kärpät Oulu", .hockey, "Liiga Finland", "hockey.puck.fill", 0.12, 0.12, 0.12, region: "Europe", kind: .team, shortCode: "KAR"),
        make("hockey-adler", "Adler Mannheim", .hockey, "DEL Germany", "hockey.puck.fill", 0.12, 0.32, 0.72, region: "Europe", kind: .team, shortCode: "ADM"),
        make("hockey-eisbaren", "Eisbären Berlin", .hockey, "DEL Germany", "hockey.puck.fill", 0.12, 0.42, 0.72, region: "Europe", kind: .team, shortCode: "EBB"),
        make("hockey-zsc", "ZSC Lions", .hockey, "National League Switzerland", "hockey.puck.fill", 0.12, 0.32, 0.62, region: "Europe", kind: .team, shortCode: "ZSC"),
        make("hockey-hcd", "HC Davos", .hockey, "National League Switzerland", "hockey.puck.fill", 0.92, 0.72, 0.12, region: "Europe", kind: .team, shortCode: "HCD"),
        make("hockey-sparta", "HC Sparta Praha", .hockey, "Extraliga Czechia", "hockey.puck.fill", 0.78, 0.12, 0.18, region: "Europe", kind: .team, shortCode: "SPA"),
        make("hockey-trinec", "HC Oceláři Třinec", .hockey, "Extraliga Czechia", "hockey.puck.fill", 0.78, 0.22, 0.12, region: "Europe", kind: .team, shortCode: "TRI"),
        make("hockey-sheffield", "Sheffield Steelers", .hockey, "EIHL UK", "hockey.puck.fill", 0.78, 0.12, 0.18, region: "Europe", kind: .team, shortCode: "SHE"),
        make("hockey-belfast", "Belfast Giants", .hockey, "EIHL UK", "hockey.puck.fill", 0.12, 0.32, 0.72, region: "Europe", kind: .team, shortCode: "BEL"),
        make("hockey-red-bull-salzburg", "EC Red Bull Salzburg", .hockey, "ICEHL", "hockey.puck.fill", 0.78, 0.12, 0.22, region: "Europe", kind: .team, shortCode: "RBS"),
        make("hockey-asiago", "Asiago Hockey", .hockey, "ICEHL", "hockey.puck.fill", 0.12, 0.42, 0.72, region: "Europe", kind: .team, shortCode: "ASI"),
    ]

    private static let globalHockeyNationalTeams: [FavoriteTeam] = [
        make("hockey-nt-canada", "Canada", .hockey, "National Team", "hockey.puck.fill", 0.78, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "CAN"),
        make("hockey-nt-usa", "United States", .hockey, "National Team", "hockey.puck.fill", 0.12, 0.22, 0.62, region: "National Teams", kind: .nationalTeam, shortCode: "USA"),
        make("hockey-nt-sweden", "Sweden", .hockey, "National Team", "hockey.puck.fill", 0.12, 0.42, 0.72, region: "National Teams", kind: .nationalTeam, shortCode: "SWE", aliases: ["Tre Kronor"]),
        make("hockey-nt-finland", "Finland", .hockey, "National Team", "hockey.puck.fill", 0.12, 0.32, 0.62, region: "National Teams", kind: .nationalTeam, shortCode: "FIN", aliases: ["Leijonat"]),
        make("hockey-nt-czechia", "Czechia", .hockey, "National Team", "hockey.puck.fill", 0.12, 0.32, 0.72, region: "National Teams", kind: .nationalTeam, shortCode: "CZE", aliases: ["Czech Republic"]),
        make("hockey-nt-switzerland", "Switzerland", .hockey, "National Team", "hockey.puck.fill", 0.78, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "SUI"),
        make("hockey-nt-germany", "Germany", .hockey, "National Team", "hockey.puck.fill", 0.12, 0.12, 0.12, region: "National Teams", kind: .nationalTeam, shortCode: "GER"),
        make("hockey-nt-slovakia", "Slovakia", .hockey, "National Team", "hockey.puck.fill", 0.12, 0.32, 0.72, region: "National Teams", kind: .nationalTeam, shortCode: "SVK"),
        make("hockey-nt-latvia", "Latvia", .hockey, "National Team", "hockey.puck.fill", 0.78, 0.12, 0.22, region: "National Teams", kind: .nationalTeam, shortCode: "LAT"),
        make("hockey-nt-norway", "Norway", .hockey, "National Team", "hockey.puck.fill", 0.78, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "NOR"),
    ]

    private static let globalHockeyLeaguesAndComps: [FavoriteTeam] = [
        make("league-khl", "KHL", .hockey, "Hockey League", "hockey.puck.fill", 0.12, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "KHL", aliases: ["Kontinental Hockey League"]),
        make("league-shl", "SHL Sweden", .hockey, "Hockey League", "hockey.puck.fill", 0.12, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "SHL", aliases: ["Swedish Hockey League"]),
        make("league-liiga", "Liiga Finland", .hockey, "Hockey League", "hockey.puck.fill", 0.12, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "LIIGA", aliases: ["Finnish Liiga"]),
        make("league-del", "DEL Germany", .hockey, "Hockey League", "hockey.puck.fill", 0.12, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "DEL", aliases: ["Deutsche Eishockey Liga"]),
        make("league-nl-swiss", "National League Switzerland", .hockey, "Hockey League", "hockey.puck.fill", 0.12, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "NLS", aliases: ["Swiss National League"]),
        make("league-extraliga", "Extraliga Czechia", .hockey, "Hockey League", "hockey.puck.fill", 0.12, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "ELH", aliases: ["Czech Extraliga"]),
        make("league-eihl", "EIHL UK", .hockey, "Hockey League", "hockey.puck.fill", 0.12, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "EIHL", aliases: ["Elite Ice Hockey League"]),
        make("league-icehl", "ICEHL", .hockey, "Hockey League", "hockey.puck.fill", 0.12, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "ICEHL", aliases: ["ICE Hockey League"]),
        make("tournament-world-juniors", "World Junior Championship", .hockey, "Hockey Tournament", "hockey.puck.fill", 0.12, 0.42, 0.72, region: "Leagues & Tournaments", kind: .competition, shortCode: "WJC", aliases: ["IIHF World Juniors", "World Juniors"]),
    ]

    // MARK: Soccer — additional worldwide clubs
    private static let globalSoccerClubs: [FavoriteTeam] = [
        make("soccer-flamengo", "Flamengo", .soccer, "Brazil Serie A", "soccerball", 0.78, 0.12, 0.18, region: "South America", kind: .team, shortCode: "FLA", aliases: ["CR Flamengo"]),
        make("soccer-palmeiras", "Palmeiras", .soccer, "Brazil Serie A", "soccerball", 0.12, 0.48, 0.28, region: "South America", kind: .team, shortCode: "PAL"),
        make("soccer-sao-paulo", "São Paulo", .soccer, "Brazil Serie A", "soccerball", 0.78, 0.12, 0.18, region: "South America", kind: .team, shortCode: "SAO", aliases: ["Sao Paulo"]),
        make("soccer-corinthians", "Corinthians", .soccer, "Brazil Serie A", "soccerball", 0.12, 0.12, 0.12, region: "South America", kind: .team, shortCode: "COR"),
        make("soccer-river-plate", "River Plate", .soccer, "Argentina Primera Division", "soccerball", 0.78, 0.12, 0.18, region: "South America", kind: .team, shortCode: "RIV"),
        make("soccer-boca-juniors", "Boca Juniors", .soccer, "Argentina Primera Division", "soccerball", 0.12, 0.32, 0.72, region: "South America", kind: .team, shortCode: "BOC"),
        make("soccer-racing-club", "Racing Club", .soccer, "Argentina Primera Division", "soccerball", 0.52, 0.72, 0.88, region: "South America", kind: .team, shortCode: "RAC"),
        make("soccer-independiente", "Independiente", .soccer, "Argentina Primera Division", "soccerball", 0.78, 0.12, 0.18, region: "South America", kind: .team, shortCode: "IND"),
        make("soccer-al-hilal", "Al Hilal", .soccer, "Saudi Pro League", "soccerball", 0.12, 0.32, 0.72, region: "Asia", kind: .team, shortCode: "HIL"),
        make("soccer-al-nassr", "Al Nassr", .soccer, "Saudi Pro League", "soccerball", 0.92, 0.72, 0.12, region: "Asia", kind: .team, shortCode: "NAS"),
        make("soccer-al-ittihad", "Al Ittihad", .soccer, "Saudi Pro League", "soccerball", 0.12, 0.12, 0.12, region: "Asia", kind: .team, shortCode: "ITT"),
        make("soccer-kawa-frontale", "Kawasaki Frontale", .soccer, "J1 League", "soccerball", 0.12, 0.42, 0.72, region: "Asia", kind: .team, shortCode: "KAW"),
        make("soccer-yokohama-fm", "Yokohama F. Marinos", .soccer, "J1 League", "soccerball", 0.12, 0.32, 0.72, region: "Asia", kind: .team, shortCode: "YFM"),
        make("soccer-vissel-kobe", "Vissel Kobe", .soccer, "J1 League", "soccerball", 0.78, 0.12, 0.22, region: "Asia", kind: .team, shortCode: "VKO"),
        make("soccer-ulsan-hd", "Ulsan HD", .soccer, "K League", "soccerball", 0.12, 0.32, 0.72, region: "Asia", kind: .team, shortCode: "ULS", aliases: ["Ulsan Hyundai"]),
        make("soccer-jeonbuk", "Jeonbuk Hyundai Motors", .soccer, "K League", "soccerball", 0.12, 0.48, 0.28, region: "Asia", kind: .team, shortCode: "JEO"),
        make("soccer-melbourne-city", "Melbourne City", .soccer, "A-League Men", "soccerball", 0.52, 0.72, 0.88, region: "Oceania", kind: .team, shortCode: "MCY"),
        make("soccer-sydney-fc", "Sydney FC", .soccer, "A-League Men", "soccerball", 0.12, 0.32, 0.72, region: "Oceania", kind: .team, shortCode: "SYD"),
        make("soccer-auckland-fc", "Auckland FC", .soccer, "A-League Men", "soccerball", 0.12, 0.32, 0.62, region: "Oceania", kind: .team, shortCode: "AUC"),
        make("soccer-al-ahly", "Al Ahly", .soccer, "Egyptian Premier League", "soccerball", 0.78, 0.12, 0.18, region: "Africa", kind: .team, shortCode: "AHL"),
        make("soccer-zamalek", "Zamalek", .soccer, "Egyptian Premier League", "soccerball", 0.12, 0.48, 0.28, region: "Africa", kind: .team, shortCode: "ZAM"),
        make("soccer-madridi", "Mamelodi Sundowns", .soccer, "South African Premiership", "soccerball", 0.92, 0.72, 0.12, region: "Africa", kind: .team, shortCode: "SUN", aliases: ["Sundowns"]),
        make("soccer-kaizer", "Kaizer Chiefs", .soccer, "South African Premiership", "soccerball", 0.92, 0.72, 0.12, region: "Africa", kind: .team, shortCode: "KAI"),
        make("soccer-orlando-pirates", "Orlando Pirates", .soccer, "South African Premiership", "soccerball", 0.12, 0.12, 0.12, region: "Africa", kind: .team, shortCode: "ORL"),
        make("soccer-wydad", "Wydad AC", .soccer, "Botola Pro", "soccerball", 0.78, 0.12, 0.18, region: "Africa", kind: .team, shortCode: "WAC"),
        make("soccer-esperance", "Espérance de Tunis", .soccer, "Tunisian Ligue 1", "soccerball", 0.92, 0.72, 0.12, region: "Africa", kind: .team, shortCode: "EST", aliases: ["Esperance"]),
        make("soccer-celtic", "Celtic", .soccer, "Scottish Premiership", "soccerball", 0.12, 0.48, 0.28, region: "Europe", kind: .team, shortCode: "CEL"),
        make("soccer-rangers", "Rangers", .soccer, "Scottish Premiership", "soccerball", 0.12, 0.32, 0.72, region: "Europe", kind: .team, shortCode: "RAN"),
        make("soccer-club-brugge", "Club Brugge", .soccer, "Belgian Pro League", "soccerball", 0.12, 0.32, 0.72, region: "Europe", kind: .team, shortCode: "BRU"),
        make("soccer-andercleht", "Anderlecht", .soccer, "Belgian Pro League", "soccerball", 0.78, 0.42, 0.12, region: "Europe", kind: .team, shortCode: "AND"),
        make("soccer-salzburg", "Red Bull Salzburg", .soccer, "Austrian Bundesliga", "soccerball", 0.78, 0.12, 0.18, region: "Europe", kind: .team, shortCode: "RBS"),
        make("soccer-young-boys", "Young Boys", .soccer, "Swiss Super League", "soccerball", 0.92, 0.72, 0.12, region: "Europe", kind: .team, shortCode: "YB"),
        make("soccer-galatasaray", "Galatasaray", .soccer, "Süper Lig", "soccerball", 0.78, 0.12, 0.18, region: "Europe", kind: .team, shortCode: "GAL"),
        make("soccer-fenerbahce", "Fenerbahçe", .soccer, "Süper Lig", "soccerball", 0.92, 0.72, 0.12, region: "Europe", kind: .team, shortCode: "FEN", aliases: ["Fenerbahce"]),
        make("soccer-olympiacos-fc", "Olympiacos", .soccer, "Greek Super League", "soccerball", 0.78, 0.12, 0.18, region: "Europe", kind: .team, shortCode: "OLY"),
        make("soccer-panathinaikos-fc", "Panathinaikos", .soccer, "Greek Super League", "soccerball", 0.12, 0.48, 0.28, region: "Europe", kind: .team, shortCode: "PAO"),
    ]

    private static let globalSoccerNationalTeams: [FavoriteTeam] = [
        make("soccer-nt-senegal", "Senegal", .soccer, "National Team", "soccerball", 0.12, 0.48, 0.28, region: "National Teams", kind: .nationalTeam, shortCode: "SEN"),
        make("soccer-nt-nigeria", "Nigeria", .soccer, "National Team", "soccerball", 0.12, 0.48, 0.28, region: "National Teams", kind: .nationalTeam, shortCode: "NGA"),
        make("soccer-nt-egypt", "Egypt", .soccer, "National Team", "soccerball", 0.78, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "EGY"),
        make("soccer-nt-ghana", "Ghana", .soccer, "National Team", "soccerball", 0.92, 0.72, 0.12, region: "National Teams", kind: .nationalTeam, shortCode: "GHA"),
        make("soccer-nt-south-africa", "South Africa", .soccer, "National Team", "soccerball", 0.12, 0.48, 0.28, region: "National Teams", kind: .nationalTeam, shortCode: "RSA"),
        make("soccer-nt-colombia", "Colombia", .soccer, "National Team", "soccerball", 0.92, 0.72, 0.12, region: "National Teams", kind: .nationalTeam, shortCode: "COL"),
        make("soccer-nt-uruguay", "Uruguay", .soccer, "National Team", "soccerball", 0.52, 0.72, 0.88, region: "National Teams", kind: .nationalTeam, shortCode: "URU"),
        make("soccer-nt-chile", "Chile", .soccer, "National Team", "soccerball", 0.78, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "CHI"),
        make("soccer-nt-saudi", "Saudi Arabia", .soccer, "National Team", "soccerball", 0.12, 0.48, 0.28, region: "National Teams", kind: .nationalTeam, shortCode: "KSA"),
        make("soccer-nt-iran", "Iran", .soccer, "National Team", "soccerball", 0.78, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "IRN"),
        make("soccer-nt-qatar", "Qatar", .soccer, "National Team", "soccerball", 0.78, 0.12, 0.22, region: "National Teams", kind: .nationalTeam, shortCode: "QAT"),
        make("soccer-nt-new-zealand", "New Zealand", .soccer, "National Team", "soccerball", 0.12, 0.12, 0.12, region: "National Teams", kind: .nationalTeam, shortCode: "NZL", aliases: ["All Whites"]),
        make("soccer-nt-croatia", "Croatia", .soccer, "National Team", "soccerball", 0.78, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "CRO"),
        make("soccer-nt-belgium", "Belgium", .soccer, "National Team", "soccerball", 0.78, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "BEL"),
        make("soccer-nt-switzerland", "Switzerland", .soccer, "National Team", "soccerball", 0.78, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "SUI"),
        make("soccer-nt-poland", "Poland", .soccer, "National Team", "soccerball", 0.78, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "POL"),
        make("soccer-nt-denmark", "Denmark", .soccer, "National Team", "soccerball", 0.78, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "DEN"),
        make("soccer-nt-sweden", "Sweden", .soccer, "National Team", "soccerball", 0.12, 0.42, 0.72, region: "National Teams", kind: .nationalTeam, shortCode: "SWE"),
        make("soccer-nt-turkey", "Turkey", .soccer, "National Team", "soccerball", 0.78, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "TUR"),
        make("soccer-nt-greece", "Greece", .soccer, "National Team", "soccerball", 0.12, 0.32, 0.72, region: "National Teams", kind: .nationalTeam, shortCode: "GRE"),
    ]

    // MARK: Cricket
    private static let globalCricketCoverage: [FavoriteTeam] = [
        make("cricket-mi", "Mumbai Indians", .cricket, "Indian Premier League", "sportscourt.fill", 0.12, 0.32, 0.72, region: "Asia", kind: .team, shortCode: "MI"),
        make("cricket-csk", "Chennai Super Kings", .cricket, "Indian Premier League", "sportscourt.fill", 0.92, 0.72, 0.12, region: "Asia", kind: .team, shortCode: "CSK"),
        make("cricket-rcb", "Royal Challengers Bengaluru", .cricket, "Indian Premier League", "sportscourt.fill", 0.78, 0.12, 0.18, region: "Asia", kind: .team, shortCode: "RCB"),
        make("cricket-kkr", "Kolkata Knight Riders", .cricket, "Indian Premier League", "sportscourt.fill", 0.42, 0.18, 0.62, region: "Asia", kind: .team, shortCode: "KKR"),
        make("cricket-dc", "Delhi Capitals", .cricket, "Indian Premier League", "sportscourt.fill", 0.12, 0.32, 0.72, region: "Asia", kind: .team, shortCode: "DC"),
        make("cricket-gt", "Gujarat Titans", .cricket, "Indian Premier League", "sportscourt.fill", 0.12, 0.42, 0.62, region: "Asia", kind: .team, shortCode: "GT"),
        make("cricket-ss", "Sunrisers Hyderabad", .cricket, "Indian Premier League", "sportscourt.fill", 0.78, 0.42, 0.12, region: "Asia", kind: .team, shortCode: "SRH"),
        make("cricket-pbks", "Punjab Kings", .cricket, "Indian Premier League", "sportscourt.fill", 0.78, 0.12, 0.18, region: "Asia", kind: .team, shortCode: "PBKS"),
        make("cricket-rr", "Rajasthan Royals", .cricket, "Indian Premier League", "sportscourt.fill", 0.12, 0.32, 0.72, region: "Asia", kind: .team, shortCode: "RR"),
        make("cricket-lsg", "Lucknow Super Giants", .cricket, "Indian Premier League", "sportscourt.fill", 0.12, 0.48, 0.28, region: "Asia", kind: .team, shortCode: "LSG"),
        make("cricket-nt-india", "India", .cricket, "National Team", "sportscourt.fill", 0.12, 0.42, 0.72, region: "National Teams", kind: .nationalTeam, shortCode: "IND"),
        make("cricket-nt-australia", "Australia", .cricket, "National Team", "sportscourt.fill", 0.12, 0.32, 0.72, region: "National Teams", kind: .nationalTeam, shortCode: "AUS"),
        make("cricket-nt-england", "England", .cricket, "National Team", "sportscourt.fill", 0.12, 0.22, 0.48, region: "National Teams", kind: .nationalTeam, shortCode: "ENG"),
        make("cricket-nt-south-africa", "South Africa", .cricket, "National Team", "sportscourt.fill", 0.12, 0.48, 0.28, region: "National Teams", kind: .nationalTeam, shortCode: "RSA"),
        make("cricket-nt-new-zealand", "New Zealand", .cricket, "National Team", "sportscourt.fill", 0.12, 0.12, 0.12, region: "National Teams", kind: .nationalTeam, shortCode: "NZL", aliases: ["Black Caps"]),
        make("cricket-nt-pakistan", "Pakistan", .cricket, "National Team", "sportscourt.fill", 0.12, 0.48, 0.28, region: "National Teams", kind: .nationalTeam, shortCode: "PAK"),
        make("cricket-nt-west-indies", "West Indies", .cricket, "National Team", "sportscourt.fill", 0.78, 0.12, 0.22, region: "National Teams", kind: .nationalTeam, shortCode: "WI", aliases: ["Windies"]),
        make("cricket-nt-sri-lanka", "Sri Lanka", .cricket, "National Team", "sportscourt.fill", 0.12, 0.42, 0.28, region: "National Teams", kind: .nationalTeam, shortCode: "SL"),
        make("cricket-nt-bangladesh", "Bangladesh", .cricket, "National Team", "sportscourt.fill", 0.12, 0.48, 0.28, region: "National Teams", kind: .nationalTeam, shortCode: "BAN"),
        make("cricket-nt-afghanistan", "Afghanistan", .cricket, "National Team", "sportscourt.fill", 0.78, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "AFG"),
        make("league-bbl", "Big Bash League", .cricket, "Cricket League", "sportscourt.fill", 0.1, 0.68, 0.54, region: "Leagues & Tournaments", kind: .league, shortCode: "BBL", aliases: ["BBL"]),
        make("league-psl", "Pakistan Super League", .cricket, "Cricket League", "sportscourt.fill", 0.1, 0.68, 0.54, region: "Leagues & Tournaments", kind: .league, shortCode: "PSL", aliases: ["PSL"]),
        make("league-the-hundred", "The Hundred", .cricket, "Cricket League", "sportscourt.fill", 0.1, 0.68, 0.54, region: "Leagues & Tournaments", kind: .league, shortCode: "HUN"),
        make("tournament-ashes", "The Ashes", .cricket, "Cricket Tournament", "sportscourt.fill", 0.1, 0.68, 0.54, region: "Leagues & Tournaments", kind: .competition, shortCode: "ASH", aliases: ["Ashes"]),
    ]

    // MARK: Rugby
    private static let globalRugbyCoverage: [FavoriteTeam] = [
        make("rugby-crusaders", "Crusaders", .rugby, "Super Rugby Pacific", "sportscourt.fill", 0.78, 0.12, 0.18, region: "Oceania", kind: .team, shortCode: "CRU"),
        make("rugby-blues", "Blues", .rugby, "Super Rugby Pacific", "sportscourt.fill", 0.12, 0.32, 0.72, region: "Oceania", kind: .team, shortCode: "BLU"),
        make("rugby-chiefs", "Chiefs", .rugby, "Super Rugby Pacific", "sportscourt.fill", 0.92, 0.72, 0.12, region: "Oceania", kind: .team, shortCode: "CHF"),
        make("rugby-hurricanes", "Hurricanes", .rugby, "Super Rugby Pacific", "sportscourt.fill", 0.92, 0.52, 0.12, region: "Oceania", kind: .team, shortCode: "HUR"),
        make("rugby-brumbies", "ACT Brumbies", .rugby, "Super Rugby Pacific", "sportscourt.fill", 0.12, 0.32, 0.62, region: "Oceania", kind: .team, shortCode: "BRU"),
        make("rugby-reds", "Queensland Reds", .rugby, "Super Rugby Pacific", "sportscourt.fill", 0.78, 0.12, 0.18, region: "Oceania", kind: .team, shortCode: "RED"),
        make("rugby-stormers", "Stormers", .rugby, "United Rugby Championship", "sportscourt.fill", 0.12, 0.32, 0.72, region: "Africa", kind: .team, shortCode: "STO"),
        make("rugby-bulls", "Bulls", .rugby, "United Rugby Championship", "sportscourt.fill", 0.12, 0.32, 0.62, region: "Africa", kind: .team, shortCode: "BUL"),
        make("rugby-leinster", "Leinster", .rugby, "United Rugby Championship", "sportscourt.fill", 0.12, 0.32, 0.72, region: "Europe", kind: .team, shortCode: "LEI"),
        make("rugby-munster", "Munster", .rugby, "United Rugby Championship", "sportscourt.fill", 0.78, 0.12, 0.18, region: "Europe", kind: .team, shortCode: "MUN"),
        make("rugby-saracens", "Saracens", .rugby, "Premiership Rugby", "sportscourt.fill", 0.12, 0.12, 0.12, region: "Europe", kind: .team, shortCode: "SAR"),
        make("rugby-northampton", "Northampton Saints", .rugby, "Premiership Rugby", "sportscourt.fill", 0.12, 0.48, 0.28, region: "Europe", kind: .team, shortCode: "NOR"),
        make("rugby-melbourne-storm", "Melbourne Storm", .rugby, "National Rugby League", "sportscourt.fill", 0.42, 0.18, 0.62, region: "Oceania", kind: .team, shortCode: "MLS"),
        make("rugby-roosters", "Sydney Roosters", .rugby, "National Rugby League", "sportscourt.fill", 0.78, 0.12, 0.18, region: "Oceania", kind: .team, shortCode: "SYR"),
        make("rugby-broncos", "Brisbane Broncos", .rugby, "National Rugby League", "sportscourt.fill", 0.78, 0.22, 0.12, region: "Oceania", kind: .team, shortCode: "BRI"),
        make("rugby-nt-new-zealand", "New Zealand", .rugby, "National Team", "sportscourt.fill", 0.12, 0.12, 0.12, region: "National Teams", kind: .nationalTeam, shortCode: "NZL", aliases: ["All Blacks"]),
        make("rugby-nt-south-africa", "South Africa", .rugby, "National Team", "sportscourt.fill", 0.12, 0.48, 0.28, region: "National Teams", kind: .nationalTeam, shortCode: "RSA", aliases: ["Springboks"]),
        make("rugby-nt-ireland", "Ireland", .rugby, "National Team", "sportscourt.fill", 0.12, 0.48, 0.28, region: "National Teams", kind: .nationalTeam, shortCode: "IRL"),
        make("rugby-nt-france", "France", .rugby, "National Team", "sportscourt.fill", 0.12, 0.32, 0.72, region: "National Teams", kind: .nationalTeam, shortCode: "FRA"),
        make("rugby-nt-england", "England", .rugby, "National Team", "sportscourt.fill", 0.12, 0.22, 0.48, region: "National Teams", kind: .nationalTeam, shortCode: "ENG"),
        make("rugby-nt-australia", "Australia", .rugby, "National Team", "sportscourt.fill", 0.12, 0.32, 0.72, region: "National Teams", kind: .nationalTeam, shortCode: "AUS", aliases: ["Wallabies"]),
        make("rugby-nt-wales", "Wales", .rugby, "National Team", "sportscourt.fill", 0.78, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "WAL"),
        make("rugby-nt-argentina", "Argentina", .rugby, "National Team", "sportscourt.fill", 0.52, 0.72, 0.88, region: "National Teams", kind: .nationalTeam, shortCode: "ARG", aliases: ["Los Pumas"]),
        make("rugby-nt-scotland", "Scotland", .rugby, "National Team", "sportscourt.fill", 0.12, 0.32, 0.62, region: "National Teams", kind: .nationalTeam, shortCode: "SCO"),
        make("rugby-nt-fiji", "Fiji", .rugby, "National Team", "sportscourt.fill", 0.52, 0.72, 0.88, region: "National Teams", kind: .nationalTeam, shortCode: "FIJ"),
        make("rugby-nt-samoa", "Samoa", .rugby, "National Team", "sportscourt.fill", 0.12, 0.32, 0.72, region: "National Teams", kind: .nationalTeam, shortCode: "SAM"),
        make("rugby-nt-tonga", "Tonga", .rugby, "National Team", "sportscourt.fill", 0.78, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "TGA"),
        make("rugby-nt-japan", "Japan", .rugby, "National Team", "sportscourt.fill", 0.78, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "JPN", aliases: ["Brave Blossoms"]),
        make("rugby-nt-italy", "Italy", .rugby, "National Team", "sportscourt.fill", 0.12, 0.42, 0.28, region: "National Teams", kind: .nationalTeam, shortCode: "ITA"),
    ]

    // MARK: Combat promotions
    private static let globalCombatCoverage: [FavoriteTeam] = [
        make("league-ufc", "UFC", .combat, "Combat Promotion", "figure.boxing", 0.78, 0.12, 0.18, region: "Leagues & Tournaments", kind: .league, shortCode: "UFC", aliases: ["Ultimate Fighting Championship"]),
        make("league-pfl", "PFL", .combat, "Combat Promotion", "figure.boxing", 0.12, 0.32, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "PFL", aliases: ["Professional Fighters League"]),
        make("league-bellator", "Bellator", .combat, "Combat Promotion", "figure.boxing", 0.78, 0.42, 0.12, region: "Leagues & Tournaments", kind: .league, shortCode: "BEL", aliases: ["Bellator MMA"]),
        make("tournament-boxing-olympics", "Olympic Boxing", .combat, "Boxing", "figure.boxing", 0.12, 0.42, 0.72, region: "Leagues & Tournaments", kind: .competition, shortCode: "OBX"),
    ]
}
