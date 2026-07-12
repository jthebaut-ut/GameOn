import Foundation
import UIKit

/// Locale used by catalog lookup, search, and offset formatting outside UI actor context.
enum FanGeoTimeZoneCatalogFormatting {
    nonisolated static let displayLocale = Locale(identifier: "en_US_POSIX")
}

/// User-selected game-time zone: device automatic or a fixed IANA identifier.
struct FanGeoTimeZonePreference: Equatable, Hashable, Codable, Identifiable, Sendable {
    nonisolated static let automaticStorageToken = "__automatic__"

    /// `__automatic__` or an IANA time-zone identifier.
    var storageValue: String

    nonisolated var id: String { storageValue }

    nonisolated static var automatic: FanGeoTimeZonePreference {
        FanGeoTimeZonePreference(storageValue: automaticStorageToken)
    }

    nonisolated static func fixed(_ ianaIdentifier: String) -> FanGeoTimeZonePreference {
        FanGeoTimeZonePreference(storageValue: ianaIdentifier)
    }

    /// Back-compat default used by previews and legacy fallbacks.
    nonisolated static var mountain: FanGeoTimeZonePreference { fixed("America/Denver") }

    nonisolated var isAutomatic: Bool { storageValue == Self.automaticStorageToken }

    /// Resolved IANA identifier for Foundation APIs (never the automatic token).
    nonisolated var identifier: String {
        if isAutomatic {
            return TimeZone.autoupdatingCurrent.identifier
        }
        return storageValue
    }

    /// Settings subtitle and legacy `rawValue` surface.
    var rawValue: String { settingsRowSubtitle }

    var settingsRowSubtitle: String {
        if isAutomatic {
            return "Automatic — \(friendlyZoneName(for: TimeZone.autoupdatingCurrent, locale: .current))"
        }
        let zone = TimeZone(identifier: storageValue) ?? TimeZone.autoupdatingCurrent
        return primaryRowTitle(for: storageValue, timeZone: zone, locale: .current)
    }

    nonisolated var abbreviation: String {
        shortAbbreviation(for: resolvedTimeZone(), at: Date())
    }

    nonisolated func resolvedTimeZone(at date: Date = Date()) -> TimeZone {
        if isAutomatic {
            return .autoupdatingCurrent
        }
        return TimeZone(identifier: storageValue) ?? .autoupdatingCurrent
    }

    nonisolated func shortAbbreviation(at date: Date = Date()) -> String {
        shortAbbreviation(for: resolvedTimeZone(at: date), at: date)
    }

    nonisolated private func shortAbbreviation(for timeZone: TimeZone, at date: Date) -> String {
        if let daylight = timeZone.localizedName(for: .daylightSaving, locale: Locale(identifier: "en_US_POSIX")),
           timeZone.isDaylightSavingTime(for: date),
           !daylight.isEmpty {
            return daylight
        }
        if let standard = timeZone.localizedName(for: .shortStandard, locale: Locale(identifier: "en_US_POSIX")),
           !standard.isEmpty {
            return standard
        }
        if let generic = timeZone.localizedName(for: .shortGeneric, locale: Locale(identifier: "en_US_POSIX")),
           !generic.isEmpty {
            return generic
        }
        return utcOffsetLabel(for: timeZone, at: date)
    }
}

typealias TimeZoneOption = FanGeoTimeZonePreference

enum FanGeoTimeZoneStore {
    nonisolated static let preferenceKey = "fangeo.selectedTimeZoneIdentifier.v2"
    nonisolated static let legacyPreferenceKey = "selectedTimeZone"
    nonisolated static let recentIdentifiersKey = "fangeo.recentTimeZoneIdentifiers.v1"
    nonisolated static let maxRecentCount = 5

    nonisolated static func load() -> FanGeoTimeZonePreference {
        if let stored = UserDefaults.standard.string(forKey: preferenceKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty,
           let preference = preference(fromStored: stored) {
            logLoaded(preference)
            return preference
        }

        if let legacy = UserDefaults.standard.string(forKey: legacyPreferenceKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !legacy.isEmpty,
           let migrated = migrateLegacyValue(legacy) {
            save(migrated)
            return migrated
        }

        let fallback = FanGeoTimeZonePreference.automatic
        TimeZoneDebug.noStoredPreferenceDefaultAutomatic()
        save(fallback)
        return fallback
    }

    nonisolated static func save(_ preference: FanGeoTimeZonePreference) {
        UserDefaults.standard.set(preference.storageValue, forKey: preferenceKey)
        TimeZoneDebug.selectedIdentifier(preference.isAutomatic ? "automatic" : preference.storageValue)
        if !preference.isAutomatic {
            recordRecentIdentifier(preference.storageValue)
        }
    }

    nonisolated static func recentIdentifiers() -> [String] {
        let raw = UserDefaults.standard.stringArray(forKey: recentIdentifiersKey) ?? []
        return raw.filter { TimeZone(identifier: $0) != nil }
    }

    nonisolated private static func preference(fromStored stored: String) -> FanGeoTimeZonePreference? {
        if stored == FanGeoTimeZonePreference.automaticStorageToken {
            return .automatic
        }
        guard TimeZone(identifier: stored) != nil else { return nil }
        return .fixed(stored)
    }

    nonisolated private static func migrateLegacyValue(_ legacy: String) -> FanGeoTimeZonePreference? {
        let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed == FanGeoTimeZonePreference.automaticStorageToken {
            return .automatic
        }

        if TimeZone(identifier: trimmed) != nil {
            TimeZoneDebug.migratedLegacyValue(from: trimmed, to: trimmed)
            return .fixed(trimmed)
        }

        let mapped: String? = switch trimmed {
        case "Mountain Time": "America/Denver"
        case "Pacific Time": "America/Los_Angeles"
        case "Central Time": "America/Chicago"
        case "Eastern Time": "America/New_York"
        case "UTC": "UTC"
        default: nil
        }

        if let mapped {
            TimeZoneDebug.migratedLegacyValue(from: trimmed, to: mapped)
            return .fixed(mapped)
        }

        return nil
    }

    nonisolated private static func recordRecentIdentifier(_ identifier: String) {
        var recent = recentIdentifiers().filter { $0 != identifier }
        recent.insert(identifier, at: 0)
        if recent.count > maxRecentCount {
            recent = Array(recent.prefix(maxRecentCount))
        }
        UserDefaults.standard.set(recent, forKey: recentIdentifiersKey)
    }

    nonisolated private static func logLoaded(_ preference: FanGeoTimeZonePreference) {
        if preference.isAutomatic {
            TimeZoneDebug.automaticZone(TimeZone.autoupdatingCurrent.identifier)
        } else {
            TimeZoneDebug.selectedIdentifier(preference.storageValue)
        }
        let zone = preference.resolvedTimeZone()
        TimeZoneDebug.displayedOffset(utcOffsetLabel(for: zone, at: Date()))
    }
}

enum FanGeoTimeZoneRegion: String, CaseIterable, Identifiable, Sendable {
    case americas
    case europe
    case africa
    case asia
    case australiaPacific
    case utc

    var id: String { rawValue }

    nonisolated var sectionTitle: String {
        switch self {
        case .americas: return "Americas"
        case .europe: return "Europe"
        case .africa: return "Africa"
        case .asia: return "Asia"
        case .australiaPacific: return "Australia & Pacific"
        case .utc: return "UTC"
        }
    }

    nonisolated static func region(for identifier: String) -> FanGeoTimeZoneRegion {
        if identifier == "UTC" || identifier.hasPrefix("Etc/") {
            return .utc
        }
        if identifier.hasPrefix("America/")
            || identifier.hasPrefix("US/")
            || identifier.hasPrefix("Canada/")
            || identifier.hasPrefix("Atlantic/") {
            return .americas
        }
        if identifier.hasPrefix("Europe/") {
            return .europe
        }
        if identifier.hasPrefix("Africa/") {
            return .africa
        }
        if identifier.hasPrefix("Asia/") || identifier.hasPrefix("Indian/") {
            return .asia
        }
        if identifier.hasPrefix("Australia/")
            || identifier.hasPrefix("Pacific/")
            || identifier.hasPrefix("Antarctica/") {
            return .australiaPacific
        }
        return .asia
    }
}

enum FanGeoTimeZoneCatalog: Sendable {
    struct Entry: Identifiable, Hashable, Sendable {
        let identifier: String

        nonisolated init(identifier: String) {
            self.identifier = identifier
        }

        nonisolated var id: String { identifier }

        nonisolated var cityTitle: String {
            primaryRowTitle(for: identifier, timeZone: TimeZone(identifier: identifier))
        }

        nonisolated var secondaryLine: String {
            let zone = TimeZone(identifier: identifier) ?? TimeZone(secondsFromGMT: 0)!
            return "\(identifier) · \(utcOffsetLabel(for: zone, at: Date()))"
        }

        nonisolated func matchesSearch(_ query: String) -> Bool {
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !needle.isEmpty else { return true }
            return FanGeoTimeZoneSearchMetadata.matchesCatalogQuery(needle, identifier: identifier)
        }
    }

    nonisolated static let allIdentifiers: [String] = {
        TimeZone.knownTimeZoneIdentifiers
            .filter { TimeZone(identifier: $0) != nil }
            .sorted { lhs, rhs in
                let left = primaryRowTitle(for: lhs, timeZone: TimeZone(identifier: lhs))
                let right = primaryRowTitle(for: rhs, timeZone: TimeZone(identifier: rhs))
                let titleOrder = left.localizedCaseInsensitiveCompare(right)
                if titleOrder != .orderedSame {
                    return titleOrder == .orderedAscending
                }
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
    }()

    nonisolated static func entries(for region: FanGeoTimeZoneRegion, matching query: String) -> [Entry] {
        allIdentifiers
            .filter { FanGeoTimeZoneRegion.region(for: $0) == region }
            .map { Entry(identifier: $0) }
            .filter { $0.matchesSearch(query) }
    }

    nonisolated static func entry(for identifier: String) -> Entry? {
        guard TimeZone(identifier: identifier) != nil else { return nil }
        return Entry(identifier: identifier)
    }

    nonisolated static func searchResults(matching query: String) -> [Entry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return allIdentifiers
            .map { Entry(identifier: $0) }
            .filter { $0.matchesSearch(trimmed) }
    }
}

nonisolated func primaryRowTitle(
    for identifier: String,
    timeZone: TimeZone?,
    locale: Locale = FanGeoTimeZoneCatalogFormatting.displayLocale
) -> String {
    let city = identifier.split(separator: "/").last.map(String.init) ?? identifier
    let cityLabel = city.replacingOccurrences(of: "_", with: " ")
    if !cityLabel.isEmpty, cityLabel != identifier {
        return cityLabel
    }
    if let timeZone,
       let localized = timeZone.localizedName(for: .standard, locale: locale),
       !localized.isEmpty {
        return localized
    }
    return identifier
}

nonisolated func friendlyZoneName(
    for timeZone: TimeZone,
    locale: Locale = FanGeoTimeZoneCatalogFormatting.displayLocale
) -> String {
    if let localized = timeZone.localizedName(for: .standard, locale: locale), !localized.isEmpty {
        return localized
    }
    return primaryRowTitle(for: timeZone.identifier, timeZone: timeZone, locale: locale)
}

nonisolated func utcOffsetLabel(for timeZone: TimeZone, at date: Date) -> String {
    let seconds = timeZone.secondsFromGMT(for: date)
    let sign = seconds >= 0 ? "+" : "-"
    let absolute = abs(seconds)
    let hours = absolute / 3600
    let minutes = (absolute % 3600) / 60
    return String(format: "UTC%@%02d:%02d", sign, hours, minutes)
}

nonisolated func friendlyTimeZoneDisplayName(
    for timeZone: TimeZone,
    at date: Date = Date(),
    locale: Locale = FanGeoTimeZoneCatalogFormatting.displayLocale
) -> String {
    if timeZone.isDaylightSavingTime(for: date),
       let daylight = timeZone.localizedName(for: .daylightSaving, locale: locale),
       !daylight.isEmpty {
        return daylight
    }
    if let standard = timeZone.localizedName(for: .standard, locale: locale), !standard.isEmpty {
        return standard
    }
    if let generic = timeZone.localizedName(for: .generic, locale: locale), !generic.isEmpty {
        return generic
    }
    return friendlyZoneName(for: timeZone, locale: locale)
}

nonisolated func timeZoneDisplayOffset(for timeZone: TimeZone, at date: Date = Date()) -> String {
    utcOffsetLabel(for: timeZone, at: date).replacingOccurrences(of: "-", with: "−")
}

struct FanGeoTimeZoneDisplayPresentation: Hashable, Sendable {
    let identifier: String
    let city: String
    let timeZoneName: String
    let countryLabel: String
    let utcOffset: String

    nonisolated static func make(
        for identifier: String,
        at date: Date = Date(),
        locale: Locale = FanGeoTimeZoneCatalogFormatting.displayLocale
    ) -> FanGeoTimeZoneDisplayPresentation {
        let zone = TimeZone(identifier: identifier) ?? TimeZone(secondsFromGMT: 0)!
        return FanGeoTimeZoneDisplayPresentation(
            identifier: identifier,
            city: primaryRowTitle(for: identifier, timeZone: zone, locale: locale),
            timeZoneName: friendlyTimeZoneDisplayName(for: zone, at: date, locale: locale),
            countryLabel: FanGeoTimeZoneSearchMetadata.primaryCountryLabel(for: identifier),
            utcOffset: timeZoneDisplayOffset(for: zone, at: date)
        )
    }
}

enum FanGeoTimeZoneSuggestedSearch {
    struct Shortcut: Identifiable, Hashable {
        let id: String
        let label: String
        let query: String
    }

    static let shortcuts: [Shortcut] = [
        Shortcut(id: "new-york", label: "New York", query: "New York"),
        Shortcut(id: "london", label: "London", query: "London"),
        Shortcut(id: "paris", label: "Paris", query: "Paris"),
        Shortcut(id: "tokyo", label: "Tokyo", query: "Tokyo"),
        Shortcut(id: "sydney", label: "Sydney", query: "Sydney")
    ]
}

enum TimeZoneDebug {
    nonisolated static func noStoredPreferenceDefaultAutomatic() {
#if DEBUG
        print("[TimeZoneDebug] noStoredPreference default=automatic")
#endif
    }

    nonisolated static func automaticZone(_ identifier: String) {
#if DEBUG
        print("[TimeZoneDebug] automaticZone=\(identifier)")
#endif
    }

    nonisolated static func selectedIdentifier(_ identifier: String) {
#if DEBUG
        print("[TimeZoneDebug] selectedIdentifier=\(identifier)")
#endif
    }

    nonisolated static func displayedOffset(_ offset: String) {
#if DEBUG
        print("[TimeZoneDebug] displayedOffset=\(offset)")
#endif
    }

    nonisolated static func migratedLegacyValue(from: String, to: String) {
#if DEBUG
        print("[TimeZoneDebug] migratedLegacyValue=\(from)->\(to)")
#endif
    }

    nonisolated static func gameDateConverted(identifier: String, offset: String, displayed: String) {
#if DEBUG
        print("[TimeZoneDebug] gameDateConverted identifier=\(identifier) offset=\(offset) displayed=\(displayed)")
#endif
    }

    nonisolated static func searchQuery(_ query: String, matchedCount: Int) {
#if DEBUG
        print("[TimeZoneDebug] searchQuery=\(query) matchedCount=\(matchedCount)")
#endif
    }

    nonisolated static func mainScreen(automaticSelected: Bool) {
#if DEBUG
        print("[TimeZoneDebug] mainScreen automaticSelected=\(automaticSelected)")
#endif
    }

    nonisolated static func recentCount(_ count: Int) {
#if DEBUG
        print("[TimeZoneDebug] recentCount=\(count)")
#endif
    }

    nonisolated static func searchOpened() {
#if DEBUG
        print("[TimeZoneDebug] searchOpened")
#endif
    }
}

final class AutomaticTimeZoneChangeObserver {
    let systemTimeZone: NSObjectProtocol
    let significantTimeChange: NSObjectProtocol

    init(systemTimeZone: NSObjectProtocol, significantTimeChange: NSObjectProtocol) {
        self.systemTimeZone = systemTimeZone
        self.significantTimeChange = significantTimeChange
    }

    deinit {
        NotificationCenter.default.removeObserver(systemTimeZone)
        NotificationCenter.default.removeObserver(significantTimeChange)
    }
}
