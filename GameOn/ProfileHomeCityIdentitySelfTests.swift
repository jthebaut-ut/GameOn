import Foundation

#if DEBUG
/// Deterministic hometown display-format regression tests (no XCTest target).
/// Emits only `[ProfileHomeCityIdentityTest]`.
enum ProfileHomeCityIdentitySelfTests {
    static func runAll() {
        var failures = 0

        func expect(_ actual: String?, _ expected: String?, _ label: String) {
            let a = actual ?? "nil"
            let e = expected ?? "nil"
            if a != e {
                failures += 1
                print("[ProfileHomeCityIdentityTest] FAIL \(label) actual=\(a) expected=\(e)")
            } else {
                print("[ProfileHomeCityIdentityTest] PASS \(label)")
            }
        }

        // A. Lehi / English (ISO country)
        expect(
            ProfileHomeCityIdentity.displayLine(
                city: "Lehi", region: "Utah", country: "US", languageCode: "en"
            ),
            "Lehi, Utah, United States",
            "lehi_en_iso"
        )

        // A2. Lehi / English (legacy English country name)
        expect(
            ProfileHomeCityIdentity.displayLine(
                city: "Lehi", region: "Utah", country: "United States", languageCode: "en"
            ),
            "Lehi, Utah, United States",
            "lehi_en_legacy_country"
        )

        // A3. Lehi / English (abbreviated region, missing country — safe UT inference)
        expect(
            ProfileHomeCityIdentity.displayLine(
                city: "Lehi", region: "UT", country: "", languageCode: "en"
            ),
            "Lehi, Utah, United States",
            "lehi_en_ut_infer"
        )

        // B. Lehi / French
        expect(
            ProfileHomeCityIdentity.displayLine(
                city: "Lehi", region: "Utah", country: "US", languageCode: "fr"
            ),
            "Lehi, Utah, États-Unis",
            "lehi_fr"
        )

        // C / D. Paris
        expect(
            ProfileHomeCityIdentity.displayLine(
                city: "Paris", region: "", country: "FR", languageCode: "fr"
            ),
            "Paris, France",
            "paris_fr"
        )
        expect(
            ProfileHomeCityIdentity.displayLine(
                city: "Paris", region: "", country: "FR", languageCode: "en"
            ),
            "Paris, France",
            "paris_en"
        )

        // E. Madrid / French
        expect(
            ProfileHomeCityIdentity.displayLine(
                city: "Madrid", region: "", country: "ES", languageCode: "fr"
            ),
            "Madrid, Espagne",
            "madrid_fr"
        )

        // F / G. Montréal
        expect(
            ProfileHomeCityIdentity.displayLine(
                city: "Montréal", region: "QC", country: "CA", languageCode: "en"
            ),
            "Montréal, Quebec, Canada",
            "montreal_en"
        )
        expect(
            ProfileHomeCityIdentity.displayLine(
                city: "Montréal", region: "Quebec", country: "CA", languageCode: "fr"
            ),
            "Montréal, Québec, Canada",
            "montreal_fr"
        )

        // H. Empty hometown
        expect(
            ProfileHomeCityIdentity.displayLine(
                city: "", region: "UT", country: "US", languageCode: "en"
            ),
            nil,
            "empty_city"
        )
        expect(
            ProfileHomeCityIdentity.displayLine(
                city: nil, region: nil, country: nil, languageCode: "en"
            ),
            nil,
            "nil_hometown"
        )

        // Ambiguous CA alone must not invent United States
        expect(
            ProfileHomeCityIdentity.displayLine(
                city: "Vancouver", region: "CA", country: "", languageCode: "en"
            ),
            "Vancouver, CA",
            "ambiguous_ca_no_us_infer"
        )

        if failures == 0 {
            print("[ProfileHomeCityIdentityTest] ALL_PASSED")
        } else {
            print("[ProfileHomeCityIdentityTest] FAILURES=\(failures)")
        }
    }
}
#endif
