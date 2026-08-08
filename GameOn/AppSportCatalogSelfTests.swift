import Foundation

#if DEBUG
/// DEBUG-only guards against duplicate sport IDs / display names in form / Open To pickers.
nonisolated enum AppSportCatalogSelfTests {
    static func runAll() {
        assertUniqueFormPickerSports(AppSportCatalog.formPickerSportsOrdered)
        assertUniqueGroupedSelectionTokens(AppSportCatalog.SportCatalog.groupedSelectionTokensOrdered)
        assertNoDuplicateGroupedCategoryRows()
        // Same token list Open To uses (`FanOpenToCatalog.pickupSportTokens`);
        // assert via the nonisolated catalog source to avoid MainActor hops.
        FanOpenToCatalogSelfTests.assertUniqueOpenToSports(AppSportCatalog.formPickerSportsOrdered)
    }

    static func assertUniqueFormPickerSports(_ tokens: [String]) {
        assertUniqueSportTokens(tokens, context: "AppSportCatalog.formPickerSportsOrdered")
        let hockeyCount = tokens.filter {
            AppSportCatalog.catalogEnglishLabel(forSportToken: $0)
                .caseInsensitiveCompare("Hockey") == .orderedSame
        }.count
        assert(hockeyCount == 1, "Expected exactly one Hockey in form picker, found \(hockeyCount)")
    }

    static func assertUniqueGroupedSelectionTokens(_ tokens: [String]) {
        assertUniqueSportTokens(tokens, context: "SportCatalog.groupedSelectionTokensOrdered")
    }

    static func assertNoDuplicateGroupedCategoryRows() {
        var seenSelections = Set<String>()
        var seenLabels = Set<String>()
        for category in AppSportCatalog.SportCatalog.groupedCategories {
            for row in category.rows {
                let selectionKey = row.selection.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let labelKey = row.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                assert(
                    seenSelections.insert(selectionKey).inserted,
                    "Duplicate grouped catalog selection '\(row.selection)' in category \(category.id)"
                )
                assert(
                    seenLabels.insert(labelKey).inserted,
                    "Duplicate grouped catalog label '\(row.label)' in category \(category.id)"
                )
            }
        }
    }

    static func assertUniqueSportTokens(_ tokens: [String], context: String) {
        var seenIDs = Set<String>()
        var seenNames = Set<String>()
        for token in tokens {
            let idKey = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            assert(!idKey.isEmpty, "\(context): empty sport token")
            assert(seenIDs.insert(idKey).inserted, "\(context): duplicate sport ID '\(token)'")

            let nameKey = AppSportCatalog.catalogEnglishLabel(forSportToken: token)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            assert(!nameKey.isEmpty, "\(context): empty display name for '\(token)'")
            assert(
                seenNames.insert(nameKey).inserted,
                "\(context): duplicate sport display name '\(nameKey)' (token '\(token)')"
            )
        }
    }
}

/// Called before Open To sport tiles are built so duplicates fail fast in DEBUG.
nonisolated enum FanOpenToCatalogSelfTests {
    static func assertUniqueOpenToSports(_ tokens: [String]) {
        AppSportCatalogSelfTests.assertUniqueSportTokens(tokens, context: "FanOpenToCatalog.pickupSportTokens")
        let hockeyCount = tokens.filter {
            AppSportCatalog.catalogEnglishLabel(forSportToken: $0)
                .caseInsensitiveCompare("Hockey") == .orderedSame
        }.count
        assert(hockeyCount == 1, "Expected exactly one Hockey in Open To picker, found \(hockeyCount)")
    }
}
#endif
