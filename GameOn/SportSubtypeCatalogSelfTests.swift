import Foundation

#if DEBUG
enum SportSubtypeCatalogSelfTests {
    static func runAll() {
        testLegacyBikingDisplaysAsCycling()
        testNewTopLevelSportsExist()
        testNoDuplicateSportChips()
        testCyclingSubtypes()
        testElectricScooterSubtypes()
        testInlineSkatingSubtypes()
        testInvalidCombinationsRejected()
        testSearchAliases()
        testIdentityAndTitles()
        testLocalizationKeysResolve()
        testSelectColumnsIncludeSubtype()
        testExistingSportsUnchanged()
        testPickupFamiliesForNewActivities()
    }

    private static func testLegacyBikingDisplaysAsCycling() {
        precondition(AppSportCatalog.canonicalFormPickerToken(for: "Biking") == "Cycling")
        precondition(AppSportCatalog.canonicalFormPickerToken(for: "biking") == "Cycling")
        precondition(AppSportCatalog.catalogEnglishLabel(forSportToken: "Biking") == "Cycling")
        precondition(AppSportCatalog.displayLabel(forSportToken: "Biking", compact: false) == L10n.t("Cycling"))
        precondition(AppSportCatalog.sport("Biking", matchesDiscoverSelection: "Cycling"))
        precondition(AppSportCatalog.sport("Cycling", matchesDiscoverSelection: "Cycling"))
        precondition(!AppSportCatalog.sport("Soccer", matchesDiscoverSelection: "Cycling"))
    }

    private static func testNewTopLevelSportsExist() {
        let tokens = AppSportCatalog.formPickerSportsOrdered
        precondition(tokens.contains("Cycling"))
        precondition(tokens.contains("Electric Scooter"))
        precondition(tokens.contains("Inline Skating"))
        precondition(!tokens.contains(where: { $0.localizedCaseInsensitiveContains("Mountain Biking") }))
        precondition(!tokens.contains(where: { $0.localizedCaseInsensitiveContains("Road Cycling") }))
        let visualScooter = SportFilterCatalog.resolve("Electric Scooter")
        precondition(visualScooter.systemImage == "scooter")
        let visualInline = SportFilterCatalog.resolve("Inline Skating")
        precondition(visualInline.systemImage == "figure.skating")
        precondition(SportFilterCatalog.resolve("Cycling").systemImage == "bicycle")
    }

    private static func testNoDuplicateSportChips() {
        let labels = AppSportCatalog.formPickerSportsOrdered.map {
            AppSportCatalog.catalogEnglishLabel(forSportToken: $0).lowercased()
        }
        precondition(Set(labels).count == labels.count)
    }

    private static func testCyclingSubtypes() {
        let ids = SportSubtypeCatalog.subtypes(forSport: "Cycling").map(\.id)
        precondition(ids == [
            "road_cycling", "mountain_biking", "gravel", "bmx", "e_bike", "casual_ride", "other"
        ])
        precondition(SportSubtypeCatalog.normalizedSubtype(sport: "Cycling", subtype: "mountain_biking") == "mountain_biking")
        precondition(
            SportSubtypeCatalog.identityLine(
                sport: "Cycling",
                subtype: "mountain_biking",
                languageCode: "en"
            ) == "Cycling · Mountain Biking"
        )
        precondition(
            SportSubtypeCatalog.suggestedTitle(
                sport: "Cycling",
                subtype: "mountain_biking",
                languageCode: "en"
            ) == "Mountain Bike Ride"
        )
        precondition(
            SportSubtypeCatalog.suggestedTitle(
                sport: "Cycling",
                subtype: "road_cycling",
                languageCode: "en"
            ) == "Road Ride"
        )
        for token in ["gravel", "bmx", "e_bike", "casual_ride"] {
            precondition(SportSubtypeCatalog.normalizedSubtype(sport: "Cycling", subtype: token) == token)
        }
    }

    private static func testElectricScooterSubtypes() {
        let ids = SportSubtypeCatalog.subtypes(forSport: "Electric Scooter").map(\.id)
        precondition(ids == ["group_ride", "street_cruise", "trail_offroad", "other"])
        precondition(
            SportSubtypeCatalog.identityLine(
                sport: "Electric Scooter",
                subtype: "group_ride",
                languageCode: "en"
            ).contains("Group Ride")
        )
        precondition(
            SportSubtypeCatalog.suggestedTitle(
                sport: "Electric Scooter",
                subtype: "trail_offroad",
                languageCode: "en"
            ) == "E-Scooter Trail Ride"
        )
        precondition(AppSportCatalog.displayLabel(forSportToken: "Electric Scooter", compact: true) == L10n.t("E-Scooter"))
        precondition(AppSportCatalog.canonicalFormPickerToken(for: "e-scooter") == "Electric Scooter")
    }

    private static func testInlineSkatingSubtypes() {
        let ids = SportSubtypeCatalog.subtypes(forSport: "Inline Skating").map(\.id)
        precondition(ids == ["recreational", "fitness", "urban_street", "speed", "other"])
        precondition(
            SportSubtypeCatalog.suggestedTitle(
                sport: "Inline Skating",
                subtype: "recreational",
                languageCode: "en"
            ) == "Inline Skating Session"
        )
        precondition(
            SportSubtypeCatalog.suggestedTitle(
                sport: "Inline Skating",
                subtype: "fitness",
                languageCode: "en"
            ) == "Inline Skating Fitness"
        )
        precondition(AppSportCatalog.canonicalFormPickerToken(for: "rollerblading") == "Inline Skating")
    }

    private static func testInvalidCombinationsRejected() {
        precondition(SportSubtypeCatalog.normalizedSubtype(sport: "Soccer", subtype: "mountain_biking") == nil)
        precondition(SportSubtypeCatalog.normalizedSubtype(sport: "Cycling", subtype: "group_ride") == nil)
        precondition(SportSubtypeCatalog.normalizedSubtype(sport: "Baseball", subtype: "mountain_biking") == nil)
        precondition(SportSubtypeCatalog.ensuringValidSelection("mountain_biking", sport: "Soccer") == nil)
        precondition(SportSubtypeCatalog.ensuringValidSelection("nope", sport: "Cycling") == "road_cycling")
        precondition(!SportSubtypeCatalog.hasSubtypes(forSport: "Soccer"))
    }

    private static func testSearchAliases() {
        precondition(SportFilterCatalog.storedSport("Cycling", matchesSearchQuery: "MTB"))
        precondition(SportFilterCatalog.storedSport("Cycling", matchesSearchQuery: "mountain bike"))
        precondition(SportFilterCatalog.storedSport("Electric Scooter", matchesSearchQuery: "e-scooter"))
        precondition(SportFilterCatalog.storedSport("Electric Scooter", matchesSearchQuery: "escooter"))
        precondition(SportFilterCatalog.storedSport("Inline Skating", matchesSearchQuery: "rollerblading"))
        precondition(SportSubtypeCatalog.matchesSearch(sport: "Cycling", subtype: "mountain_biking", query: "MTB"))
        precondition(SportSubtypeCatalog.matchesSearch(sport: "Cycling", subtype: "e_bike", query: "electric bike"))
        precondition(SportSubtypeCatalog.matchesSearch(sport: "Inline Skating", subtype: "recreational", query: "rollerblade"))
        let cyclingHits = AppSportCatalog.SportCatalog.filteredCategories(query: "mtb")
        precondition(cyclingHits.contains(where: { category in
            category.rows.contains(where: { $0.selection == "Cycling" })
        }))
        let scooterHits = AppSportCatalog.SportCatalog.filteredCategories(query: "e-scooter")
        precondition(scooterHits.contains(where: { category in
            category.rows.contains(where: { $0.selection == "Electric Scooter" })
        }))
        let skateHits = AppSportCatalog.SportCatalog.filteredCategories(query: "rollerblading")
        precondition(skateHits.contains(where: { category in
            category.rows.contains(where: { $0.selection == "Inline Skating" })
        }))
    }

    private static func testIdentityAndTitles() {
        let custom = SportSubtypeCatalog.identityLine(
            sport: "Cycling",
            subtype: "casual_ride",
            languageCode: "en"
        )
        precondition(custom.contains("Cycling"))
        precondition(custom.contains("Casual Ride"))
        let league = SportSubtypeCatalog.identityLine(
            sport: "Soccer",
            subtype: nil,
            languageCode: "en"
        )
        precondition(league == AppSportCatalog.displayLabel(forSportToken: "Soccer"))
        let twoTeams = SportSubtypeCatalog.identityLine(
            sport: "Cycling",
            subtype: "road_cycling",
            languageCode: "en"
        )
        precondition(twoTeams != SportSubtypeCatalog.identityLine(
            sport: "Cycling",
            subtype: "mountain_biking",
            languageCode: "en"
        ))
    }

    private static func testLocalizationKeysResolve() {
        for key in [
            "Electric Scooter", "E-Scooter", "Inline Skating",
            "sport_subtype_picker_cycling", "sport_subtype_mountain_biking",
            "sport_subtype_group_ride", "sport_subtype_recreational",
            "sport_subtype_identity_format"
        ] {
            let value = L10n.t(key, languageCode: "en")
            precondition(!value.isEmpty, "missing l10n \(key)")
            precondition(value != key || key == "E-Scooter" || key == "Electric Scooter" || key == "Inline Skating",
                         "unresolved l10n \(key)")
        }
        for lang in ["es", "fr", "pt", "de", "it", "pl", "ru", "sq", "zh-Hans", "nl"] {
            let cycling = L10n.t("sport_subtype_mountain_biking", languageCode: lang)
            precondition(!cycling.isEmpty)
            precondition(cycling != "sport_subtype_mountain_biking", "lang \(lang) missing subtype")
        }
    }

    private static func testSelectColumnsIncludeSubtype() {
        precondition(pickupGamesSelectColumns.contains("sport,sport_subtype,description"))
    }

    private static func testExistingSportsUnchanged() {
        for token in ["Soccer", "NBA", "NFL", "Running", "Climbing", "Skateboarding"] {
            precondition(AppSportCatalog.formPickerSportsOrdered.contains(token) || token == "NBA" || token == "NFL")
        }
        precondition(AppSportCatalog.formPickerSportsOrdered.contains("Soccer"))
        precondition(AppSportCatalog.formPickerSportsOrdered.contains("Running"))
        precondition(PickupEventTypeCatalog.sportFamily(forSport: "Soccer") == .teamBall)
    }

    private static func testPickupFamiliesForNewActivities() {
        precondition(PickupEventTypeCatalog.sportFamily(forSport: "Electric Scooter") == .cycling)
        precondition(PickupEventTypeCatalog.sportFamily(forSport: "Inline Skating") == .climbing)
        precondition(PickupEventTypeCatalog.usesParticipantTerminology(for: "Electric Scooter"))
        precondition(PickupEventTypeCatalog.usesParticipantTerminology(for: "Inline Skating"))
        precondition(
            PickupEventTypeCatalog.displayTitle(for: .pickup, sport: "Cycling", languageCode: "en")
                == L10n.t("pickup_event_type_group_ride", languageCode: "en")
        )
        precondition(
            PickupEventTypeCatalog.displayTitle(for: .pickup, sport: "Electric Scooter", languageCode: "en")
                == L10n.t("pickup_event_type_group_ride", languageCode: "en")
        )
        precondition(
            PickupEventTypeCatalog.displayTitle(for: .pickup, sport: "Inline Skating", languageCode: "en")
                == L10n.t("pickup_event_type_group_session", languageCode: "en")
        )
    }
}
#endif
