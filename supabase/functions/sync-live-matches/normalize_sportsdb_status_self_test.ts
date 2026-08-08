/**
 * Standalone self-test for baseball inning progress mapping.
 * Mirrors `isBaseballInningProgressStatus` + `normalizeSportsDBStatus` rules in index.ts.
 * Run: `deno run --allow-none normalize_sportsdb_status_self_test.ts`
 */

type MatchStatus = "LIVE" | "HT" | "FT" | "SCHEDULED"

function isBaseballInningProgressStatus(compact: string): boolean {
  const s = String(compact ?? "").replace(/\s+/g, " ").trim().toUpperCase()
  if (!s) return false
  // TheSportsDB compact inning codes: IN1…IN99 (e.g. production strStatus=IN9).
  if (/^IN[0-9]{1,2}$/.test(s)) return true
  if (/\bEXTRA\s+INNINGS?\b/.test(s)) return true
  if (/\bINNING\s+\d{1,2}\b/.test(s)) return true
  if (/\b\d{1,2}(?:ST|ND|RD|TH)?\s+INNING\b/.test(s)) return true
  if (
    /\b(?:TOP|BOT|BOTTOM|MID|MIDDLE)\s+(?:OF\s+(?:THE\s+)?)?\d{1,2}(?:ST|ND|RD|TH)?\b/
      .test(s)
  ) {
    return true
  }
  if (/\bEND\s+(?:OF\s+(?:THE\s+)?)?\d{1,2}(?:ST|ND|RD|TH)?\b/.test(s)) {
    return true
  }
  return false
}

function normalizeSportsDBStatus(raw: unknown): MatchStatus {
  const status = String(raw ?? "").trim().toUpperCase()
  const compact = status.replace(/[_-]+/g, " ").replace(/\s+/g, " ").trim()
  if (compact.includes("HALF") || compact === "HT") return "HT"
  if (
    status === "FT" ||
    status === "AET" ||
    status === "AP" ||
    status === "AW" ||
    compact === "END" ||
    compact.includes("FT") ||
    compact.includes("FINAL") ||
    compact.includes("FINISHED") ||
    compact.includes("COMPLETED") ||
    compact.includes("COMPLETE") ||
    compact.includes("ENDED") ||
    compact.includes("FULL TIME") ||
    compact.includes("AFTER FULL TIME") ||
    compact.includes("AFTER EXTRA TIME") ||
    compact.includes("AFTER PENALTIES") ||
    compact.includes("AFTER PEN") ||
    compact.includes("PENALTIES FINISHED")
  ) return "FT"

  if (
    compact === "NS" ||
    compact.includes("NOT STARTED") ||
    compact.includes("PRE GAME") ||
    compact.includes("PREGAME") ||
    compact.includes("WARMUP") ||
    compact.includes("SCHED") ||
    compact.includes("POSTPON") ||
    compact.includes("DELAY") ||
    compact.includes("CANCEL")
  ) {
    return "SCHEDULED"
  }

  if (isBaseballInningProgressStatus(compact)) return "LIVE"

  if (["1H", "2H", "ET", "BT", "P", "OT", "Q1", "Q2", "Q3", "Q4", "LIVE"].includes(status)) return "LIVE"
  if (
    compact.includes("LIVE") ||
    compact.includes("INPLAY") ||
    compact.includes("IN PROGRESS") ||
    compact.includes("IN PLAY") ||
    compact.includes("PLAYING") ||
    compact.includes("ACTIVE") ||
    compact.includes("STARTED") ||
    compact.includes("EXTRA INNING") ||
    compact.includes("'") ||
    compact.includes("Q") ||
    compact.includes("PERIOD") ||
    compact.includes("INNING")
  ) {
    return "LIVE"
  }
  return "SCHEDULED"
}

let failures = 0
function expect(condition: boolean, name: string) {
  if (condition) {
    console.log(`PASS ${name}`)
  } else {
    failures += 1
    console.log(`FAIL ${name}`)
  }
}

const liveCases = [
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
  "In Progress",
  "END 5",
  "IN1",
  "IN9",
  "IN10",
  "in9",
  " IN9 ",
]
for (const raw of liveCases) {
  expect(normalizeSportsDBStatus(raw) === "LIVE", `LIVE ← ${raw}`)
}

for (const raw of ["Final", "Final/10", "Final - 10 Innings", "Completed", "END"]) {
  expect(normalizeSportsDBStatus(raw) === "FT", `FT ← ${raw}`)
}

for (const raw of [
  "Scheduled",
  "NS",
  "Pre-Game",
  "Postponed",
  "Delayed",
  "Cancelled",
  "Not Started",
  "top of the morning",
  "desktop end",
  "IN",
]) {
  expect(normalizeSportsDBStatus(raw) === "SCHEDULED", `SCHEDULED ← ${raw}`)
}

// Compact IN# helper must not false-positive on bare/partial tokens.
expect(!isBaseballInningProgressStatus("IN"), "helper rejects IN")
expect(!isBaseballInningProgressStatus("INNING"), "helper rejects INNING")
expect(!isBaseballInningProgressStatus("FOOIN9"), "helper rejects FOOIN9")
expect(!isBaseballInningProgressStatus("IN9BAR"), "helper rejects IN9BAR")
expect(!isBaseballInningProgressStatus("IN999"), "helper rejects IN999")
expect(isBaseballInningProgressStatus("IN9"), "helper accepts IN9")
expect(isBaseballInningProgressStatus("IN99"), "helper accepts IN99")

// IN PROGRESS stays LIVE via generic live-token path (not compact IN#).
expect(normalizeSportsDBStatus("IN PROGRESS") === "LIVE", "LIVE ← IN PROGRESS (generic)")
expect(!isBaseballInningProgressStatus("IN PROGRESS"), "helper rejects IN PROGRESS")

expect(normalizeSportsDBStatus("Final/Extra Innings") === "FT", "FT precedence Final/Extra Innings")
expect(normalizeSportsDBStatus("Not Started") === "SCHEDULED", "NOT STARTED before STARTED")
expect(normalizeSportsDBStatus("POSTPONED") === "SCHEDULED", "POSTPONED before IN#")
expect(normalizeSportsDBStatus("DELAYED") === "SCHEDULED", "DELAYED before IN#")
expect(normalizeSportsDBStatus("FINAL") === "FT", "FINAL before IN#")
expect(normalizeSportsDBStatus("FINAL/10") === "FT", "FINAL/10 before IN#")

if (failures === 0) {
  console.log("ALL PASSED")
} else {
  console.log(`FAILURES=${failures}`)
  Deno.exit(1)
}
