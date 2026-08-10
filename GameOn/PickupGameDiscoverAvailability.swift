import CoreLocation
import Foundation

// MARK: - Date normalization (single source of truth)

/// Canonical Discover rule:
/// A pickup game belongs to the **local calendar day** on which `game_start_at`
/// occurs in the intended **display timezone**.
///
/// Discover’s date-picker grid uses `Calendar.current` / the device local zone, so
/// Discover map + orange dots must bucket with that same zone — never UTC midnights
/// and never a hard-coded Mountain Time zone.
enum PickupGameDateNormalizer {
    /// Calendar configured for Discover day identity (start-of-day, same-day checks).
    static func displayCalendar(timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    /// Start of the local calendar day containing `date` in `timeZone`.
    static func startOfDay(for date: Date, timeZone: TimeZone) -> Date {
        displayCalendar(timeZone: timeZone).startOfDay(for: date)
    }

    /// Inclusive local-day start and exclusive next-day start for SQL / range queries.
    static func dayBounds(
        containing date: Date,
        timeZone: TimeZone
    ) -> (start: Date, endExclusive: Date)? {
        let cal = displayCalendar(timeZone: timeZone)
        let start = cal.startOfDay(for: date)
        guard let endExclusive = cal.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (start, endExclusive)
    }

    static func isSameDay(_ a: Date, _ b: Date, timeZone: TimeZone) -> Bool {
        displayCalendar(timeZone: timeZone).isDate(a, inSameDayAs: b)
    }

    static func ymdString(for date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = displayCalendar(timeZone: timeZone)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Parse a Supabase timestamptz and return its Discover local day (start-of-day), if valid.
    static func normalizedLocalDay(
        fromStartRaw raw: String,
        timeZone: TimeZone,
        parse: (String) -> Date? = PickupGameModels.parseSupabaseTimestamptz
    ) -> (decodedStart: Date, localDay: Date)? {
        guard let decoded = parse(raw) else { return nil }
        return (decoded, startOfDay(for: decoded, timeZone: timeZone))
    }
}

// MARK: - Discover context + candidate

/// Geographic / filter context shared by Discover map pins and calendar orange dots.
struct PickupGameAvailabilityContext: Equatable {
    /// Intended Discover display timezone (device local for the date-picker grid).
    var timeZone: TimeZone
    var now: Date
    /// `"All"` disables sport filtering.
    var selectedSport: String
    var mapBounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)?
    /// When true, a missing bounds or out-of-AABB coordinate excludes the game.
    var requireMapBounds: Bool
    /// When true (pins / calendar dots), rows without a plottable coordinate are excluded.
    /// Day-scoped map loads keep `false` so the in-memory day list can still hold rows.
    var requireValidCoordinates: Bool
    /// Guest Discover floor (start-of-day); games before this day are excluded when set.
    var guestRecentFloor: Date?
    /// When true (authenticated Discover), private rows (`is_visible=false`) that RLS already
    /// returned for the viewer remain eligible. Guests must keep this false.
    var allowAuthorizedPrivateGames: Bool = false

    static func == (lhs: PickupGameAvailabilityContext, rhs: PickupGameAvailabilityContext) -> Bool {
        lhs.timeZone.identifier == rhs.timeZone.identifier
            && lhs.now == rhs.now
            && lhs.selectedSport == rhs.selectedSport
            && lhs.requireMapBounds == rhs.requireMapBounds
            && lhs.requireValidCoordinates == rhs.requireValidCoordinates
            && lhs.guestRecentFloor == rhs.guestRecentFloor
            && lhs.allowAuthorizedPrivateGames == rhs.allowAuthorizedPrivateGames
            && lhs.mapBounds?.minLat == rhs.mapBounds?.minLat
            && lhs.mapBounds?.maxLat == rhs.mapBounds?.maxLat
            && lhs.mapBounds?.minLon == rhs.mapBounds?.minLon
            && lhs.mapBounds?.maxLon == rhs.mapBounds?.maxLon
    }
}

/// Lightweight row shape so map (`PickupGameRow`) and calendar (`PickupGameCalendarRow`) share one evaluator.
struct PickupGameAvailabilityCandidate: Equatable {
    var id: UUID?
    var sport: String
    var gameStartAtRaw: String
    var removeAfterAtRaw: String?
    var status: String
    var isVisible: Bool
    var latitude: Double?
    var longitude: Double?

    init(
        id: UUID? = nil,
        sport: String,
        gameStartAtRaw: String,
        removeAfterAtRaw: String? = nil,
        status: String,
        isVisible: Bool,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.id = id
        self.sport = sport
        self.gameStartAtRaw = gameStartAtRaw
        self.removeAfterAtRaw = removeAfterAtRaw
        self.status = status
        self.isVisible = isVisible
        self.latitude = latitude
        self.longitude = longitude
    }
}

extension PickupGameAvailabilityCandidate {
    init(row: PickupGameRow) {
        self.init(
            id: row.id,
            sport: row.sport,
            gameStartAtRaw: row.game_start_at,
            removeAfterAtRaw: row.remove_after_at,
            status: row.status,
            isVisible: row.is_visible,
            latitude: row.latitude,
            longitude: row.longitude
        )
    }
}

enum PickupGameDiscoverExclusionReason: String, Equatable {
    case invalidStart
    case inactiveStatus
    case notVisible
    case removeAfterPast
    case sportMismatch
    case missingCoordinates
    case outsideMapBounds
    case missingMapBounds
    case beforeGuestFloor
}

struct PickupGameAvailabilityEvaluation: Equatable {
    var discoverEligible: Bool
    var decodedStart: Date?
    var normalizedLocalDay: Date?
    var exclusionReason: PickupGameDiscoverExclusionReason?
}

// MARK: - Resolver

/// One definition of “discoverable pickup under the current Discover context.”
///
/// Orange calendar dots and Discover map pin eligibility must both call this rather
/// than reinterpreting status / geo / day independently.
enum PickupGameAvailabilityResolver {
    static func evaluate(
        _ candidate: PickupGameAvailabilityCandidate,
        context: PickupGameAvailabilityContext,
        parse: (String) -> Date? = PickupGameModels.parseSupabaseTimestamptz
    ) -> PickupGameAvailabilityEvaluation {
        guard let decodedStart = parse(candidate.gameStartAtRaw) else {
            return PickupGameAvailabilityEvaluation(
                discoverEligible: false,
                decodedStart: nil,
                normalizedLocalDay: nil,
                exclusionReason: .invalidStart
            )
        }
        let localDay = PickupGameDateNormalizer.startOfDay(for: decodedStart, timeZone: context.timeZone)

        if let floor = context.guestRecentFloor, localDay < floor {
            return PickupGameAvailabilityEvaluation(
                discoverEligible: false,
                decodedStart: decodedStart,
                normalizedLocalDay: localDay,
                exclusionReason: .beforeGuestFloor
            )
        }

        if candidate.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "active" {
            return PickupGameAvailabilityEvaluation(
                discoverEligible: false,
                decodedStart: decodedStart,
                normalizedLocalDay: localDay,
                exclusionReason: .inactiveStatus
            )
        }

        if !candidate.isVisible, !context.allowAuthorizedPrivateGames {
            return PickupGameAvailabilityEvaluation(
                discoverEligible: false,
                decodedStart: decodedStart,
                normalizedLocalDay: localDay,
                exclusionReason: .notVisible
            )
        }

        if let remRaw = candidate.removeAfterAtRaw,
           let rem = parse(remRaw),
           rem <= context.now {
            return PickupGameAvailabilityEvaluation(
                discoverEligible: false,
                decodedStart: decodedStart,
                normalizedLocalDay: localDay,
                exclusionReason: .removeAfterPast
            )
        }

        let sport = context.selectedSport.trimmingCharacters(in: .whitespacesAndNewlines)
        if sport != "All", candidate.sport != sport {
            return PickupGameAvailabilityEvaluation(
                discoverEligible: false,
                decodedStart: decodedStart,
                normalizedLocalDay: localDay,
                exclusionReason: .sportMismatch
            )
        }

        if context.requireValidCoordinates || context.requireMapBounds {
            guard let lat = candidate.latitude, let lon = candidate.longitude,
                  CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lon)) else {
                return PickupGameAvailabilityEvaluation(
                    discoverEligible: false,
                    decodedStart: decodedStart,
                    normalizedLocalDay: localDay,
                    exclusionReason: .missingCoordinates
                )
            }

            if context.requireMapBounds {
                guard let bounds = context.mapBounds else {
                    return PickupGameAvailabilityEvaluation(
                        discoverEligible: false,
                        decodedStart: decodedStart,
                        normalizedLocalDay: localDay,
                        exclusionReason: .missingMapBounds
                    )
                }
                guard lat >= bounds.minLat, lat <= bounds.maxLat,
                      lon >= bounds.minLon, lon <= bounds.maxLon else {
                    return PickupGameAvailabilityEvaluation(
                        discoverEligible: false,
                        decodedStart: decodedStart,
                        normalizedLocalDay: localDay,
                        exclusionReason: .outsideMapBounds
                    )
                }
            }
        }

        return PickupGameAvailabilityEvaluation(
            discoverEligible: true,
            decodedStart: decodedStart,
            normalizedLocalDay: localDay,
            exclusionReason: nil
        )
    }

    /// Distinct start-of-day dates with at least one discover-eligible pickup in `context`.
    static func availableNormalizedDays(
        from candidates: [PickupGameAvailabilityCandidate],
        context: PickupGameAvailabilityContext,
        parse: (String) -> Date? = PickupGameModels.parseSupabaseTimestamptz
    ) -> Set<Date> {
        var days = Set<Date>()
        days.reserveCapacity(min(candidates.count, 64))
        for candidate in candidates {
            let evaluation = evaluate(candidate, context: context, parse: parse)
            if evaluation.discoverEligible, let day = evaluation.normalizedLocalDay {
                days.insert(day)
            }
        }
        return days
    }

    /// Whether a coordinate falls inside an axis-aligned Discover map viewport.
    static func isCoordinate(
        _ lat: Double,
        _ lon: Double,
        inside bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)
    ) -> Bool {
        lat >= bounds.minLat && lat <= bounds.maxLat
            && lon >= bounds.minLon && lon <= bounds.maxLon
    }
}

// MARK: - Immutable month-dot request context

/// Axis-aligned Discover map viewport captured for a month-dot request (Sendable / Equatable).
struct PickupGameMapBounds: Equatable, Hashable, Sendable {
    var minLat: Double
    var maxLat: Double
    var minLon: Double
    var maxLon: Double

    init(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        self.minLat = minLat
        self.maxLat = maxLat
        self.minLon = minLon
        self.maxLon = maxLon
    }

    init(_ tuple: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)) {
        self.init(minLat: tuple.minLat, maxLat: tuple.maxLat, minLon: tuple.minLon, maxLon: tuple.maxLon)
    }

    var asTuple: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        (minLat, maxLat, minLon, maxLon)
    }

    /// Same formatting as Discover calendar-dot cache buckets.
    var bucketString: String {
        [
            FanGeoFixedFloatFormat.d3(minLat),
            FanGeoFixedFloatFormat.d3(maxLat),
            FanGeoFixedFloatFormat.d3(minLon),
            FanGeoFixedFloatFormat.d3(maxLon)
        ].joined(separator: "|")
    }

    func contains(latitude: Double, longitude: Double) -> Bool {
        PickupGameAvailabilityResolver.isCoordinate(latitude, longitude, inside: asTuple)
    }
}

/// One immutable availability context for a Discover pickup month-dot load.
/// Cache key identity and the async month query must both use this snapshot —
/// never re-read live map bounds / sport mid-flight.
struct PickupGameMonthAvailabilityRequestContext: Equatable, Sendable {
    let requestID: UUID
    let monthStart: Date
    let dateMin: Date
    let dateMax: Date
    let sport: String
    let timeZoneIdentifier: String
    /// Captured viewport; `nil` means bounds were unavailable at capture time.
    let mapBounds: PickupGameMapBounds?
    /// Geographic cache identity (`mapBounds.bucketString` or `"nb"`).
    let boundsBucket: String
    let guestRecentFloor: Date?
    let capturedAt: Date

    var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? .autoupdatingCurrent
    }

    var hasMapBounds: Bool { mapBounds != nil }

    var cacheKey: String {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"
        return "p:b:\(boundsBucket)|m:\(fmt.string(from: monthStart))|r:\(fmt.string(from: dateMin))...\(fmt.string(from: dateMax))|s:\(sport)"
    }

    /// Eligibility context built solely from this snapshot (no live MapViewModel reads).
    func availabilityContext(now: Date = Date()) -> PickupGameAvailabilityContext {
        PickupGameAvailabilityContext(
            timeZone: timeZone,
            now: now,
            selectedSport: sport,
            mapBounds: mapBounds?.asTuple,
            requireMapBounds: true,
            requireValidCoordinates: true,
            guestRecentFloor: guestRecentFloor,
            // Guest requests capture a guestRecentFloor; authenticated requests do not.
            allowAuthorizedPrivateGames: guestRecentFloor == nil
        )
    }

    static func boundsBucket(for bounds: PickupGameMapBounds?) -> String {
        bounds?.bucketString ?? "nb"
    }
}

/// Outcome of a month-scoped pickup calendar-dot fetch.
enum PickupGameMonthDotFetchOutcome: Equatable, Sendable {
    /// Authoritative month result for the captured viewport (may be empty).
    case success(dates: Set<Date>, rawRowCount: Int, eligibleRowCount: Int)
    /// Bounds were unavailable — must NOT be cached as an empty authoritative month.
    case skippedNoBounds
}

// MARK: - Month availability merge (selected day ≠ month dots)

/// Pure merge rules so Discover orange dots stay a **month** set.
///
/// Selected-day map rows (`pickupGamesForDiscoverMap`) are **never** month authority.
/// They must not seed, replace, or complete the published availability set.
enum PickupGameMonthAvailabilityMerge {
    /// What to show synchronously while a month fetch runs / cache is consulted.
    ///
    /// - Non-empty authoritative month cache → show it (union prior published window).
    /// - Empty or missing cache → keep prior published only; never invent selected-day-only dots.
    static func presentationSeed(
        published: Set<Date>,
        authoritativeCached: Set<Date>?
    ) -> Set<Date> {
        if let authoritativeCached, !authoritativeCached.isEmpty {
            return authoritativeCached.union(published)
        }
        return published
    }

    /// Synchronous publish seed (legacy name). Selected-day evidence is ignored by design.
    static func seedPublished(
        published: Set<Date>,
        cached: Set<Date>?,
        selectedDayEvidence: Set<Date>
    ) -> Set<Date> {
        _ = selectedDayEvidence
        return presentationSeed(published: published, authoritativeCached: cached)
    }

    /// Authoritative month fetch result only (selected-day evidence is not merged into truth).
    static func mergeAuthoritative(
        fetchedMonth: Set<Date>,
        selectedDayEvidence: Set<Date>
    ) -> Set<Date> {
        _ = selectedDayEvidence
        return fetchedMonth
    }

    /// After a failed month fetch: keep prior month dots only.
    static func mergeAfterFetchFailure(
        previousPublished: Set<Date>,
        selectedDayEvidence: Set<Date>
    ) -> Set<Date> {
        _ = selectedDayEvidence
        return previousPublished
    }

    /// Successful authoritative empty month.
    static func resolveSuccessfulEmptyMonthFetch() -> Set<Date> {
        []
    }

    /// Month query returned empty while selected-day viewport pins exist for the month —
    /// treat as inconsistent / non-authoritative (do not cache empty).
    static func isInconsistentEmptyMonthFetch(
        fetchedMonth: Set<Date>,
        selectedDayEvidenceInMonth: Set<Date>
    ) -> Bool {
        fetchedMonth.isEmpty && !selectedDayEvidenceInMonth.isEmpty
    }

    /// When fetch returns empty without authority (legacy helper).
    static func resolveEmptyAuthoritativeFetch(
        previousPublished: Set<Date>,
        selectedDayEvidence: Set<Date>
    ) -> Set<Date> {
        _ = selectedDayEvidence
        return previousPublished
    }

    /// Bounds-unavailable / skipped: keep prior month dots.
    static func resolveSkippedNoBounds(
        previousPublished: Set<Date>
    ) -> Set<Date> {
        previousPublished
    }

    /// Empty month cache is never "complete" when selected-day evidence exists in-window.
    static func selectedDayEvidenceImpliesIncompleteCache(
        selectedDayEvidence: Set<Date>,
        cached: Set<Date>?
    ) -> Bool {
        guard let cached else {
            return !selectedDayEvidence.isEmpty
        }
        if cached.isEmpty {
            return !selectedDayEvidence.isEmpty
        }
        return !selectedDayEvidence.isSubset(of: cached)
    }

    /// Selecting another day in the same month/viewport/sport must not change month dots.
    static func monthDotsStableAcrossSelectionChange(
        dotsBefore: Set<Date>,
        dotsAfter: Set<Date>
    ) -> Bool {
        dotsBefore == dotsAfter
    }

    /// Cache key and query must use the same bounds identity.
    static func cacheKeyMatchesQueryBounds(
        cacheKeyBoundsBucket: String,
        queryBoundsBucket: String
    ) -> Bool {
        cacheKeyBoundsBucket == queryBoundsBucket
    }

    /// Canonicalize to `Calendar.current` start-of-day so Set membership matches ``EventCalendarView``.
    static func canonicalizeForCalendarGrid(_ dates: Set<Date>, calendar: Calendar = .current) -> Set<Date> {
        Set(dates.map { calendar.startOfDay(for: $0) })
    }

    /// Same-day membership (avoids exact-instant mismatch between normalizer and grid cells).
    static func gridDay(
        _ day: Date,
        isCoveredBy availability: Set<Date>,
        calendar: Calendar = .current
    ) -> Bool {
        let sod = calendar.startOfDay(for: day)
        if availability.contains(sod) { return true }
        return availability.contains { calendar.isDate($0, inSameDayAs: sod) }
    }
}

#if DEBUG
enum PickupGameAvailabilityDebugLog {
    static func logComparison(
        games: [(candidate: PickupGameAvailabilityCandidate, evaluation: PickupGameAvailabilityEvaluation)],
        discoverAvailableDates: Set<Date>,
        calendarAvailableDates: Set<Date>,
        timeZone: TimeZone
    ) {
        print("===== PICKUP DATE AVAILABILITY =====")
        print("displayTimeZone=\(timeZone.identifier)")
        for item in games.prefix(40) {
            let c = item.candidate
            let e = item.evaluation
            let dayLabel = e.normalizedLocalDay.map {
                PickupGameDateNormalizer.ymdString(for: $0, timeZone: timeZone)
            } ?? "nil"
            let decoded = e.decodedStart.map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
            print(
                "gameId=\(c.id?.uuidString ?? "nil") rawStartTime=\(c.gameStartAtRaw) decodedStartTime=\(decoded) displayTimeZone=\(timeZone.identifier) normalizedLocalDay=\(dayLabel) lat=\(c.latitude.map(String.init(describing:)) ?? "nil") lon=\(c.longitude.map(String.init(describing:)) ?? "nil") sport=\(c.sport) status=\(c.status) discoverEligible=\(e.discoverEligible) calendarEligible=\(e.discoverEligible) exclusionReason=\(e.exclusionReason?.rawValue ?? "none")"
            )
        }
        let discover = discoverAvailableDates.sorted().map {
            PickupGameDateNormalizer.ymdString(for: $0, timeZone: timeZone)
        }
        let calendar = calendarAvailableDates.sorted().map {
            PickupGameDateNormalizer.ymdString(for: $0, timeZone: timeZone)
        }
        print("discoverAvailableDates=[\(discover.joined(separator: ","))]")
        print("calendarAvailableDates=[\(calendar.joined(separator: ","))]")
        print("setsEqual=\(discoverAvailableDates == calendarAvailableDates)")
        print("===== END PICKUP DATE AVAILABILITY =====")
    }
}
#endif
