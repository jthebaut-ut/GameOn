import Foundation

/// DEBUG breadcrumb trail for Discover → Pickup detail presentation / termination.
///
/// iOS 26 can terminate on `String(format:)` type mismatches without firing
/// Swift `fatalError` / `abort` breakpoints. These markers identify the last
/// successful step before process death.
enum PickupDetailCrashTrace {
    static func log(_ stage: String, gameId: UUID? = nil, title: String? = nil) {
#if DEBUG
        var parts: [String] = ["[PickupDetailCrashTrace]", stage]
        if let gameId {
            parts.append("gameId=\(gameId.uuidString.lowercased())")
        }
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                parts.append("title=\(trimmed)")
            }
        }
        print(parts.joined(separator: " "))
#endif
    }
}

/// POSIX float formatting that never passes `Int` / `CGFloat` into `%.Nf` specifiers.
/// iOS 26 validates `String(format:locale:arguments:)` and terminates on type mismatch
/// (`Format '%.3f' does not match expected '%lld'` when an `Int` is supplied).
nonisolated enum FanGeoFixedFloatFormat {
    static func string(_ value: Double, decimals: Int) -> String {
        let clamped = max(0, min(decimals, 9))
        let format = "%.\(clamped)f"
        return String(format: format, locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func d3(_ value: Double) -> String { string(value, decimals: 3) }
    static func d4(_ value: Double) -> String { string(value, decimals: 4) }
}
