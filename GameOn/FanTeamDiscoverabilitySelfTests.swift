import CoreLocation
import Foundation

#if DEBUG
enum FanTeamDiscoverabilitySelfTests {
    static func runAll() {
        testHiddenTeamNeverMaps()
        testDiscoverableRequiresLocation()
        testLookingForPlayersDoesNotPublish()
        testGeneralAreaOmitsStreet()
        testSportSubtypeMatching()
        testMixedCountCopy()
        testEmptyStateWhenOnlyTeamsExist()
        testEditIdentityGate()
        testClusteringReusesExistingKey()
        testPlacesAndTeamsClusterSeparately()
        testOverlappingTeamAndPlaceClustersSplit()
        testClusterChromeScalesWithCount()
        testClusterAccessibilityCopy()
        testMixedClusterKindIsUnusedFallback()
        testUnifiedPlacesAlwaysShowsBothFamilies()
        testLocationClearFlagPreservesSavedLocation()
        testDiscoveryEditorChromeAndMiniMap()
        testDiscoveryEditorPublicPreviewAndRecruiting()
        testDiscoveryEditorPrecisionAndLocationUpdates()
        testDiscoveryEditorWorldwideFormatting()
        testDiscoveryEditorLocalizationKeys()
        testDiscoveryEditorPermissionsUnchanged()
        testWorkspaceRoutingOwnerManagerMemberGuardian()
        testWorkspaceRoutingOutsiderAndAnonymous()
        testDiscoverabilityDoesNotGrantWorkspace()
        testPublicEventVisibilityDoesNotGrantWorkspace()
        testPublicSummaryFieldsAreSafe()
        testPublicProfileOmitsPrivateTabs()
        print("[FanTeamDiscoverabilitySelfTests] all passed")
    }

    private static func sampleTeam(
        name: String = "Wasatch MTB Crew",
        sport: String = "Cycling",
        subtype: String? = "mountain_biking",
        looking: Bool = true,
        precision: FanTeamDiscoveryLocationPrecision = .specific,
        placeName: String? = "Corner Canyon Trailhead",
        city: String? = "Draper",
        region: String? = "Utah",
        postal: String? = "84020",
        country: String = "US",
        lat: Double = 40.494,
        lon: Double = -111.863
    ) -> DiscoverableFanTeamMapRow {
        DiscoverableFanTeamMapRow(
            id: UUID(),
            name: name,
            sport: sport,
            sportSubtype: subtype,
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: "#22C25A",
            lookingForPlayers: looking,
            memberCount: 18,
            precision: precision,
            placeName: placeName,
            city: city,
            region: region,
            postalCode: postal,
            countryCode: country,
            latitude: lat,
            longitude: lon
        )
    }

    private static func testHiddenTeamNeverMaps() {
        var settings = FanTeamDiscoverySettings.hidden
        precondition(!settings.isDiscoverable)
        precondition(!settings.lookingForPlayers)
        precondition(FanTeamDiscoveryLocationPolicy.canSave(settings: settings))
        settings.lookingForPlayers = true
        precondition(!settings.isDiscoverable)
        precondition(FanTeamDiscoveryRPCRow(
            team_id: UUID(),
            name: "Hidden",
            sport: "Soccer",
            sport_subtype: nil,
            logo_url: nil,
            logo_thumbnail_url: nil,
            color_hex: nil,
            looking_for_players: true,
            member_count: 4,
            location_precision: "specific",
            place_name: nil,
            city: nil,
            region: nil,
            postal_code: nil,
            country_code: nil,
            latitude: nil,
            longitude: nil
        ).asMapRow() == nil)
    }

    private static func testDiscoverableRequiresLocation() {
        var settings = FanTeamDiscoverySettings.hidden
        settings.isDiscoverable = true
        precondition(!FanTeamDiscoveryLocationPolicy.canSave(settings: settings))
        settings.apply(
            selection: FanTeamLocationSelection(
                address: "1 Rue de Rivoli",
                city: "Paris",
                state: "Île-de-France",
                zipCode: "75001",
                countryCode: "FR",
                latitude: 48.8606,
                longitude: 2.3376
            )
        )
        precondition(settings.hasValidPublicLocation)
        precondition(FanTeamDiscoveryLocationPolicy.canSave(settings: settings))
        precondition(!FanTeamDiscoveryLocationPolicy.hasValidCoordinate(latitude: 0, longitude: 0))
        precondition(
            FanTeamDiscoveryLocationPolicy.isValid(
                latitude: 30.0444,
                longitude: 31.2357,
                countryCode: "EG",
                city: "Cairo",
                placeName: nil
            )
        )
        precondition(
            FanTeamDiscoveryLocationPolicy.isValid(
                latitude: 45.4215,
                longitude: -75.6972,
                countryCode: "CA",
                city: "Ottawa",
                placeName: nil
            )
        )
    }

    private static func testLookingForPlayersDoesNotPublish() {
        var settings = FanTeamDiscoverySettings.hidden
        settings.lookingForPlayers = true
        precondition(!settings.isDiscoverable)
        precondition(FanTeamDiscoveryLocationPolicy.canSave(settings: settings))
    }

    private static func testGeneralAreaOmitsStreet() {
        let specific = sampleTeam(precision: .specific)
        precondition(specific.localityDisplayLine().localizedCaseInsensitiveContains("Corner Canyon"))
        let general = sampleTeam(precision: .generalArea)
        let line = general.localityDisplayLine()
        precondition(!line.localizedCaseInsensitiveContains("Corner Canyon"))
        precondition(line.localizedCaseInsensitiveContains("Draper") || line.localizedCaseInsensitiveContains("Utah"))
    }

    private static func testSportSubtypeMatching() {
        let team = sampleTeam()
        precondition(AppSportCatalog.sport(team.sport, matchesDiscoverSelection: "Cycling"))
        precondition(SportSubtypeCatalog.matchesSearch(sport: team.sport, subtype: team.sportSubtype, query: "MTB"))
        precondition(SportSubtypeCatalog.matchesSearch(sport: team.sport, subtype: team.sportSubtype, query: "mountain biking"))
        let soccer = sampleTeam(name: "Lehi United", sport: "Soccer", subtype: nil)
        precondition(AppSportCatalog.sport(soccer.sport, matchesDiscoverSelection: "Soccer"))
        precondition(!AppSportCatalog.sport(soccer.sport, matchesDiscoverSelection: "Cycling"))
    }

    private static func testMixedCountCopy() {
        let mixed = FanTeamDiscoveryCopy.statusLine(
            placeCount: 144,
            teamCount: 6,
            sport: nil,
            languageCode: "en"
        )
        precondition(mixed.contains("144"))
        precondition(mixed.localizedCaseInsensitiveContains("6"))
        precondition(!mixed.localizedCaseInsensitiveContains("pickup places"))
        let placesOnly = FanTeamDiscoveryCopy.statusLine(
            placeCount: 144,
            teamCount: 0,
            sport: nil,
            languageCode: "en"
        )
        precondition(placesOnly.contains("144"))
        let teamsOnly = FanTeamDiscoveryCopy.statusLine(
            placeCount: 0,
            teamCount: 6,
            sport: nil,
            languageCode: "en"
        )
        precondition(teamsOnly.contains("6"))
        let bothEmpty = FanTeamDiscoveryCopy.statusLine(
            placeCount: 0,
            teamCount: 0,
            sport: nil,
            languageCode: "en"
        )
        precondition(bothEmpty.localizedCaseInsensitiveContains("places") || bothEmpty.localizedCaseInsensitiveContains("teams"))
    }

    private static func testEmptyStateWhenOnlyTeamsExist() {
        let teamsOnly = FanTeamDiscoveryCopy.emptyTitle(
            placeCount: 0,
            teamCount: 3,
            languageCode: "en"
        )
        precondition(teamsOnly == nil)
        let placesOnly = FanTeamDiscoveryCopy.emptyTitle(
            placeCount: 3,
            teamCount: 0,
            languageCode: "en"
        )
        precondition(placesOnly == nil)
        let bothEmpty = FanTeamDiscoveryCopy.emptyTitle(
            placeCount: 0,
            teamCount: 0,
            languageCode: "en"
        )
        precondition(bothEmpty != nil)
        precondition(bothEmpty?.localizedCaseInsensitiveContains("places") == true)
        precondition(bothEmpty?.localizedCaseInsensitiveContains("teams") == true)
    }

    private static func testEditIdentityGate() {
        let owner = FanTeamSummary(
            id: UUID(),
            name: "AF Hoops",
            sport: "Basketball",
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: nil,
            competitionLevel: nil,
            ownerUserId: UUID(),
            groupConversationId: UUID(),
            myRole: .owner,
            memberCount: 8,
            pendingInvitationCount: 0,
            pushNotificationsMuted: false,
            nextGameStartsAt: nil,
            nextGameTitle: nil,
            nextGameVenue: nil,
            createdAt: Date()
        )
        precondition(owner.canEditIdentity)
        let member = FanTeamSummary(
            id: UUID(),
            name: "AF Hoops",
            sport: "Basketball",
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: nil,
            competitionLevel: nil,
            ownerUserId: UUID(),
            groupConversationId: UUID(),
            myRole: .member,
            memberCount: 8,
            pendingInvitationCount: 0,
            pushNotificationsMuted: false,
            nextGameStartsAt: nil,
            nextGameTitle: nil,
            nextGameVenue: nil,
            createdAt: Date()
        )
        precondition(!member.canEditIdentity)
    }

    private static func testClusteringReusesExistingKey() {
        let a = CLLocationCoordinate2D(latitude: 40.494, longitude: -111.863)
        let b = CLLocationCoordinate2D(latitude: 40.4941, longitude: -111.8631)
        let keyA = DiscoverVenueClusterTuning.clusterKey(for: a, visibleLatitudeDelta: 0.08)
        let keyB = DiscoverVenueClusterTuning.clusterKey(for: b, visibleLatitudeDelta: 0.08)
        precondition(!keyA.isEmpty)
        precondition(keyA == keyB)
    }

    private static func testPlacesAndTeamsClusterSeparately() {
        let coord = CLLocationCoordinate2D(latitude: 40.494, longitude: -111.863)
        let key = DiscoverVenueClusterTuning.clusterKey(for: coord, visibleLatitudeDelta: 0.35)
        let teamCluster = DiscoverableFanTeamCluster(
            id: "\(DiscoverPlacesClusterSeparation.teamIDPrefix)\(key)",
            rows: [sampleTeam()],
            coordinate: coord
        )
        let placeCluster = PickupPlaceCluster(
            id: "\(DiscoverPlacesClusterSeparation.placeIDPrefix)\(key)",
            rows: [],
            coordinate: coord
        )
        precondition(teamCluster.id != placeCluster.id)
        precondition(DiscoverMapClusterKind.teams.iconSystemName == "shield.fill")
        precondition(DiscoverMapClusterKind.places.iconSystemName == "sportscourt.fill")
        precondition(DiscoverMapClusterKind.teams.iconSystemName != DiscoverMapClusterKind.places.iconSystemName)
    }

    private static func testOverlappingTeamAndPlaceClustersSplit() {
        let coord = CLLocationCoordinate2D(latitude: 40.494, longitude: -111.863)
        let key = DiscoverVenueClusterTuning.clusterKey(for: coord, visibleLatitudeDelta: 0.35)
        let teams = [
            DiscoverableFanTeamCluster(
                id: "\(DiscoverPlacesClusterSeparation.teamIDPrefix)\(key)",
                rows: [sampleTeam(), sampleTeam(name: "IMC Team")],
                coordinate: coord
            )
        ]
        let places = [
            PickupPlaceCluster(
                id: "\(DiscoverPlacesClusterSeparation.placeIDPrefix)\(key)",
                rows: [],
                coordinate: coord
            )
        ]
        let separated = DiscoverPlacesClusterSeparation.separateOverlapping(
            teams: teams,
            places: places,
            visibleLatitudeDelta: 0.35
        )
        precondition(separated.teams.count == 1)
        precondition(separated.places.count == 1)
        precondition(separated.teams[0].id == teams[0].id)
        precondition(separated.places[0].id == places[0].id)
        let teamMoved = abs(separated.teams[0].coordinate.latitude - coord.latitude) > 0.00001
            || abs(separated.teams[0].coordinate.longitude - coord.longitude) > 0.00001
        let placeMoved = abs(separated.places[0].coordinate.latitude - coord.latitude) > 0.00001
            || abs(separated.places[0].coordinate.longitude - coord.longitude) > 0.00001
        precondition(teamMoved)
        precondition(placeMoved)
        precondition(separated.teams[0].coordinate.latitude != separated.places[0].coordinate.latitude)

        let farPlace = PickupPlaceCluster(
            id: "\(DiscoverPlacesClusterSeparation.placeIDPrefix)\(key)",
            rows: [],
            coordinate: CLLocationCoordinate2D(latitude: 40.6, longitude: -111.7)
        )
        let unchanged = DiscoverPlacesClusterSeparation.separateOverlapping(
            teams: teams,
            places: [farPlace],
            visibleLatitudeDelta: 0.35
        )
        precondition(abs(unchanged.teams[0].coordinate.latitude - coord.latitude) < 0.0000001)
        precondition(abs(unchanged.places[0].coordinate.latitude - 40.6) < 0.0000001)

        let differentKeyPlace = PickupPlaceCluster(
            id: "\(DiscoverPlacesClusterSeparation.placeIDPrefix)other-cell",
            rows: [],
            coordinate: coord
        )
        let nearbyDifferentKey = DiscoverPlacesClusterSeparation.separateOverlapping(
            teams: teams,
            places: [differentKeyPlace],
            visibleLatitudeDelta: 0.35
        )
        precondition(nearbyDifferentKey.teams[0].coordinate.latitude != coord.latitude)
        precondition(nearbyDifferentKey.places[0].coordinate.latitude != coord.latitude)
    }

    private static func testClusterChromeScalesWithCount() {
        let two = DiscoverMapClusterChrome.diameter(count: 2)
        let seven = DiscoverMapClusterChrome.diameter(count: 7)
        let twentyFive = DiscoverMapClusterChrome.diameter(count: 25)
        precondition(two < seven)
        precondition(seven < twentyFive)
        precondition(DiscoverMapClusterChrome.iconPointSize(count: 2) > 8)
        precondition(DiscoverMapClusterChrome.iconPointSize(count: 25) >= DiscoverMapClusterChrome.iconPointSize(count: 2))
    }

    private static func testClusterAccessibilityCopy() {
        let teams = String(
            format: L10n.t("discover_team_cluster_a11y_format", languageCode: "en"),
            locale: Locale(identifier: "en"),
            Int64(12)
        )
        let places = String(
            format: L10n.t("discover_place_cluster_a11y_format", languageCode: "en"),
            locale: Locale(identifier: "en"),
            Int64(5)
        )
        precondition(teams == "12 Teams")
        precondition(places == "5 Pickup Places")
        precondition(!teams.localizedCaseInsensitiveContains("cluster"))
        precondition(!places.localizedCaseInsensitiveContains("cluster"))
        let mixed = String(
            format: L10n.t("discover_mixed_cluster_a11y_format", languageCode: "en"),
            locale: Locale(identifier: "en"),
            Int64(3)
        )
        precondition(!mixed.localizedCaseInsensitiveContains("cluster"))
    }

    private static func testMixedClusterKindIsUnusedFallback() {
        precondition(DiscoverMapClusterKind.mixed.iconSystemName == "circle.grid.2x1.fill")
        precondition(DiscoverMapClusterKind.teams.iconSystemName == "shield.fill")
        precondition(DiscoverMapClusterKind.places.iconSystemName == "sportscourt.fill")
        precondition(DiscoverMapClusterKind.teams.iconSystemName != DiscoverMapClusterKind.places.iconSystemName)
        precondition(DiscoverMapClusterKind.mixed.iconSystemName != DiscoverMapClusterKind.teams.iconSystemName)
        precondition(DiscoverMapClusterKind.mixed.iconSystemName != DiscoverMapClusterKind.places.iconSystemName)
    }

    private static func testUnifiedPlacesAlwaysShowsBothFamilies() {
        let mixed = FanTeamDiscoveryCopy.statusLine(
            placeCount: 57,
            teamCount: 3,
            sport: nil,
            languageCode: "en"
        )
        precondition(mixed.contains("57"))
        precondition(mixed.localizedCaseInsensitiveContains("3"))
        precondition(FanTeamDiscoveryCopy.emptyTitle(placeCount: 0, teamCount: 3, languageCode: "en") == nil)
        precondition(FanTeamDiscoveryCopy.emptyTitle(placeCount: 3, teamCount: 0, languageCode: "en") == nil)
        precondition(FanTeamDiscoveryCopy.emptyTitle(placeCount: 0, teamCount: 0, languageCode: "en") != nil)
        let soccerMixed = FanTeamDiscoveryCopy.statusLine(
            placeCount: 12,
            teamCount: 4,
            sport: "soccer",
            languageCode: "en"
        )
        precondition(soccerMixed.contains("12"))
        precondition(soccerMixed.localizedCaseInsensitiveContains("4"))
        precondition(AppSportCatalog.sport("Soccer", matchesDiscoverSelection: "Soccer"))
        precondition(AppSportCatalog.sport("Basketball", matchesDiscoverSelection: "Basketball"))
        precondition(!AppSportCatalog.sport("Soccer", matchesDiscoverSelection: "Basketball"))
    }

    private static func testLocationClearFlagPreservesSavedLocation() {
        var hiddenWithLocation = FanTeamDiscoverySettings.hidden
        hiddenWithLocation.apply(
            selection: FanTeamLocationSelection(
                address: "123 Main St",
                city: "Lehi",
                state: "Utah",
                zipCode: "84043",
                countryCode: "US",
                latitude: 40.387,
                longitude: -111.849
            )
        )
        precondition(!hiddenWithLocation.isDiscoverable)
        precondition(hiddenWithLocation.hasValidDiscoveryCoordinate)
        precondition(!hiddenWithLocation.shouldClearStoredDiscoveryLocation)

        var discoverOn = hiddenWithLocation
        discoverOn.isDiscoverable = true
        precondition(!discoverOn.shouldClearStoredDiscoveryLocation)
        precondition(FanTeamDiscoveryLocationPolicy.canSave(settings: discoverOn))

        var lookingOnly = FanTeamDiscoverySettings.hidden
        lookingOnly.lookingForPlayers = true
        lookingOnly.apply(
            selection: FanTeamLocationSelection(
                address: "123 Main St",
                city: "Lehi",
                state: "Utah",
                zipCode: "84043",
                countryCode: "US",
                latitude: 40.387,
                longitude: -111.849
            )
        )
        precondition(lookingOnly.lookingForPlayers)
        precondition(!lookingOnly.isDiscoverable)
        precondition(!lookingOnly.shouldClearStoredDiscoveryLocation)

        var explicitClear = hiddenWithLocation
        explicitClear.clearLocation()
        precondition(explicitClear.shouldClearStoredDiscoveryLocation)
        precondition(FanTeamDiscoveryLocationPolicy.canSave(settings: explicitClear))

        var discoverOnNoLocation = FanTeamDiscoverySettings.hidden
        discoverOnNoLocation.isDiscoverable = true
        precondition(!FanTeamDiscoveryLocationPolicy.canSave(settings: discoverOnNoLocation))
    }

    private static func rivertonSelection() -> FanTeamLocationSelection {
        FanTeamLocationSelection(
            placeName: "Riverton Courts",
            address: "14641 S 800 W",
            city: "Riverton",
            state: "Utah",
            zipCode: "84065",
            countryCode: "US",
            latitude: 40.521,
            longitude: -111.939
        )
    }

    private static func settings(
        discoverable: Bool,
        looking: Bool = false,
        precision: FanTeamDiscoveryLocationPrecision = .specific,
        location: FanTeamLocationSelection? = nil
    ) -> FanTeamDiscoverySettings {
        var value = FanTeamDiscoverySettings.hidden
        value.isDiscoverable = discoverable
        value.lookingForPlayers = looking
        value.precision = precision
        if let location {
            value.apply(selection: location)
        }
        return value
    }

    private static func testDiscoveryEditorChromeAndMiniMap() {
        let offNoLocation = settings(discoverable: false)
        precondition(FanTeamDiscoveryEditorPresentation.locationChrome(for: offNoLocation) == .compactSetup)
        precondition(!FanTeamDiscoveryEditorPresentation.showsMiniMap(settings: offNoLocation))
        precondition(!FanTeamDiscoveryEditorPresentation.showsEmptyMap(settings: offNoLocation))
        precondition(!FanTeamDiscoveryEditorPresentation.showsPublicPreview(settings: offNoLocation))
        precondition(!FanTeamDiscoveryEditorPresentation.showsChooseLocationCTA(settings: offNoLocation))

        let onNoLocation = settings(discoverable: true)
        precondition(FanTeamDiscoveryEditorPresentation.locationChrome(for: onNoLocation) == .prominentMissing)
        precondition(!FanTeamDiscoveryEditorPresentation.showsMiniMap(settings: onNoLocation))
        precondition(!FanTeamDiscoveryEditorPresentation.showsEmptyMap(settings: onNoLocation))
        precondition(FanTeamDiscoveryEditorPresentation.showsChooseLocationCTA(settings: onNoLocation))
        precondition(!FanTeamDiscoveryLocationPolicy.canSave(settings: onNoLocation))

        let onSpecific = settings(discoverable: true, precision: .specific, location: rivertonSelection())
        precondition(FanTeamDiscoveryEditorPresentation.locationChrome(for: onSpecific) == .prominentConfigured)
        precondition(FanTeamDiscoveryEditorPresentation.showsMiniMap(settings: onSpecific))
        let specificDelta = FanTeamDiscoveryEditorPresentation.mapCamera(for: onSpecific)?.delta ?? 0
        precondition(specificDelta > 0)

        let onGeneral = settings(discoverable: true, precision: .generalArea, location: rivertonSelection())
        precondition(FanTeamDiscoveryEditorPresentation.showsMiniMap(settings: onGeneral))
        let generalDelta = FanTeamDiscoveryEditorPresentation.mapCamera(for: onGeneral)?.delta ?? 0
        precondition(generalDelta > specificDelta)
        precondition(FanTeamDiscoveryEditorPresentation.generalAreaRadiusMeters > 0)

        let offWithLocation = settings(discoverable: false, location: rivertonSelection())
        precondition(FanTeamDiscoveryEditorPresentation.locationChrome(for: offWithLocation) == .compactConfigured)
        precondition(!FanTeamDiscoveryEditorPresentation.showsMiniMap(settings: offWithLocation))
        precondition(offWithLocation.hasValidDiscoveryCoordinate)
        precondition(!offWithLocation.shouldClearStoredDiscoveryLocation)
    }

    private static func testDiscoveryEditorPublicPreviewAndRecruiting() {
        let lookingOnDiscoverOff = settings(discoverable: false, looking: true, location: rivertonSelection())
        precondition(lookingOnDiscoverOff.lookingForPlayers)
        precondition(!lookingOnDiscoverOff.isDiscoverable)
        precondition(!FanTeamDiscoveryEditorPresentation.publiclyAdvertisesRecruiting(settings: lookingOnDiscoverOff))
        precondition(
            FanTeamDiscoveryEditorPresentation.publicPreviewRow(
                settings: lookingOnDiscoverOff,
                teamId: UUID(),
                name: "IMC Team",
                sport: "Badminton",
                logoURL: nil,
                logoThumbnailURL: nil,
                colorHex: "#22C25A",
                memberCount: 12
            ) == nil
        )

        var lookingKept = lookingOnDiscoverOff
        lookingKept.isDiscoverable = false
        precondition(lookingKept.lookingForPlayers)
        lookingKept.isDiscoverable = true
        precondition(lookingKept.lookingForPlayers)
        precondition(FanTeamDiscoveryEditorPresentation.publiclyAdvertisesRecruiting(settings: lookingKept))

        let discoverOnLookingOff = settings(discoverable: true, looking: false, location: rivertonSelection())
        precondition(discoverOnLookingOff.isDiscoverable)
        precondition(!FanTeamDiscoveryEditorPresentation.publiclyAdvertisesRecruiting(settings: discoverOnLookingOff))
        let previewOff = FanTeamDiscoveryEditorPresentation.publicPreviewRow(
            settings: discoverOnLookingOff,
            teamId: UUID(),
            name: "IMC Team",
            sport: "Badminton",
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: "#22C25A",
            memberCount: 12
        )
        precondition(previewOff != nil)
        precondition(previewOff?.lookingForPlayers == false)

        let discoverOnLookingOn = settings(discoverable: true, looking: true, location: rivertonSelection())
        let previewOn = FanTeamDiscoveryEditorPresentation.publicPreviewRow(
            settings: discoverOnLookingOn,
            teamId: UUID(),
            name: "IMC Team",
            sport: "Badminton",
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: "#22C25A",
            memberCount: 12
        )
        precondition(previewOn?.lookingForPlayers == true)
        precondition(previewOn?.memberCount == 12)
    }

    private static func testDiscoveryEditorPrecisionAndLocationUpdates() {
        var draft = settings(discoverable: true, looking: true, precision: .specific, location: rivertonSelection())
        let beforeIdentity = FanTeamDiscoveryEditorPresentation.mapIdentity(for: draft)
        let specificPreview = FanTeamDiscoveryEditorPresentation.publicPreviewRow(
            settings: draft,
            teamId: UUID(),
            name: "IMC Team",
            sport: "Badminton",
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: nil,
            memberCount: 0
        )
        precondition(specificPreview?.precision == .specific)

        draft.precision = .generalArea
        precondition(FanTeamDiscoveryEditorPresentation.mapIdentity(for: draft) != beforeIdentity)
        let generalPreview = FanTeamDiscoveryEditorPresentation.publicPreviewRow(
            settings: draft,
            teamId: UUID(),
            name: "IMC Team",
            sport: "Badminton",
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: nil,
            memberCount: 0
        )
        precondition(generalPreview?.precision == .generalArea)
        precondition(
            !FanTeamDiscoveryEditorPresentation.publicPreviewExposesStreetLevelDetail(
                row: generalPreview!,
                street: "14641 S 800 W",
                placeName: "Riverton Courts",
                postalCode: "84065"
            )
        )
        let ownerGeneral = draft.displayLocationSummary(languageCode: "en")
        precondition(!ownerGeneral.localizedCaseInsensitiveContains("14641"))
        precondition(!ownerGeneral.localizedCaseInsensitiveContains("84065"))

        draft.precision = .specific
        let restored = FanTeamDiscoveryEditorPresentation.publicPreviewRow(
            settings: draft,
            teamId: UUID(),
            name: "IMC Team",
            sport: "Badminton",
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: nil,
            memberCount: 0
        )
        precondition(restored?.precision == .specific)
        let ownerSpecific = draft.displayLocationSummary(languageCode: "en")
        precondition(ownerSpecific.localizedCaseInsensitiveContains("14641") || ownerSpecific.localizedCaseInsensitiveContains("Riverton"))

        let moved = FanTeamLocationSelection(
            placeName: "Corner Canyon Trailhead",
            address: "123 Canyon Rd",
            city: "Draper",
            state: "Utah",
            zipCode: "84020",
            countryCode: "US",
            latitude: 40.494,
            longitude: -111.863
        )
        let identityBeforeMove = FanTeamDiscoveryEditorPresentation.mapIdentity(for: draft)
        draft.apply(selection: moved)
        precondition(FanTeamDiscoveryEditorPresentation.mapIdentity(for: draft) != identityBeforeMove)
        precondition(abs((draft.latitude ?? 0) - 40.494) < 0.0001)
        let movedPreview = FanTeamDiscoveryEditorPresentation.publicPreviewRow(
            settings: draft,
            teamId: UUID(),
            name: "IMC Team",
            sport: "Badminton",
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: nil,
            memberCount: 0
        )
        precondition(movedPreview?.city == "Draper")
    }

    private static func testDiscoveryEditorWorldwideFormatting() {
        var ottawa = FanTeamDiscoverySettings.hidden
        ottawa.isDiscoverable = true
        ottawa.apply(
            selection: FanTeamLocationSelection(
                placeName: "Lansdowne Park",
                address: "1015 Bank Street",
                city: "Ottawa",
                state: "Ontario",
                zipCode: "K1S 3W7",
                countryCode: "CA",
                latitude: 45.398,
                longitude: -75.683
            )
        )
        let specific = ottawa.displayLocationSummary(languageCode: "en")
        precondition(specific.localizedCaseInsensitiveContains("Ottawa"))
        precondition(specific.localizedCaseInsensitiveContains("Bank") || specific.localizedCaseInsensitiveContains("Lansdowne"))
        ottawa.precision = .generalArea
        let general = ottawa.displayLocationSummary(languageCode: "en")
        precondition(general.localizedCaseInsensitiveContains("Ottawa"))
        precondition(!general.localizedCaseInsensitiveContains("Bank"))
        precondition(!general.localizedCaseInsensitiveContains("K1S"))
        let preview = FanTeamDiscoveryEditorPresentation.publicPreviewRow(
            settings: ottawa,
            teamId: UUID(),
            name: "Ottawa United",
            sport: "Soccer",
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: nil,
            memberCount: 0
        )
        precondition(preview != nil)
        precondition(
            !FanTeamDiscoveryEditorPresentation.publicPreviewExposesStreetLevelDetail(
                row: preview!,
                street: "1015 Bank Street",
                placeName: "Lansdowne Park",
                postalCode: "K1S 3W7"
            )
        )
    }

    private static func testDiscoveryEditorLocalizationKeys() {
        for key in FanTeamDiscoveryEditorPresentation.localizationKeys {
            for language in L10n.supportedLanguages {
                let value = L10n.t(key, languageCode: language.code)
                precondition(value != key, "missing localization \(key) \(language.code)")
                precondition(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        let section = L10n.t("team_discovery_section_title", languageCode: "en")
        precondition(section.localizedCaseInsensitiveContains("Discovery"))
        precondition(section.localizedCaseInsensitiveContains("Location"))
        let saveValidation = L10n.t("team_discovery_location_required", languageCode: "en")
        precondition(saveValidation.localizedCaseInsensitiveContains("location"))
    }

    private static func testDiscoveryEditorPermissionsUnchanged() {
        let owner = FanTeamSummary(
            id: UUID(),
            name: "AF Hoops",
            sport: "Basketball",
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: nil,
            competitionLevel: nil,
            ownerUserId: UUID(),
            groupConversationId: UUID(),
            myRole: .owner,
            memberCount: 8,
            pendingInvitationCount: 0,
            pushNotificationsMuted: false,
            nextGameStartsAt: nil,
            nextGameTitle: nil,
            nextGameVenue: nil,
            createdAt: Date()
        )
        let member = FanTeamSummary(
            id: UUID(),
            name: "AF Hoops",
            sport: "Basketball",
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: nil,
            competitionLevel: nil,
            ownerUserId: UUID(),
            groupConversationId: UUID(),
            myRole: .member,
            memberCount: 8,
            pendingInvitationCount: 0,
            pushNotificationsMuted: false,
            nextGameStartsAt: nil,
            nextGameTitle: nil,
            nextGameVenue: nil,
            createdAt: Date()
        )
        precondition(owner.canEditIdentity)
        precondition(!member.canEditIdentity)
        var hidden = FanTeamDiscoverySettings.hidden
        hidden.lookingForPlayers = true
        precondition(!hidden.isDiscoverable)
        precondition(FanTeamDiscoveryLocationPolicy.canSave(settings: hidden))
        precondition(sampleTeam(looking: false).lookingForPlayers == false)
    }

    private static func workspaceSummary(
        id: UUID = UUID(),
        role: FanTeamMemberRole,
        accessVia: FanTeamListAccessVia = .account,
        memberCount: Int = 4
    ) -> FanTeamSummary {
        FanTeamSummary(
            id: id,
            name: "IMC Team",
            sport: "Soccer",
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: nil,
            competitionLevel: .adult_recreational,
            ownerUserId: UUID(),
            groupConversationId: UUID(),
            myRole: role,
            memberCount: memberCount,
            pendingInvitationCount: 0,
            pushNotificationsMuted: false,
            nextGameStartsAt: Date().addingTimeInterval(86_400),
            nextGameTitle: "Private next event",
            nextGameVenue: "Private field",
            createdAt: Date(),
            accessVia: accessVia
        )
    }

    private static func testWorkspaceRoutingOwnerManagerMemberGuardian() {
        let teamId = UUID()
        for role in FanTeamMemberRole.allCases {
            let mine = workspaceSummary(id: teamId, role: role, accessVia: .account)
            precondition(mine.hasTeamAccountAccess)
            precondition(
                FanTeamDiscoverWorkspaceRouting.destination(
                    teamId: teamId,
                    isAuthenticated: true,
                    myTeams: [mine]
                ) == .privateWorkspace
            )
            precondition(
                FanTeamDiscoverWorkspaceRouting.workspaceSummary(
                    teamId: teamId,
                    isAuthenticated: true,
                    myTeams: [mine]
                )?.id == teamId
            )
        }
        let guardian = workspaceSummary(id: teamId, role: .member, accessVia: .managedPlayer)
        precondition(guardian.hasTeamAccountAccess)
        precondition(guardian.accessVia == .managedPlayer)
        precondition(
            FanTeamDiscoverWorkspaceRouting.destination(
                teamId: teamId,
                isAuthenticated: true,
                myTeams: [guardian]
            ) == .privateWorkspace
        )
        precondition(
            FanTeamDiscoverWorkspaceRouting.workspaceSummary(
                teamId: teamId,
                isAuthenticated: true,
                myTeams: [guardian]
            )?.accessVia == .managedPlayer
        )
    }

    private static func testWorkspaceRoutingOutsiderAndAnonymous() {
        let teamId = UUID()
        let outsiderTeams = [workspaceSummary(id: UUID(), role: .owner)]
        precondition(
            FanTeamDiscoverWorkspaceRouting.destination(
                teamId: teamId,
                isAuthenticated: true,
                myTeams: outsiderTeams
            ) == .publicProfile
        )
        precondition(
            FanTeamDiscoverWorkspaceRouting.workspaceSummary(
                teamId: teamId,
                isAuthenticated: true,
                myTeams: outsiderTeams
            ) == nil
        )
        let owner = workspaceSummary(id: teamId, role: .owner)
        precondition(
            FanTeamDiscoverWorkspaceRouting.destination(
                teamId: teamId,
                isAuthenticated: false,
                myTeams: [owner]
            ) == .publicProfile
        )
        precondition(
            FanTeamDiscoverWorkspaceRouting.workspaceSummary(
                teamId: teamId,
                isAuthenticated: false,
                myTeams: [owner]
            ) == nil
        )
        precondition(
            FanTeamDiscoverWorkspaceRouting.destination(
                teamId: teamId,
                isAuthenticated: false,
                myTeams: []
            ) == .publicProfile
        )
    }

    private static func testDiscoverabilityDoesNotGrantWorkspace() {
        let teamId = UUID()
        let discoverable = sampleTeam(looking: true)
        precondition(discoverable.lookingForPlayers)
        precondition(discoverable.memberCount > 0)
        // Map-row discoverability / recruiting / member count never enter the router.
        precondition(
            FanTeamDiscoverWorkspaceRouting.destination(
                teamId: teamId,
                isAuthenticated: true,
                myTeams: []
            ) == .publicProfile
        )
        // A polluted Discover "My Teams" pin cache must not grant workspace.
        let pollutedCache: Set<UUID> = [teamId]
        precondition(pollutedCache.contains(teamId))
        precondition(
            FanTeamDiscoverWorkspaceRouting.destination(
                teamId: teamId,
                isAuthenticated: true,
                myTeams: []
            ) == .publicProfile
        )
    }

    private static func testPublicEventVisibilityDoesNotGrantWorkspace() {
        let teamId = UUID()
        // Router has no public-event / schedule-visibility parameter on purpose.
        let destination = FanTeamDiscoverWorkspaceRouting.destination(
            teamId: teamId,
            isAuthenticated: true,
            myTeams: []
        )
        precondition(destination == .publicProfile)
        precondition(FanTeamDiscoverWorkspaceRouting.publicProfilePrivateTabs.contains(.schedule) == false)
        precondition(FanTeamDetailTab.allCases.contains(.schedule))
    }

    private static func testPublicSummaryFieldsAreSafe() {
        let row = FanTeamDiscoveryRPCRow(
            team_id: UUID(),
            name: "IMC Team",
            sport: "Soccer",
            sport_subtype: "11v11",
            logo_url: nil,
            logo_thumbnail_url: nil,
            color_hex: "#22C25A",
            looking_for_players: true,
            member_count: 4,
            location_precision: "general_area",
            place_name: "Should be omitted for general area by RPC",
            city: "Lehi",
            region: "Utah",
            postal_code: "84043",
            country_code: "US",
            latitude: 40.39,
            longitude: -111.85
        )
        let labels = Set(Mirror(reflecting: row).children.compactMap(\.label))
        precondition(labels == FanTeamDiscoverWorkspaceRouting.publicSafeSummaryFields)
        let forbidden: Set<String> = [
            "email",
            "phone",
            "bio",
            "description",
            "owner_user_id",
            "group_conversation_id",
            "next_game_starts_at",
            "next_game_title",
            "next_game_venue",
            "my_role",
            "access_via",
            "jersey_number",
            "permissions",
            "leadership",
            "roster",
            "created_at",
            "competition_level",
        ]
        precondition(FanTeamDiscoverWorkspaceRouting.publicSafeSummaryFields.isDisjoint(with: forbidden))
        let mapRow = row.asMapRow()
        precondition(mapRow != nil)
        precondition(mapRow?.lookingForPlayers == true)
        precondition(mapRow?.memberCount == 4)
    }

    private static func testPublicProfileOmitsPrivateTabs() {
        precondition(FanTeamDiscoverWorkspaceRouting.publicProfilePrivateTabs.isEmpty)
        let privateTabs = FanTeamDetailTab.allCases
        precondition(privateTabs == [.overview, .chat, .schedule, .roster])
        let outsider = FanTeamDiscoverWorkspaceRouting.destination(
            teamId: UUID(),
            isAuthenticated: true,
            myTeams: []
        )
        precondition(outsider == .publicProfile)
        let guardian = workspaceSummary(role: .member, accessVia: .managedPlayer)
        precondition(
            FanTeamDetailTabComposition.visibleTabs(canAccessTeamChat: guardian.canAccessTeamChat)
                == FanTeamDetailTab.allCases
        )
        precondition(FanTeamDetailTabComposition.showsChatTab(for: guardian))
    }
}
#endif
