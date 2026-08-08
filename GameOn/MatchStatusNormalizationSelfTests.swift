import Foundation

#if DEBUG
/// Baseball / MLB status normalization coverage for ``MatchStatus.normalized``.
enum MatchStatusNormalizationSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[MatchStatusNormTest] PASS \(name)")
            } else {
                failures += 1
                print("[MatchStatusNormTest] FAIL \(name)")
            }
        }

        let liveCases = [
            "Top 1",
            "Top 7",
            "Bot 5",
            "Bottom 9",
            "Bottom of the 5th",
            "Mid 8",
            "Middle 6",
            "Inning 4",
            "4th Inning",
            "Extra Innings",
            "Extra Inning",
            "In Progress",
            "END 5",
            "End of the 7th",
            "IN1",
            "IN9",
            "IN10",
            "in9",
            " IN9 "
        ]
        for raw in liveCases {
            expect(MatchStatus.normalized(from: raw) == .live, "LIVE ← \(raw)")
        }

        let finalCases = [
            "Final",
            "Final/10",
            "Final - 10 Innings",
            "Completed",
            "FT",
            "END"
        ]
        for raw in finalCases {
            expect(MatchStatus.normalized(from: raw) == .fullTime, "FT ← \(raw)")
        }

        let scheduledCases = [
            "Scheduled",
            "NS",
            "Pre-Game",
            "Pregame",
            "Postponed",
            "Delayed",
            "Cancelled",
            "Canceled",
            "Not Started",
            "Warmup",
            "top of the morning",
            "desktop end",
            "IN"
        ]
        for raw in scheduledCases {
            expect(MatchStatus.normalized(from: raw) == .scheduled, "SCHEDULED ← \(raw)")
        }

        // Final/finished precedence over inning-like trailing text.
        expect(MatchStatus.normalized(from: "Final/Extra Innings") == .fullTime, "FT precedence Final/Extra Innings")
        expect(MatchStatus.normalized(from: "Final - 10 Innings") == .fullTime, "FT precedence Final - 10 Innings")
        expect(MatchStatus.normalized(from: "FINAL") == .fullTime, "FINAL before compact IN#")
        expect(MatchStatus.normalized(from: "FINAL/10") == .fullTime, "FINAL/10 before compact IN#")

        // Stale DB SCHEDULED + progress hint upgrade (client defensive path).
        expect(
            MatchStatus.normalized(from: "SCHEDULED", progressHint: "Bot 5") == .live,
            "progressHint upgrades SCHEDULED + Bot 5"
        )
        expect(
            MatchStatus.normalized(from: "SCHEDULED", progressHint: "IN9") == .live,
            "progressHint upgrades SCHEDULED + IN9"
        )
        expect(
            MatchStatus.normalized(from: "SCHEDULED", progressHint: "Final") == .fullTime,
            "progressHint upgrades SCHEDULED + Final"
        )
        expect(
            MatchStatus.normalized(from: "FT", progressHint: "Bot 5") == .fullTime,
            "explicit FT not overridden by progressHint"
        )
        expect(
            MatchStatus.normalized(from: "FT", progressHint: "IN9") == .fullTime,
            "explicit FT not overridden by IN9 progressHint"
        )
        expect(
            MatchStatus.normalized(from: "POSTPONED", progressHint: "Bot 5") == .scheduled,
            "postponed not overridden by progressHint"
        )
        expect(
            MatchStatus.normalized(from: "POSTPONED", progressHint: "IN9") == .scheduled,
            "postponed not overridden by IN9 progressHint"
        )
        expect(
            MatchStatus.normalized(from: "DELAYED", progressHint: "Top 3") == .scheduled,
            "delayed not overridden by progressHint"
        )
        expect(
            MatchStatus.normalized(from: "CANCELLED", progressHint: "IN9") == .scheduled,
            "cancelled not overridden by IN9 progressHint"
        )
        expect(
            MatchStatus.normalized(from: "Not Started", progressHint: "IN9") == .scheduled,
            "not started not overridden by IN9 progressHint"
        )

        expect(
            MatchStatus.looksLikeBaseballInningProgress("Bottom of the 5th"),
            "looksLikeBaseballInningProgress Bottom of the 5th"
        )
        expect(
            MatchStatus.looksLikeBaseballInningProgress("IN9"),
            "looksLikeBaseballInningProgress IN9"
        )
        expect(
            MatchStatus.looksLikeBaseballInningProgress("IN99"),
            "looksLikeBaseballInningProgress IN99"
        )
        expect(
            !MatchStatus.looksLikeBaseballInningProgress("top of the morning"),
            "looksLikeBaseballInningProgress rejects top of the morning"
        )
        expect(
            !MatchStatus.looksLikeBaseballInningProgress("IN"),
            "looksLikeBaseballInningProgress rejects IN"
        )
        expect(
            !MatchStatus.looksLikeBaseballInningProgress("INNING"),
            "looksLikeBaseballInningProgress rejects INNING"
        )
        expect(
            !MatchStatus.looksLikeBaseballInningProgress("IN PROGRESS"),
            "looksLikeBaseballInningProgress rejects IN PROGRESS"
        )
        expect(
            !MatchStatus.looksLikeBaseballInningProgress("FOOIN9"),
            "looksLikeBaseballInningProgress rejects FOOIN9"
        )
        expect(
            !MatchStatus.looksLikeBaseballInningProgress("IN9BAR"),
            "looksLikeBaseballInningProgress rejects IN9BAR"
        )
        expect(
            !MatchStatus.looksLikeBaseballInningProgress("IN999"),
            "looksLikeBaseballInningProgress rejects IN999"
        )
        // Generic live path (not compact IN#) still recognizes IN PROGRESS.
        expect(MatchStatus.normalized(from: "IN PROGRESS") == .live, "LIVE ← IN PROGRESS (generic)")

        if failures == 0 {
            print("[MatchStatusNormTest] ALL PASSED")
        } else {
            print("[MatchStatusNormTest] FAILURES=\(failures)")
        }
    }
}
#endif
