import Foundation

#if DEBUG
enum PickupBulkImportParserSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[PickupImportParserTest] PASS \(name)")
            } else {
                failures += 1
                print("[PickupImportParserTest] FAIL \(name)")
            }
        }

        do {
            let soccer = try PickupBulkImportParser.parseCSV(data: csvData(
                headers: newRegularHeaders,
                rows: [soccerExpectedRow]
            )).example(titled: "EXAMPLE — Saturday Soccer Pickup")
            expect(soccer.value("max_players") == "14", "new-order soccer max_players == 14")
            expect(soccer.value("min_age").isEmpty, "new-order soccer min_age blank")
            expect(soccer.value("max_age").isEmpty, "new-order soccer max_age blank")
            expect(soccer.value("participant_preference") == "everyone", "new-order soccer participant_preference == everyone")
            expect(soccer.value("is_free").caseInsensitiveCompare("TRUE") == .orderedSame, "new-order soccer is_free == true")
            expect(soccer.value("entry_fee_amount").isEmpty, "new-order soccer entry_fee blank")
            expect(soccer.value("end_time") == "2026-09-12 11:00", "new-order soccer end_time from header")
            expect(Int(soccer.value("max_players")) != nil, "new-order soccer max_players numeric")
            expect(soccer.value("min_age") != "everyone", "new-order soccer does not treat everyone as min_age")
        } catch {
            failures += 1
            print("[PickupImportParserTest] FAIL new-order soccer parse \(error)")
        }

        do {
            let baseball = try PickupBulkImportParser.parseCSV(data: csvData(
                headers: newRegularHeaders,
                rows: [baseballExpectedRow]
            )).example(titled: "EXAMPLE — Sunday Baseball Pickup")
            expect(baseball.value("max_players") == "18", "new-order baseball max_players == 18")
            expect(baseball.value("min_age") != "everyone", "new-order baseball min_age is not everyone")
            expect(Int(baseball.value("max_players")) != nil, "new-order baseball max_players numeric")
        } catch {
            failures += 1
            print("[PickupImportParserTest] FAIL new-order baseball parse \(error)")
        }

        do {
            let reordered = try PickupBulkImportParser.parseCSV(data: csvData(
                headers: reorderedRegularHeaders,
                rows: [reorderedSoccerRow]
            )).example(titled: "EXAMPLE — Saturday Soccer Pickup")
            expect(reordered.value("max_players") == "14", "reordered columns max_players == 14")
            expect(reordered.value("participant_preference") == "everyone", "reordered columns participant_preference")
            expect(reordered.value("min_age").isEmpty, "reordered columns min_age blank")
            expect(reordered.value("end_time") == "2026-09-12 11:00", "reordered columns end_time")
        } catch {
            failures += 1
            print("[PickupImportParserTest] FAIL reordered columns parse \(error)")
        }

        do {
            let oldOrder = try PickupBulkImportParser.parseCSV(data: csvData(
                headers: oldOfficialHeaders,
                rows: [oldOfficialSoccerRow]
            )).example(titled: "EXAMPLE — Saturday Soccer Pickup")
            expect(oldOrder.value("max_players") == "14", "old official header order max_players == 14")
            expect(oldOrder.value("min_age").isEmpty, "old official header order min_age blank")
            expect(oldOrder.value("participant_preference") == "everyone", "old official header order participant_preference")
            expect(oldOrder.value("end_time") == "2026-09-12 11:00", "old official header order end_time")
        } catch {
            failures += 1
            print("[PickupImportParserTest] FAIL old official header order parse \(error)")
        }

        do {
            let csvUnchanged = try PickupBulkImportParser.parseCSV(data: csvData(
                headers: oldOfficialHeaders,
                rows: [oldOfficialSoccerRow]
            )).example(titled: "EXAMPLE — Saturday Soccer Pickup")
            expect(csvUnchanged.value("title") == "EXAMPLE — Saturday Soccer Pickup", "CSV parsing unchanged title")
            expect(csvUnchanged.value("sport") == "Soccer", "CSV parsing unchanged sport")
            expect(csvUnchanged.value("players_needed") == "6", "CSV parsing unchanged players_needed")
        } catch {
            failures += 1
            print("[PickupImportParserTest] FAIL CSV unchanged parse \(error)")
        }

        do {
            let url = try PickupBulkImportParser.bundledTemplateFileURL()
            let regular = try PickupBulkImportParser.parseFile(at: url, prefersTeamWorksheet: false)
            let soccer = regular.example(titled: "EXAMPLE — Saturday Soccer Pickup")
            let baseball = regular.example(titled: "EXAMPLE — Sunday Baseball Pickup")
            expect(soccer.value("max_players") == "14", "bundled Regular soccer max_players == 14")
            expect(soccer.value("participant_preference") == "everyone", "bundled Regular soccer participant_preference")
            expect(soccer.value("min_age") != "everyone", "bundled Regular soccer min_age is not everyone")
            expect(Int(soccer.value("max_players")) != nil, "bundled Regular soccer max_players numeric")
            expect(soccer.value("is_free").caseInsensitiveCompare("TRUE") == .orderedSame, "bundled Regular soccer is_free == TRUE")
            expect(soccer.value("entry_fee_amount").isEmpty, "bundled Regular soccer entry_fee blank")
            expect(soccer.value("entry_fee_amount") != "United States", "bundled Regular soccer fee is not country string")
            expect(baseball.value("max_players") == "18", "bundled Regular baseball max_players == 18")
            expect(baseball.value("min_age") != "everyone", "bundled Regular baseball min_age is not everyone")
            expect(baseball.value("is_free").caseInsensitiveCompare("TRUE") == .orderedSame, "bundled Regular baseball is_free == TRUE")
            expect(baseball.value("entry_fee_amount").isEmpty, "bundled Regular baseball entry_fee blank")
            expect(baseball.value("entry_fee_amount") != "United States", "bundled Regular baseball fee is not country string")

            let team = try PickupBulkImportParser.parseFile(at: url, prefersTeamWorksheet: true)
            let teamSoccer = team.example(titled: "EXAMPLE — Sandy Strikers vs Riverton FC")
            expect(teamSoccer.value("opponent_name") == "Riverton FC", "bundled Team soccer opponent_name")
            expect(teamSoccer.value("max_players").isEmpty, "bundled Team soccer max_players blank")
            expect(teamSoccer.value("min_age") != "everyone", "bundled Team soccer min_age is not everyone")
            expect(teamSoccer.value("participant_preference") == "everyone", "bundled Team soccer participant_preference")
            expect(teamSoccer.value("end_time") == "2026-09-12 16:00", "bundled Team soccer end_time")
        } catch {
            failures += 1
            print("[PickupImportParserTest] FAIL bundled template parse \(error)")
        }

        if failures == 0 {
            print("[PickupImportParserTest] ALL PASSED")
        } else {
            print("[PickupImportParserTest] FAILURES=\(failures)")
            assertionFailure("PickupBulkImportParserSelfTests failed: \(failures)")
        }
    }

    private static let newRegularHeaders = [
        "title", "game_format", "game_start_at", "end_time", "address", "city", "state",
        "sport", "players_needed", "max_players", "description", "skill_level",
        "play_environment", "participant_preference", "min_age", "max_age", "is_free",
        "entry_fee_amount", "country", "competition_level"
    ]

    private static let oldOfficialHeaders = [
        "title", "game_format", "sport", "description", "skill_level", "game_start_at",
        "address", "city", "state", "country", "players_needed", "play_environment",
        "participant_preference", "min_age", "max_age", "is_free", "entry_fee_amount",
        "max_players", "end_time"
    ]

    private static let reorderedRegularHeaders = [
        "max_players", "min_age", "participant_preference", "end_time", "title",
        "game_format", "sport", "description", "skill_level", "game_start_at",
        "address", "city", "state", "country", "players_needed", "play_environment",
        "max_age", "is_free", "entry_fee_amount"
    ]

    private static let soccerExpectedRow = [
        "EXAMPLE — Saturday Soccer Pickup", "pickup", "2026-09-12 09:00", "2026-09-12 11:00",
        "123 Main St", "Lehi", "UT", "Soccer", "6", "14",
        "Friendly weekend pickup game.", "casual", "outdoor", "everyone", "", "", "TRUE",
        "", "United States", "adult_recreational"
    ]

    private static let baseballExpectedRow = [
        "EXAMPLE — Sunday Baseball Pickup", "pickup", "2026-09-13 10:00", "2026-09-13 12:00",
        "500 Ballpark Dr", "Sandy", "UT", "Baseball", "5", "18",
        "Casual baseball pickup.", "beginner_friendly", "outdoor", "everyone", "", "", "TRUE",
        "", "United States", "adult_recreational"
    ]

    private static let reorderedSoccerRow = [
        "14", "", "everyone", "2026-09-12 11:00", "EXAMPLE — Saturday Soccer Pickup",
        "pickup", "Soccer", "Friendly weekend pickup game.", "casual", "2026-09-12 09:00",
        "123 Main St", "Lehi", "UT", "United States", "6", "outdoor",
        "", "TRUE", ""
    ]

    private static let oldOfficialSoccerRow = [
        "EXAMPLE — Saturday Soccer Pickup", "pickup", "Soccer", "Friendly weekend pickup game.",
        "casual", "2026-09-12 09:00", "123 Main St", "Lehi", "UT", "United States",
        "6", "outdoor", "everyone", "", "", "TRUE", "", "14", "2026-09-12 11:00"
    ]

    private static func csvData(headers: [String], rows: [[String]]) -> Data {
        func escape(_ value: String) -> String {
            if value.contains(",") || value.contains("\"") || value.contains("\n") {
                return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
            }
            return value
        }
        let lines = ([headers] + rows).map { $0.map(escape).joined(separator: ",") }
        return Data(lines.joined(separator: "\n").utf8)
    }
}

private extension Array where Element == PickupBulkImportRawRow {
    func example(titled title: String) -> PickupBulkImportRawRow {
        first { $0.value("title") == title }
            ?? PickupBulkImportRawRow(rowNumber: -1, values: [:], sourceHeaders: [])
    }
}
#endif
