import Foundation
import os

/// Calendar bucket for Inbox date-section headers. Precomputed outside card bodies.
enum FanGeoInboxDateGroupKind: Equatable, Hashable, Sendable {
    case today
    case yesterday
    case daysAgo(Int)
    case calendarDay(Date)
    case older

    var stableId: String {
        switch self {
        case .today: return "today"
        case .yesterday: return "yesterday"
        case .daysAgo(let days): return "daysAgo-\(days)"
        case .calendarDay(let day):
            return "day-\(Int(day.timeIntervalSince1970))"
        case .older: return "older"
        }
    }
}

struct FanGeoInboxListEntry: Identifiable, Equatable {
    var item: FanGeoActionItem
    var timestampLabel: String

    var id: String { item.id }
}

struct FanGeoInboxDateGroup: Identifiable, Equatable {
    var kind: FanGeoInboxDateGroupKind
    var title: String
    var entries: [FanGeoInboxListEntry]

    var id: String { kind.stableId }
}

/// Cheap Inbox grouping + card timestamps. Cached formatters; no per-row `DateFormatter` alloc.
enum FanGeoInboxDateGrouping {
    static func groups(
        items: [FanGeoActionItem],
        languageCode: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [FanGeoInboxDateGroup] {
        var orderedKinds: [FanGeoInboxDateGroupKind] = []
        var entriesByKind: [FanGeoInboxDateGroupKind: [FanGeoInboxListEntry]] = [:]
        orderedKinds.reserveCapacity(8)

        for item in items {
            let kind = groupKind(for: item, now: now, calendar: calendar)
            let timestampLabel = cardTimestampLabel(
                for: item,
                languageCode: languageCode,
                now: now,
                calendar: calendar
            )
            let entry = FanGeoInboxListEntry(item: item, timestampLabel: timestampLabel)
            if entriesByKind[kind] == nil {
                orderedKinds.append(kind)
            }
            var bucket = entriesByKind[kind] ?? []
            bucket.append(entry)
            entriesByKind[kind] = bucket
        }

        return orderedKinds.compactMap { kind in
            guard let entries = entriesByKind[kind], !entries.isEmpty else { return nil }
            return FanGeoInboxDateGroup(
                kind: kind,
                title: title(for: kind, languageCode: languageCode, calendar: calendar),
                entries: entries
            )
        }
    }

    static func groupKind(
        for item: FanGeoActionItem,
        now: Date,
        calendar: Calendar
    ) -> FanGeoInboxDateGroupKind {
        guard let date = authoritativeTimestamp(for: item) else { return .older }
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }

        let startNow = calendar.startOfDay(for: now)
        let startDate = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: startDate, to: startNow).day ?? 0
        if days >= 2, days <= 6 {
            return .daysAgo(days)
        }
        if days > 6 {
            return .calendarDay(startDate)
        }
        if days < 0 {
            return .calendarDay(startDate)
        }
        return .older
    }

    static func title(
        for kind: FanGeoInboxDateGroupKind,
        languageCode: String,
        calendar: Calendar
    ) -> String {
        let locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        switch kind {
        case .today:
            return L10n.t("action_center_inbox_group_today", languageCode: languageCode)
        case .yesterday:
            return L10n.t("action_center_inbox_group_yesterday", languageCode: languageCode)
        case .daysAgo(let days):
            return String(
                format: L10n.t("action_center_inbox_group_days_ago_format", languageCode: languageCode),
                locale: locale,
                Int64(days)
            )
        case .calendarDay(let day):
            return FanGeoInboxTimeFormatting.monthDay(day, languageCode: languageCode, calendar: calendar)
        case .older:
            return L10n.t("action_center_inbox_group_older", languageCode: languageCode)
        }
    }

    /// Card header timestamp. Today uses clock time (mockup); other days reuse relative copy.
    static func cardTimestampLabel(
        for item: FanGeoActionItem,
        languageCode: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        guard let date = authoritativeTimestamp(for: item) else { return "" }
        if calendar.isDate(date, inSameDayAs: now) {
            return FanGeoInboxTimeFormatting.shortTime(date, languageCode: languageCode)
        }
        return FanGeoActionCenterCopy.relativeTimestampLabel(
            for: item,
            languageCode: languageCode,
            now: now
        ) ?? ""
    }

    static func authoritativeTimestamp(for item: FanGeoActionItem) -> Date? {
        item.timestamp ?? item.context.relativeTimestamp ?? item.context.eventStartAt
    }
}

nonisolated enum FanGeoInboxTimeFormatting {
    private struct Cache {
        var time: [String: DateFormatter] = [:]
        var monthDay: [String: DateFormatter] = [:]
    }

    private static let cache = OSAllocatedUnfairLock(initialState: Cache())

    static func shortTime(_ date: Date, languageCode: String) -> String {
        let code = L10n.normalizedLanguageCode(languageCode)
        return cache.withLock { state in
            let formatter: DateFormatter
            if let existing = state.time[code] {
                formatter = existing
            } else {
                let created = DateFormatter()
                created.locale = Locale(identifier: code)
                created.timeStyle = .short
                created.dateStyle = .none
                state.time[code] = created
                formatter = created
            }
            return formatter.string(from: date)
        }
    }

    static func monthDay(_ date: Date, languageCode: String, calendar: Calendar) -> String {
        let code = L10n.normalizedLanguageCode(languageCode)
        let cacheKey = "\(code)|\(calendar.timeZone.identifier)"
        return cache.withLock { state in
            if let existing = state.monthDay[cacheKey] {
                return existing.string(from: date)
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: code)
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
            state.monthDay[cacheKey] = formatter
            return formatter.string(from: date)
        }
    }
}
