import Foundation

enum FanTeamLocationSelfTests {
    static func runAll() {
        var failures: [String] = []
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[FanTeamLocationTest] PASS \(name)")
            } else {
                failures.append(name)
                print("[FanTeamLocationTest] FAIL \(name)")
            }
        }

        // Dedupe preference: provider > geo+address > address/name
        let providerKey = FanTeamLocationPresentation.identityKey(
            providerPlaceId: "ABC",
            latitude: 40.5,
            longitude: -111.8,
            address: "1 Main",
            city: "Lehi",
            state: "UT",
            placeName: "Park"
        )
        expect(providerKey == "provider:abc", "provider identity preferred")

        let geoKey = FanTeamLocationPresentation.identityKey(
            providerPlaceId: nil,
            latitude: 40.123456,
            longitude: -111.987654,
            address: "123 River Rd",
            city: "Lehi",
            state: "UT",
            placeName: "Riverside"
        )
        expect(geoKey?.hasPrefix("geoaddr:") == true, "geoaddr identity when lat/lon present")

        let samePlaceRounded = FanTeamLocationPresentation.identityKey(
            providerPlaceId: nil,
            latitude: 40.123459,
            longitude: -111.987651,
            address: "123 River Rd",
            city: "Lehi",
            state: "UT",
            placeName: "Riverside"
        )
        expect(geoKey == samePlaceRounded, "lat/lon rounded to 5 decimals for dedupe")

        // Split hides saved duplicates from recent
        let teamId = UUID()
        let riversideKey = FanTeamLocationPresentation.identityKey(
            providerPlaceId: nil,
            latitude: 40.1,
            longitude: -111.8,
            address: "123 River Rd",
            city: "Lehi",
            state: "UT",
            placeName: "Riverside Park"
        ) ?? "geo:40.10000,-111.80000"
        let saved = FanTeamLocation.stub(
            teamId: teamId,
            nickname: "Home Field",
            placeName: "Riverside Park",
            address: "123 River Rd",
            city: "Lehi",
            state: "UT",
            postalCode: "84043",
            countryCode: "US",
            latitude: 40.1,
            longitude: -111.8,
            identityKey: riversideKey,
            isSaved: true,
            isDefault: true,
            usageCount: 3,
            lastUsedAt: Date()
        )
        let recentDup = FanTeamLocation.stub(
            teamId: teamId,
            placeName: "Riverside Park",
            address: "123 River Rd",
            city: "Lehi",
            state: "UT",
            postalCode: "84043",
            countryCode: "US",
            latitude: 40.1,
            longitude: -111.8,
            identityKey: riversideKey,
            isSaved: false,
            usageCount: 3,
            lastUsedAt: Date()
        )
        let recentOther = FanTeamLocation.stub(
            teamId: teamId,
            placeName: "Smith Park",
            address: "600 W 800 N",
            city: "Orem",
            state: "UT",
            countryCode: "US",
            latitude: 40.3,
            longitude: -111.7,
            identityKey: "geo:40.30000,-111.70000",
            isSaved: false,
            usageCount: 1,
            lastUsedAt: Date().addingTimeInterval(-86_400)
        )
        let split = FanTeamLocationPresentation.split(locations: [recentDup, recentOther, saved])
        expect(split.saved.count == 1 && split.saved.first?.isDefault == true, "default saved pinned")
        expect(split.recent.count == 1 && split.recent.first?.placeName == "Smith Park", "saved identity excluded from recent")

        let matchingSelection = FanTeamLocationSelection(
            placeName: "Riverside Park",
            address: "123 River Rd",
            city: "Lehi",
            state: "UT",
            zipCode: "84043",
            countryCode: "US",
            latitude: 40.1,
            longitude: -111.8
        )
        expect(
            FanTeamLocationPresentation.isSelectionAlreadySaved(matchingSelection, amongSaved: split.saved),
            "matching identity skips duplicate save prompt"
        )
        expect(
            FanTeamLocationPresentation.isSelectionAlreadySaved(
                FanTeamLocationSelection(
                    address: "1 Other St",
                    city: "Lehi",
                    state: "UT",
                    zipCode: "84043",
                    countryCode: "US",
                    latitude: 40.2,
                    longitude: -111.9
                ),
                amongSaved: split.saved
            ) == false,
            "different place is not treated as already saved"
        )

        let a11y = FanTeamLocationPresentation.accessibilityLabel(location: saved, languageCode: "en")
        expect(a11y.localizedCaseInsensitiveContains("Home Field"), "a11y includes nickname")
        expect(a11y.localizedCaseInsensitiveContains("Default"), "a11y includes default")

        let selection = saved.selection
        expect(selection?.hasValidCoordinate == true, "selection has coordinates")
        expect(selection?.persistableAddress == "123 River Rd", "selection persists street address")
        expect(selection?.countryCode == "US", "selection preserves ISO country")
        expect(selection?.zipCode == "84043", "selection preserves postal")

        let times = FanTeamLocationPresentation.recentUsageCaption(
            lastUsedAt: Date(),
            usageCount: 3,
            languageCode: "en"
        )
        expect(times.contains("3"), "usage count caption")

        runInternationalAddressTests(expect: expect)
        runMapItemAdapterTests(expect: expect)
        runLegacyDecodeTests(expect: expect)

        if failures.isEmpty {
            print("[FanTeamLocationTest] ALL PASSED")
        } else {
            print("[FanTeamLocationTest] FAILURES=\(failures)")
            assertionFailure("FanTeamLocationSelfTests failed: \(failures)")
        }
    }

    private static func runInternationalAddressTests(expect: (Bool, String) -> Void) {
        // UNITED STATES — Lehi, Utah
        let us = FanTeamLocationSelection(
            address: "123 River Rd",
            city: "Lehi",
            state: "UT",
            zipCode: "84043",
            countryCode: "US",
            latitude: 40.39,
            longitude: -111.85
        )
        expect(us.displayAddressLine.localizedCaseInsensitiveContains("Lehi"), "US display includes city")
        expect(us.displayAddressLine.localizedCaseInsensitiveContains("84043"), "US display includes ZIP")
        expect(us.countryCode == "US", "US country code normalized")

        // CANADA — Montreal alphanumeric postal
        let ca = FanTeamLocationSelection(
            placeName: "Olympic Stadium",
            address: "4545 Pierre-de Coubertin Ave",
            city: "Montreal",
            state: "QC",
            zipCode: "H1V 3N7",
            countryCode: "CA",
            latitude: 45.56,
            longitude: -73.55
        )
        expect(ca.zipCode.contains("H1V"), "CA alphanumeric postal accepted")
        expect(FanTeamLocationPresentation.manualEntryValidationError(
            placeName: ca.placeName ?? "",
            address: ca.address,
            city: ca.city,
            countryCode: ca.countryCode,
            languageCode: "en"
        ) == nil, "CA validation accepts region + postal without US ZIP regex")

        // UNITED KINGDOM — no US state requirement
        let uk = FanTeamLocationSelection(
            placeName: "Old Trafford",
            address: "Sir Matt Busby Way",
            city: "Manchester",
            state: "",
            zipCode: "M16 0RA",
            countryCode: "GB",
            latitude: 53.46,
            longitude: -2.29
        )
        expect(uk.displayAddressLine.localizedCaseInsensitiveContains("Manchester"), "UK display includes city")
        expect(uk.displayAddressLine.localizedCaseInsensitiveContains("M16"), "UK postal accepted")
        expect(
            uk.displayAddressLine.localizedCaseInsensitiveContains("United Kingdom")
                || uk.displayAddressLine.contains("GB"),
            "UK display includes country context"
        )
        expect(FanTeamLocationPresentation.manualEntryValidationError(
            placeName: uk.placeName ?? "",
            address: uk.address,
            city: uk.city,
            countryCode: uk.countryCode,
            languageCode: "en"
        ) == nil, "UK validation does not require state")

        // FRANCE — accented text + postal
        let fr = FanTeamLocationSelection(
            address: "Champ de Mars",
            city: "Paris",
            state: "",
            zipCode: "75007",
            countryCode: "FR",
            latitude: 48.86,
            longitude: 2.29
        )
        expect(fr.city == "Paris", "FR city preserved")
        expect(fr.zipCode == "75007", "FR postal accepted")

        // GERMANY — diacritics
        let de = FanTeamLocationSelection(
            placeName: "Allianz Arena",
            address: "Werner-Heisenberg-Allee 25",
            city: "München",
            state: "Bayern",
            zipCode: "80939",
            countryCode: "DE",
            latitude: 48.22,
            longitude: 11.62
        )
        expect(de.city.contains("ü") || de.city == "München", "DE accented city supported")

        // BRAZIL — São Paulo
        let br = FanTeamLocationSelection(
            address: "Av. Paulista 1578",
            city: "São Paulo",
            state: "SP",
            zipCode: "01310-200",
            countryCode: "BR",
            latitude: -23.56,
            longitude: -46.65
        )
        expect(br.city.contains("ã") || br.city == "São Paulo", "BR accented city supported")
        expect(br.zipCode.contains("-"), "BR postal with hyphen supported")

        // AUSTRALIA — Sydney NSW
        let au = FanTeamLocationSelection(
            address: "1 Stadium Dr",
            city: "Sydney",
            state: "NSW",
            zipCode: "2000",
            countryCode: "AU",
            latitude: -33.89,
            longitude: 151.22
        )
        expect(au.state == "NSW", "AU region/state supported")

        // JAPAN — Tokyo
        let jp = FanTeamLocationSelection(
            placeName: "Tokyo Dome",
            address: "1-3-61 Koraku",
            city: "Bunkyo City",
            state: "Tokyo",
            zipCode: "112-0004",
            countryCode: "JP",
            latitude: 35.71,
            longitude: 139.75
        )
        expect(jp.countryCode == "JP", "JP country preserved")
        expect(jp.displayAddressLine.localizedCaseInsensitiveContains("Japan")
            || jp.displayAddressLine.contains("JP")
            || jp.displayAddressLine.localizedCaseInsensitiveContains("Tokyo"),
            "JP display retains international context")

        // Country required for manual entry
        expect(
            FanTeamLocationPresentation.manualEntryValidationError(
                placeName: "Park",
                address: "1 Main",
                city: "Lehi",
                countryCode: "",
                languageCode: "en"
            ) != nil,
            "manual entry requires country"
        )

        // Country change clears only US default UT region (existing policy)
        var region = "UT"
        BusinessLocationCountryPolicy.clearDefaultRegionIfNeeded(&region, whenCountryChangesTo: "GB")
        expect(region.isEmpty, "leaving US clears default UT region only")
        region = "Quebec"
        BusinessLocationCountryPolicy.clearDefaultRegionIfNeeded(&region, whenCountryChangesTo: "FR")
        expect(region == "Quebec", "country change does not erase unrelated regions")

        // Round-trip saved → selection keeps country + postal
        let savedIntl = FanTeamLocation.stub(
            placeName: "Old Trafford",
            address: "Sir Matt Busby Way",
            city: "Manchester",
            state: nil,
            postalCode: "M16 0RA",
            countryCode: "GB",
            latitude: 53.46,
            longitude: -2.29,
            isSaved: true
        )
        expect(savedIntl.selection?.countryCode == "GB", "saved location selection keeps country")
        expect(savedIntl.selection?.zipCode == "M16 0RA", "saved location selection keeps postal")
    }

    private static func runLegacyDecodeTests(expect: (Bool, String) -> Void) {
        let legacyJSON = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "team_id": "22222222-2222-2222-2222-222222222222",
          "nickname": null,
          "place_name": "Legacy Park",
          "address": "1 Main St",
          "city": "Lehi",
          "state": "UT",
          "latitude": 40.1,
          "longitude": -111.8,
          "provider_place_id": null,
          "identity_key": "geo:40.10000,-111.80000",
          "is_saved": true,
          "is_default": false,
          "usage_count": 1,
          "last_used_at": null,
          "created_by": null,
          "created_at": "2026-01-01T00:00:00Z",
          "updated_at": "2026-01-01T00:00:00Z"
        }
        """
        do {
            let row = try JSONDecoder().decode(FanTeamLocation.self, from: Data(legacyJSON.utf8))
            expect(row.countryCode == nil, "legacy decode without country_code")
            expect(row.postalCode == nil, "legacy decode without postal_code")
            expect(row.selection?.countryCode.isEmpty == true, "legacy selection country empty not invented")
            expect(row.city == "Lehi", "legacy US city still decodes")
        } catch {
            expect(false, "legacy decode without country_code throws \(error)")
        }

        let withCountryJSON = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "team_id": "22222222-2222-2222-2222-222222222222",
          "nickname": null,
          "place_name": "Parc Olympique",
          "address": "4545 Pierre-de Coubertin",
          "city": "Montréal",
          "state": "QC",
          "postal_code": "H1V 3N7",
          "country_code": "ca",
          "latitude": 45.56,
          "longitude": -73.55,
          "provider_place_id": null,
          "identity_key": "geo:45.56000,-73.55000",
          "is_saved": true,
          "is_default": false,
          "usage_count": 1,
          "last_used_at": null,
          "created_by": null,
          "created_at": "2026-01-01T00:00:00Z",
          "updated_at": "2026-01-01T00:00:00Z"
        }
        """
        do {
            let row = try JSONDecoder().decode(FanTeamLocation.self, from: Data(withCountryJSON.utf8))
            expect(row.countryCode == "CA", "country_code normalized to ISO alpha-2")
            expect(row.postalCode == "H1V 3N7", "postal_code decoded")
            expect(row.city == "Montréal", "accented city decoded")
        } catch {
            expect(false, "country postal decode throws \(error)")
        }
    }

    private static func runMapItemAdapterTests(expect: (Bool, String) -> Void) {
        let full = FanTeamMapItemLocationAdapter.parseAddressComponents(
            placeName: "Riverside Park",
            shortAddress: "123 River Rd",
            fullAddressSingleLine: "123 River Rd, Lehi, UT 84043",
            fullAddressMultiline: "123 River Rd\nLehi, UT 84043",
            cityName: "Lehi",
            cityWithContext: "Lehi, UT",
            countryCode: "US"
        )
        expect(full.placeName == "Riverside Park", "adapter keeps business name")
        expect(full.address == "123 River Rd", "adapter street from multiline")
        expect(full.city == "Lehi", "adapter city")
        expect(full.state == "UT", "adapter state from cityWithContext")
        expect(full.zipCode == "84043", "adapter zip from city line")
        expect(full.countryCode == "US", "adapter country from MapKit region")
        let composed = FanTeamMapItemLocationAdapter.composedAddressLine(fields: full)
        expect(composed.localizedCaseInsensitiveContains("Lehi"), "adapter composed includes city")
        expect(composed.localizedCaseInsensitiveContains("123 River Rd"), "adapter composed includes street")
        expect(
            composed.localizedCaseInsensitiveContains("United States") || composed.contains("US"),
            "adapter composed includes country when known"
        )

        let noName = FanTeamMapItemLocationAdapter.parseAddressComponents(
            placeName: nil,
            shortAddress: "5032 North Shady Bend Lane",
            fullAddressSingleLine: "5032 North Shady Bend Lane, Draper, UT 84020",
            fullAddressMultiline: nil,
            cityName: "Draper",
            cityWithContext: "Draper, UT",
            countryCode: "US"
        )
        expect(noName.placeName == nil, "adapter placeName nil when absent")
        expect(noName.address == "5032 North Shady Bend Lane", "adapter street from shortAddress")
        expect(noName.city == "Draper" && noName.state == "UT", "adapter city/state without business name")
        expect(noName.zipCode == "84020", "adapter zip from single-line full address")

        let missingCity = FanTeamMapItemLocationAdapter.parseAddressComponents(
            placeName: "Trailhead",
            shortAddress: "1 Canyon Rd",
            fullAddressSingleLine: "1 Canyon Rd",
            fullAddressMultiline: "1 Canyon Rd",
            cityName: nil,
            cityWithContext: nil
        )
        expect(missingCity.city.isEmpty, "adapter missing city stays empty")
        expect(missingCity.state.isEmpty, "adapter missing state stays empty")
        expect(missingCity.countryCode.isEmpty, "adapter missing country stays empty")
        expect(missingCity.address == "1 Canyon Rd", "adapter street preserved without city")
        expect(missingCity.placeName == "Trailhead", "adapter placeName preserved without city")

        let missingState = FanTeamMapItemLocationAdapter.parseAddressComponents(
            placeName: "Civic Center",
            shortAddress: "100 Main",
            fullAddressSingleLine: "100 Main, Springfield",
            fullAddressMultiline: "100 Main\nSpringfield",
            cityName: "Springfield",
            cityWithContext: "Springfield"
        )
        expect(missingState.city == "Springfield", "adapter city without state")
        expect(missingState.state.isEmpty, "adapter missing state stays empty not invented")
        expect(missingState.address == "100 Main", "adapter street without state")

        let nameIsStreet = FanTeamMapItemLocationAdapter.parseAddressComponents(
            placeName: "100 Main",
            shortAddress: "100 Main",
            fullAddressSingleLine: "100 Main, Lehi, UT 84043",
            fullAddressMultiline: "100 Main\nLehi, UT 84043",
            cityName: "Lehi",
            cityWithContext: "Lehi, UT",
            countryCode: "US"
        )
        expect(nameIsStreet.placeName == nil, "adapter drops placeName when it equals street")

        // Provider identity mapping (no network).
        expect(
            FanTeamLocationPresentation.identityKey(
                providerPlaceId: "ICBB5FD7684CE949",
                latitude: 40.5,
                longitude: -111.8,
                address: "1 Main",
                city: "Lehi",
                state: "UT",
                placeName: nil
            ) == "provider:icbb5fd7684ce949",
            "adapter provider id identity preserved"
        )
    }
}
