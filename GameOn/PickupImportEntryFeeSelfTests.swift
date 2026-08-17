import Foundation

#if DEBUG
enum PickupImportEntryFeeSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[PickupImportEntryFeeTest] PASS \(name)")
            } else {
                failures += 1
                print("[PickupImportEntryFeeTest] FAIL \(name)")
            }
        }

        do {
            let soccer = try bundledExample(titled: "EXAMPLE — Saturday Soccer Pickup")
            let parsed = PickupImportEntryFeeParsing.parse(
                raw: soccer.value("entry_fee_amount"),
                isFree: true
            )
            expect(soccer.value("entry_fee_amount").isEmpty, "1 FREE XLSX blank fee raw empty")
            expect(parsed.amount == nil, "1 FREE XLSX blank fee amount nil")
            expect(parsed.errors.isEmpty, "1 FREE XLSX blank fee valid")
            expect(
                !parsed.errors.contains(PickupImportEntryFeeParsing.invalidNumberMessage),
                "1 FREE XLSX blank fee no numeric error"
            )
        } catch {
            failures += 1
            print("[PickupImportEntryFeeTest] FAIL 1 FREE XLSX blank fee \(error)")
        }

        do {
            let soccer = try PickupBulkImportParser.parseCSV(data: csvFreeBlankFee)
                .first { $0.value("title") == "EXAMPLE — Saturday Soccer Pickup" }
                ?? PickupBulkImportRawRow(rowNumber: -1, values: [:], sourceHeaders: [])
            let parsed = PickupImportEntryFeeParsing.parse(
                raw: soccer.value("entry_fee_amount"),
                isFree: true
            )
            expect(soccer.value("entry_fee_amount").isEmpty, "2 FREE CSV blank fee raw empty")
            expect(parsed.errors.isEmpty, "2 FREE CSV blank fee remains valid")
            expect(parsed.amount == nil, "2 FREE CSV blank fee amount nil")
        } catch {
            failures += 1
            print("[PickupImportEntryFeeTest] FAIL 2 FREE CSV blank fee \(error)")
        }

        let whitespace = PickupImportEntryFeeParsing.parse(raw: " \t\n ", isFree: true)
        expect(whitespace.amount == nil, "3 FREE whitespace-only fee amount nil")
        expect(whitespace.errors.isEmpty, "3 FREE whitespace-only fee valid")
        expect(
            !whitespace.errors.contains(PickupImportEntryFeeParsing.invalidNumberMessage),
            "3 FREE whitespace-only fee no numeric error"
        )

        let paidValid = PickupImportEntryFeeParsing.parse(raw: "12.50", isFree: false)
        expect(paidValid.errors.isEmpty, "4 PAID numeric fee valid")
        expect(paidValid.amount == 12.50, "4 PAID numeric fee value preserved")

        let paidInvalid = PickupImportEntryFeeParsing.parse(raw: "not-a-number", isFree: false)
        expect(
            paidInvalid.errors.contains(PickupImportEntryFeeParsing.invalidNumberMessage),
            "5 PAID invalid text fee keeps numeric error"
        )
        expect(paidInvalid.amount == nil, "5 PAID invalid text fee amount nil")

        let paidBlank = PickupImportEntryFeeParsing.parse(raw: "", isFree: false)
        expect(
            paidBlank.errors.contains(PickupImportEntryFeeParsing.requiredWhenPaidMessage),
            "6 PAID blank fee keeps required-when-paid error"
        )
        expect(
            !paidBlank.errors.contains(PickupImportEntryFeeParsing.invalidNumberMessage),
            "6 PAID blank fee is not a numeric-format error"
        )
        expect(paidBlank.amount == nil, "6 PAID blank fee amount nil")

        do {
            let soccer = try bundledExample(titled: "EXAMPLE — Saturday Soccer Pickup")
            let baseball = try bundledExample(titled: "EXAMPLE — Sunday Baseball Pickup")
            let soccerFee = PickupImportEntryFeeParsing.parse(
                raw: soccer.value("entry_fee_amount"),
                isFree: true
            )
            let baseballFee = PickupImportEntryFeeParsing.parse(
                raw: baseball.value("entry_fee_amount"),
                isFree: true
            )
            expect(soccerFee.errors.isEmpty, "7 bundled soccer fee has no errors")
            expect(baseballFee.errors.isEmpty, "7 bundled baseball fee has no errors")
            expect(soccer.value("max_players") == "14", "7 bundled soccer max_players == 14")
            expect(baseball.value("max_players") == "18", "7 bundled baseball max_players == 18")
            expect(
                soccer.value("participant_preference") == "everyone",
                "7 bundled soccer Everyone Welcome token"
            )
            expect(
                baseball.value("participant_preference") == "everyone",
                "7 bundled baseball Everyone Welcome token"
            )
            expect(
                soccer.value("is_free").caseInsensitiveCompare("TRUE") == .orderedSame,
                "7 bundled soccer is_free Free"
            )
            expect(
                baseball.value("is_free").caseInsensitiveCompare("TRUE") == .orderedSame,
                "7 bundled baseball is_free Free"
            )
            expect(soccer.value("entry_fee_amount").isEmpty, "7 bundled soccer fee still blank")
            expect(baseball.value("entry_fee_amount").isEmpty, "7 bundled baseball fee still blank")
        } catch {
            failures += 1
            print("[PickupImportEntryFeeTest] FAIL 7 bundled template \(error)")
        }

        if failures == 0 {
            print("[PickupImportEntryFeeTest] ALL PASSED")
        } else {
            print("[PickupImportEntryFeeTest] FAILURES=\(failures)")
            assertionFailure("PickupImportEntryFeeSelfTests failed: \(failures)")
        }
    }

    private static func bundledExample(titled title: String) throws -> PickupBulkImportRawRow {
        let url = try PickupBulkImportParser.bundledTemplateFileURL()
        let rows = try PickupBulkImportParser.parseFile(at: url, prefersTeamWorksheet: false)
        return rows.first { $0.value("title") == title }
            ?? PickupBulkImportRawRow(rowNumber: -1, values: [:], sourceHeaders: [])
    }

    private static let csvFreeBlankFee: Data = {
        let headers = [
            "title", "game_format", "game_start_at", "end_time", "address", "city", "state",
            "sport", "players_needed", "max_players", "description", "skill_level",
            "play_environment", "participant_preference", "min_age", "max_age", "is_free",
            "entry_fee_amount", "country", "competition_level"
        ]
        let row = [
            "EXAMPLE — Saturday Soccer Pickup", "pickup", "2026-09-12 09:00", "2026-09-12 11:00",
            "123 Main St", "Lehi", "UT", "Soccer", "6", "14",
            "Friendly weekend pickup game.", "casual", "outdoor", "everyone", "", "", "TRUE",
            "", "United States", "adult_recreational"
        ]
        func escape(_ value: String) -> String {
            if value.contains(",") || value.contains("\"") || value.contains("\n") {
                return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
            }
            return value
        }
        let lines = ([headers] + [row]).map { $0.map(escape).joined(separator: ",") }
        return Data(lines.joined(separator: "\n").utf8)
    }()
}
#endif
